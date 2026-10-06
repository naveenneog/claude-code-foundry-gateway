<#
.SYNOPSIS
    Updates a gateway deployed by an older accelerator release to the current release.

.DESCRIPTION
    Plans the ordered migrations in scripts\flow\migrations and prints a fingerprinted plan. It writes only with
    -Apply and the plan's fingerprint, after a backup. Migration 0004 moves a gateway that serves entitlement from
    named values to the Cosmos projection (ADR-0054). Its plan finds the gateway's previous tier groups, business
    units and entitlement, checks the subscription's readiness, and shows the resources, network and cost. Without
    a decision record, -ResourceGroup and -ApimName name the gateway, and the apply writes the record.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$RecordPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'onboarding\claude-gateway.json'),
    [string]$DiscoveryPath,
    [string]$ResourceGroup,
    [string]$ApimName,
    [switch]$Apply,
    [string]$ApprovedPlanFingerprint,
    [string]$SnapshotPath,
    # The move to the Cosmos projection (ADR-0054). The previous values come from the gateway and its record;
    # these override them.
    [string]$StandardGroup,
    [string]$PremiumGroup,
    [string]$NamePrefix,
    [ValidateSet('', 'public', 'private')][string]$ResolverInboundAccess = '',
    [switch]$KeepNamedValues
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'flow\FlowContract.ps1')
. (Join-Path $PSScriptRoot 'flow\lib\LifecycleCommon.ps1')

if (-not (Test-Path -LiteralPath $RecordPath)) {
    if (-not ($ResourceGroup -and $ApimName)) {
        Write-Warning "No decision record found at '$RecordPath'. Nothing can be updated until setup has written the record."
        return [pscustomobject]@{ Plans = @(); Fingerprint = ''; SnapshotPath = $null; MissingRecord = $true }
    }
    Write-Host "No decision record at '$RecordPath'. The plan reads the live gateway $ApimName, and the apply writes the record." -ForegroundColor DarkGray
    $record = [pscustomobject]@{ resourceGroup = $ResourceGroup; apimName = $ApimName }
}
else { $record = Read-ClaudeDecisionRecord -Path $RecordPath }
$discovery = Import-ClaudeFlowLifecycleDiscovery -Path $DiscoveryPath
if (-not $discovery) {
    $target = Get-ClaudeFlowLifecycleRecordTarget -Record $record
    if ($ResourceGroup) { $target.ResourceGroup = $ResourceGroup }
    if ($ApimName) { $target.ApimName = $ApimName }
    $discovery = Get-ClaudeFlowLifecycleLiveDiscovery -ResourceGroup $target.ResourceGroup -ApimName $target.ApimName
    # Migration 0004 renders facts read here, from the live gateway, Microsoft Graph and the subscription.
    . (Join-Path $PSScriptRoot 'ApimNamedValue.ps1')
    . (Join-Path $PSScriptRoot 'ClaudeRunner.ps1')
    . (Join-Path $PSScriptRoot 'ClaudeProjectionChecks.ps1')
    . (Join-Path $PSScriptRoot 'ClaudeProjectionReadiness.ps1')
    . (Join-Path $PSScriptRoot 'ClaudeProjectionInventory.ps1')
    . (Join-Path $PSScriptRoot 'ClaudeEntitlementMigration.ps1')
    $factParameters = @{ Discovery = $discovery; Record = $record; StandardGroup = $StandardGroup; PremiumGroup = $PremiumGroup
        NamePrefix = $NamePrefix; ResolverInboundAccess = $ResolverInboundAccess; KeepNamedValues = [bool]$KeepNamedValues }
    try { $facts = Get-ClaudeEntitlementMigrationFacts @factParameters }
    catch { $facts = New-ClaudeEntitlementMigrationFailure -Discovery $discovery -Message $_.Exception.Message }
    $discovery | Add-Member -NotePropertyName entitlementMigration -NotePropertyValue $facts -Force
    if ($facts.Needed -and @($facts.Checks).Count) {
        Write-Host ''
        Write-Host 'Readiness evidence for the move to the Cosmos projection (shown here, not part of the plan fingerprint):' -ForegroundColor Cyan
        foreach ($check in @($facts.Checks)) { Write-Host ("  {0,-4} {1}: {2}" -f $check.Result, $check.Name, $check.Evidence) }
    }
}
$target = Get-ClaudeFlowLifecycleRecordTarget -Record $record -Discovery $discovery
if (-not $SnapshotPath) {
    $SnapshotPath = Join-Path $root "backups\before-update-$($target.ApimName).json"
}

