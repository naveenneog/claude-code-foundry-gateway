<#
.SYNOPSIS
    Discovers a reporting gateway and its actual resources, with numbered choices.
.EXAMPLE
    ./scripts/Get-ClaudeChargebackTarget.ps1 -Inventory -AsJson
.EXAMPLE
    ./scripts/Get-ClaudeChargebackTarget.ps1 -ResourceGroup rg-contoso -ApimName apim-contoso -NonInteractive -Inventory -AsJson
#>
[CmdletBinding()]
param(
    [string]$SubscriptionId,
    [string]$ResourceGroup = $(& (Join-Path $PSScriptRoot 'Get-ClaudeGatewayTarget.ps1') ResourceGroup),
    [string]$ApimName = $(& (Join-Path $PSScriptRoot 'Get-ClaudeGatewayTarget.ps1') ApimName),
    [switch]$NonInteractive,[switch]$Inventory,[switch]$AsJson
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'ClaudeChargebackDiscovery.ps1')
$target=Resolve-ClaudeReportTarget -ResourceGroup $ResourceGroup -ApimName $ApimName -SubscriptionId $SubscriptionId -NonInteractive:$NonInteractive
$value=if($Inventory){Get-ClaudeReportInventory $target.ResourceGroup $target.ApimName}else{$target}
if($AsJson){$value|ConvertTo-Json -Depth 20}else{$value}
