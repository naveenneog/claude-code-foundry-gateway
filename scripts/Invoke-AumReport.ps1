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
$allowed = @('Month','MonthToDate','OutputPath','Format','NonInteractive','BusinessUnit','Send','ResourceGroup','ApimName','SubscriptionId','WorkspaceResourceId')
foreach ($key in $options.Keys) { if ($key -notin $allowed) { throw 'Unknown report parameter.' } }
if ($options.SubscriptionId) {
    $subscription = [guid]::Empty
    if (-not [guid]::TryParse($options.SubscriptionId, [ref]$subscription)) { throw 'Subscription must be an object id.' }
    $aumReportSubscription = [string]$subscription
    $aumAzureCliExecutable = @(Get-Command az -CommandType Application -ErrorAction Stop)[0].Source
    function az {
        $arguments = @($args)
        if ($arguments.Count -ge 2 -and $arguments[0] -eq 'account' -and $arguments[1] -eq 'set') {
            $index = [array]::IndexOf($arguments, '--subscription')
            if ($index -lt 0 -or $arguments[$index + 1] -ne $aumReportSubscription) {
                throw 'A report cannot change the shared Azure CLI subscription.'
            }
            $global:LASTEXITCODE = 0
            return
        }
        if ($arguments -notcontains '--subscription' -and
            -not ($arguments.Count -ge 2 -and $arguments[0] -eq 'account' -and $arguments[1] -eq 'list')) {
            $arguments += @('--subscription', $aumReportSubscription)
        }
        & $aumAzureCliExecutable @arguments
        $global:LASTEXITCODE = $LASTEXITCODE
    }
}
$result = & $generator @options 6>$null
if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw 'Report generator returned a failure.' }
$result | ConvertTo-Json -Depth 30 -Compress
