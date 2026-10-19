$ErrorActionPreference = 'Stop'
trap { Write-Host "  [FAIL] unexpected model-family quota error: $($_.Exception.Message)" -ForegroundColor Red; exit 1 }

$root = Split-Path $PSScriptRoot -Parent
$module = Join-Path $root 'scripts\ClaudeModelFamilyQuotas.ps1'
$policyPath = Join-Path $root 'infra\policy.xml'
$bicepPath = Join-Path $root 'infra\main.bicep'
$lifecyclePath = Join-Path $root 'scripts\flow\lib\LifecycleCommon.ps1'
$checkpointPath = Join-Path $root 'scripts\ClaudeInstallCheckpoint.ps1'
$installerPath = Join-Path $root 'Install-ClaudeGateway.ps1'
$testAllPath = Join-Path $root 'tests\Test-All.ps1'
$schemaPath = Join-Path $root 'schemas\claude-gateway.answers.schema.json'
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
Write-Host 'P118 installer model-family token quotas' -ForegroundColor Cyan

Assert 'the focused model-family quota module ships' (Test-Path -LiteralPath $module -PathType Leaf)
if (Test-Path -LiteralPath $module -PathType Leaf) {
    . $module

    Assert 'a discovered generated-name gateway counts as existing for quota preservation' (
        (Test-ClaudeModelFamilyQuotaExistingGateway -ExistingApim '' -LiveApimId '/subscriptions/example/apim-generated') -and
        -not (Test-ClaudeModelFamilyQuotaExistingGateway -ExistingApim '' -LiveApimId '')
    )

    $preserveIntent = Resolve-ClaudeModelFamilyQuotaIntent -ExistingGateway $true `
        -StandardMonthlyUsdSpecified $false -PremiumMonthlyUsdSpecified $false `
        -OutputShareSpecified $false -Unattended $false
    Assert 'an ordinary existing-gateway rerun preserves the live quota map' (
        -not $preserveIntent.Recalculate -and -not $preserveIntent.InputsSpecified
    ) ($preserveIntent | ConvertTo-Json -Compress)

    $newIntent = Resolve-ClaudeModelFamilyQuotaIntent -ExistingGateway $false `
        -StandardMonthlyUsdSpecified $false -PremiumMonthlyUsdSpecified $false `
        -OutputShareSpecified $false -Unattended $true
    Assert 'a new gateway records its prompted or default quota choice' (
        $newIntent.Recalculate -and $newIntent.InputsSpecified
    ) ($newIntent | ConvertTo-Json -Compress)

    $outputOnlyError = ''
    try {
        Resolve-ClaudeModelFamilyQuotaIntent -ExistingGateway $true `
            -StandardMonthlyUsdSpecified $false -PremiumMonthlyUsdSpecified $false `
            -OutputShareSpecified $true -Unattended $false | Out-Null
    }
    catch { $outputOnlyError = $_.Exception.Message }
    Assert 'output share alone cannot disable an existing quota map' (
        $outputOnlyError -match 'no monthly USD allowance'
    ) $outputOnlyError

    $oneTierUnattendedError = ''
    try {
        Resolve-ClaudeModelFamilyQuotaIntent -ExistingGateway $true `
            -StandardMonthlyUsdSpecified $true -PremiumMonthlyUsdSpecified $false `
            -OutputShareSpecified $false -Unattended $true | Out-Null
    }
    catch { $oneTierUnattendedError = $_.Exception.Message }
    Assert 'an unattended existing-gateway change requires both tier amounts' (
        $oneTierUnattendedError -match 'requires both'
    ) $oneTierUnattendedError

    $deployments = @(
        [pscustomobject]@{ name = 'fast'; model = 'claude-haiku-4.5'; sku = 'GlobalStandard' }
        [pscustomobject]@{ name = 'balanced'; model = 'claude-sonnet-5'; sku = 'GlobalStandard' }
        [pscustomobject]@{ name = 'deep'; model = 'claude-opus-5'; sku = 'GlobalStandard' }
    )
    $priceBook = Join-Path $root 'config\price-book.example.json'
    $plan = New-ClaudeModelFamilyQuotaPlan -StandardMonthlyUsd 100 -PremiumMonthlyUsd 300 `
        -StandardModels @('fast', 'balanced') -PremiumModels @('balanced', 'deep') `
        -Deployments $deployments -PriceBookPath $priceBook -OutputShare 0.2

    Assert 'the plan emits one quota for each allowed tier-family pair' (
        @($plan.Entries).Count -eq 4 -and
        (@($plan.Entries | ForEach-Object { "$($_.Tier):$($_.Family)" }) -join ',') -eq
            'standard:haiku,standard:sonnet,premium:sonnet,premium:opus'
    ) ($plan.Entries | ConvertTo-Json -Compress)
    Assert 'the plan retains exact deployment aliases for policy family resolution' (
        @($plan.DeploymentFamilies).Count -eq 3 -and
        (@($plan.DeploymentFamilies | ForEach-Object { "$($_.Name)=$($_.Family)" } | Sort-Object) -join ',') -eq
            'balanced=sonnet,deep=opus,fast=haiku'
    ) ($plan.DeploymentFamilies | ConvertTo-Json -Compress)
    $prefixAliasPlan = New-ClaudeModelFamilyQuotaPlan -StandardMonthlyUsd 100 -PremiumMonthlyUsd 0 `
        -StandardModels @('claude-haiku-cheap') -PremiumModels @() `
        -Deployments @([pscustomobject]@{ name = 'claude-haiku-cheap'; model = 'claude-opus-5'; sku = 'GlobalStandard' }) `
        -PriceBookPath $priceBook -OutputShare 0.2
    Assert 'an exact alias mapping overrides a misleading family-shaped deployment name' (
        $prefixAliasPlan.DeploymentFamilies[0].Family -eq 'opus'
    ) ($prefixAliasPlan.DeploymentFamilies | ConvertTo-Json -Compress)

    $byKey = @{}
    foreach ($entry in $plan.Entries) { $byKey["$($entry.Tier):$($entry.Family)"] = $entry }
    Assert 'the tier allowance is split equally and expensive families receive fewer tokens' (
        $byKey['standard:haiku'].AllocatedUsd -eq 50 -and
        $byKey['standard:sonnet'].AllocatedUsd -eq 50 -and
        $byKey['standard:haiku'].TokensPerMonth -eq 27777777 -and
        $byKey['standard:sonnet'].TokensPerMonth -eq 13888888 -and
        $byKey['premium:sonnet'].TokensPerMonth -eq 41666666 -and
        $byKey['premium:opus'].TokensPerMonth -eq 16666666
    ) ($plan.Entries | ConvertTo-Json -Compress)
    Assert 'the plan states its approximation inputs and dated source' (
        $plan.OutputShare -eq 0.2 -and $plan.PriceBookDate -eq '2026-10-08' -and
        $plan.IsEstimate -eq $true
    ) ($plan | ConvertTo-Json -Depth 6 -Compress)

    $sameFamilyPlan = New-ClaudeModelFamilyQuotaPlan -StandardMonthlyUsd 100 -PremiumMonthlyUsd 0 `
        -StandardModels @('sonnet-new', 'sonnet-old') -PremiumModels @() `
        -Deployments @(
            [pscustomobject]@{ name = 'sonnet-new'; model = 'claude-sonnet-5'; sku = 'GlobalStandard' }
            [pscustomobject]@{ name = 'sonnet-old'; model = 'claude-sonnet-4-5'; sku = 'GlobalStandard' }
        ) -PriceBookPath $priceBook -OutputShare 0.2
    Assert 'multiple selected deployments in one family use one quota at the highest blended rate' (
        @($sameFamilyPlan.Entries).Count -eq 1 -and
        $sameFamilyPlan.Entries[0].Family -eq 'sonnet' -and
        $sameFamilyPlan.Entries[0].AllocatedUsd -eq 100 -and
        $sameFamilyPlan.Entries[0].BlendedUsdPerM -eq 5.4 -and
        $sameFamilyPlan.Entries[0].TokensPerMonth -eq 18518518
    ) ($sameFamilyPlan.Entries | ConvertTo-Json -Compress)
    $allOutputPlan = New-ClaudeModelFamilyQuotaPlan -StandardMonthlyUsd 100 -PremiumMonthlyUsd 0 `
        -StandardModels @('sonnet-old') -PremiumModels @() `
        -Deployments @([pscustomobject]@{ name = 'sonnet-old'; model = 'claude-sonnet-4-5'; sku = 'GlobalStandard' }) `
        -PriceBookPath $priceBook -OutputShare 1
    Assert 'a 100 percent output assumption is accepted' (
        $allOutputPlan.Entries[0].BlendedUsdPerM -eq 15 -and
        $allOutputPlan.Entries[0].TokensPerMonth -eq 6666666
    ) ($allOutputPlan.Entries | ConvertTo-Json -Compress)
    Assert 'all supported family names are classified canonically' (
        (Get-ClaudeModelFamily 'claude-haiku-4-5') -eq 'haiku' -and
        (Get-ClaudeModelFamily 'claude-sonnet-5') -eq 'sonnet' -and
        (Get-ClaudeModelFamily 'claude-opus-5') -eq 'opus' -and
        (Get-ClaudeModelFamily 'claude-fable-5-1') -eq 'fable' -and
        (Get-ClaudeModelFamily 'claude-mythos-1') -eq 'mythos'
    )

    $value = ConvertTo-ClaudeModelFamilyQuotaValue -Entries $plan.Entries -DeploymentFamilies $plan.DeploymentFamilies
    Assert 'serialization is canonical and sentinel-delimited' (
        $value -eq ',deployment:balanced=sonnet,deployment:deep=opus,deployment:fast=haiku,standard:haiku=27777777,standard:sonnet=13888888,premium:sonnet=41666666,premium:opus=16666666,'
    ) $value
    Assert 'empty serialization is the disabled sentinel' (
        (ConvertTo-ClaudeModelFamilyQuotaValue -Entries @()) -eq ',,'
    )
    $duplicateError = ''
    try {
        ConvertTo-ClaudeModelFamilyQuotaValue -Entries @(
            [pscustomobject]@{ Tier = 'standard'; Family = 'haiku'; TokensPerMonth = 1 }
            [pscustomobject]@{ Tier = 'standard'; Family = 'haiku'; TokensPerMonth = 2 }
        ) | Out-Null
    }
    catch { $duplicateError = $_.Exception.Message }
    Assert 'duplicate tier-family entries refuse serialization' (
        $duplicateError -match 'Duplicate model-family quota for standard:haiku'
    ) $duplicateError

    $unpriced = ''
    try {
        New-ClaudeModelFamilyQuotaPlan -StandardMonthlyUsd 50 -PremiumMonthlyUsd 0 `
            -StandardModels @('future') -PremiumModels @() `
            -Deployments @([pscustomobject]@{ name = 'future'; model = 'claude-mythos-1'; sku = 'GlobalStandard' }) `
            -PriceBookPath $priceBook | Out-Null
    }
    catch { $unpriced = $_.Exception.Message }
    Assert 'an unpriced selected family refuses instead of becoming free' (
        $unpriced -match 'mythos' -and $unpriced -match 'price book'
    ) $unpriced

    $zeroPricePath = Join-Path $root '.test-work\p118-zero-price.json'
    New-Item -ItemType Directory -Path (Split-Path $zeroPricePath) -Force | Out-Null
    [IO.File]::WriteAllText($zeroPricePath, '{"date":"2026-10-19","source":"test","models":{"claude-haiku-zero":{"inputPerM":0,"outputPerM":0}}}')
    $zeroPriceError = ''
    try {
        New-ClaudeModelFamilyQuotaPlan -StandardMonthlyUsd 50 -PremiumMonthlyUsd 0 `
            -StandardModels @('zero') -PremiumModels @() `
            -Deployments @([pscustomobject]@{ name = 'zero'; model = 'claude-haiku-zero'; sku = 'GlobalStandard' }) `
            -PriceBookPath $zeroPricePath | Out-Null
    }
    catch { $zeroPriceError = $_.Exception.Message }
    finally { Remove-Item -LiteralPath $zeroPricePath -Force -ErrorAction SilentlyContinue }
    Assert 'a zero blended price refuses with the price-book remedy' (
        $zeroPriceError -match 'zero blended price' -and $zeroPriceError -match 'price'
    ) $zeroPriceError
}

