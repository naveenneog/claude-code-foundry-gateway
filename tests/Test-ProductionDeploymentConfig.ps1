$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot -Parent
$catalogPath = Join-Path $root 'config\access-catalog.example.json'
$deploymentPath = Join-Path $root 'config\production-deployment.example.json'
$fail = 0
$count = 0

function Assert-ProductionConfig([string]$Label, [bool]$Condition, [string]$Detail = '') {
    $script:count++
    if ($Condition) {
        Write-Host "  [OK]   $Label" -ForegroundColor Green
    }
    else {
        Write-Host "  [FAIL] $Label$(if ($Detail) { " - $Detail" })" -ForegroundColor Red
        $script:fail++
    }
}

Write-Host ''
Write-Host 'P117 production deployment configuration' -ForegroundColor Cyan

Assert-ProductionConfig 'the nine-plan and 47-profile catalog exists' (Test-Path -LiteralPath $catalogPath -PathType Leaf)
Assert-ProductionConfig 'the sanitized production deployment example exists' (Test-Path -LiteralPath $deploymentPath -PathType Leaf)

$catalog = if (Test-Path -LiteralPath $catalogPath -PathType Leaf) {
    Get-Content -Raw -LiteralPath $catalogPath | ConvertFrom-Json -ErrorAction Stop
}
$deployment = if (Test-Path -LiteralPath $deploymentPath -PathType Leaf) {
    Get-Content -Raw -LiteralPath $deploymentPath | ConvertFrom-Json -ErrorAction Stop
}

if ($catalog) {
    Assert-ProductionConfig 'the catalog contains exactly nine plans' (@($catalog.plans).Count -eq 9) (@($catalog.plans).Count)
    Assert-ProductionConfig 'the catalog contains exactly 47 enabled access profiles' (
        @($catalog.profiles).Count -eq 47 -and -not @($catalog.profiles | Where-Object { -not $_.enabled }).Count
    ) (@($catalog.profiles).Count)
}

if ($deployment) {
    . (Join-Path $root 'scripts\ClaudeInstallerAnswers.ps1')
    $validation = @(Test-ClaudeInstallerAnswers -Answers $deployment -Consumer 'Install-ClaudeGateway.ps1')
    Assert-ProductionConfig 'the deployment example passes the canonical installer answers schema' (-not $validation.Count) (
        ($validation | ForEach-Object { "$($_.checkId): $($_.message)" }) -join '; '
    )
    $units = @($deployment.BusinessUnits)
    Assert-ProductionConfig 'the deployment example contains exactly 48 business units' ($units.Count -eq 48) $units.Count
    Assert-ProductionConfig 'the 48 business units are independent and have unique ids and groups' (
        -not @($units | Where-Object { $_.PSObject.Properties['parent'] }).Count -and
        @($units.id | Sort-Object -Unique).Count -eq 48 -and
        @($units.group | Sort-Object -Unique).Count -eq 48
    )
    Assert-ProductionConfig 'the deployment reuses Standard v2 APIM and selects the Cosmos projection' (
        [string]$deployment.ExistingApimName -and
        [string]$deployment.EntitlementStore -eq 'projection'
    )
    Assert-ProductionConfig 'the deployment uses a separate Foundry subscription with client credentials' (
        [string]$deployment.FoundrySubscriptionId -and
        [string]$deployment.FoundryAuthenticationMode -eq 'client-credentials' -and
        [string]$deployment.FoundryEndpoint -and
        [string]$deployment.FoundryTenantId -and
        [string]$deployment.FoundryClientId -and
        [string]$deployment.FoundryCredentialNamedValue
    )
    $networkFields = @(
        'ProjectionVnetId', 'ProjectionEndpointsSubnetId', 'ProjectionRunnerSubnetId',
        'ProjectionResolverSubnetId', 'ProjectionRenewalSubnetId', 'ProjectionApimSubnetId',
        'ProjectionCosmosDnsZoneId', 'ProjectionSitesDnsZoneId', 'ProjectionBlobDnsZoneId',
        'ProjectionQueueDnsZoneId', 'ProjectionTableDnsZoneId'
    )
    Assert-ProductionConfig 'the deployment supplies the customer VNet, five subnets and five central DNS zones' (
        [string]$deployment.ProjectionNetworkMode -eq 'existing' -and
        -not @($networkFields | Where-Object { -not [string]$deployment.$_ }).Count
    )
    Assert-ProductionConfig 'the scheduled projection job starts in manual mode' (
        [string]$deployment.ProjectionSyncInterval -eq 'manual'
    )
    $serialized = $deployment | ConvertTo-Json -Depth 12
    Assert-ProductionConfig 'the committed example contains placeholders rather than the live customer identifiers' (
        $serialized -notmatch 'd2885cb9-fed7-44e5-bf35-834991ed5eb0|66db7d6e-9810-4e77-853a-164a7dbde561|ccof-poc-|32db3f22-0cbb-4806-9b12-36bcb0d3c625'
    )
}

Write-Host ''
if ($fail) {
    Write-Host "$fail of $count assertion(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host "$count production deployment assertion(s) passed." -ForegroundColor Green
