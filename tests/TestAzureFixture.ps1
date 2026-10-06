# Native az.cmd and HTTP fixtures shared by the wizard and both-host preflight checks.
function New-TestAzureFixture {
    param([Parameter(Mandatory)][string]$Directory)
    $ErrorActionPreference = 'Stop'
    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    $native = @'
$ErrorActionPreference = 'Stop'
$joined = $args -join ' '
[IO.File]::AppendAllText($env:P78_AZ_CALLS, $joined + [Environment]::NewLine)
if ($joined -like 'version *') { '2.86.0'; exit 0 }
if ($joined -like 'bicep version*') { 'Bicep CLI version 0.46.1'; exit 0 }
if ($joined -like 'account list-locations *') {
    '[{"name":"eastus2","regionalDisplayName":"(US) East US 2","metadata":{"regionType":"Physical","geographyGroup":"US"}}]'
    exit 0
}
if ($joined -like 'account list --query *') { '00000000-0000-4000-8000-000000000078'; exit 0 }
if ($joined -like 'account show --query name *') { 'P78 offline subscription'; exit 0 }
if ($joined -like 'account show *') {
    '{"id":"00000000-0000-4000-8000-000000000078","name":"P78 offline subscription","state":"Enabled","tenantId":"00000000-0000-4000-8000-000000000079","user":{"name":"admin@contoso.com","type":"user"}}'
    exit 0
}
if ($joined -ceq 'account set --subscription 00000000-0000-4000-8000-000000000078') { exit 0 }
if ($joined -like 'cognitiveservices account deployment list *') {
    if ($args -contains 'json') {
        '[{"name":"claude-sonnet-5","sku":{"name":"GlobalStandard","capacity":20},"properties":{"provisioningState":"Succeeded","model":{"format":"Anthropic","name":"claude-sonnet-5","version":"2"}}}]'
    } else { 'claude-sonnet-5' }
    exit 0
}
if ($joined -like 'cognitiveservices account list *') {
    '[{"name":"ai-p78","n":"ai-p78","rg":"rg-ai-p78","loc":"eastus2","kind":"AIServices"}]'
    exit 0
}
if ($joined -like 'cognitiveservices account show *--query location *') { 'eastus2'; exit 0 }
if ($joined -like 'apim list *') { '[]'; exit 0 }
if ($joined -like 'apim show -g rg-ai-p78 -n apim-p78fixture *') {
    [Console]::Error.WriteLine('ERROR: (ResourceNotFound) fixture gateway does not exist.')
    exit 3
}
if ($joined -like 'apim nv show *--named-value-id entitlement-cache-seconds *') {
    [Console]::Error.WriteLine('ERROR: (ResourceNotFound) fixture gateway does not exist.')
    exit 3
}
[IO.File]::AppendAllText($env:P78_UNEXPECTED_CALLS, 'az ' + $joined + [Environment]::NewLine)
[Console]::Error.WriteLine('Unexpected offline az command: ' + $joined)
exit 97
'@
    [IO.File]::WriteAllText((Join-Path $Directory 'az-fixture.ps1'), $native)
    $ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $cmd = '@echo off' + "`r`n" + '"' + $ps51 + '" -NoProfile -File "%~dp0az-fixture.ps1" %*' +
        "`r`nexit /b %errorlevel%`r`n"
    [IO.File]::WriteAllText((Join-Path $Directory 'az.cmd'), $cmd, [Text.Encoding]::ASCII)
    $hostScript = @'
param([Parameter(Mandatory)][string]$Script, [ValidateSet('Wizard', 'Preflight')][string]$Mode)
$ErrorActionPreference = 'Stop'
$scratch = $PSScriptRoot
$env:AZURE_CONFIG_DIR = Join-Path $scratch 'azure'
$env:P78_AZ_CALLS = Join-Path $scratch 'az.calls'
$env:P78_UNEXPECTED_CALLS = Join-Path $scratch 'unexpected.calls'
$env:PATH = $scratch + ';' + $env:PATH
if ((Get-Command az -CommandType Application | Select-Object -First 1).Source -ne (Join-Path $scratch 'az.cmd')) {
    throw 'The native Azure CLI fixture was not selected.'
}
function Invoke-WebRequest {
    param($Uri, $Method, $TimeoutSec, $ErrorAction, [switch]$UseBasicParsing)
    if ([string]$Uri -ceq 'https://management.azure.com/' -and $Method -eq 'Head') {
        [IO.File]::AppendAllText((Join-Path $PSScriptRoot 'http.calls'), "management HEAD`n")
        return [pscustomobject]@{ StatusCode = 200 }
    }
    [IO.File]::AppendAllText($env:P78_UNEXPECTED_CALLS, "WEB $Uri`n")
    throw "Unexpected offline web request: $Uri"
}
function Invoke-RestMethod {
    param($Uri, $Method, $Headers, $Body, $ContentType, $TimeoutSec, $ErrorAction, [switch]$UseBasicParsing)
    $decoded = [uri]::UnescapeDataString([string]$Uri)
    if ($decoded -notmatch "^https://prices\.azure\.com/api/retail/prices\?.*serviceName eq 'API Management'") {
        [IO.File]::AppendAllText($env:P78_UNEXPECTED_CALLS, "REST $Uri`n")
        throw "Unexpected offline REST request: $Uri"
    }
    $rows = foreach ($pair in @(@('Basic v2 Unit', 0.21), @('Standard v2 Unit', 0.96), @('Premium v2 Unit', 3.84))) {
        [pscustomobject]@{
            meterName = $pair[0]; retailPrice = $pair[1]; type = 'Consumption'
            skuName = ($pair[0] -replace ' Unit$', ''); productName = 'API Management'
            tierMinimumUnits = 0; unitOfMeasure = '1 Hour'; currencyCode = 'USD'; armRegionName = 'eastus2'
        }
    }
    [pscustomobject]@{ Items = @($rows); NextPageLink = $null }
}
if ($Mode -eq 'Preflight') {
    . $Script
    $result = Test-ClaudePrerequisites -Mode Admin
    Write-Host "RESULT=$result"
}
else {
    & $Script -WhatIf -NamePrefix p78fixture -Sku BasicV2 -PublisherEmail ops@contoso.com -SkipFinOpsOffer
    if (-not $?) { throw 'The wizard returned a failed exit status.' }
}
exit 0
'@
    $path = Join-Path $Directory 'offline-host.ps1'
    [IO.File]::WriteAllText($path, $hostScript)
    $path
}
