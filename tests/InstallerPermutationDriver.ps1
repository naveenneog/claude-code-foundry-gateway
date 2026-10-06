# Runs Install-ClaudeGateway.ps1 under -WhatIf -Yes once per case, in this process, and writes one
# JSON line per case. tests/Test-InstallerPermutations.ps1 runs it on PowerShell 7 and on Windows
# PowerShell 5.1. Offline unless -Live: az, the Azure Retail Prices API and the reachability probe
# are functions here, and PowerShell resolves a function before the az.cmd application or a cmdlet.
param(
    [Parameter(Mandatory = $true)][string]$Installer,
    [Parameter(Mandatory = $true)][string]$CasesPath,
    [Parameter(Mandatory = $true)][string]$ResultsPath,
    [switch]$Live
)
$ErrorActionPreference = 'Stop'
# Global: inside a function, $script: names the running script's scope, which is the installer's.
$global:P72DriverCalls = New-Object System.Collections.Generic.List[string]
$global:P72DriverUnexpected = New-Object System.Collections.Generic.List[string]

if (-not $Live) {
    $global:P72DriverDeployments = (@(
        foreach ($m in @(@('claude-opus-5', 40), @('claude-sonnet-5', 20), @('claude-haiku-4-5', 50))) {
            [ordered]@{ name = $m[0]; sku = [ordered]@{ name = 'GlobalStandard'; capacity = $m[1] }; properties = [ordered]@{ provisioningState = 'Succeeded'; model = [ordered]@{ format = 'Anthropic'; name = $m[0]; version = '2' } } }
        }
    ) | ConvertTo-Json -Depth 6)
    $global:P72DriverExisting = [ordered]@{
        name = 'apim-p72live'; resourceGroup = 'rg-p72live'; location = 'East US 2'; publisherEmail = 'ops@contoso.com'
        sku = [ordered]@{ name = 'StandardV2'; capacity = 1 }; identity = [ordered]@{ type = 'SystemAssigned' }; gatewayUrl = 'https://apim-p72live.azure-api.net'
    } | ConvertTo-Json -Depth 4 -Compress
    $global:P72DriverProjection = [ordered]@{
        name = 'apim-p72projection'; resourceGroup = 'rg-p72projection'; location = 'East US 2'; publisherEmail = 'ops@contoso.com'
        sku = [ordered]@{ name = 'StandardV2'; capacity = 1 }; identity = [ordered]@{ type = 'SystemAssigned' }; gatewayUrl = 'https://apim-p72projection.azure-api.net'
    } | ConvertTo-Json -Depth 4 -Compress

    function az {
        $joined = $args -join ' '
        $global:P72DriverCalls.Add($joined)
        $global:LASTEXITCODE = 0
        if ($joined -like 'version*') { return "2.86.0`t2.86.0`t1.1.0`t" }
        if ($joined -like 'bicep version*') { return 'Bicep CLI version 0.46.1 (545b338e2c)' }
        if ($joined -like 'account list --query*') { return '00000000-0000-4000-8000-0000000000a1' }
        if ($joined -like 'account show --query name*') { return 'p72-subscription' }
        if ($joined -like 'account get-access-token*') { return '{"accessToken":"offline-token"}' }
        if ($joined -like 'account show*') { return '{"id":"00000000-0000-4000-8000-0000000000a1","name":"p72-subscription","state":"Enabled","tenantId":"00000000-0000-4000-8000-0000000000f1","user":{"name":"admin@contoso.com","type":"user"}}' }
        if ($joined -like 'account set --subscription *') { return }
        if ($joined -like 'cognitiveservices account deployment list *') { return $global:P72DriverDeployments }
        if ($joined -like 'apim show -g rg-p72live -n apim-p72live*--query id*') { return '/subscriptions/00000000-0000-4000-8000-0000000000a1/resourceGroups/rg-p72live/providers/Microsoft.ApiManagement/service/apim-p72live' }
        if ($joined -like 'apim show -g rg-p72live -n apim-p72live*') { return $global:P72DriverExisting }
        if ($joined -like 'apim show -g rg-p72projection -n apim-p72projection*--query id*') { return '/subscriptions/00000000-0000-4000-8000-0000000000a1/resourceGroups/rg-p72projection/providers/Microsoft.ApiManagement/service/apim-p72projection' }
        if ($joined -like 'apim show -g rg-p72projection -n apim-p72projection*') { return $global:P72DriverProjection }
        if ($joined -like 'apim show -g rg-p72 -n apim-p72perm*') { $global:LASTEXITCODE = 3; return 'ERROR: (ResourceNotFound) API Management service not found.' }
        if ($joined -like 'functionapp show -g rg-p72projection -n func-resolver-p72projection*publicNetworkAccess*') { return 'Disabled' }
        if ($joined -like 'apim nv show *apim-p72projection*entitlement-source*') { return 'projection' }
        if ($joined -like 'apim nv show *entitlement-source*') { return 'named-value' }
        # The projection a gateway records; a gateway without one answers as Azure does (exit 3, NamedValue not found).
        if ($joined -like 'apim nv show *apim-p72projection*entitlement-projection-prefix*') { return 'p72projection' }
        if ($joined -like 'apim nv show *entitlement-projection-prefix*') { $global:LASTEXITCODE = 3; return 'ERROR: (ResourceNotFound) NamedValue not found.' }
        # A gateway that never had the projection has no resolver site (exit 3, ResourceNotFound).
        if ($joined -like 'functionapp show *func-resolver-*publicNetworkAccess*') { $global:LASTEXITCODE = 3; return "ERROR: (ResourceNotFound) The Resource 'Microsoft.Web/sites/func-resolver' was not found." }
        if ($joined -like 'apim nv show *entitlement-resolver-url*') { return 'https://resolver-not-deployed.invalid' }
        if ($joined -like 'apim nv show *entitlement-resolver-audience*') { return 'https://resolver-not-deployed.invalid' }
        if ($joined -like 'apim nv show *entitlement-cache-seconds*') { $global:LASTEXITCODE = 3; return }
        $global:P72DriverUnexpected.Add($joined)
        $global:LASTEXITCODE = 2
    }
    function Invoke-RestMethod {
        param($Uri, $TimeoutSec, $ErrorAction, $Method, $Headers, $Body, $ContentType, [switch]$UseBasicParsing)
        $u = [uri]::UnescapeDataString([string]$Uri)
        $global:P72DriverCalls.Add("REST $u")
        if ($u -match 'https://graph.microsoft.com/v1.0/groups') {
            if ($u -match '/transitiveMembers/') { return [pscustomobject]@{ value=@() } }
            return [pscustomobject]@{ value=@([pscustomobject]@{ id='00000000-0000-4000-8000-0000000000aa' }) }
        }
        if ($u -notmatch "serviceName eq 'API Management'") { throw 'offline: only the API Management prices are stubbed' }
        $rows = foreach ($r in @(@('Basic v2 Unit', 0.21), @('Standard v2 Unit', 0.96), @('Premium v2 Unit', 3.84))) {
            [pscustomobject]@{ meterName = $r[0]; retailPrice = $r[1]; type = 'Consumption'; skuName = ($r[0] -replace ' Unit$', ''); productName = 'API Management'; tierMinimumUnits = 0; unitOfMeasure = '1 Hour'; currencyCode = 'USD'; armRegionName = 'eastus2' }
        }
        [pscustomobject]@{ Items = @($rows); NextPageLink = $null }
    }
    function Invoke-WebRequest {
        param($Uri, $Method, $TimeoutSec, $ErrorAction, [switch]$UseBasicParsing)
        $global:P72DriverCalls.Add("WEB $Uri")
        [pscustomobject]@{ StatusCode = 200 }
    }
}

