<#
.SYNOPSIS
    Runs one reports generator or outbox dispatch pass; also runnable by hand.
.EXAMPLE
    ./scripts/Invoke-ClaudeChargebackSchedule.ps1 -Mode dispatcher -StorageAccount streportscontoso
#>
[CmdletBinding()]
param(
    [ValidateSet('generator','dispatcher')][string]$Mode='generator',
    [Parameter(Mandatory)][string]$StorageAccount,
    [string]$ResourceGroup = $(& (Join-Path $PSScriptRoot 'Get-ClaudeGatewayTarget.ps1') ResourceGroup),
    [string]$ApimName = $(& (Join-Path $PSScriptRoot 'Get-ClaudeGatewayTarget.ps1') ApimName)
)
$ErrorActionPreference='Stop'
foreach($helper in @('Report','Query','Configuration','Storage','Email','Outbox')) {. (Join-Path $PSScriptRoot "ClaudeChargeback$helper.ps1")}
$config=(Get-ClaudeReportConfiguration $StorageAccount).Configuration
if($Mode -eq 'dispatcher') {Invoke-ClaudeReportOutbox $StorageAccount | ConvertTo-Json -Compress;return}
$output=Join-Path (Get-Location).Path ('.chargeback-job-' + [guid]::NewGuid().ToString('N'))
try {
    $result=& (Join-Path $PSScriptRoot 'New-ClaudeChargebackReport.ps1') -ResourceGroup $ResourceGroup -ApimName $ApimName `
        -OutputPath $output -MonthToDate:$config.MonthToDate -BusinessUnit $config.BusinessUnits -Format $config.Formats
    $prefix=Save-ClaudeReportArchive $StorageAccount $result.Path $result.Manifest
    $queued=0
    if($config.DeliveryEnabled) {$queued=Add-ClaudeReportOutbox $StorageAccount $result.Path $result.Manifest $config $prefix}
    [pscustomobject]@{Status='Archived';RunId=$result.Manifest.RunId;Month=$result.Manifest.Month;Requests=$result.Manifest.Totals.Requests;Archive=$prefix;Queued=$queued;Utc=[datetime]::UtcNow.ToString('o')} | ConvertTo-Json -Compress
}
finally {if(Test-Path $output) {Remove-Item $output -Recurse -Force}}
