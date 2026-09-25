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
    [ValidateRange(1,3650)][int]$RetentionDays,[switch]$List,[string]$StorageAccount,[switch]$ViaJob,
    [string]$SubscriptionId,[switch]$NonInteractive,
    [string]$JobName,
    [string]$ResourceGroup = $(& (Join-Path $PSScriptRoot 'Get-ClaudeGatewayTarget.ps1') ResourceGroup),
    [string]$ApimName = $(& (Join-Path $PSScriptRoot 'Get-ClaudeGatewayTarget.ps1') ApimName)
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'ClaudeChargebackReport.ps1')
. (Join-Path $PSScriptRoot 'ClaudeChargebackQuery.ps1')
. (Join-Path $PSScriptRoot 'ClaudeChargebackConfiguration.ps1')
. (Join-Path $PSScriptRoot 'ClaudeChargebackStorage.ps1')
. (Join-Path $PSScriptRoot 'ClaudeChargebackSchedule.ps1')
. (Join-Path $PSScriptRoot 'ClaudeChargebackAdministration.ps1')
. (Join-Path $PSScriptRoot 'ClaudeChargebackDiscovery.ps1')
if(-not $ResourceGroup -or -not $ApimName -or $SubscriptionId){
    $target=Resolve-ClaudeReportTarget $ResourceGroup $ApimName $SubscriptionId -NonInteractive:$NonInteractive
    $ResourceGroup=$target.ResourceGroup;$ApimName=$target.ApimName
}
if($ViaJob) {
    $settings=@{}
    foreach($key in @('AllowedDomains','MonthToDate','DeliveryEnabled','RetentionDays')) {if($PSBoundParameters.ContainsKey($key)) {$settings[$key]=$PSBoundParameters[$key]}}
    if($PSBoundParameters.ContainsKey('BusinessUnit')) {$settings.BusinessUnits=@($BusinessUnit)}
    if($PSBoundParameters.ContainsKey('Format')) {$settings.Formats=@($Format)}
    $request=if($List) {@{Operation='Inspect'}} else {@{Operation='Settings';Settings=$settings}}
    if($PSCmdlet.ShouldProcess('Private report administration job',"$($request.Operation) without redeploying")) {
        if($RetentionDays) {
            $StorageAccount=Get-ClaudeReportStorageAccount $ResourceGroup $ApimName $StorageAccount -NonInteractive:$NonInteractive
        }
        Invoke-ClaudeReportAdminRequest $ResourceGroup $ApimName $request $JobName -NonInteractive:$NonInteractive
        if($RetentionDays) {
            Set-ClaudeReportRetention $ResourceGroup $StorageAccount $RetentionDays
        }
    }
    return
}
$StorageAccount=Get-ClaudeReportStorageAccount $ResourceGroup $ApimName $StorageAccount -NonInteractive:$NonInteractive
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
