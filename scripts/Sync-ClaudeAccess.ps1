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
    .\Sync-ClaudeAccess.ps1 -ApimName apim-claude-gw-xxxx -ResourceGroup rg-contosohub
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ApimName,
    [Parameter(Mandatory = $true)][string]$ResourceGroup,
    [string]$StandardGroup = 'claude-code-standard',
    [string]$PremiumGroup = 'claude-code-premium',
    [string[]]$AdditionalStandardOids = @(),
    [string[]]$AdditionalPremiumOids = @(),
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'

function Get-GroupMemberOids {
    param([string]$GroupName)

    $gid = az ad group show --group $GroupName --query id -o tsv 2>$null
    if (-not $gid) {
        Write-Warning "Group '$GroupName' not found - treating as empty."
        return @()
    }

    # Transitive membership so nested groups work the way admins expect.
    $raw = az rest --method get `
        --uri "https://graph.microsoft.com/v1.0/groups/$gid/transitiveMembers?`$select=id,displayName,userPrincipalName&`$top=999" `
        --headers "Content-Type=application/json" 2>$null | ConvertFrom-Json

    $members = @()
    foreach ($m in $raw.value) {
        $members += [pscustomobject]@{
            Oid  = $m.id
            Name = if ($m.userPrincipalName) { $m.userPrincipalName } else { $m.displayName }
        }
    }
    return $members
}

function Set-NamedValue {
    param([string]$Id, [string]$Value)

    if ($WhatIf) {
        Write-Host "  [WhatIf] $Id = $Value" -ForegroundColor DarkGray
        return
    }

    $existing = az apim nv show -g $ResourceGroup --service-name $ApimName --named-value-id $Id -o json 2>$null
    if ($existing) {
        az apim nv update -g $ResourceGroup --service-name $ApimName --named-value-id $Id --value $Value -o none 2>$null
    }
    else {
        az apim nv create -g $ResourceGroup --service-name $ApimName --named-value-id $Id --display-name $Id --value $Value -o none 2>$null
    }
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
foreach ($t in $tiers) {
    $members = @(Get-GroupMemberOids -GroupName $t.Group)

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
    Set-NamedValue -Id $t.NamedValue -Value $value
    Write-Host ""
}

Write-Host "Done. $($seen.Count) identity(ies) authorised." -ForegroundColor Green
Write-Host "Anyone not listed receives HTTP 403 from the gateway." -ForegroundColor DarkGray
Write-Host ""