$policy = Get-Content -Raw -LiteralPath $policyPath
$bicep = Get-Content -Raw -LiteralPath $bicepPath
$lifecycle = Get-Content -Raw -LiteralPath $lifecyclePath
$checkpoint = Get-Content -Raw -LiteralPath $checkpointPath
$installer = Get-Content -Raw -LiteralPath $installerPath
$testAll = Get-Content -Raw -LiteralPath $testAllPath
$schema = Get-Content -Raw -LiteralPath $schemaPath | ConvertFrom-Json

$familyExpression = [regex]::Match(
    $policy, '<set-variable name="modelFamily" value="@\{(?<code>.*?)\}" />',
    [Text.RegularExpressions.RegexOptions]::Singleline)
$quotaExpression = [regex]::Match(
    $policy, '<set-variable name="modelFamilyQuota" value="@\{(?<code>.*?)\}" />',
    [Text.RegularExpressions.RegexOptions]::Singleline)
Assert 'the policy family and quota expressions can be extracted for behavior tests' (
    $familyExpression.Success -and $quotaExpression.Success
)
if ($familyExpression.Success -and $quotaExpression.Success) {
    $familyCode = [Net.WebUtility]::HtmlDecode($familyExpression.Groups['code'].Value).
        Replace('var model = (string)context.Variables["modelName"];', '').
        Replace('var map = "{{model-family-quotas}}";', '')
    $quotaCode = [Net.WebUtility]::HtmlDecode($quotaExpression.Groups['code'].Value).
        Replace('var tier = (string)context.Variables["tier"];', '').
        Replace('var family = (string)context.Variables["modelFamily"];', '').
        Replace('var map = "{{model-family-quotas}}";', '')
    Add-Type -TypeDefinition @"
using System;
public static class P118PolicyContract {
    public static string Family(string model, string map) {
$familyCode
    }
    public static long Quota(string tier, string family, string map) {
$quotaCode
    }
}
"@ -ErrorAction Stop
    $policyMap = ',deployment:fast=haiku,standard:haiku=100,standard:sonnet=200,'
    Assert 'the policy resolves canonical and aliased deployment families' (
        [P118PolicyContract]::Family('claude-sonnet-5', $policyMap) -eq 'sonnet' -and
        [P118PolicyContract]::Family('fast', $policyMap) -eq 'haiku' -and
        [P118PolicyContract]::Family('claude-haiku-cheap', ',deployment:claude-haiku-cheap=opus,standard:opus=100,') -eq 'opus' -and
        [P118PolicyContract]::Family('unknown', $policyMap) -eq ''
    )
    Assert 'the policy distinguishes disabled tiers from missing enabled-family entries' (
        [P118PolicyContract]::Quota('standard', 'haiku', $policyMap) -eq 100 -and
        [P118PolicyContract]::Quota('premium', 'opus', $policyMap) -eq 0 -and
        [P118PolicyContract]::Quota('standard', 'opus', $policyMap) -eq -1
    )
    Assert 'the policy rejects malformed, non-positive and duplicate family entries' (
        [P118PolicyContract]::Quota('standard', 'haiku', ',standard:haiku=oops,') -eq -1 -and
        [P118PolicyContract]::Quota('standard', 'haiku', ',standard:haiku=0,') -eq -1 -and
        [P118PolicyContract]::Quota('standard', 'haiku', ',standard:haiku=1,standard:haiku=2,') -eq -1
    )
}

