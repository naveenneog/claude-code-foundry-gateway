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

.EXAMPLE
    [string]$ResourceGroup = $(& (Join-Path $PSScriptRoot 'Get-ClaudeGatewayTarget.ps1') ResourceGroup)
#>
[CmdletBinding()]
param(
    [ValidateSet('ResourceGroup', 'ApimName', 'StandardGroup', 'PremiumGroup')][string]$Field = 'ResourceGroup'
)

$fromEnvironment = switch ($Field) { 'ResourceGroup' { $env:CLAUDE_RG } 'ApimName' { $env:CLAUDE_APIM } default { $null } }
if ($fromEnvironment) { return [string]$fromEnvironment }

$config = Join-Path (Split-Path $PSScriptRoot -Parent) 'onboarding/claude-gateway.json'
if (Test-Path $config) {
    try {
        $recorded = Get-Content $config -Raw | ConvertFrom-Json
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
