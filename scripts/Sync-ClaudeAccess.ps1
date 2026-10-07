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
    [string]$StandardGroup,
    [string]$PremiumGroup,
    [string[]]$AdditionalStandardOids = @(),
    [string[]]$AdditionalPremiumOids = @(),
    [switch]$AllowEmpty,
    [switch]$AllowEmptyStandard,
    [switch]$AllowEmptyPremium,
    [switch]$WhatIf,
    [ValidateSet('auto','named-value','projection')][string]$Store = 'auto',
    [string]$User,
    [switch]$RecordGroups
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'ApimNamedValue.ps1')

. (Join-Path $PSScriptRoot 'ClaudeGraphMembership.ps1')
. (Join-Path $PSScriptRoot 'ClaudeEntitlementGroups.ps1')

function Invoke-ClaudeProjectionAccessSync {
    param(
        [string]$ApimName, [string]$ResourceGroup, [string]$StandardGroup, [string]$PremiumGroup,
        [string]$User, [switch]$AllowEmpty, [switch]$WhatIf
    )
    . (Join-Path $PSScriptRoot 'ClaudeRunner.ps1')
    . (Join-Path $PSScriptRoot 'ClaudeProjectionPackage.ps1')
    $prefix = Get-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id 'entitlement-projection-prefix' -FailOnError
    if ([string]::IsNullOrWhiteSpace($prefix)) {
        throw ("API Management $ApimName has no named value 'entitlement-projection-prefix', which names the projection to sync. " +
            "Remedy: .\scripts\Deploy-ClaudeProjection.ps1 -ResourceGroup $ResourceGroup -ApimName $ApimName -NamePrefix <prefix>, with the -Sku, " +
            "-ResolverInboundAccess, -StandardGroup and -PremiumGroup the projection was deployed with; it records the named value. Nothing was written.")
    }
    if ($prefix -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') { throw "Projection prefix '$prefix' is unsafe." }
    $apim = az apim show -g $ResourceGroup -n $ApimName -o json | ConvertFrom-Json
    if (-not $apim -or -not $apim.identity -or -not $apim.identity.tenantId) { throw 'Could not read the APIM managed identity tenant id for projection sync.' }
    $tenantId = [string]$apim.identity.tenantId
    if ($tenantId -notmatch '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$') { throw 'APIM identity tenant id is not a GUID.' }
    $subscriptionId = @([string]$apim.id -split '/')[2]
    if ($subscriptionId -notmatch '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$') { throw 'APIM resource id did not contain a subscription GUID.' }
    $accountResourceId = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.DocumentDB/databaseAccounts/cosmos-$prefix"
    $work = Join-Path ([IO.Path]::GetTempPath()) ('claude-projection-sync-' + [guid]::NewGuid().ToString('N'))
    $runner = $null
    # Each run has its own snapshot file on the shared runner, so concurrent runs never apply each other's file.
    $remoteSnapshot = "/work/projection-snapshot-$([guid]::NewGuid().ToString('N')).json"
    $null = New-Item -ItemType Directory -Path $work -Force
    try {
        $snapshot = Join-Path $work 'projection-snapshot.json'
        $exportArgs = @('-NoProfile','-File',(Join-Path $PSScriptRoot 'Sync-ClaudeProjection.ps1'),
            '-Account',"cosmos-$prefix",'-TenantId',$tenantId,'-StandardGroup',$StandardGroup,'-PremiumGroup',$PremiumGroup,
            '-ApimName',$ApimName,'-ResourceGroup',$ResourceGroup,'-ExportPath',$snapshot)
        if ($User) { $exportArgs += @('-User',$User) }
        $exportOutput = & pwsh @exportArgs 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Projection snapshot export failed (exit $LASTEXITCODE): $(($exportOutput | Select-Object -Last 12) -join "`n")" }
        $targetUserOid = $null
        $targetSnapshotRecord = $null
        if ($User) {
            $snap = Get-Content -LiteralPath $snapshot -Raw | ConvertFrom-Json
            if (-not $snap.user -or [string]$snap.scope -ne 'user') { throw 'Targeted projection export did not produce a user-scoped snapshot.' }
            $targetUserOid = [string]$snap.user
            $targetSnapshotRecord = @($snap.records | Where-Object { [string]$_.oid -eq $targetUserOid } | Select-Object -First 1)
        }
        if ($WhatIf) {
            Write-Host "  [WhatIf] Projection snapshot exported to $snapshot; runner was not started and Cosmos was not changed." -ForegroundColor DarkGray
            if ($targetUserOid) {
                $publishedTier = if ($targetSnapshotRecord -and $targetSnapshotRecord.tier) { [string]$targetSnapshotRecord.tier } else { 'none' }
                Write-Host "Developer tier as written: $publishedTier" -ForegroundColor Green
                Write-Host "Microsoft Graph can report a membership change a few minutes late; if this developer's groups changed just now and the tier is the previous one, run this command again." -ForegroundColor DarkGray
                [pscustomobject]@{ published_tier = $publishedTier; user = $targetUserOid }
            }
            return
        }
        $runner = "aci-projtest-$prefix"
        $null = Start-ClaudeProjectionRunner -ResourceGroup $ResourceGroup -Name $runner
        $archive = Join-Path $work 'sync-package.tgz'
        $null = New-ClaudeProjectionSyncArchive -Path $archive -Root (Split-Path $PSScriptRoot -Parent)
        $null = Send-RunnerFile -ResourceGroup $ResourceGroup -Name $runner -Path $archive -Destination '/work/sync-package.tgz'
        $null = Invoke-RunnerCommand -ResourceGroup $ResourceGroup -Name $runner -Command 'tar -xzf /work/sync-package.tgz -C /work'
        $null = Send-RunnerFile -ResourceGroup $ResourceGroup -Name $runner -Path $snapshot -Destination $remoteSnapshot -Deadline (Get-RunnerFileDeadline -Path $snapshot)
        $nodeModules = Invoke-RunnerCommand -ResourceGroup $ResourceGroup -Name $runner -Command "node -e console.log(require('fs').existsSync('/work/sync/node_modules')?'present':'absent')"
        if (($nodeModules -split '\r?\n' | Select-Object -Last 1).Trim() -ne 'present') {
            $null = Invoke-RunnerCommand -ResourceGroup $ResourceGroup -Name $runner -Command 'npm --prefix /work/sync ci --omit=dev --ignore-scripts --no-audit --fund=false'
        }
        $command = "node /work/sync/src/apply-projection.mjs --cosmos https://cosmos-$prefix.documents.azure.com:443/ --tenant $tenantId --account-resource-id $accountResourceId --snapshot $remoteSnapshot"
        if ($targetUserOid) { $command += " --user $targetUserOid" }
        if ($AllowEmpty) { $command += ' --allow-empty' }
        $raw = Invoke-RunnerCommand -ResourceGroup $ResourceGroup -Name $runner -Command $command
        $result = ConvertFrom-ClaudeRunnerResult -RawOutput $raw -Step 'projection apply'
        Write-Host ("Projection sync complete: written={0} deleted={1} unchanged={2}" -f ([int]$result.written), ([int]$result.deleted), ([int]$result.unchanged)) -ForegroundColor Green
        if ($targetUserOid) {
            $appliedRecord = $null
            if ($result.PSObject.Properties['userRecord']) { $appliedRecord = $result.userRecord }
            $publishedTier = if ($appliedRecord -and $appliedRecord.PSObject.Properties['tier'] -and $appliedRecord.tier) { [string]$appliedRecord.tier }
                elseif ($targetSnapshotRecord -and $targetSnapshotRecord.tier) { [string]$targetSnapshotRecord.tier }
                else { 'none' }
            Write-Host "Developer tier as written: $publishedTier" -ForegroundColor Green
            Write-Host "Microsoft Graph can report a membership change a few minutes late; if this developer's groups changed just now and the tier is the previous one, run this command again." -ForegroundColor DarkGray
            [pscustomobject]@{ published_tier = $publishedTier; user = $targetUserOid }
        }
        $excluded = [int]$result.excludedByNewerTargetedSync
        if ($excluded -gt 0) {
            Write-Host ("  {0} user(s) changed by a targeted sync while this full sync ran were left out of it (ADR-0051 decision 11). Remedy: rerun scripts/Sync-ClaudeAccess.ps1 -ResourceGroup {1} -ApimName {2} after five minutes, or with -User for each of them." -f $excluded, $ResourceGroup, $ApimName) -ForegroundColor Yellow
        }
    }
    finally {
        if ($runner) {
            try {
                $null = Invoke-RunnerCommand -ResourceGroup $ResourceGroup -Name $runner -Command "node -e f=require('fs');f.rmSync('$remoteSnapshot',{force:true});f.rmSync('/work/projection-snapshot.json',{force:true});f.rmSync('/work/gateway-decisions.json',{force:true})"
            } catch { }
        }
        if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -WhatIf:$false -ErrorAction SilentlyContinue }
    }
}