# Code-point order: the migrations' order feeds the plan's fingerprint (P76).
$migrationFiles = @(Sort-ClaudeFlowOrdinal -InputObject @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'flow\migrations') -Filter '*.ps1') -Key { $_.Name })
$plans = @()
foreach ($file in $migrationFiles) {
    . $file.FullName
    $plan = Get-ClaudeFlowMigrationPlan -Record $record -Discovery $discovery
    if ($plan.Data -is [hashtable]) {
        $plan.Data.SnapshotPath = $SnapshotPath
        $plan.Data.SnapshotTaken = $false
    }
    $plans += $plan
}
$fingerprint = Get-ClaudeFlowFingerprint -Plans $plans
Format-ClaudeFlowReview -Plans $plans
Write-Host ''
Write-Host "Plan fingerprint: $fingerprint" -ForegroundColor Cyan
$blocked = @($plans | Where-Object { $_.Data -is [hashtable] -and $_.Data.Blocked })

if (-not $Apply -or $WhatIfPreference) {
    if ($blocked.Count) {
        Write-Host "Plan only, and blocked in $(@($blocked | ForEach-Object Step) -join ', '): nothing can be applied until the BLOCKED items are fixed and the plan is made again." -ForegroundColor Yellow
    }
    else {
        $parts = @('.\Update-ClaudeGateway.ps1')
        foreach ($name in 'RecordPath', 'DiscoveryPath', 'ResourceGroup', 'ApimName', 'SnapshotPath', 'StandardGroup', 'PremiumGroup', 'NamePrefix', 'ResolverInboundAccess') {
            if ($PSBoundParameters.ContainsKey($name) -and $PSBoundParameters[$name]) { $parts += "-$name $(ConvertTo-ClaudeFlowCommandArgument $PSBoundParameters[$name])" }
        }
        if ($KeepNamedValues) { $parts += '-KeepNamedValues' }
        Write-Host 'Plan only. Nothing has been changed. Add -Apply with -ApprovedPlanFingerprint to write; for this plan:' -ForegroundColor Cyan
        Write-Host ("  " + (($parts + @('-Apply', "-ApprovedPlanFingerprint $fingerprint")) -join ' '))
    }
    return [pscustomobject]@{ Plans = $plans; Fingerprint = $fingerprint; SnapshotPath = $SnapshotPath }
}
if ($blocked.Count) {
    throw "The plan is blocked in $(@($blocked | ForEach-Object Step) -join ', '); nothing was written. Fix the BLOCKED items shown above and plan again."
}
if ($ApprovedPlanFingerprint -ne $fingerprint) {
    throw "Approved plan fingerprint does not match. Expected $fingerprint."
}
if (-not $PSCmdlet.ShouldProcess($target.ApimName, 'apply ordered gateway update migrations')) { return }

foreach ($file in $migrationFiles) {
    . $file.FullName
    $plan = @($plans | Where-Object Step -eq (Get-ClaudeFlowMigrationInfo).Name)[0]
    Invoke-ClaudeFlowMigration -Record $record -Plan $plan | Out-Null
    if (-not $DiscoveryPath -and -not (Test-ClaudeFlowPlanIsNoop $plan)) {
        $discovery = Get-ClaudeFlowLifecycleLiveDiscovery -ResourceGroup $target.ResourceGroup -ApimName $target.ApimName
    }
    # A migration whose verification needs its own plan (0004: nothing to verify when no move was planned) takes it.
    $check = if ((Get-Command Test-ClaudeFlowMigration).Parameters.ContainsKey('Plan')) { Test-ClaudeFlowMigration -Record $record -Discovery $discovery -Plan $plan }
        else { Test-ClaudeFlowMigration -Record $record -Discovery $discovery }
    if (-not $check.Passed) {
        throw "Migration '$($plan.Step)' did not verify. Roll back with Restore-ClaudeGateway.ps1 -Path '$SnapshotPath' -Apply."
    }
}
$release = Get-ClaudeFlowReleaseInfo
Set-ClaudeDecisionRelease -Record $record -Version $release.version -Commit $release.commit
Write-ClaudeDecisionRecord -Record $record -Path $RecordPath
Write-Host "Updated. Snapshot: $SnapshotPath" -ForegroundColor Green
