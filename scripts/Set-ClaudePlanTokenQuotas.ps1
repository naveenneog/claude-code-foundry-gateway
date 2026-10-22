<#
.SYNOPSIS
    Sets monthly token limits per access plan and model family from each plan's nominal dollar credit (P123, ADR-0069).

.DESCRIPTION
    Reads the access catalog file (the one published with Set-ClaudeAccessCatalog.ps1), the Foundry deployments and
    the price book, and writes plan entries into the gateway's model-family-quotas named value:

        ,plan:<planId>:<family>=<tokens per month>,

    A person whose plan has entries is limited per model family by them; anyone else keeps the standard or premium
    tier limits. A plan's credit is split equally across the model families its enabled profiles allow, and each
    share is turned into tokens at the dearest deployed model of that family (or, with no deployment, the dearest
    price-book model). APIM counts uncached input and output tokens, not cache reads, so the rate per counted token
    includes the estimated cache-read spend (-CacheReadShare of input tokens, default 0.5). The result approximates
    the dollar value; it is not a dollar cap and not an invoice. Each family is priced by -PriceModels (default Haiku
    5.5, Sonnet 5.5, Opus 5.5, Fable 5.1), and -SheetPath applies a profile's tokensPerMonth where the sheet sets one.
    Haiku 5.5 is priced by prompt size; -Haiku55PromptTier long (default) uses its over-100,000-token rate, standard
    the lower rate. The shared price book leaves Haiku 5.5 unpriced for dollar budgets (U178); only these limits use it.

    -WhatIf prints the table and the value and writes nothing. Existing deployment and tier entries are kept.

.EXAMPLE
    ./scripts/Set-ClaudePlanTokenQuotas.ps1 -ResourceGroup rg-gw -ApimName apim-gw `
        -CatalogPath ./onboarding/access-catalog.production.json -FoundryAccount ai-x -FoundryResourceGroup rg-ai -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$ResourceGroup,
    [Parameter(Mandatory)][string]$ApimName,
    [Parameter(Mandatory)][string]$CatalogPath,
    [Parameter(Mandatory)][string]$FoundryAccount,
    [Parameter(Mandatory)][string]$FoundryResourceGroup,
    [string]$SubscriptionId,
    [string]$FoundrySubscriptionId,
    [ValidateRange(0, 1)][decimal]$OutputShare = 0.2,
    [ValidateRange(0, 0.95)][decimal]$CacheReadShare = 0.5,
    [string]$PriceBookPath,
    # Family -> price-book model that prices it. Default: Haiku 5.5, Sonnet 5.5, Opus 5.5, Fable 5.1.
    [hashtable]$PriceModels = @{ haiku = 'claude-haiku-5-5'; sonnet = 'claude-sonnet-5-5'; opus = 'claude-opus-5-5'; fable = 'claude-fable-5-1' },
    # The customer sheet (ConvertTo-ClaudeAccessCatalog.ps1 input): a profile's tokensPerMonth, when set, replaces the
    # dollar-derived figure for that tier and is split equally across its model families.
    [string]$SheetPath,
    # Haiku 5.5 rate for the limits: prompts up to 100,000 tokens ('standard') or over ('long', default).
    [ValidateSet('standard', 'long')][string]$Haiku55PromptTier = 'long',
    # Test seam: deployments as JSON instead of reading Foundry.
    [Parameter(DontShow)][string]$DeploymentsPath
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'ClaudeModelPrices.ps1')
. (Join-Path $PSScriptRoot 'ClaudeModelFamilyQuotas.ps1')
. (Join-Path $PSScriptRoot 'ApimNamedValue.ps1')
if (-not (Get-Command Sort-ClaudeFlowOrdinal -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'flow\FlowContract.ps1') }
if (-not $PriceBookPath) { $PriceBookPath = Join-Path $root 'config\price-book.example.json' }

$safe = '^[A-Za-z0-9._()-]{1,90}$'
foreach ($pair in @(@('ResourceGroup', $ResourceGroup), @('ApimName', $ApimName), @('FoundryAccount', $FoundryAccount), @('FoundryResourceGroup', $FoundryResourceGroup))) {
    if ($pair[1] -notmatch $safe) { throw "-$($pair[0]) '$($pair[1])' is not a valid Azure name; nothing was changed." }
}
foreach ($pair in @(@('SubscriptionId', $SubscriptionId), @('FoundrySubscriptionId', $FoundrySubscriptionId))) {
    if ($pair[1] -and $pair[1] -notmatch '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$') { throw "-$($pair[0]) must be a subscription GUID; nothing was changed." }
}
if (-not (Test-Path -LiteralPath $CatalogPath)) { throw "Catalog '$CatalogPath' was not found; nothing was changed." }
$catalog = Get-Content -Raw -LiteralPath $CatalogPath | ConvertFrom-Json
if (-not @($catalog.plans).Count -or -not @($catalog.profiles).Count) { throw "Catalog '$CatalogPath' has no plans or profiles; nothing was changed." }

$deployments = if ($DeploymentsPath) { @(Get-Content -Raw -LiteralPath $DeploymentsPath | ConvertFrom-Json) } else {
    $listArgs = @('cognitiveservices', 'account', 'deployment', 'list', '-n', $FoundryAccount, '-g', $FoundryResourceGroup, '-o', 'json')
    if ($FoundrySubscriptionId) { $listArgs += @('--subscription', $FoundrySubscriptionId) } elseif ($SubscriptionId) { $listArgs += @('--subscription', $SubscriptionId) }
    $raw = & az @listArgs 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "Reading the Foundry deployments failed: $($raw.Trim()) Nothing was changed." }
    @($raw | ConvertFrom-Json | ForEach-Object { [pscustomobject]@{ name = [string]$_.name; model = [string]$_.properties.model.name; sku = [string]$_.sku.name } })
}

$overrides = @{}
if ($SheetPath) {
    if (-not (Test-Path -LiteralPath $SheetPath)) { throw "Sheet '$SheetPath' was not found; nothing was changed." }
    foreach ($profile in @((Get-Content -Raw -LiteralPath $SheetPath | ConvertFrom-Json).profiles)) {
        if ($null -ne $profile.tokensPerMonth) {
            if (-not ([long]$profile.tokensPerMonth -gt 0)) { throw "Profile '$($profile.id)' tokensPerMonth must be a positive whole number." }
            $overrides[([string]$profile.id).ToLowerInvariant()] = [long]$profile.tokensPerMonth
        }
    }
}
$plan = New-ClaudePlanModelFamilyQuotaPlan -Catalog $catalog -Deployments $deployments -PriceBookPath $PriceBookPath -OutputShare $OutputShare `
    -CacheReadShare $CacheReadShare -PriceModels $PriceModels -TokenOverrides $overrides -Haiku55PromptTier $Haiku55PromptTier
