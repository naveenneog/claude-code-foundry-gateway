<#
.SYNOPSIS
    Generates one live unit and verifies manual send/repeat/resend to one approved admin.
.DESCRIPTION
    Requires the reporting managed identity or equivalent permissions on a connected host.
    Refuses unless the all-units list contains exactly the explicitly approved recipient.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$StorageAccount,[Parameter(Mandatory)][string]$Recipient,
    [string]$ResourceGroup = $(& (Join-Path $PSScriptRoot '..\scripts\Get-ClaudeGatewayTarget.ps1') ResourceGroup),
    [string]$ApimName = $env:CLAUDE_APIM,[string]$Month,[switch]$Apply
)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
foreach($helper in @('Report','Query','Configuration','Storage')) {. (Join-Path $root "scripts\ClaudeChargeback$helper.ps1")}
if(-not $Apply -or -not $PSCmdlet.ShouldProcess('Approved recipient only','Generate one live unit, queue one send and one explicit resend')){return}
$config=(Get-ClaudeReportConfiguration $StorageAccount).Configuration
$recipients=Get-ClaudeChargebackRecipients $config all
if($recipients.Count -ne 1 -or $recipients[0] -ne $Recipient.ToLowerInvariant()){throw 'Live delivery test requires exactly the approved all-units recipient; no email was queued.'}
$catalog=@(Get-ClaudeReportCatalog $ResourceGroup $ApimName)
$unit=@($catalog|Where-Object {-not $_.Parent}|Select-Object -First 1)[0].Id
if(-not $unit){$unit='unassigned'}
$folder=Join-Path (Get-Location).Path ('.chargeback-live-delivery-'+[guid]::NewGuid().ToString('N'))
try {
    $report=& (Join-Path $root 'scripts\New-ClaudeChargebackReport.ps1') -ResourceGroup $ResourceGroup -ApimName $ApimName `
        -Month $Month -BusinessUnit $unit -OutputPath $folder -NonInteractive
    $send=Join-Path $root 'scripts\Send-ClaudeChargebackReport.ps1'
    $first=& $send -ReportPath $report.Path -StorageAccount $StorageAccount -ResourceGroup $ResourceGroup -ApimName $ApimName -AllUnits -NonInteractive
    if($first.Queued -ne 1){throw 'Manual send did not queue exactly one approved-recipient message.'}
    $repeat=& $send -ReportPath $report.Path -StorageAccount $StorageAccount -ResourceGroup $ResourceGroup -ApimName $ApimName -AllUnits -NonInteractive
    if($repeat.Queued -ne 0){throw 'Repeated manual send unexpectedly queued a duplicate.'}
    $resend=& $send -ReportPath $report.Path -StorageAccount $StorageAccount -ResourceGroup $ResourceGroup -ApimName $ApimName -AllUnits -Resend -NonInteractive
    if($resend.Queued -ne 1){throw 'Explicit resend did not create exactly one new message.'}
    [pscustomobject]@{Status='Passed';RunId=$report.Manifest.RunId;Month=$report.Manifest.Month;SelectedUnits=1
        FirstQueued=$first.Queued;RepeatQueued=$repeat.Queued;ExplicitResendQueued=$resend.Queued
        RecipientCount=1;Archive=$first.Archive;Utc=[datetime]::UtcNow.ToString('o')}|ConvertTo-Json -Compress
}
finally {if(Test-Path $folder){Remove-Item $folder -Recurse -Force}}