function ConvertTo-SummaryRows([string[]]$Lines) {
    # The summary prints each row as two spaces, the name padded to 24 and the value.
    $rows = [ordered]@{}
    $at = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) { if ($Lines[$i].Trim() -eq 'Summary') { $at = $i } }
    if ($at -lt 0) { return $rows }
    for ($i = $at + 1; $i -lt $Lines.Count; $i++) {
        $line = $Lines[$i].TrimEnd()
        if ($line -match 'WhatIf - stopping') { break }
        # Column 26 is the space between the padded name and the value; a wrapped note has text there.
        if ($line.Length -gt 27 -and $line.StartsWith('  ') -and $line[2] -ne ' ' -and $line[26] -eq ' ' -and $line.Substring(2, 24).Trim() -match '^[A-Za-z][A-Za-z -]*$') {
            $rows[$line.Substring(2, 24).Trim()] = $line.Substring(27).Trim()
        }
    }
    return $rows
}

$cases = Get-Content -LiteralPath $CasesPath -Raw | ConvertFrom-Json
foreach ($case in @($cases)) {
    $global:P72DriverCalls.Clear()
    $global:P72DriverUnexpected.Clear()
    $params = @{ Yes = $true; WhatIf = $true; SkipFinOpsOffer = $true }
    foreach ($p in $case.params.PSObject.Properties) { $params[$p.Name] = $p.Value }
    $lines = New-Object System.Collections.Generic.List[string]
    $failure = ''
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try { & $Installer @params *>&1 | ForEach-Object { foreach ($l in ([string]$_ -split "`r?`n")) { $lines.Add($l) } } }
    catch { $failure = $_.Exception.Message }
    $seconds = [math]::Round($watch.Elapsed.TotalSeconds, 2)
    $text = $lines.ToArray()
    $audience = @($text | Where-Object { $_ -match 'Desktop gateway audience:\s*(\S+)' } | ForEach-Object { $Matches[1] })
    $address = @($text | Where-Object { $_ -match '^\s+azure\s+https://' })
    $result = [ordered]@{
        id = [string]$case.id
        shell = [string]$PSVersionTable.PSVersion
        seconds = $seconds
        reachedSummary = [bool](@($text | Where-Object { $_ -match 'WhatIf - stopping before any change' }).Count)
        sawSummary = [bool](@($text | Where-Object { $_.Trim() -eq 'Summary' }).Count)
        failure = $failure
        rows = ConvertTo-SummaryRows -Lines $text
        audience = $(if ($audience.Count) { $audience[0] } else { '' })
        addressLine = $(if ($address.Count) { $address[0].Trim() } else { '' })
        unexpected = @($global:P72DriverUnexpected)
        calls = @($global:P72DriverCalls)
        lineCount = $text.Count
        tail = @($text | Where-Object { $_.Trim() } | Select-Object -Last 6)
    }
    Add-Content -LiteralPath $ResultsPath -Value ($result | ConvertTo-Json -Depth 5 -Compress) -Encoding UTF8
}
