<#
.SYNOPSIS
    Which Application Insights this gateway actually sends telemetry to.

.DESCRIPTION
    Resolves the App Insights instance from the gateway's own diagnostic
    configuration rather than from its name.

    This exists because guessing the name was wrong. The accelerator names the
    workspace appi-{namePrefix}, and namePrefix carries a random suffix, so a
    redeploy that picks a new prefix leaves the old workspace in place and
    starts writing to a new one. On the reference deployment that happened on
    2026-08-31: customMetrics stopped arriving in appi-claude-gateway and
    started arriving in appi-claude-gw-fzgql9, while requests kept appearing in
    both because the service-level and API-level diagnostics pointed at
    different loggers. A report reading the old workspace showed zero and looked
    like "nobody used it" rather than "you are reading the wrong workspace".

    Resolution order, most specific first:
      1. the API's own diagnostic       apis/{api}/diagnostics/applicationinsights
      2. the service-level diagnostic   diagnostics/applicationinsights
      3. -AppInsightsName, if given

.PARAMETER Quiet
    Emit only the app id, for use in a pipeline.

.EXAMPLE
    ./scripts/Get-ClaudeTelemetry.ps1

.EXAMPLE
    $appId = ./scripts/Get-ClaudeTelemetry.ps1 -Quiet
#>
[CmdletBinding()]
param(
    [string]$ResourceGroup = $(if ($env:CLAUDE_RG) { $env:CLAUDE_RG } else { 'rg-contosohub' }),
    [string]$ApimName,
    [string]$ApiId = 'claude-foundry',
    [string]$AppInsightsName,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

$sub = az account show --query id -o tsv 2>$null
if (-not $sub) { throw 'Not signed in. Run: az login' }
if (-not $ApimName) {
    $ApimName = az apim list -g $ResourceGroup --query "[0].name" -o tsv 2>$null
    if (-not $ApimName) { throw "No API Management instance in $ResourceGroup. Pass -ApimName." }
}

$token = az account get-access-token --resource https://management.azure.com --query accessToken -o tsv 2>$null
$H = @{ Authorization = 'Bearer ' + $token.Trim() }
$base = "https://management.azure.com/subscriptions/$sub/resourceGroups/$ResourceGroup/providers/Microsoft.ApiManagement/service/$ApimName"
$v = '?api-version=2024-05-01'

function Get-Arm($uri) { try { return Invoke-RestMethod -Uri $uri -Headers $H } catch { return $null } }

$loggerId = $null
$scope = $null

$apiDiag = Get-Arm "$base/apis/$ApiId/diagnostics/applicationinsights$v"
if ($apiDiag -and $apiDiag.properties.loggerId) {
    $loggerId = $apiDiag.properties.loggerId
    $scope = "api/$ApiId"
    $metrics = $apiDiag.properties.metrics
}
else {
    $svcDiag = Get-Arm "$base/diagnostics/applicationinsights$v"
    if ($svcDiag -and $svcDiag.properties.loggerId) {
        $loggerId = $svcDiag.properties.loggerId
        $scope = 'service'
        $metrics = $svcDiag.properties.metrics
    }
}

$componentName = $null
if ($loggerId) {
    $logger = Get-Arm ("https://management.azure.com" + $loggerId + $v)
    if ($logger -and $logger.properties.resourceId) {
        $componentName = ($logger.properties.resourceId -split '/')[-1]
    }
}
if (-not $componentName) { $componentName = $AppInsightsName }
if (-not $componentName) {
    throw "Could not work out which Application Insights $ApimName logs to. Pass -AppInsightsName."
}

$component = Get-Arm ("https://management.azure.com/subscriptions/$sub/resourceGroups/$ResourceGroup" +
                      "/providers/Microsoft.Insights/components/$componentName" + '?api-version=2020-02-02')
if (-not $component) { throw "Application Insights '$componentName' not found in $ResourceGroup." }

if ($Quiet) { $component.properties.AppId; exit 0 }

# metrics must be on, or llm-emit-token-metric emits nothing and every usage
# report is silently empty.
[pscustomobject]@{
    Gateway         = $ApimName
    AppInsights     = $componentName
    AppId           = $component.properties.AppId
    DiagnosticScope = $scope
    MetricsEnabled  = [bool]$metrics
}
