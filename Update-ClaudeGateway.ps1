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
    [string]$SnapshotPath,
    [string]$StandardGroup,
    [string]$PremiumGroup,
    [string]$NamePrefix,
    [ValidateSet('', 'public', 'private')][string]$ResolverInboundAccess = '',
    [switch]$KeepNamedValues
)

$args = @{
    # Relative to the repository, as Start-ClaudeGateway.ps1 resolves it, from any folder (P79).
    RecordPath = $(if ([IO.Path]::IsPathRooted($RecordPath)) { $RecordPath } else { Join-Path $PSScriptRoot $RecordPath })
}
if ($DiscoveryPath) { $args.DiscoveryPath = $DiscoveryPath }
if ($ResourceGroup) { $args.ResourceGroup = $ResourceGroup }
if ($ApimName) { $args.ApimName = $ApimName }
if ($Apply) { $args.Apply = $true }
if ($ApprovedPlanFingerprint) { $args.ApprovedPlanFingerprint = $ApprovedPlanFingerprint }
if ($SnapshotPath) { $args.SnapshotPath = $SnapshotPath }
foreach ($name in 'StandardGroup', 'PremiumGroup', 'NamePrefix', 'ResolverInboundAccess') { if ($PSBoundParameters[$name]) { $args[$name] = $PSBoundParameters[$name] } }
if ($KeepNamedValues) { $args.KeepNamedValues = $true }

& (Join-Path $PSScriptRoot 'scripts\Update-ClaudeGateway.ps1') @args -WhatIf:$WhatIfPreference
