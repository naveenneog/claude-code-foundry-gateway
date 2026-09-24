<#
.SYNOPSIS
    Adds, removes or lists private report recipients without redeployment.
.EXAMPLE
    ./scripts/Set-ClaudeChargebackRecipients.ps1 -BusinessUnit engineering -Add alice@contoso.com -WhatIf
.EXAMPLE
    ./scripts/Set-ClaudeChargebackRecipients.ps1 -AllUnits -List
#>
[CmdletBinding(SupportsShouldProcess,DefaultParameterSetName='List')]
param(
    [string]$BusinessUnit,[switch]$AllUnits,
    [Parameter(Mandatory,ParameterSetName='Add')][string[]]$Add,
    [Parameter(Mandatory,ParameterSetName='Remove')][string[]]$Remove,
    [Parameter(ParameterSetName='List')][switch]$List,
    [string]$StorageAccount,
    [string]$ResourceGroup = $(& (Join-Path $PSScriptRoot 'Get-ClaudeGatewayTarget.ps1') ResourceGroup),
    [string]$ApimName = $(& (Join-Path $PSScriptRoot 'Get-ClaudeGatewayTarget.ps1') ApimName)
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'ClaudeChargebackReport.ps1')
. (Join-Path $PSScriptRoot 'ClaudeChargebackQuery.ps1')
. (Join-Path $PSScriptRoot 'ClaudeChargebackConfiguration.ps1')
. (Join-Path $PSScriptRoot 'ClaudeChargebackStorage.ps1')
if($BusinessUnit -and $AllUnits) { throw 'Choose -BusinessUnit or -AllUnits, not both.' }
if($BusinessUnit) { Get-ClaudeReportFileName $BusinessUnit | Out-Null }
if(-not $BusinessUnit -and -not $AllUnits -and $PSCmdlet.ParameterSetName -ne 'List') { throw 'Choose -BusinessUnit or -AllUnits for a recipient change.' }
$StorageAccount=Get-ClaudeReportStorageAccount $ResourceGroup $ApimName $StorageAccount
$stored=Get-ClaudeReportConfiguration $StorageAccount
$scope=if($AllUnits) {'all'} else {$BusinessUnit}
if($PSCmdlet.ParameterSetName -eq 'List') {
    if($scope) { $addresses=Get-ClaudeChargebackRecipients $stored.Configuration $scope; [pscustomobject]@{Scope=$scope;Recipients=$addresses} }
    else {
        [pscustomobject]@{Scope='all';Recipients=$stored.Configuration.AllUnitsRecipients}
        foreach($id in @($stored.Configuration.Units.Keys | Sort-Object)) { [pscustomobject]@{Scope=$id;Recipients=$stored.Configuration.Units[$id]} }
    }
    return
}
$updated=Update-ClaudeChargebackRecipients $stored.Configuration $scope $Add $Remove
$before=Get-ClaudeChargebackRecipients $stored.Configuration $scope
$after=Get-ClaudeChargebackRecipients $updated $scope
if(($before -join ';') -eq ($after -join ';')) { Write-Host "Unchanged: $scope ($($after.Count) recipient(s))."; return }
if($PSCmdlet.ShouldProcess("$scope recipients","Save $($after.Count) validated recipient(s) using an ETag conditional write")) {
    Save-ClaudeReportConfiguration $StorageAccount $updated $stored.ETag
    Write-Host "Saved: $scope ($($after.Count) recipient(s)); effective on the next delivery."
}