if (-not $plan.Entries.Count) { throw 'No enabled plan allows a model family; nothing was changed.' }

Write-Host ''
Write-Host ("Plan token limits per month (price book {0}; output share {1:P0}; cache reads {2:P0} of input)" -f $plan.PriceBookDate, $plan.OutputShare, $plan.CacheReadShare) -ForegroundColor Cyan
Write-Host ("  {0,-14} {1,-7} {2,10} {3,14} {4,16}  {5}" -f 'Plan', 'Family', 'USD', 'USD/M counted', 'Tokens/month', 'Priced at')
foreach ($e in $plan.Entries) {
    Write-Host ("  {0,-14} {1,-7} {2,10:N2} {3,14:N4} {4,16:N0}  {5} ({6})" -f $e.Plan, $e.Family, $e.AllocatedUsd, $e.UsdPerMCountedTokens, $e.TokensPerMonth, $e.PricedModel, $e.PriceSource)
}

$existing = Get-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id 'model-family-quotas' -FailOnError -SubscriptionId $SubscriptionId
if (-not $existing) { $existing = ',,' }
$value = Merge-ClaudePlanModelFamilyQuotaValue -Existing $existing -PlanEntries $plan.Entries -DeploymentFamilies $plan.DeploymentFamilies
Test-ApimNamedValueLength -Id 'model-family-quotas' -Value $value
Write-Host ''
Write-Host "  model-family-quotas: $($value.Length) characters" -ForegroundColor DarkGray

if ($PSCmdlet.ShouldProcess("$ApimName model-family-quotas", "write $($plan.Entries.Count) plan limits")) {
    Set-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id 'model-family-quotas' -Value $value -SubscriptionId $SubscriptionId
    $read = Get-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id 'model-family-quotas' -FailOnError -SubscriptionId $SubscriptionId
    if ($read -cne $value) { throw 'The gateway returned a different model-family-quotas value after the write.' }
    Write-Host "  Written and read back. A user's counter starts with the next request; limits reset monthly." -ForegroundColor Green
}
