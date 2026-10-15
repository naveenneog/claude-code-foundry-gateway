$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$fail = 0
$count = 0

function Assert([string]$Label, [bool]$Condition, [string]$Detail = '') {
    $script:count++
    if ($Condition) { Write-Host "  [OK]   $Label" -ForegroundColor Green }
    else {
        Write-Host "  [FAIL] $Label$(if ($Detail) { " - $Detail" })" -ForegroundColor Red
        $script:fail++
    }
}

Write-Host ''
Write-Host 'P117 cross-tenant Foundry and customer DNS contracts' -ForegroundColor Cyan

$mainPath = Join-Path $root 'infra\main.bicep'
$policyPath = Join-Path $root 'infra\policy.xml'
$managedAuthPath = Join-Path $root 'infra\foundry-auth-managed-identity.xml'
$crossAuthPath = Join-Path $root 'infra\foundry-auth-client-credentials.xml'
$networkPath = Join-Path $root 'infra\projection-network.bicep'
$deployerPath = Join-Path $root 'scripts\Deploy-ClaudeProjection.ps1'

$main = Get-Content -LiteralPath $mainPath -Raw
$policy = Get-Content -LiteralPath $policyPath -Raw
$network = Get-Content -LiteralPath $networkPath -Raw
$deployer = Get-Content -LiteralPath $deployerPath -Raw

Assert 'main declares the opt-in Foundry authentication mode' (
    $main -match "param foundryAuthenticationMode string = 'managed-identity'" -and
    $main -match "'client-credentials'"
)
Assert 'main takes an explicit cross-tenant endpoint, tenant and client id' (
    $main -match 'param foundryEndpoint string' -and
    $main -match 'param foundryTenantId string' -and
    $main -match 'param foundryClientId string'
)
Assert 'main keeps the existing secret as a named-value reference rather than a value' (
    $main -match "param foundryClientSecretNamedValue string = 'foundry-crosstenant-client-secret'" -and
    $main -notmatch 'param foundryClientSecret(?!NamedValue)'
)
Assert 'the Foundry ARM reference is conditional on managed identity mode' (
    $main -match "resource foundry .* existing = if \(foundryAuthenticationMode == 'managed-identity'\)"
)
Assert 'the Foundry role grant cannot run in client-credential mode' (
    $main -match "if \(grantFoundryRole && foundryAuthenticationMode == 'managed-identity'\)"
)
Assert 'the API and output use one effective endpoint for either tenant shape' (
    $main -match 'var effectiveFoundryEndpoint' -and
    $main -match "serviceUrl: '\$\{effectiveFoundryEndpoint\}anthropic'" -and
    $main -match 'output foundryEndpoint string = effectiveFoundryEndpoint'
)
Assert 'the main policy has one replaceable Foundry authentication marker' (
    ([regex]::Matches($policy, '<!-- FOUNDRY_AUTHENTICATION -->')).Count -eq 1
)
Assert 'managed identity authentication remains in its own fragment' (Test-Path -LiteralPath $managedAuthPath)
Assert 'client-credential authentication remains in its own fragment' (Test-Path -LiteralPath $crossAuthPath)
if (Test-Path -LiteralPath $managedAuthPath) {
    $managedAuth = Get-Content -LiteralPath $managedAuthPath -Raw
    Assert 'the managed fragment obtains a Cognitive Services managed-identity token' (
        $managedAuth -match '<authentication-managed-identity' -and
        $managedAuth -match 'resource="https://cognitiveservices.azure.com"'
    )
}
if (Test-Path -LiteralPath $crossAuthPath) {
    $crossAuth = Get-Content -LiteralPath $crossAuthPath -Raw
    Assert 'the cross-tenant fragment requests the client-credential scope' (
        $crossAuth -match '__FOUNDRY_TENANT_ID__' -and
        $crossAuth -match '__FOUNDRY_CLIENT_ID__' -and
        $crossAuth -match '__FOUNDRY_CLIENT_SECRET_NAMED_VALUE__' -and
        $crossAuth -match 'https%3A%2F%2Fcognitiveservices.azure.com%2F.default'
    )
    Assert 'the cross-tenant fragment caches the token and fails on a refused token request' (
        $crossAuth -match '<cache-lookup-value' -and
        $crossAuth -match '<cache-store-value' -and
        $crossAuth -match 'foundry_token_failed'
    )
}
Assert 'main inserts only the selected authentication fragment into the policy' (
    $main -match "loadTextContent\('foundry-auth-managed-identity.xml'\)" -and
    $main -match "loadTextContent\('foundry-auth-client-credentials.xml'\)" -and
    $main -match "replace\(\s*loadTextContent\('policy.xml'\)"
)

$zoneParams = @(
    'cosmosDnsZoneId',
    'sitesDnsZoneId',
    'blobDnsZoneId',
    'queueDnsZoneId',
    'tableDnsZoneId'
)
foreach ($zoneParam in $zoneParams) {
    Assert "network accepts optional $zoneParam" ($network -match "param $zoneParam string = ''")
}
Assert 'customer-owned DNS zones are not created or linked when their ids are supplied' (
    $network -match 'if \(empty\(cosmosDnsZoneId\)\)' -and
    $network -match 'if \(empty\(sitesDnsZoneId\)\)' -and
    $network -match 'if \(empty\(blobDnsZoneId\)\)' -and
    $network -match 'if \(empty\(queueDnsZoneId\)\)' -and
    $network -match 'if \(empty\(tableDnsZoneId\)\)'
)
Assert 'Cosmos private endpoint uses the selected existing-or-created zone id' (
    $network -match 'privateDnsZoneId: effectiveCosmosDnsZoneId'
)
foreach ($zoneParam in $zoneParams) {
    Assert "the projection deployer passes $zoneParam" ($deployer -match $zoneParam)
}

Write-Host ''
if ($fail) {
    Write-Host "$fail of $count assertion(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host "$count cross-tenant production assertion(s) passed." -ForegroundColor Green
