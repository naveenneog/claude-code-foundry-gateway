<#
.SYNOPSIS
    Changes report selection, domains, formats, retention and delivery without redeploying.
.EXAMPLE
    ./scripts/Set-ClaudeChargebackSettings.ps1 -AllowedDomains contoso.com -BusinessUnit engineering,finance -WhatIf
.EXAMPLE
    ./scripts/Set-ClaudeChargebackSettings.ps1 -DeliveryEnabled $false
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string[]]$AllowedDomains,[AllowEmptyCollection()][string[]]$BusinessUnit,
    [ValidateSet('CSV','HTML')][string[]]$Format,
    [Nullable[bool]]$MonthToDate,[Nullable[bool]]$DeliveryEnabled,
    [ValidateRange(1,3650)][int]$RetentionDays,[switch]$List,[string]$StorageAccount,
    [string]$ResourceGroup = $(& (Join-Path $PSScriptRoot 'Get-ClaudeGatewayTarget.ps1') ResourceGroup),
    [string]$ApimName = $(& (Join-Path $PSScriptRoot 'Get-ClaudeGatewayTarget.ps1') ApimName)
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'ClaudeChargebackReport.ps1')
. (Join-Path $PSScriptRoot 'ClaudeChargebackQuery.ps1')
. (Join-Path $PSScriptRoot 'ClaudeChargebackConfiguration.ps1')
. (Join-Path $PSScriptRoot 'ClaudeChargebackStorage.ps1')
. (Join-Path $PSScriptRoot 'ClaudeChargebackSchedule.ps1')
$StorageAccount=Get-ClaudeReportStorageAccount $ResourceGroup $ApimName $StorageAccount
$stored=Get-ClaudeReportConfiguration $StorageAccount
$config=$stored.Configuration
if($List) { $config; return }
if($PSBoundParameters.ContainsKey('AllowedDomains')) { $config.AllowedDomains=@($AllowedDomains | ForEach-Object {$_.ToLowerInvariant()} | Sort-Object -Unique) }
if($PSBoundParameters.ContainsKey('BusinessUnit')) { $config.BusinessUnits=@($BusinessUnit | Sort-Object -Unique) }
if($Format) { $config.Formats=@($Format | Sort-Object -Unique) }
if($null -ne $MonthToDate) { $config.MonthToDate=[bool]$MonthToDate }
if($null -ne $DeliveryEnabled) { $config.DeliveryEnabled=[bool]$DeliveryEnabled }
if($RetentionDays) { $config.RetentionDays=$RetentionDays }
Test-ClaudeChargebackConfiguration $config
$config.UpdatedUtc=[datetime]::UtcNow.ToString('o')
if($PSCmdlet.ShouldProcess('Report configuration','Save validated settings (next run); apply lifecycle retention if changed')) {
    Save-ClaudeReportConfiguration $StorageAccount $config $stored.ETag
    if($RetentionDays) { Set-ClaudeReportRetention -ResourceGroup $ResourceGroup -Account $StorageAccount -Days $RetentionDays }
    Write-Host 'Settings saved. No job or image was redeployed.'
}
