<#
.SYNOPSIS
    The gateway's resource group or API Management name, as this deployment recorded it.

.DESCRIPTION
    Scripts take their -ResourceGroup and -ApimName defaults from here, so nothing about one
    deployment is written into them. In order:

      1. The CLAUDE_RG and CLAUDE_APIM environment variables.
      2. onboarding/claude-gateway.json, which Install-ClaudeGateway.ps1 writes with the
         resourceGroup and apimName it deployed to. The file is not committed.

    Returns an empty string when neither has a value, after a warning that says what to pass,
    so the calling script can still fail with its own message.

    -ForApimName and -ForResourceGroup limit the recorded group names to the gateway they were
    recorded for: when the record names a different API Management instance or resource group,
    StandardGroup and PremiumGroup return an empty string, so a caller falls back to its own
    default instead of publishing another gateway's groups.

.EXAMPLE
    [string]$ResourceGroup = $(& (Join-Path $PSScriptRoot 'Get-ClaudeGatewayTarget.ps1') ResourceGroup)
#>
[CmdletBinding()]
param(
    [ValidateSet('ResourceGroup', 'ApimName', 'StandardGroup', 'PremiumGroup')][string]$Field = 'ResourceGroup',
    [string]$ForApimName,
    [string]$ForResourceGroup
)

$fromEnvironment = switch ($Field) { 'ResourceGroup' { $env:CLAUDE_RG } 'ApimName' { $env:CLAUDE_APIM } default { $null } }
if ($fromEnvironment) { return [string]$fromEnvironment }

$config = Join-Path (Split-Path $PSScriptRoot -Parent) 'onboarding/claude-gateway.json'
if (Test-Path $config) {
    try {
        $recorded = Get-Content $config -Raw | ConvertFrom-Json
        if ($Field -in @('StandardGroup', 'PremiumGroup')) {
            if ($ForApimName -and -not [string]::Equals([string]$recorded.apimName, $ForApimName, [StringComparison]::OrdinalIgnoreCase)) { return '' }
            if ($ForResourceGroup -and -not [string]::Equals([string]$recorded.resourceGroup, $ForResourceGroup, [StringComparison]::OrdinalIgnoreCase)) { return '' }
        }
        $value = switch ($Field) { 'ResourceGroup' { $recorded.resourceGroup } 'ApimName' { $recorded.apimName } 'StandardGroup' { $recorded.standardGroup } 'PremiumGroup' { $recorded.premiumGroup } }
        if ($value) { return [string]$value }
    }
    catch {
        Write-Warning "onboarding/claude-gateway.json could not be read: $($_.Exception.Message)"
    }
}

if ($Field -eq 'ResourceGroup') {
    Write-Warning 'No gateway resource group is known. Pass -ResourceGroup, set CLAUDE_RG, or run Install-ClaudeGateway.ps1, which records it in onboarding/claude-gateway.json.'
}
return ''
