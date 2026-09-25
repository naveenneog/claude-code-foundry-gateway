<#
.SYNOPSIS
    Archives a reconciled report and queues scoped, domain-validated email.
.DESCRIPTION
    Delivery is paced through a durable outbox. Dispatch performs one send or status check
    if the shared rate limit allows it. Resend explicitly creates new messages; repeating
    the same normal command never resends a completed message.
.EXAMPLE
    ./scripts/Send-ClaudeChargebackReport.ps1 -ReportPath ./chargeback-reports/2026-08 -BusinessUnit engineering -Dispatch
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$ReportPath,[string[]]$BusinessUnit,[switch]$AllUnits,
    [switch]$Dispatch,[switch]$Resend,[string]$StorageAccount,[string]$SubscriptionId,[switch]$NonInteractive,
    [string]$ResourceGroup = $(& (Join-Path $PSScriptRoot 'Get-ClaudeGatewayTarget.ps1') ResourceGroup),
    [string]$ApimName = $(& (Join-Path $PSScriptRoot 'Get-ClaudeGatewayTarget.ps1') ApimName)
)
$ErrorActionPreference='Stop'
foreach($helper in @('Report','Query','Configuration','Storage','Email','Outbox','Discovery')) {. (Join-Path $PSScriptRoot "ClaudeChargeback$helper.ps1")}
$ReportPath=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ReportPath)
$manifest=Get-Content (Join-Path $ReportPath 'manifest.json') -Raw | ConvertFrom-Json
Test-ClaudeReportArtifacts $ReportPath $manifest
if($BusinessUnit -and $AllUnits) {throw 'Choose unit recipients or the all-units admin list, not both.'}
$scope=if($AllUnits) {@('all')} else {$BusinessUnit}
if(-not $PSCmdlet.ShouldProcess("$($manifest.Month) ($($manifest.RunId))",'Archive verified artifacts and queue scoped reports'+$(if($Resend){' as an explicit resend'}))) {return}
if(-not $ResourceGroup -or -not $ApimName -or $SubscriptionId){
    $target=Resolve-ClaudeReportTarget $ResourceGroup $ApimName $SubscriptionId -NonInteractive:$NonInteractive
    $ResourceGroup=$target.ResourceGroup;$ApimName=$target.ApimName
}
$StorageAccount=Get-ClaudeReportStorageAccount $ResourceGroup $ApimName $StorageAccount -NonInteractive:$NonInteractive
$config=(Get-ClaudeReportConfiguration $StorageAccount).Configuration
$existing=Get-ClaudeReportArchiveJson $StorageAccount "runs/$($manifest.Month)/$($manifest.RunId)/manifest.json" -AllowMissing
if($existing) { $manifest.Sends=$existing.Sends }
$prefix=Save-ClaudeReportArchive $StorageAccount $ReportPath $manifest
$count=Add-ClaudeReportOutbox $StorageAccount $ReportPath $manifest $config $prefix -Scope $scope -Resend:$Resend
Write-Host "Archived $($manifest.RunId); queued $count message part(s). Success means queued, not delivered."
if($Dispatch) {Invoke-ClaudeReportOutbox $StorageAccount}
[pscustomobject]@{Archive=$prefix;Queued=$count;RunId=$manifest.RunId}