$selectedStore = $Store
if ($selectedStore -eq 'auto') {
    $source = Get-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id 'entitlement-source' -FailOnError
    $selectedStore = if ($source -eq 'projection') { 'projection' } else { 'named-value' }
}

$graphToken = Get-GraphToken
$groupResolution = Resolve-ClaudeEntitlementGroupsForSync -ResourceGroup $ResourceGroup -ApimName $ApimName -StandardGroup $StandardGroup -PremiumGroup $PremiumGroup `
    -GetNamedValue { param($Id) Get-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id $Id -FailOnError } `
    -FindGroup { param($Value) Get-ClaudeGraphGroup -GroupName $Value -Token $graphToken }

function Assert-RecordGroupChangeAllowed {
    param([string]$Tier, [string]$Explicit, [string]$Recorded, [string]$Resolved)
    if (-not $Explicit -or -not $Recorded) { return }
    if ([string]::Equals($Recorded, $Resolved, [StringComparison]::OrdinalIgnoreCase)) { return }
    if ($RecordGroups) { return }
    $switch = if ($Tier -eq 'standard') { '-StandardGroup' } else { '-PremiumGroup' }
    throw "The gateway records $Tier group '$Recorded' in entitlement-groups, but $switch resolved to '$Resolved'. Remedy: rerun with -RecordGroups to replace entitlement-groups after a successful sync. Nothing was written."
}
Assert-RecordGroupChangeAllowed -Tier standard -Explicit $StandardGroup -Recorded ([string]$groupResolution.Recorded['standard']) -Resolved ([string]$groupResolution.Standard.Id)
Assert-RecordGroupChangeAllowed -Tier premium -Explicit $PremiumGroup -Recorded ([string]$groupResolution.Recorded['premium']) -Resolved ([string]$groupResolution.Premium.Id)

