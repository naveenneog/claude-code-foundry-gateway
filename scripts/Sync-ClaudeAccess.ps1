<#
.SYNOPSIS
    Syncs Microsoft Entra ID group membership into API Management named values,
    which the Claude gateway policy uses for authorization and tiering.

.DESCRIPTION
    Microsoft Entra security groups are the source of truth for who may use
    Claude Code and at which tier. The gateway cannot read group membership
    directly from the caller's token: Claude Code requests its token for the
    Cognitive Services data plane, and that first-party audience does not carry
    a `groups` claim we can configure.

    Two ways to close that gap:

      1. This script. It resolves each group's members to object ids and writes
         them into APIM named values. No tenant-admin consent required. Run it
         on a schedule (or from your joiner/mover/leaver automation).

      2. Have the gateway call Microsoft Graph per request. That removes the
         sync lag but needs an admin to grant the APIM managed identity the
         GroupMember.Read.All application permission, which requires tenant
         admin consent. See README-governance.md.

    Object ids are used rather than UPNs because the `oid` claim is immutable:
    it survives renames and email changes, and it is what the policy meters on.

.EXAMPLE
    .\Sync-ClaudeAccess.ps1 -ApimName <apim-name> -ResourceGroup <resource-group>
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ApimName,
    [Parameter(Mandatory = $true)][string]$ResourceGroup,
    [string]$StandardGroup = 'claude-code-standard',
    [string]$PremiumGroup = 'claude-code-premium',
    [string[]]$AdditionalStandardOids = @(),
    [string[]]$AdditionalPremiumOids = @(),
    [switch]$AllowEmpty,
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'ApimNamedValue.ps1')

. (Join-Path $PSScriptRoot 'ClaudeGraphMembership.ps1')

function Set-NamedValue {
    param([string]$Id, [string]$Value)

    if ($WhatIf) {
        Write-Host "  [WhatIf] $Id = $Value" -ForegroundColor DarkGray
        return
    }

    # Writes through the shared helper, which refuses an oversized value and
    # throws on a failed write. This used to shell out with `2>$null` and no
    # exit check, so a named value too large to store failed silently and the
    # sync went on reporting success while entitlement stopped updating.
    Set-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id $Id -Value $Value
}

Write-Host ""
Write-Host "Syncing Entra group membership -> APIM named values" -ForegroundColor Cyan
Write-Host "  APIM : $ApimName ($ResourceGroup)"
Write-Host ""

$tiers = @(
    @{ Name = 'premium';  Group = $PremiumGroup;  NamedValue = 'allow-premium';  Extra = $AdditionalPremiumOids },
    @{ Name = 'standard'; Group = $StandardGroup; NamedValue = 'allow-standard'; Extra = $AdditionalStandardOids }
)

$seen = @{}
$graphToken = Get-GraphToken

