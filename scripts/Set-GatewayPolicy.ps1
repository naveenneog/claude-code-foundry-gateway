<#
.SYNOPSIS
    Applies a policy XML file to the Claude gateway API in API Management.
.DESCRIPTION
    Uses the ARM REST API directly. `az rest` is avoided for the response
    because the Azure CLI mis-decodes APIM's policy responses on Windows
    (a BOM/charmap bug) and reports failure for calls that actually succeeded.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)][string]$ApimName,
    [Parameter(Mandatory = $true)][string]$ResourceGroup,
    [Parameter(Mandatory = $true)][string]$PolicyFile,
    [string]$ApiId = 'claude-foundry',
    [string]$SubscriptionId
)

$ErrorActionPreference = 'Stop'

$xml = [IO.File]::ReadAllText((Resolve-Path $PolicyFile))
$xml = $xml.TrimStart([char]0xFEFF)
if ($xml -match '<!DOCTYPE|<!ENTITY' -or $xml -notmatch '<policies(?:\s|>)' -or $xml -notmatch '</policies>\s*$') {
    throw 'Expected APIM rawxml policies without DTD or entity declarations'
}
if (-not $PSCmdlet.ShouldProcess("$ApimName/$ApiId", 'Replace gateway policy')) { return }
if (-not $SubscriptionId) {
    $SubscriptionId = az account show --query id -o tsv
    if ($LASTEXITCODE -ne 0) { throw 'Cannot resolve subscription' }
}
if ($SubscriptionId -notmatch '^[a-fA-F0-9]{8}(-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$') { throw 'Invalid subscription ID' }

$token = az account get-access-token --resource https://management.azure.com --query accessToken -o tsv
if ($LASTEXITCODE -ne 0 -or -not $token) { throw 'Cannot acquire ARM credential' }
$uri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$([uri]::EscapeDataString($ResourceGroup))" +
       "/providers/Microsoft.ApiManagement/service/$([uri]::EscapeDataString($ApimName))/apis/$([uri]::EscapeDataString($ApiId))/policies/policy?api-version=2024-05-01"
$current = Invoke-WebRequest -Uri $uri -Headers @{ Authorization = "Bearer $token" } -UseBasicParsing -MaximumRedirection 0
$etag = @($current.Headers['ETag'])[0]
if (-not $etag) { throw 'Missing policy ETag; refusing unprotected replacement' }

$body = @{ properties = @{ format = 'rawxml'; value = $xml } } | ConvertTo-Json -Depth 5 -Compress

$resp = Invoke-WebRequest -Uri $uri -Method Put `
    -Headers @{ Authorization = "Bearer $token"; 'If-Match' = $etag } `
    -ContentType 'application/json' `
    -Body ([Text.Encoding]::UTF8.GetBytes($body)) `
    -UseBasicParsing -MaximumRedirection 0

if ($resp.StatusCode -in 200, 201) {
    Write-Host "Policy applied to '$ApiId' ($([math]::Round($xml.Length/1KB,1)) KB)" -ForegroundColor Green
}
else {
    Write-Host "FAILED - HTTP $($resp.StatusCode)" -ForegroundColor Red
    exit 1
}