$StandardGroup = [string]$groupResolution.Standard.Argument
$PremiumGroup = [string]$groupResolution.Premium.Argument
$targetUserOid = if ($User) { Resolve-ClaudeGraphUserObjectId -Identity $User -Token $graphToken } else { '' }

function Get-ClaudeNamedValueTierForUser {
    param([string]$UserObjectId, [string]$StandardList, [string]$PremiumList)
    $needle = ",$($UserObjectId.ToLowerInvariant()),"
    if (([string]$PremiumList).ToLowerInvariant().Contains($needle)) { return 'premium' }
    if (([string]$StandardList).ToLowerInvariant().Contains($needle)) { return 'standard' }
    return 'none'
}

function Set-ClaudeEntitlementGroupsIfNeeded {
    if ($WhatIf) { return }
    $wanted = ConvertTo-ClaudeEntitlementGroups -StandardId ([string]$groupResolution.Standard.Id) -PremiumId ([string]$groupResolution.Premium.Id)
    if ($RecordGroups -or -not $groupResolution.Raw -or $groupResolution.Raw -ne $wanted) {
        Set-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id 'entitlement-groups' -Value $wanted
    }
}

if ($selectedStore -eq 'projection') {
    Invoke-ClaudeProjectionAccessSync -ApimName $ApimName -ResourceGroup $ResourceGroup -StandardGroup $StandardGroup -PremiumGroup $PremiumGroup -User $User -AllowEmpty:$AllowEmpty -WhatIf:$WhatIf
    Set-ClaudeEntitlementGroupsIfNeeded
    return
}

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
# Every value is resolved and checked against the 4,096-character limit before the first write, so a list
# that does not fit leaves every named value as it was, rather than some lists refreshed beside others stale.
$pendingWrites = [Collections.Generic.List[object]]::new()
$skippedTierWrites = [Collections.Generic.List[string]]::new()
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
    $allowEmptyTier = $AllowEmpty -or ($t.Name -eq 'standard' -and $AllowEmptyStandard) -or ($t.Name -eq 'premium' -and $AllowEmptyPremium)
    if (-not $effective.Count -and -not $allowEmptyTier -and -not $WhatIf) {
        $current = az apim nv show -g $ResourceGroup --service-name $ApimName `
            --named-value-id $t.NamedValue --query value -o tsv 2>$null
        if ($current -and $current.Trim().Trim(',')) {
            Write-Host ''
            Write-Warning ("$($t.Group) resolved to 0 members, but '$($t.NamedValue)' currently entitles " +
                           "$(($current.Trim(',') -split ',').Count). Not overwriting.")
            Write-Host "  If the group really is empty, re-run with -AllowEmpty." -ForegroundColor DarkGray
            Write-Host "  Otherwise check the group name and that you can read its membership." -ForegroundColor DarkGray
            Write-Host ''
            $skippedTierWrites.Add($t.Name)
            continue
        }
    }

    $pendingWrites.Add([pscustomobject]@{ Id = $t.NamedValue; Value = $value })
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
        $pendingWrites.Add([pscustomobject]@{ Id = 'bu-members'; Value = $buValue })
        Write-Host ("  {0} developer(s) to map to a business unit." -f $buMap.Keys.Count) -ForegroundColor Green
    }

    $unmapped = @($seen.Keys | Where-Object { -not $buMap.Contains($_) })
    if ($unmapped.Count) {
        Write-Host ("  {0} entitled developer(s) belong to no business unit." -f $unmapped.Count) -ForegroundColor Yellow
        Write-Host "  Their usage is recorded against 'unassigned' and counts against no budget." -ForegroundColor DarkGray
    }
    Write-Host ""
}

foreach ($write in $pendingWrites) { Test-ApimNamedValueLength -Id $write.Id -Value $write.Value }
foreach ($write in $pendingWrites) { Set-NamedValue -Id $write.Id -Value $write.Value }
Set-ClaudeEntitlementGroupsIfNeeded

if ($targetUserOid) {
    $standardList = if ($WhatIf) { [string]@($pendingWrites | Where-Object Id -eq 'allow-standard' | Select-Object -First 1).Value } else { Get-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id 'allow-standard' -FailOnError }
    $premiumList = if ($WhatIf) { [string]@($pendingWrites | Where-Object Id -eq 'allow-premium' | Select-Object -First 1).Value } else { Get-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id 'allow-premium' -FailOnError }
    $publishedTier = Get-ClaudeNamedValueTierForUser -UserObjectId $targetUserOid -StandardList $standardList -PremiumList $premiumList
    Write-Host "Developer tier as written: $publishedTier" -ForegroundColor Green
    if ($skippedTierWrites.Count) {
        Write-Host "A tier write was skipped by the empty-tier guard; rerun with -AllowEmptyStandard, -AllowEmptyPremium or -AllowEmpty if the group really is empty." -ForegroundColor DarkGray
    }
    else {
        Write-Host "Microsoft Graph can report a membership change a few minutes late; if this developer's groups changed just now and the tier is the previous one, run this command again." -ForegroundColor DarkGray
    }
    [pscustomobject]@{ published_tier = $publishedTier; user = $targetUserOid }
}

Write-Host "Done. $($seen.Count) identity(ies) authorised." -ForegroundColor Green
Write-Host "Anyone not listed receives HTTP 403 from the gateway." -ForegroundColor DarkGray
Write-Host ""
