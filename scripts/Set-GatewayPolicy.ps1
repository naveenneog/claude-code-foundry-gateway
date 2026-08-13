<#
.SYNOPSIS
    Applies a policy XML file to the Claude gateway API in API Management.
.DESCRIPTION
    Uses the ARM REST API directly. `az rest` is avoided for the response
    because the Azure CLI mis-decodes APIM's policy responses on Windows
    (a BOM/charmap bug) and reports failure for calls that actually succeeded.
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

$xml = [IO.File]::ReadAllText((Resolve-Path $PolicyFile))
$xml = $xml.TrimStart([char]0xFEFF)

$token = az account get-access-token --resource https://management.azure.com --query accessToken -o tsv
$uri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup" +
       "/providers/Microsoft.ApiManagement/service/$ApimName/apis/$ApiId/policies/policy?api-version=2024-05-01"

$body = @{ properties = @{ format = 'rawxml'; value = $xml } } | ConvertTo-Json -Depth 5 -Compress

$resp = Invoke-WebRequest -Uri $uri -Method Put `
    -Headers @{ Authorization = "Bearer $token" } `
    -ContentType 'application/json' `
    -Body ([Text.Encoding]::UTF8.GetBytes($body)) `
    -SkipHttpErrorCheck

if ($resp.StatusCode -in 200, 201) {
    Write-Host "Policy applied to '$ApiId' ($([math]::Round($xml.Length/1KB,1)) KB)" -ForegroundColor Green
}
else {
    Write-Host "FAILED - HTTP $($resp.StatusCode)" -ForegroundColor Red
    Write-Host $resp.Content
    exit 1
}