foreach ($t in $tiers) {
    $members = @(Get-GroupMemberOids -GroupName $t.Group -Token $graphToken)

    # Service principals in a group are invisible to a delegated token without
    # Application.Read.All, so CI/service identities are supplied explicitly.
    foreach ($oid in $t.Extra) {
        if ($oid) { $members += [pscustomobject]@{ Oid = $oid; Name = 'service principal (explicit)' } }
    }

    # A member of both groups gets the higher tier only, so the counter keys
    # stay unambiguous. Premium is processed first for that reason.
    $effective = @()
    foreach ($m in $members) {
        if ($seen.ContainsKey($m.Oid)) {
            Write-Host ("  {0,-9} {1}  (already {2}, skipped)" -f '', $m.Name, $seen[$m.Oid]) -ForegroundColor DarkGray
            continue
        }
        $seen[$m.Oid] = $t.Name
        $effective += $m
    }

    Write-Host ("$($t.Group)  ->  $($effective.Count) member(s)") -ForegroundColor Yellow
    foreach ($m in $effective) {
        Write-Host ("  {0,-38} {1}" -f $m.Oid, $m.Name)
    }

    # Comma-delimited with sentinels so the policy can do a simple contains()
    # without matching a partial id.
    $value = if ($effective.Count) { ',' + (($effective.Oid) -join ',') + ',' } else { ',' }

    # Writing an empty list revokes everyone in that tier. That is a legitimate
    # thing to want, but it is also exactly what a failed lookup used to
    # produce silently - so it now has to be deliberate. Refuse if the tier is
    # resolving to empty while APIM still holds entries for it.
    if (-not $effective.Count -and -not $AllowEmpty -and -not $WhatIf) {
        $current = az apim nv show -g $ResourceGroup --service-name $ApimName `
            --named-value-id $t.NamedValue --query value -o tsv 2>$null
        if ($current -and $current.Trim().Trim(',')) {
            Write-Host ''
            Write-Warning ("$($t.Group) resolved to 0 members, but '$($t.NamedValue)' currently entitles " +
                           "$(($current.Trim(',') -split ',').Count). Not overwriting.")
            Write-Host "  If the group really is empty, re-run with -AllowEmpty." -ForegroundColor DarkGray
            Write-Host "  Otherwise check the group name and that you can read its membership." -ForegroundColor DarkGray
            Write-Host ''
            continue
        }
    }

    Set-NamedValue -Id $t.NamedValue -Value $value
    Write-Host ""
}

# ------------------------------------------------------- business units
#
# Membership for chargeback, from the same groups mechanism as tiers. The
# registry says which Entra group backs each business unit; this resolves those
# groups to object ids and writes the ,oid=id, map the policy reads.
#
# A developer in two business-unit groups at the same depth takes the first in
# registry order, which is deterministic and visible in the registry. See
# ADR-0007.
#
# Teams are resolved before the business units that contain them. An Entra group
# can contain another group, so claude-bu-mcaps transitively contains everyone in
# claude-team-ites-1 and a developer matches both. Charging them to the most
# specific unit is what makes the cascade meaningful: the team is charged, and
# the parent is charged through the cascade rather than through membership. See
# ADR-0008.

. (Join-Path $PSScriptRoot 'ClaudeBusinessUnit.ps1')

$registryRaw = Get-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id 'bu-registry'
$registry = @(ConvertFrom-ClaudeBuRegistry $registryRaw)

$parentsRaw = Get-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id 'bu-parents'
$parents = ConvertFrom-ClaudeBuParents $parentsRaw

if (-not $registry.Count) {
    Write-Host "No business units defined, so nothing to map." -ForegroundColor DarkGray
    Write-Host "  Add one with ./scripts/Set-ClaudeBusinessUnit.ps1." -ForegroundColor DarkGray
    Write-Host ""
}
else {
    Write-Host "Business unit membership" -ForegroundColor Cyan

    # Deepest first, so a team wins over the business unit that contains it.
    $ordered = @(Sort-ClaudeBuByDepth $registry -Parents $parents)

    $buMap = [ordered]@{}
    $resolvedAny = $false
    foreach ($bu in $ordered) {
        $buMembers = @(Get-GroupMemberOids -GroupName $bu.Group -Token $graphToken)
        $depth = Resolve-ClaudeBuDepth -Id $bu.Id -Parents $parents
        $label = if ($depth -gt 0) { "$($bu.Id)  (team of $($parents[$bu.Id]))" } else { $bu.Id }
        Write-Host ("  {0,-26} {1,-30} {2} member(s)" -f $label, $bu.Group, $buMembers.Count) -ForegroundColor Yellow
        if ($buMembers.Count) { $resolvedAny = $true }
        foreach ($m in $buMembers) {
            # First business unit in registry order wins.
            if (-not $buMap.Contains($m.Oid)) { $buMap[$m.Oid] = $bu.Id }
        }
    }

    $buValue = ConvertTo-ClaudeBuMembers $buMap

    # Same guard as entitlement: a lookup that resolved nothing must not wipe a
    # map that currently assigns people, because the result is silent and the
    # symptom is spend landing on no budget.
    $currentBu = Get-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id 'bu-members'
    $currentCount = @(ConvertFrom-ClaudeBuMembers $currentBu).Keys.Count

    if (-not $buMap.Keys.Count -and -not $AllowEmpty -and -not $WhatIf -and $currentCount) {
        Write-Host ''
        Write-Warning ("Business unit groups resolved to 0 members, but 'bu-members' currently maps $currentCount. Not overwriting.")
        Write-Host "  If they really are empty, re-run with -AllowEmpty." -ForegroundColor DarkGray
        Write-Host ''
    }
    else {
        Set-NamedValue -Id 'bu-members' -Value $buValue
        Write-Host ("  {0} developer(s) mapped to a business unit." -f $buMap.Keys.Count) -ForegroundColor Green
    }

    $unmapped = @($seen.Keys | Where-Object { -not $buMap.Contains($_) })
    if ($unmapped.Count) {
        Write-Host ("  {0} entitled developer(s) belong to no business unit." -f $unmapped.Count) -ForegroundColor Yellow
        Write-Host "  Their usage is recorded against 'unassigned' and counts against no budget." -ForegroundColor DarkGray
    }
    Write-Host ""
}

Write-Host "Done. $($seen.Count) identity(ies) authorised." -ForegroundColor Green
Write-Host "Anyone not listed receives HTTP 403 from the gateway." -ForegroundColor DarkGray
Write-Host ""
