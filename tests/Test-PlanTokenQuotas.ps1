# P123: token limits per access plan and model family, derived from each plan's dollar credit (ADR-0069).
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$script:fail = 0
$script:count = 0
$expected = 14
function Assert([string]$Label, [bool]$Condition, [string]$Detail = '') {
    $script:count++
    if ($Condition) { Write-Host "  [OK]   $Label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $Label$(if ($Detail) { " - $Detail" })" -ForegroundColor Red; $script:fail++ }
}

Write-Host ''
Write-Host 'P123 plan token limits' -ForegroundColor Cyan

. (Join-Path $root 'scripts\flow\FlowContract.ps1')
. (Join-Path $root 'scripts\ClaudeModelFamilyQuotas.ps1')
$work = Join-Path ([IO.Path]::GetTempPath()) ('claude-plan-quotas-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $work | Out-Null
try {
    # The customer's 11 tiers and 47 groups, converted as in production.
    $catalogPath = Join-Path $work 'catalog.json'
    $null = & pwsh -NoProfile -File (Join-Path $root 'scripts\ConvertTo-ClaudeAccessCatalog.ps1') -InputPath (Join-Path $PSScriptRoot 'fixtures\customer-access-sheet.json') -OutputPath $catalogPath -Offline 2>&1
    $catalog = Get-Content -Raw -LiteralPath $catalogPath | ConvertFrom-Json
    $deployments = @(
        [pscustomobject]@{ name = 'claude-haiku-4-5'; model = 'claude-haiku-4-5'; sku = 'GlobalStandard' }
        [pscustomobject]@{ name = 'claude-sonnet-5'; model = 'claude-sonnet-5'; sku = 'GlobalStandard' }
        [pscustomobject]@{ name = 'claude-opus-5'; model = 'claude-opus-5'; sku = 'GlobalStandard' }
        [pscustomobject]@{ name = 'fable-prod'; model = 'claude-fable-5'; sku = 'GlobalStandard' }
    )
    $plan = New-ClaudePlanModelFamilyQuotaPlan -Catalog $catalog -Deployments $deployments -OutputShare 0.2 -CacheReadShare 0.5
    $by = @{}; foreach ($e in $plan.Entries) { $by["$($e.Plan):$($e.Family)"] = $e }

    Assert 'each of the 11 tiers gets a limit for each family its model set allows, and no other' (
        $plan.Entries.Count -eq 31 -and $by.ContainsKey('standard-l1-ha-so:haiku') -and $by.ContainsKey('standard-l3-ha-so-op:opus') -and
        -not $by.ContainsKey('standard-l3-ha-so:opus') -and $by.ContainsKey('power-l3-ha-so-op-fa:fable') -and -not $by.ContainsKey('power-l1-ha-so-op:fable')) (
        ($plan.Entries | ForEach-Object { "$($_.Plan):$($_.Family)" }) -join ',')
    Assert 'a tier credit is split equally across its model families' (
        $by['standard-l1-ha-so:haiku'].AllocatedUsd -eq 25 -and $by['standard-l3-ha-so-op:opus'].AllocatedUsd -eq 50 -and
        $by['standard-l3-ha-so:sonnet'].AllocatedUsd -eq 75 -and $by['power-l3-ha-so-op-fa:fable'].AllocatedUsd -eq 1250)
    Assert 'twice the credit gives twice the tokens: $50 Standard-L1 against $100 Standard-L2' (
        [math]::Abs($by['standard-l2-ha-so:sonnet'].TokensPerMonth - 2 * $by['standard-l1-ha-so:sonnet'].TokensPerMonth) -le 1)
    # Sonnet 5.5: input 2, output 10, cache read 0.10 (platform.claude.com pricing, read 2026-10-22). At 20% output and
    # half of input from cache: 0.8 x (2 + 1 x 0.10) + 0.2 x 10 = 3.68 USD per million counted; $25 -> 6,793,478.
    # Haiku 5.5, priced by prompt size (U178): default 'long' 0.8 x (0.50 + 0.05) + 0.2 x 2.50 = 0.94 -> 26,595,744;
    # 'standard' 0.8 x (0.10 + 0.01) + 0.2 x 0.50 = 0.188 -> 132,978,723.
    Assert 'families are priced at Haiku 5.5, Sonnet 5.5, Opus 5.5 and Fable 5.1, with the estimated cache reads' (
        $by['standard-l1-ha-so:sonnet'].PricedModel -eq 'claude-sonnet-5-5' -and $by['standard-l1-ha-so:sonnet'].UsdPerMCountedTokens -eq 3.68 -and
        $by['standard-l1-ha-so:sonnet'].TokensPerMonth -eq 6793478 -and $by['standard-l1-ha-so:haiku'].PricedModel -eq 'claude-haiku-5-5' -and
        $by['standard-l1-ha-so:haiku'].TokensPerMonth -eq 26595744 -and $by['advanced-l2-ha-so-op:opus'].PricedModel -eq 'claude-opus-5-5' -and
        $by['power-l3-ha-so-op-fa:fable'].PricedModel -eq 'claude-fable-5-1') (
        "$($by['standard-l1-ha-so:sonnet'].UsdPerMCountedTokens) $($by['standard-l1-ha-so:sonnet'].TokensPerMonth) $($by['standard-l1-ha-so:haiku'].TokensPerMonth)")
    $short = New-ClaudePlanModelFamilyQuotaPlan -Catalog $catalog -Deployments $deployments -Haiku55PromptTier standard
    $shortHaiku = @($short.Entries | Where-Object { $_.Plan -eq 'standard-l1-ha-so' -and $_.Family -eq 'haiku' })[0]
    Assert 'Haiku 5.5 uses its long-prompt rate by default and its short-prompt rate on request, not the shared price book' (
        $shortHaiku.TokensPerMonth -eq 132978723 -and $by['standard-l1-ha-so:haiku'].PriceSource -eq 'price model (long prompts)' -and
        -not ((Get-Content -Raw (Join-Path $root 'config\price-book.example.json')) -match 'claude-haiku-5-5'))
    $noCache = New-ClaudePlanModelFamilyQuotaPlan -Catalog $catalog -Deployments $deployments -OutputShare 0.2 -CacheReadShare 0
    $noCacheSonnet = @($noCache.Entries | Where-Object { $_.Plan -eq 'standard-l1-ha-so' -and $_.Family -eq 'sonnet' })[0]
    Assert 'the cache-read share is configurable, and more cache reads leave fewer counted tokens for the same dollars' ($noCacheSonnet.TokensPerMonth -gt $by['standard-l1-ha-so:sonnet'].TokensPerMonth)
    $overridden = New-ClaudePlanModelFamilyQuotaPlan -Catalog $catalog -Deployments $deployments -TokenOverrides @{ 'standard-l1-ha-so' = 13888888 }
    $o = @($overridden.Entries | Where-Object Plan -eq 'standard-l1-ha-so')
    Assert 'a sheet tokensPerMonth replaces the derived figure, split across the tier families' (
        $o.Count -eq 2 -and @($o | Where-Object { $_.TokensPerMonth -eq 6944444 -and $_.PriceSource -eq 'tokensPerMonth override' }).Count -eq 2)
    $refusedModel = try { $null = New-ClaudePlanModelFamilyQuotaPlan -Catalog $catalog -Deployments $deployments -PriceModels @{ haiku = 'claude-sonnet-5-5' }; '' } catch { $_.Exception.Message }
    Assert 'a price model from another family is refused' ($refusedModel -match 'is not a haiku model') $refusedModel
    $existing = ',deployment:fast=haiku,standard:haiku=100,premium:opus=300,plan:old-plan:haiku=5,'
    $value = Merge-ClaudePlanModelFamilyQuotaValue -Existing $existing -PlanEntries $plan.Entries -DeploymentFamilies $plan.DeploymentFamilies
    Assert 'writing plan limits keeps tier entries and deployment mappings and replaces earlier plan entries' (
        $value -match ',standard:haiku=100,' -and $value -match ',premium:opus=300,' -and $value -match ',deployment:fast=haiku,' -and
        $value -match ',deployment:fable-prod=fable,' -and $value -notmatch 'old-plan' -and $value -match ',plan:standard-l1-ha-so:haiku=\d+,')
    Assert 'the value for 11 tiers fits a named value' ($value.Length -lt 4096) "$($value.Length)"
    $refused = try { Merge-ClaudePlanModelFamilyQuotaValue -Existing ',mystery=1,' -PlanEntries $plan.Entries; '' } catch { $_.Exception.Message }
    Assert 'an entry the script does not recognise stops the write' ($refused -match 'does not recognise')

    # The policy expressions, compiled: the plan scope wins when the plan has entries; otherwise the tier, as before.
    $policy = [IO.File]::ReadAllText((Join-Path $root 'infra\policy.xml'))
    $scope = [regex]::Match($policy, '<set-variable name="modelFamilyQuotaScope" value="@\{(?<code>.*?)\}" />', 'Singleline')
    $quota = [regex]::Match($policy, '<set-variable name="modelFamilyQuota" value="@\{(?<code>.*?)\}" />', 'Singleline')
    if ($scope.Success -and $quota.Success) {
        $scopeCode = [Net.WebUtility]::HtmlDecode($scope.Groups['code'].Value).
            Replace('var plan = (string)context.Variables["entPlanId"];', '').
            Replace('var map = "{{model-family-quotas}}";', '').
            Replace('return (string)context.Variables["tier"];', 'return tier;')
        $quotaCode = [Net.WebUtility]::HtmlDecode($quota.Groups['code'].Value).
            Replace('var tier = (string)context.Variables["modelFamilyQuotaScope"];', '').
            Replace('var family = (string)context.Variables["modelFamily"];', '').
            Replace('var map = "{{model-family-quotas}}";', '')
        Add-Type -TypeDefinition @"
using System;
public static class P123PolicyContract {
    public static string Scope(string plan, string tier, string map) {
$scopeCode
    }
    public static long Quota(string tier, string family, string map) {
$quotaCode
    }
}
"@ -ErrorAction Stop
        $s1 = [P123PolicyContract]::Scope('standard-l1-ha-so', 'standard', $value)
        $s2 = [P123PolicyContract]::Scope('', 'premium', $value)
        $s3 = [P123PolicyContract]::Scope('not-in-map', 'standard', $value)
        Assert 'a person on a plan with entries is limited by the plan; others by their tier' ($s1 -eq 'plan:standard-l1-ha-so' -and $s2 -eq 'premium' -and $s3 -eq 'standard') "$s1 $s2 $s3"
        Assert 'the plan figure is enforced, and a family the plan lacks fails closed' (
            [P123PolicyContract]::Quota($s1, 'sonnet', $value) -eq $by['standard-l1-ha-so:sonnet'].TokensPerMonth -and
            [P123PolicyContract]::Quota($s1, 'opus', $value) -eq -1 -and
            [P123PolicyContract]::Quota('standard', 'haiku', $value) -eq 100)
    }
    else {
        Assert 'a person on a plan with entries is limited by the plan; others by their tier' $false 'expressions not found'
        Assert 'the plan figure is enforced, and a family the plan lacks fails closed' $false 'expressions not found'
    }
    Assert 'each plan and family has its own monthly counter' ($policy -match 'counter-key="@\(\(string\)context\.Variables\["userId"\] \+ ":family:" \+ \(string\)context\.Variables\["modelFamilyQuotaScope"\] \+ ":" \+ \(string\)context\.Variables\["modelFamily"\]\)"')
}
finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host ''
if ($script:count -ne $expected) { Write-Host "Expected $expected plan-limit assertions, ran $($script:count)." -ForegroundColor Red; exit 1 }
if ($script:fail) { Write-Host "$($script:fail) of $($script:count) plan-limit assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "$($script:count) plan-limit assertion(s) passed." -ForegroundColor Green
exit 0
