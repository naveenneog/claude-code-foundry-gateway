<#
.SYNOPSIS
    Updates a gateway deployed by an older accelerator release to the current release.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$RecordPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'onboarding\claude-gateway.json'),
    [string]$DiscoveryPath,
    [string]$ResourceGroup,
    [string]$ApimName,
    [switch]$Apply,
    [string]$ApprovedPlanFingerprint,
    [string]$SnapshotPath
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'flow\FlowContract.ps1')
. (Join-Path $PSScriptRoot 'flow\LifecycleCommon.ps1')

if (-not (Test-Path -LiteralPath $RecordPath)) {
    throw "No decision record found at '$RecordPath'. Pass -RecordPath or run the guided setup first."
}
$record = Read-ClaudeDecisionRecord -Path $RecordPath
$discovery = Import-ClaudeFlowDiscovery -Path $DiscoveryPath
if (-not $discovery) {
    $target = Get-ClaudeFlowRecordTarget -Record $record
    if ($ResourceGroup) { $target.ResourceGroup = $ResourceGroup }
    if ($ApimName) { $target.ApimName = $ApimName }
    $discovery = Get-ClaudeFlowLiveDiscovery -ResourceGroup $target.ResourceGroup -ApimName $target.ApimName
}
$target = Get-ClaudeFlowRecordTarget -Record $record -Discovery $discovery
if (-not $SnapshotPath) {
    $SnapshotPath = Join-Path $root "backups\before-update-$($target.ApimName).json"
}

$migrationFiles = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'flow\migrations') -Filter '*.ps1' | Sort-Object Name)
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

if (-not $Apply -or $WhatIfPreference) {
    Write-Host 'Plan only. Nothing has been changed. Add -Apply with -ApprovedPlanFingerprint to write.' -ForegroundColor Cyan
    return [pscustomobject]@{ Plans = $plans; Fingerprint = $fingerprint; SnapshotPath = $SnapshotPath }
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
        $discovery = Get-ClaudeFlowLiveDiscovery -ResourceGroup $target.ResourceGroup -ApimName $target.ApimName
    }
    $check = Test-ClaudeFlowMigration -Record $record -Discovery $discovery
    if (-not $check.Passed) {
        throw "Migration '$($plan.Step)' did not verify. Roll back with Restore-ClaudeGateway.ps1 -Path '$SnapshotPath' -Apply."
    }
}
$release = Get-ClaudeFlowReleaseInfo
Set-ClaudeDecisionRelease -Record $record -Version $release.version -Commit $release.commit
Write-ClaudeDecisionRecord -Record $record -Path $RecordPath
Write-Host "Updated. Snapshot: $SnapshotPath" -ForegroundColor Green