Assert 'the policy enforces a monthly user-tier-family quota after model authorization' (
    $policy -match '\{\{model-family-quotas\}\}' -and
    $policy -match 'token-quota-period="Monthly"' -and
    $policy -match 'modelFamilyQuota' -and
    $policy.IndexOf('name="modelAllowed"') -ge 0 -and
    $policy.IndexOf('<include-fragment fragment-id="content-safety-screening" />') -ge 0 -and
    $policy.IndexOf('<set-variable name="budget" value="organisation" />') -ge 0 -and
    $policy.IndexOf('name="modelAllowed"') -lt $policy.IndexOf('name="modelFamilyQuota"') -and
    $policy.IndexOf('<include-fragment fragment-id="content-safety-screening" />') -lt $policy.IndexOf('name="modelFamilyQuota"') -and
    $policy.IndexOf('<set-variable name="budget" value="organisation" />') -lt $policy.IndexOf('<set-variable name="budget" value="model family" />') -and
    $policy -match 'deployment:" \+ model \+ "="' -and
    $policy -match 'marker = "," \+ tier \+ ":" \+ family \+ "="' -and
    $policy -match 'userId"\] \+ ":family:" \+ \(string\)context\.Variables\["tier"\] \+ ":" \+ \(string\)context\.Variables\["modelFamily"\]'
)
Assert 'an enabled tier with a missing or malformed family quota fails closed' (
    $policy -match 'tierEnabled' -and
    $policy -match 'if \(start &lt; 0\) \{ return \(long\)-1; \}' -and
    $policy -match 'return \(long\)-1' -and
    $policy -match 'model_family_quota_config_invalid' -and
    $policy -match 'code="503"'
)
Assert 'a family-quota refusal names the model-family budget and family' (
    $policy -match '<set-variable name="budget" value="model family" />' -and
    $policy -match '<set-variable name="budgetUnit" value="@\(\(string\)context\.Variables\["modelFamily"\]\)" />' -and
    $policy -match 'which == "model family"' -and
    $policy -match 'model family is spent for this month'
)
Assert 'Bicep deploys and preserves one model-family quota named value' (
    $bicep -match 'param modelFamilyQuotasExisting string' -and
    $bicep -match "key: 'model-family-quotas'" -and
    $bicep -match 'value: modelFamilyQuotasValue'
)
Assert 'policy-update flows create a disabled family-quota value on older gateways' (
    $lifecycle -match "model-family-quotas[^\r\n]+\{ ',,'; break \}"
)
Assert 'the installer accepts dollar inputs, previews the plan and forwards the named value' (
    $installer -match '\[decimal\]\$StandardMonthlyUsd' -and
    $installer -match '\[decimal\]\$PremiumMonthlyUsd' -and
    $installer -match 'New-ClaudeModelFamilyQuotaPlan' -and
    $installer -match 'Get-ApimNamedValue -ResourceGroup \$ResourceGroup -ApimName \$apimName' -and
    $installer -match "-Id 'model-family-quotas' -FailOnError -SubscriptionId \`$SubscriptionId" -and
    $installer -match 'Assert-AzArgumentsSafe -Values \(\[ordered\]@\{ ModelFamilyQuotas = \$modelFamilyQuotas \}\)' -and
    $installer -match 'modelFamilyQuotasExisting=\$modelFamilyQuotas' -and
    $installer -match 'if \(-not \$modelFamilyQuotas\) \{ \$modelFamilyQuotas = \$modelFamilyQuotasExisting \}' -and
    $installer -match 'Test-ClaudeModelFamilyQuotaExistingGateway' -and
    $installer -match 'Resolve-ClaudeModelFamilyQuotaIntent -ExistingGateway \$existingGatewayForModelQuotas' -and
    $installer -match 'Model-family quota details included in this approval'
)
Assert 'the packet gate runs the family-quota behavior and mutation suites' (
    $testAll -match "Test-ModelFamilyQuotas\.ps1" -and
    $testAll -match "Test-ModelFamilyQuotaMutations\.ps1"
)
Assert 'the install checkpoint fingerprints quota logic and its dated price book' (
    $checkpoint -match "'scripts/ClaudeModelFamilyQuotas\.ps1'" -and
    $checkpoint -match "'scripts/ClaudeModelPrices\.ps1'" -and
    $checkpoint -match "'config/price-book\.example\.json'" -and
    $checkpoint -match "modelFamilyQuotaInputsSpecified"
)
Assert 'the answer schema exposes both optional tier dollar inputs' (
    $schema.properties.StandardMonthlyUsd.type -eq 'number' -and
    $schema.properties.PremiumMonthlyUsd.type -eq 'number' -and
    $schema.properties.ModelQuotaOutputShare.type -eq 'number' -and
    $schema.properties.ModelQuotaOutputShare.minimum -eq 0 -and
    $schema.properties.ModelQuotaOutputShare.maximum -eq 1 -and
    $schema.properties.ModelQuotaOutputShare.description -notmatch 'conservative'
)

Write-Host ''
if ($fail) { Write-Host "$fail of $count assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "$count model-family quota assertion(s) passed." -ForegroundColor Green
