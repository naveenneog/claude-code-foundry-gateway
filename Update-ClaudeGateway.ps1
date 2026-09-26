<#
.SYNOPSIS
    Root entry point shim for the guided-flow orchestrator's Update action.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$RecordPath = 'onboarding/claude-gateway.json',
    [string]$DiscoveryPath,
    [string]$ResourceGroup,
    [string]$ApimName,
    [switch]$Apply,
    [string]$ApprovedPlanFingerprint,
    [string]$SnapshotPath
)

$args = @{
    RecordPath = $RecordPath
}
if ($DiscoveryPath) { $args.DiscoveryPath = $DiscoveryPath }
if ($ResourceGroup) { $args.ResourceGroup = $ResourceGroup }
if ($ApimName) { $args.ApimName = $ApimName }
if ($Apply) { $args.Apply = $true }
if ($ApprovedPlanFingerprint) { $args.ApprovedPlanFingerprint = $ApprovedPlanFingerprint }
if ($SnapshotPath) { $args.SnapshotPath = $SnapshotPath }

& (Join-Path $PSScriptRoot 'scripts\Update-ClaudeGateway.ps1') @args -WhatIf:$WhatIfPreference

