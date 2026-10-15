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
function Capture([scriptblock]$Block) {
    $script:Failure = ''
    try { & $Block }
    catch { $script:Failure = $_.Exception.Message }
}

Write-Host ''
Write-Host 'P117 cross-tenant Foundry and customer DNS contracts' -ForegroundColor Cyan

$mainPath = Join-Path $root 'infra\main.bicep'
$policyPath = Join-Path $root 'infra\policy.xml'
$managedAuthPath = Join-Path $root 'infra\foundry-auth-managed-identity.xml'
$crossAuthPath = Join-Path $root 'infra\foundry-auth-client-credentials.xml'
$networkPath = Join-Path $root 'infra\projection-network.bicep'
$deployerPath = Join-Path $root 'scripts\Deploy-ClaudeProjection.ps1'
$installerPath = Join-Path $root 'Install-ClaudeGateway.ps1'
$preflightPath = Join-Path $root 'scripts\ClaudeInstallerPreflight.ps1'
$authHelperPath = Join-Path $root 'scripts\ClaudeFoundryAuthentication.ps1'
$schemaPath = Join-Path $root 'schemas\claude-gateway.answers.schema.json'

$main = Get-Content -LiteralPath $mainPath -Raw
$policy = Get-Content -LiteralPath $policyPath -Raw
$network = Get-Content -LiteralPath $networkPath -Raw
$deployer = Get-Content -LiteralPath $deployerPath -Raw
$installer = Get-Content -LiteralPath $installerPath -Raw
$preflight = Get-Content -LiteralPath $preflightPath -Raw
$schema = Get-Content -LiteralPath $schemaPath -Raw

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

Assert 'the installer exposes separate target and Foundry subscriptions' (
    $installer -match '\[string\]\$SubscriptionId' -and
    $installer -match '\[string\]\$FoundrySubscriptionId'
)
foreach ($parameter in @(
    'FoundryAuthenticationMode',
    'FoundryEndpoint',
    'FoundryTenantId',
    'FoundryClientId',
    'FoundryCredentialNamedValue',
    'ProjectionCosmosDnsZoneId',
    'ProjectionSitesDnsZoneId',
    'ProjectionBlobDnsZoneId',
    'ProjectionQueueDnsZoneId',
    'ProjectionTableDnsZoneId'
)) {
    Assert "the installer accepts $parameter" ($installer -match ('\$' + [regex]::Escape($parameter) + '\b'))
    Assert "the answers schema accepts $parameter" ($schema -match ('"' + [regex]::Escape($parameter) + '"\s*:'))
}
Assert 'the installer passes cross-tenant fields to main.bicep' (
    $installer -match 'foundryAuthenticationMode=\$FoundryAuthenticationMode' -and
    $installer -match 'foundryEndpoint=\$FoundryEndpoint' -and
    $installer -match 'foundryTenantId=\$FoundryTenantId' -and
    $installer -match 'foundryClientId=\$FoundryClientId' -and
    $installer -match 'foundryClientSecretNamedValue=\$FoundryCredentialNamedValue'
)
Assert 'the installer passes customer DNS ids through projection deployment' (
    $installer -match 'ProjectionCosmosDnsZoneId' -and
    $installer -match 'ProjectionTableDnsZoneId'
)
Assert 'a focused helper verifies secret metadata without a listValue call' (
    (Test-Path -LiteralPath $authHelperPath) -and
    $preflight -match 'Get-ClaudeApimNamedValueMetadata' -and
    $installer -match 'Get-ClaudeApimNamedValueMetadata' -and
    $installer -notmatch 'foundry-crosstenant-client-secret.+listValue'
)
if (Test-Path -LiteralPath $authHelperPath) {
    . $authHelperPath
    $seen = [Collections.Generic.List[string]]::new()
    $metadata = Get-ClaudeApimNamedValueMetadata -ResourceGroup rg-p117 -ApimName apim-p117 `
        -Id foundry-crosstenant-client-secret -SubscriptionId '11111111-2222-4333-8444-555555555555' `
        -InvokeRead {
            param([string[]]$Arguments)
            $seen.Add(($Arguments -join ' '))
            '{"name":"foundry-crosstenant-client-secret","secret":true,"value":"must-not-escape"}'
        }
    Assert 'metadata lookup returns only the identifier and secret flag' (
        $metadata.Id -eq 'foundry-crosstenant-client-secret' -and $metadata.Secret -eq $true -and
        -not $metadata.PSObject.Properties['Value'] -and
        ($seen -join ' ') -notmatch 'listValue'
    ) ($metadata | ConvertTo-Json -Depth 3)
    Capture {
        Assert-ClaudeFoundryAuthenticationConfiguration -Mode client-credentials `
            -Endpoint 'https://foundry.example.test/' -TenantId '11111111-2222-4333-8444-555555555555' `
            -ClientId 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee' -ClientSecretNamedValue $metadata.Id `
            -ExistingApimName apim-p117 -ClientSecretMetadata $metadata
    }
    Assert 'a complete cross-tenant configuration with secret metadata passes' (-not $Failure) $Failure
    Capture {
        Assert-ClaudeFoundryAuthenticationConfiguration -Mode client-credentials `
            -Endpoint 'https://foundry.example.test/' -TenantId '11111111-2222-4333-8444-555555555555' `
            -ClientId 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee' -ClientSecretNamedValue $metadata.Id `
            -ExistingApimName apim-p117 -ClientSecretMetadata ([pscustomobject]@{ Id=$metadata.Id; Secret=$false })
    }
    Assert 'a non-secret APIM named value is refused before deployment' (
        $Failure -match 'not marked secret' -and $Failure -match 'Nothing was changed'
    ) $Failure
}

Write-Host ''
if ($fail) {
    Write-Host "$fail of $count assertion(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host "$count cross-tenant production assertion(s) passed." -ForegroundColor Green
