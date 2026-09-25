<#
.SYNOPSIS
    Read-only historical caller analysis before restricting network access.
.DESCRIPTION
    Discovers all actual gateway telemetry destinations. Missing, masked,
    sampled and incomplete data remains unknown. WhatIf still performs these
    read-only queries and prints the same report; it changes no Azure setting.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory=$true)][string]$ApimId,
    [Parameter(Mandatory=$true)][ValidateRange(1,90)][int]$LookbackDays,
    [string[]]$PrivateClientCidrs=@(),
    [string[]]$EdgeSourceCidrs=@(),
    [ValidateSet('GatewayPrivate','EdgeOnly','FoundryPrivate','EdgeRemoval')][string[]]$Actions=@(),
    [switch]$BackendPathValidated,
    [ValidateRange(1,50000)][int]$MaximumRows=10000,
    [switch]$AsJson
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'ClaudeNetwork.ps1')
. (Join-Path $PSScriptRoot 'ClaudeNetworkImpact.ps1')
$report=Get-ClaudeNetworkImpact -ApimId $ApimId -LookbackDays $LookbackDays -PrivateClientCidrs $PrivateClientCidrs -EdgeSourceCidrs $EdgeSourceCidrs -Actions $Actions -BackendPathValidated:$BackendPathValidated -MaximumRows $MaximumRows
if($AsJson){$report|ConvertTo-Json -Depth 40}else{Show-ClaudeNetworkImpact $report}
