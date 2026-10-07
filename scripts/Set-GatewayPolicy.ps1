<#
.SYNOPSIS
    Applies a policy XML file to the Claude gateway API in API Management.
.DESCRIPTION
    Creates any named values and policy fragments referenced by the policy before PUTting the API policy.
    This lets pre-P102 gateways accept policy.xml, whose APIM include-fragment depends on a fragment resource.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ApimName,
    [Parameter(Mandatory = $true)][string]$ResourceGroup,
    [Parameter(Mandatory = $true)][string]$PolicyFile,
    [string]$ApiId = 'claude-foundry',
    [string]$SubscriptionId
)

$ErrorActionPreference = 'Stop'
if (-not $SubscriptionId) { $SubscriptionId = az account show --query id -o tsv }
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'flow\FlowContract.ps1')
. (Join-Path $PSScriptRoot 'flow\lib\LifecycleCommon.ps1')
. (Join-Path $PSScriptRoot 'ApimNamedValue.ps1')

$resolvedPolicyPath = (Resolve-Path $PolicyFile)
$xml = [IO.File]::ReadAllText($resolvedPolicyPath).TrimStart([char]0xFEFF)
$scope = if (Test-ClaudeFlowSubscriptionId $SubscriptionId) { @{ SubscriptionId = $SubscriptionId } } else { @{} }
$defaults = Get-ClaudeFlowLifecycleTemplateNamedValueDefaults
foreach ($name in @(Get-ClaudeFlowLifecyclePolicyAndFragmentNamedValueReferences -PolicyPath $resolvedPolicyPath)) {
    if (-not $defaults.Contains($name) -or $null -eq $defaults[$name].Value) {
        throw "Policy references named value '$name' but this script has no safe default. Create the named value first, or run Update-ClaudeGateway.ps1 so the fingerprinted migration can plan it."
    }
    Set-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id $name -Value ([string]$defaults[$name].Value) @scope
}

$token = az account get-access-token --resource https://management.azure.com --query accessToken -o tsv
$headers = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }
foreach ($fragment in @(Get-ClaudeFlowLifecyclePolicyFragmentIds -PolicyPath $resolvedPolicyPath)) {
    $fragmentPath = Join-Path (Join-Path $root 'infra') "$fragment.xml"
    if (-not (Test-Path -LiteralPath $fragmentPath)) { throw "Policy includes fragment '$fragment', but '$fragmentPath' was not found." }
    $fragmentXml = [IO.File]::ReadAllText($fragmentPath).TrimStart([char]0xFEFF)
    $fragmentUri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup" +
        "/providers/Microsoft.ApiManagement/service/$ApimName/policyFragments/$fragment`?api-version=2024-05-01"
    $fragmentBody = @{ properties = @{ format = 'rawxml'; value = $fragmentXml } } | ConvertTo-Json -Depth 5 -Compress
    $fragmentResp = Invoke-WebRequest -Uri $fragmentUri -Method Put -Headers $headers -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($fragmentBody)) -SkipHttpErrorCheck
    if ($fragmentResp.StatusCode -notin 200, 201) {
        Write-Host "FAILED - fragment '$fragment' HTTP $($fragmentResp.StatusCode)" -ForegroundColor Red
        Write-Host $fragmentResp.Content
        exit 1
    }
}

$uri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup" +
       "/providers/Microsoft.ApiManagement/service/$ApimName/apis/$ApiId/policies/policy?api-version=2024-05-01"
$body = @{ properties = @{ format = 'rawxml'; value = $xml } } | ConvertTo-Json -Depth 5 -Compress
$resp = Invoke-WebRequest -Uri $uri -Method Put -Headers $headers -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -SkipHttpErrorCheck
if ($resp.StatusCode -in 200, 201) {
    Write-Host "Policy applied to '$ApiId' ($([math]::Round($xml.Length/1KB,1)) KB)" -ForegroundColor Green
}
else {
    Write-Host "FAILED - HTTP $($resp.StatusCode)" -ForegroundColor Red
    Write-Host $resp.Content
    exit 1
}
