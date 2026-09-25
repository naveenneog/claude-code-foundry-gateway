<#
.SYNOPSIS
    Runs the repository's P50 report generator with a JSON parameter file.
#>
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$InputFile)
$ErrorActionPreference = 'Stop'
$generator = Join-Path $PSScriptRoot 'New-ClaudeChargebackReport.ps1'
if (-not (Test-Path $generator)) { throw 'The P50 report generator is not installed.' }
$options = Get-Content -LiteralPath $InputFile -Raw | ConvertFrom-Json -AsHashtable
$allowed = @('Month','OutputPath','Format','NonInteractive','BusinessUnit','Send','ResourceGroup','ApimName','SubscriptionId','WorkspaceResourceId')
foreach ($key in $options.Keys) { if ($key -notin $allowed) { throw 'Unknown report parameter.' } }
$result = & $generator @options 6>$null
if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw 'Report generator returned a failure.' }
$result | ConvertTo-Json -Depth 30 -Compress
