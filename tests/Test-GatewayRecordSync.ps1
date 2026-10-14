# P115: regenerate the local onboarding record from live gateway reads only.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$scriptPath = Join-Path $root 'scripts\Sync-ClaudeGatewayRecord.ps1'
$fail = 0
$assertions = 0
function Assert($Label, [bool]$Condition, $Detail = '') {
    $script:assertions++
    if ($Condition) { Write-Host "  [OK]   $Label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $Label$(if ($Detail) { " - $Detail" })" -ForegroundColor Red; $script:fail++ }
}
function Refusal([scriptblock]$Action) {
    try { & $Action | Out-Null; return '' } catch { return $_.Exception.Message }
}

Write-Host ''
Write-Host 'Gateway onboarding record sync' -ForegroundColor Cyan
Assert 'the record sync script exists' (Test-Path -LiteralPath $scriptPath -PathType Leaf) $scriptPath
if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
    Write-Host "Assertions: $assertions"
    exit 1
}

$scratch = Join-Path ([IO.Path]::GetTempPath()) ('gateway-record-sync-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch -Force | Out-Null
$subscription = '11111111-1111-4111-8111-111111111111'
$tenant = '22222222-2222-4222-8222-222222222222'
$standardId = '33333333-3333-4333-8333-333333333333'
$premiumId = '44444444-4444-4444-8444-444444444444'
$global:P115AzCalls = [Collections.Generic.List[string]]::new()
$global:P115IncludeEntitlementGroups = $false
$global:P115Backend = 'https://ai-sync.services.ai.azure.com/anthropic'
$global:P115EntitlementGroups = "standard=$standardId,premium=$premiumId"

function global:az {
    $line = @($args | ForEach-Object { [string]$_ }) -join ' '
    $global:P115AzCalls.Add($line)
    $global:LASTEXITCODE = 0
    if ($line -match '^account show ') {
        return (@{ id = $subscription; tenantId = $tenant } | ConvertTo-Json -Compress)
    }
    if ($line -match '^apim show -g rg-sync -n apim-sync ') {
        return (@{
            id = "/subscriptions/$subscription/resourceGroups/rg-sync/providers/Microsoft.ApiManagement/service/apim-sync"
            name = 'apim-sync'
            location = 'East US 2'
            gatewayUrl = 'https://apim-sync.azure-api.net'
            sku = @{ name = 'BasicV2'; capacity = 1 }
            hostnameConfigurations = @(@{ type = 'Proxy'; hostName = 'claude.contoso.example' })
        } | ConvertTo-Json -Depth 8 -Compress)
    }
    if ($line -match '^apim api show -g rg-sync --service-name apim-sync --api-id claude-foundry ') {
        return (@{ serviceUrl = $global:P115Backend } | ConvertTo-Json -Compress)
    }
    if ($line -match '^apim nv list -g rg-sync --service-name apim-sync ') {
        $rows = @(
            @{ name = 'tenant-id'; value = $tenant; secret = $false },
            @{ name = 'tpm-standard'; value = '21000'; secret = $false },
            @{ name = 'quota-standard'; value = '510000'; secret = $false },
            @{ name = 'tpm-premium'; value = '81000'; secret = $false },
            @{ name = 'quota-premium'; value = '5100000'; secret = $false },
            @{ name = 'quota-org'; value = '101000000'; secret = $false },
            @{ name = 'calls-per-minute'; value = '121'; secret = $false },
            @{ name = 'models-standard'; value = ',sonnet-live,'; secret = $false },
            @{ name = 'models-premium'; value = ',,'; secret = $false },
            @{ name = 'entitlement-source'; value = 'projection'; secret = $false },
            @{ name = 'entitlement-projection-prefix'; value = 'sync'; secret = $false }
        )
        if ($global:P115IncludeEntitlementGroups) {
            $rows += @{ name = 'entitlement-groups'; value = $global:P115EntitlementGroups; secret = $false }
        }
        return ($rows | ConvertTo-Json -Depth 5 -Compress)
    }
    if ($line -match '^resource list --name ai-sync --resource-type Microsoft.CognitiveServices/accounts ') {
        return (ConvertTo-Json -InputObject @(@{
            name = 'ai-sync'
            resourceGroup = 'rg-foundry'
            location = 'eastus2'
            id = "/subscriptions/$subscription/resourceGroups/rg-foundry/providers/Microsoft.CognitiveServices/accounts/ai-sync"
        }) -Depth 5 -Compress)
    }
    if ($line -match '^cognitiveservices account deployment list -g rg-foundry -n ai-sync ') {
        return (@(
            @{ name = 'sonnet-live'; properties = @{ provisioningState = 'Succeeded'; model = @{ name = 'claude-sonnet-5'; version = '2026-01-01'; format = 'Anthropic' } }; sku = @{ name = 'GlobalStandard'; capacity = 10 } },
            @{ name = 'opus-live'; properties = @{ provisioningState = 'Succeeded'; model = @{ name = 'claude-opus-5'; version = '2026-01-01'; format = 'Anthropic' } }; sku = @{ name = 'GlobalStandard'; capacity = 5 } },
            @{ name = 'failed-live'; properties = @{ provisioningState = 'Failed'; model = @{ name = 'claude-haiku-4-5'; version = '2026-01-01'; format = 'Anthropic' } }; sku = @{ name = 'GlobalStandard'; capacity = 1 } }
        ) | ConvertTo-Json -Depth 8 -Compress)
    }
    if ($line -match '^ad group show --group ') {
        $id = if ($line -match [regex]::Escape($standardId)) { $standardId } else { $premiumId }
        $name = if ($id -eq $standardId) { 'sync-standard' } else { 'sync-premium' }
        return (@{ id = $id; displayName = $name } | ConvertTo-Json -Compress)
    }
    throw "Unexpected az call: $line"
}

try {
    $recordPath = Join-Path $scratch 'existing\claude-gateway.json'
    New-Item -ItemType Directory -Path (Split-Path $recordPath -Parent) -Force | Out-Null
    [IO.File]::WriteAllText($recordPath, ([ordered]@{
        resourceGroup = 'rg-sync'
        apimName = 'apim-sync'
        gatewayUrl = 'https://claude.contoso.example/claude'
        standardGroup = 'existing-standard'
        premiumGroup = 'existing-premium'
        desktopSignIn = @{ kind = 'external-idp'; clientId = '55555555-5555-4555-8555-555555555555' }
        customField = 'preserved'
    } | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))

    $global:P115AzCalls.Clear()
    $result = & $scriptPath -ResourceGroup rg-sync -ApimName apim-sync -RecordPath $recordPath
    $record = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json
    Assert 'sync writes schema version 2' ($record.schemaVersion -eq 2)
    Assert 'sync records the live subscription and tenant' ($record.subscriptionId -eq $subscription -and $record.tenantId -eq $tenant)
    Assert 'sync records the live APIM and Foundry target' (
        $record.resourceGroup -eq 'rg-sync' -and $record.apimName -eq 'apim-sync' -and
        $record.location -eq 'eastus2' -and $record.foundryAccount -eq 'ai-sync' -and
        $record.foundryResourceGroup -eq 'rg-foundry')
    Assert 'sync preserves a live configured company hostname' ($record.gatewayUrl -eq 'https://claude.contoso.example/claude')
    Assert 'sync preserves choices Azure does not own' (
        $record.standardGroup -eq 'existing-standard' -and $record.premiumGroup -eq 'existing-premium' -and
        $record.desktopSignIn.kind -eq 'external-idp' -and $record.customField -eq 'preserved')
    Assert 'sync reads live limits and serving store' (
        $record.entitlementStore -eq 'projection' -and $record.tiers.standard.tokensPerMinute -eq 21000 -and
        $record.tiers.premium.tokensPerDay -eq 5100000 -and $record.organisation.tokensPerMonth -eq 101000000 -and
        $record.requestsPerMinute -eq 121)
    Assert 'an explicit tier list stays explicit and allow-all expands to succeeded Claude deployments' (
        (@($record.tiers.standard.models) -join ',') -eq 'sonnet-live' -and
        (@($record.tiers.premium.models) -join ',') -eq 'opus-live,sonnet-live' -and
        (@($record.models) -join ',') -eq 'opus-live,sonnet-live')
    Assert 'failed deployments are excluded' (@($record.deployments.name) -notcontains 'failed-live')
    Assert 'the old record is backed up' ($result.BackupPath -and (Test-Path -LiteralPath $result.BackupPath))
    Assert 'the sync records release and history evidence' ($record.release -and @($record.history | Where-Object action -eq 'Sync').Count -eq 1)
    $writePattern = '(?i)\b(create|update|delete|set|deployment group create|role assignment create)\b'
    Assert 'the sync performs Azure reads only' (-not (@($global:P115AzCalls) -match $writePattern)) ($global:P115AzCalls -join ' | ')
    $global:P115AzCalls.Add('apim nv update -g rg-sync --service-name apim-sync --named-value-id tenant-id')
    Assert 'mutation detected: an Azure write makes the read-only detector fail' (
        -not (-not (@($global:P115AzCalls) -match $writePattern)))
    $global:P115AzCalls.RemoveAt($global:P115AzCalls.Count - 1)

    $missingPath = Join-Path $scratch 'missing\claude-gateway.json'
    $missing = Refusal { & $scriptPath -ResourceGroup rg-sync -ApimName apim-sync -RecordPath $missingPath }
    Assert 'a new record without an authoritative standard group refuses before writing' (
        $missing -match 'StandardGroup' -and -not (Test-Path -LiteralPath $missingPath)) $missing

    $global:P115IncludeEntitlementGroups = $true
    $newPath = Join-Path $scratch 'new\claude-gateway.json'
    $new = & $scriptPath -ResourceGroup rg-sync -ApimName apim-sync -RecordPath $newPath
    $newRecord = Get-Content -LiteralPath $newPath -Raw | ConvertFrom-Json
    Assert 'entitlement-groups can seed a new record' (
        $newRecord.standardGroup -eq 'sync-standard' -and $newRecord.premiumGroup -eq 'sync-premium')
    Assert 'a new record defaults to the documented helper-script desktop path' (
        $newRecord.authMode -eq 'interactive' -and $newRecord.desktopSignIn.kind -eq 'helper-script')
    Assert 'a new record has no backup path' (-not $new.BackupPath)

    $otherPath = Join-Path $scratch 'other\claude-gateway.json'
    New-Item -ItemType Directory -Path (Split-Path $otherPath -Parent) -Force | Out-Null
    '{"resourceGroup":"rg-other","apimName":"apim-other","standardGroup":"other-standard"}' |
        Set-Content -LiteralPath $otherPath -Encoding UTF8
    $beforeOtherCalls = $global:P115AzCalls.Count
    $other = Refusal { & $scriptPath -ResourceGroup rg-sync -ApimName apim-sync -RecordPath $otherPath }
    Assert 'a record for another gateway refuses before Azure reads or local writes' (
        $other -match 'not.*rg-sync/apim-sync' -and $global:P115AzCalls.Count -eq $beforeOtherCalls -and
        (Get-Content -LiteralPath $otherPath -Raw) -match 'rg-other') $other

    $global:P115Backend = 'https://example.invalid/anthropic'
    $foreignBackend = Refusal {
        & $scriptPath -ResourceGroup rg-sync -ApimName apim-sync -RecordPath $newPath -StandardGroup sync-standard
    }
    Assert 'a non-Foundry backend host refuses instead of inferring an account name' (
        $foreignBackend -match 'Foundry Anthropic endpoint') $foreignBackend
    $global:P115Backend = 'https://ai-sync.services.ai.azure.com/anthropic'

    $global:P115EntitlementGroups = "standard=not-a-guid,premium=$premiumId"
    $badGroups = Refusal {
        & $scriptPath -ResourceGroup rg-sync -ApimName apim-sync -RecordPath $newPath -StandardGroup sync-standard
    }
    Assert 'a malformed entitlement-groups value refuses instead of falling back to local groups' (
        $badGroups -match 'entitlement-groups') $badGroups
    $global:P115EntitlementGroups = "standard=$standardId,premium=$premiumId"

    $beforeUnsafeCalls = $global:P115AzCalls.Count
    $unsafe = Refusal { & $scriptPath -ResourceGroup 'rg&whoami' -ApimName apim-sync -RecordPath (Join-Path $scratch 'unsafe.json') }
    Assert 'cmd metacharacters are refused before Azure CLI' (
        $unsafe -match 'safe Azure resource name' -and $global:P115AzCalls.Count -eq $beforeUnsafeCalls) $unsafe
}
finally {
    Remove-Item Function:\az -ErrorAction SilentlyContinue
    Remove-Variable P115AzCalls -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable P115IncludeEntitlementGroups -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable P115Backend -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable P115EntitlementGroups -Scope Global -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "Assertions: $assertions"
if ($fail) { exit 1 }
Write-Host 'Gateway onboarding record sync contract holds.' -ForegroundColor Green
