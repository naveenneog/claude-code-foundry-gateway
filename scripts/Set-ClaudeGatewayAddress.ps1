<#
.SYNOPSIS
    Plans, configures and proves a company gateway address before publishing it (ADR-0033).
.EXAMPLE
    .\scripts\Set-ClaudeGatewayAddress.ps1 -SubscriptionId <id> -ResourceGroup <rg> -ApimName <apim> -Hostname claude.contoso.com -CertificateSource KeyVault -KeyVaultCertificateId https://kv-contoso.vault.azure.net/certificates/company -PlanOnly
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$SubscriptionId, [string]$ResourceGroup, [string]$ApimName, [string]$Hostname,
    [ValidateSet('KeyVault','Pfx','Managed')][string]$CertificateSource,
    [string]$KeyVaultCertificateId, [string]$PfxPath, [securestring]$CertificatePassword,
    [string]$DnsZoneResourceId, [string]$ReplaceHostname,
    [string]$RecordPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'onboarding\claude-gateway.json'),
    [switch]$PlanOnly, [string]$ApprovedPlanFingerprint,
    [switch]$IsolatedProof, [string]$DnsServer, [string]$ConnectAddress,
    [ValidateRange(0,7200)][int]$TimeoutSeconds = 2700,
    [ValidateRange(0,7200)][int]$DnsTimeoutSeconds = 600,
    [ValidateRange(0,120)][int]$PollSeconds = 15
)
. (Join-Path $PSScriptRoot 'ClaudeGatewayAddress.ps1')
if ($MyInvocation.InvocationName -eq '.') { return }
$ErrorActionPreference = 'Stop'
$planArgs = @{}
foreach ($name in 'SubscriptionId','ResourceGroup','ApimName','Hostname','CertificateSource','KeyVaultCertificateId','PfxPath','CertificatePassword','DnsZoneResourceId','ReplaceHostname','IsolatedProof','DnsServer','ConnectAddress') {
    $planArgs[$name] = Get-Variable -Name $name -ValueOnly
}
$plan = Get-ClaudeAddressPlan @planArgs
$fingerprint = Get-ClaudeFlowFingerprint @($plan)
Write-Host (Format-ClaudeFlowReview @($plan))
Write-Host "Fingerprint: $fingerprint"
if ($PlanOnly -or $WhatIfPreference) { return }
if (-not $ApprovedPlanFingerprint -or $ApprovedPlanFingerprint.Length -lt 8 -or -not $fingerprint.StartsWith($ApprovedPlanFingerprint, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'No matching ApprovedPlanFingerprint was supplied; no company-address writes were made.'
}
if ($PSCmdlet.ShouldProcess($Hostname, 'Apply the reviewed company address')) {
    Invoke-ClaudeAddressPlan -Plan $plan -CertificatePassword $CertificatePassword -RecordPath $RecordPath -TimeoutSeconds $TimeoutSeconds -DnsTimeoutSeconds $DnsTimeoutSeconds -PollSeconds $PollSeconds
}
