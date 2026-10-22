if (-not (Get-Command Get-ClaudeModelPriceBook -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'ClaudeModelPrices.ps1')
}

function Get-ClaudeModelFamily {
    param([AllowNull()][string]$Name)
    $value = ([string]$Name).ToLowerInvariant()
    foreach ($family in 'haiku', 'sonnet', 'opus', 'fable', 'mythos') {
        if ($value -match "(^|[-_.])$family($|[-_.])") { return $family }
    }
    return ''
}

function Test-ClaudeModelFamilyQuotaExistingGateway {
    param(
        [AllowEmptyString()][string]$ExistingApim,
        [AllowEmptyString()][string]$LiveApimId
    )
    return [bool]($ExistingApim -or $LiveApimId)
}

function Resolve-ClaudeModelFamilyQuotaIntent {
    [CmdletBinding()]
    param(
        [bool]$ExistingGateway,
        [bool]$StandardMonthlyUsdSpecified,
        [bool]$PremiumMonthlyUsdSpecified,
        [bool]$OutputShareSpecified,
        [bool]$Unattended
    )
    $monthlyChanged = $StandardMonthlyUsdSpecified -or $PremiumMonthlyUsdSpecified
    if ($ExistingGateway -and $OutputShareSpecified -and -not $monthlyChanged) {
        throw 'Stopped: -ModelQuotaOutputShare changes a calculation assumption but no monthly USD allowance was supplied. Pass both -StandardMonthlyUsd and -PremiumMonthlyUsd, or omit all three to preserve the live family quotas. Nothing was changed.'
    }
    if ($ExistingGateway -and $Unattended -and
        ($StandardMonthlyUsdSpecified -xor $PremiumMonthlyUsdSpecified)) {
        throw 'Stopped: changing model-family quotas on an existing gateway under -Yes requires both -StandardMonthlyUsd and -PremiumMonthlyUsd. Pass zero explicitly for a tier that should be disabled. Nothing was changed.'
    }
    return [pscustomobject][ordered]@{
        Recalculate = -not $ExistingGateway -or $monthlyChanged
        InputsSpecified = -not $ExistingGateway -or $monthlyChanged
        MonthlyChanged = $monthlyChanged
    }
}

function New-ClaudeModelFamilyQuotaPlan {
    [CmdletBinding()]
    param(
        [decimal]$StandardMonthlyUsd,
        [decimal]$PremiumMonthlyUsd,
        [string[]]$StandardModels = @(),
        [string[]]$PremiumModels = @(),
        [object[]]$Deployments = @(),
        [string]$PriceBookPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'config\price-book.example.json'),
        [ValidateRange(0, 1)][decimal]$OutputShare = 0.2
    )
    if ($StandardMonthlyUsd -lt 0 -or $PremiumMonthlyUsd -lt 0) {
        throw 'A tier monthly USD allowance cannot be negative.'
    }

    $book = Get-ClaudeModelPriceBook -Path $PriceBookPath
    $byName = @{}
    foreach ($deployment in @($Deployments)) {
        if ($deployment -and [string]$deployment.name) { $byName[[string]$deployment.name] = $deployment }
    }

    $entries = [Collections.Generic.List[object]]::new()
    $deploymentFamilies = [ordered]@{}
    foreach ($tierSpec in @(
        [pscustomobject]@{ Tier = 'standard'; MonthlyUsd = $StandardMonthlyUsd; Models = @($StandardModels) }
        [pscustomobject]@{ Tier = 'premium'; MonthlyUsd = $PremiumMonthlyUsd; Models = @($PremiumModels) }
    )) {
        if ($tierSpec.MonthlyUsd -le 0) { continue }
        $selected = @($tierSpec.Models | Where-Object { $_ } | Select-Object -Unique)
        if (-not $selected.Count) {
            throw "The $($tierSpec.Tier) tier has a monthly USD allowance but no selected models."
        }

        $priced = [Collections.Generic.List[object]]::new()
        foreach ($name in $selected) {
            if (-not $byName.ContainsKey($name)) {
                throw "The $($tierSpec.Tier) tier model '$name' has no deployment metadata for model-family quota calculation."
            }
            $deployment = $byName[$name]
            $modelName = if ([string]$deployment.model) { [string]$deployment.model } else { [string]$deployment.name }
            $family = Get-ClaudeModelFamily $modelName
            if (-not $family) {
                throw "The selected model '$modelName' has no supported model family. Expected Haiku, Sonnet, Opus, Fable or Mythos."
            }
            if ($name -notmatch '^[A-Za-z0-9._-]+$') {
                throw "The deployment name '$name' cannot be serialized into the model-family quota map."
            }
            if ($deploymentFamilies.Contains($name) -and $deploymentFamilies[$name] -ne $family) {
                throw "The deployment name '$name' resolves to conflicting model families."
            }
            $deploymentFamilies[$name] = $family
            $lookup = [pscustomobject]@{
                name = [string]$deployment.name
                model = $modelName
                sku = $(if ([string]$deployment.sku) { [string]$deployment.sku } else { 'GlobalStandard' })
            }
            $price = Get-ClaudeDeploymentPrice -Deployment $lookup -Book $book
            if ($price.Status -ne 'priced') {
                throw "The selected $family model '$modelName' has no usable price book entry; update '$PriceBookPath' before calculating a dollar-derived token quota."
            }
            $blended = ([decimal]$price.InputPerM * (1 - $OutputShare)) +
                ([decimal]$price.OutputPerM * $OutputShare)
            if ($blended -le 0) {
                throw "The selected $family model '$modelName' has a zero blended price; update '$PriceBookPath' with a usable positive rate before calculating a dollar-derived token quota."
            }
            $priced.Add([pscustomobject]@{
                Family = $family
                Model = $modelName
                BlendedUsdPerM = $blended
                PriceSourceKey = $price.SourceKey
            })
        }

        $families = @('haiku', 'sonnet', 'opus', 'fable', 'mythos' | Where-Object {
            $candidate = $_
            @($priced | Where-Object Family -eq $candidate).Count
        })
        $allocatedUsd = [decimal]$tierSpec.MonthlyUsd / [decimal]$families.Count
        foreach ($family in $families) {
            $familyPrices = @($priced | Where-Object Family -eq $family)
            $rate = [decimal](($familyPrices | Measure-Object -Property BlendedUsdPerM -Maximum).Maximum)
            $tokens = [long][math]::Floor(($allocatedUsd / $rate) * 1000000)
            if ($tokens -le 0) {
                throw "The $($tierSpec.Tier) $family allocation is too small to produce a positive token quota."
            }
            $entries.Add([pscustomobject][ordered]@{
                Tier = $tierSpec.Tier
                Family = $family
                AllocatedUsd = [math]::Round($allocatedUsd, 2)
                BlendedUsdPerM = [math]::Round($rate, 4)
                TokensPerMonth = $tokens
                PricedModels = @($familyPrices.Model)
            })
        }
    }

    return [pscustomobject][ordered]@{
        Entries = @($entries)
        DeploymentFamilies = @($deploymentFamilies.Keys | ForEach-Object {
            [pscustomobject][ordered]@{ Name = [string]$_; Family = [string]$deploymentFamilies[$_] }
        })
        OutputShare = $OutputShare
        PriceBookDate = [string]$book.date
        PriceBookSource = [string]$book.source
        IsEstimate = $true
    }
}

function ConvertTo-ClaudeModelFamilyQuotaValue {
    param(
        [AllowNull()][object[]]$Entries,
        [AllowNull()][object[]]$DeploymentFamilies
    )
    $parts = [Collections.Generic.List[string]]::new()
    $familiesByDeployment = @{}
    foreach ($mapping in @($DeploymentFamilies | Where-Object { $_ })) {
        $name = [string]$mapping.Name
        $family = [string]$mapping.Family
        if ($name -notmatch '^[A-Za-z0-9._-]+$') { throw "Deployment name '$name' cannot be serialized." }
        if ($family -notin @('haiku', 'sonnet', 'opus', 'fable', 'mythos')) {
            throw "Deployment '$name' has unsupported model family '$family'."
        }
        if ($familiesByDeployment.ContainsKey($name) -and $familiesByDeployment[$name] -ne $family) {
            throw "Deployment '$name' has conflicting model families."
        }
        $familiesByDeployment[$name] = $family
    }
    foreach ($name in @(Sort-ClaudeFlowOrdinal -InputObject @($familiesByDeployment.Keys))) {
        $parts.Add("deployment`:$name=$($familiesByDeployment[$name])")
    }
    foreach ($tier in 'standard', 'premium') {
        foreach ($family in 'haiku', 'sonnet', 'opus', 'fable', 'mythos') {
            $matches = @($Entries | Where-Object { $_.Tier -eq $tier -and $_.Family -eq $family })
            if ($matches.Count -gt 1) { throw "Duplicate model-family quota for ${tier}:$family." }
            if ($matches.Count -eq 1) {
                $tokens = [long]$matches[0].TokensPerMonth
                if ($tokens -le 0) { throw "Model-family quota for ${tier}:$family must be positive." }
                $parts.Add("$tier`:$family=$tokens")
            }
        }
    }
    if ($parts.Count) { return ',' + ($parts -join ',') + ',' }
    return ',,'
}

# P123 (ADR-0069): monthly token limits per access plan and model family, from each plan's nominal dollar credit.
# APIM counts uncached input and output tokens; cache reads are not counted, so the rate per counted token adds the
# estimated cache-read spend: per million counted tokens,
#   (1 - output share) x (input rate + cache ratio x cache-read rate) + output share x output rate,
# where cache ratio = cache-read share / (1 - cache-read share) of input tokens. The token limit is the plan's
# per-family dollar share divided by that rate. It approximates the dollar value; it is not a dollar cap.
function New-ClaudePlanModelFamilyQuotaPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Catalog,
        [object[]]$Deployments = @(),
        [string]$PriceBookPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'config\price-book.example.json'),
        [ValidateRange(0, 1)][decimal]$OutputShare = 0.2,
        [ValidateRange(0, 0.95)][decimal]$CacheReadShare = 0.5,
        # The price-book model that prices each family (the customer's chosen generation). A family not listed here is
        # priced from its dearest deployment, else its dearest price-book model.
        [hashtable]$PriceModels = @{ haiku = 'claude-haiku-5-5'; sonnet = 'claude-sonnet-5-5'; opus = 'claude-opus-5-5'; fable = 'claude-fable-5-1' },
        # planId -> total tokens per month across the plan's families; replaces the dollar-derived figure.
        [hashtable]$TokenOverrides = @{},
        # Claude Haiku 5.5 is priced by prompt size and is deliberately absent from the shared price book (U178). These
        # limits use its list rates for prompts up to 100,000 tokens ('standard') or over ('long', five times higher,
        # the default because Claude Code sends long prompts; fewer tokens, so the credit is not overrun).
        [ValidateSet('standard', 'long')][string]$Haiku55PromptTier = 'long'
    )
    $book = Get-ClaudeModelPriceBook -Path $PriceBookPath
    # Claude pricing, read 2026-10-22 (https://platform.claude.com/docs/en/about-claude/pricing), USD per million.
    $tieredRates = @{
        'claude-haiku-5-5' = $(if ($Haiku55PromptTier -eq 'long') {
            [pscustomobject]@{ inputPerM = 0.5; outputPerM = 2.5; cacheReadPerM = 0.05 } } else {
            [pscustomobject]@{ inputPerM = 0.1; outputPerM = 0.5; cacheReadPerM = 0.01 } })
    }
    $cacheRatio = $CacheReadShare / (1 - $CacheReadShare)
    $rateOf = {
        param($Entry)
        $r = Get-ClaudeEffectivePriceRates $Entry
        ((1 - $OutputShare) * ([decimal]$r[0] + $cacheRatio * [decimal]$r[2])) + ($OutputShare * [decimal]$r[1])
    }

    # Deployed models by family, priced from the book; deployment names that are not claude-<family>-* are mapped.
    $deployedByFamily = @{}
    $deploymentFamilies = [ordered]@{}
    foreach ($d in @($Deployments | Where-Object { $_ -and [string]$_.name })) {
        $model = if ([string]$d.model) { [string]$d.model } else { [string]$d.name }
        $family = Get-ClaudeModelFamily $model
        if (-not $family) { continue }
        $name = [string]$d.name
        if ($name -notmatch '^[A-Za-z0-9._-]+$') { throw "The deployment name '$name' cannot be serialized into the model-family quota map." }
        $deploymentFamilies[$name] = $family
        $price = Get-ClaudeDeploymentPrice -Deployment ([pscustomobject]@{ name = $name; model = $model; sku = $(if ([string]$d.sku) { [string]$d.sku } else { 'GlobalStandard' }) }) -Book $book
        if ($price.Status -ne 'priced') { continue }
        if (-not $deployedByFamily.ContainsKey($family)) { $deployedByFamily[$family] = [Collections.Generic.List[object]]::new() }
        $deployedByFamily[$family].Add([pscustomobject]@{ Model = $model; Rate = (& $rateOf $book.models.($price.SourceKey)) })
    }

    $entries = [Collections.Generic.List[object]]::new()
    foreach ($plan in @($Catalog.plans | Where-Object { $_.enabled })) {
        $planId = [string]$plan.id
        if ($planId -cnotmatch '^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$') { throw "Plan id '$planId' is not a canonical lowercase id." }
        $usd = [decimal]$plan.nominalCredit.amount
        if ($plan.nominalCredit.currency -ne 'USD' -or $plan.nominalCredit.period -ne 'month' -or $usd -le 0) {
            throw "Plan '$planId' needs a positive USD monthly nominal credit."
        }
        $families = @('haiku', 'sonnet', 'opus', 'fable', 'mythos' | Where-Object {
            $f = $_
            @($Catalog.profiles | Where-Object { $_.enabled -and $_.planId -eq $planId -and @($_.modelFamilies) -contains $f }).Count
        })
        if (-not $families.Count) { continue }
        $share = $usd / [decimal]$families.Count
        $override = if ($TokenOverrides.ContainsKey($planId)) { [long]$TokenOverrides[$planId] } else { 0 }
        foreach ($family in $families) {
            if ($override -gt 0) {
                $entries.Add([pscustomobject][ordered]@{
                    Plan = $planId; Family = $family; AllocatedUsd = [math]::Round($share, 2); UsdPerMCountedTokens = $null
                    TokensPerMonth = [long][math]::Floor($override / $families.Count); PricedModel = ''; PriceSource = 'tokensPerMonth override'
                })
                continue
            }
            $source = 'deployment'
            $candidates = if ($deployedByFamily.ContainsKey($family)) { @($deployedByFamily[$family]) } else { @() }
            if ($PriceModels.ContainsKey($family) -and $PriceModels[$family]) {
                $key = [string]$PriceModels[$family]
                if ((Get-ClaudeModelFamily $key) -ne $family) { throw "Price model '$key' is not a $family model." }
                $entry = if ($tieredRates.ContainsKey($key)) { $tieredRates[$key] } elseif ($null -ne $book.models.PSObject.Properties[$key]) { $book.models.$key } else { $null }
                if (-not $entry) { throw "Price model '$key' for $family is not in the price book '$PriceBookPath'." }
                $source = if ($tieredRates.ContainsKey($key)) { "price model ($Haiku55PromptTier prompts)" } else { 'price model' }
                $candidates = @([pscustomobject]@{ Model = $key; Rate = (& $rateOf $entry) })
            }
            if (-not $candidates.Count) {
                # No deployment yet: price the family from the book's dearest model, so the limit errs low.
                $source = 'price book (no deployment)'
                $candidates = @($book.models.PSObject.Properties | Where-Object { (Get-ClaudeModelFamily $_.Name) -eq $family } |
                    ForEach-Object { [pscustomobject]@{ Model = $_.Name; Rate = (& $rateOf $_.Value) } })
            }
            if (-not $candidates.Count) { throw "Plan '$planId' allows $family, which has no deployment and no price book entry." }
            $top = $candidates | Sort-Object Rate -Descending | Select-Object -First 1
            if ($top.Rate -le 0) { throw "The $family price for plan '$planId' is not positive." }
            $tokens = [long][math]::Floor(($share / $top.Rate) * 1000000)
            if ($tokens -le 0) { throw "Plan '$planId' $family allocation is too small to produce a positive token limit." }
            $entries.Add([pscustomobject][ordered]@{
                Plan = $planId; Family = $family; AllocatedUsd = [math]::Round($share, 2)
                UsdPerMCountedTokens = [math]::Round($top.Rate, 4); TokensPerMonth = $tokens; PricedModel = $top.Model; PriceSource = $source
            })
        }
    }
    [pscustomobject][ordered]@{
        Entries = @($entries)
        DeploymentFamilies = @($deploymentFamilies.Keys | ForEach-Object { [pscustomobject][ordered]@{ Name = [string]$_; Family = [string]$deploymentFamilies[$_] } })
        OutputShare = $OutputShare
        CacheReadShare = $CacheReadShare
        PriceModels = $PriceModels
        PriceBookDate = [string]$book.date
        IsEstimate = $true
    }
}

# Replaces the plan entries of a model-family-quotas value and adds deployment mappings; tier entries are kept.
function Merge-ClaudePlanModelFamilyQuotaValue {
    param(
        [AllowEmptyString()][string]$Existing = ',,',
        [AllowNull()][object[]]$PlanEntries,
        [AllowNull()][object[]]$DeploymentFamilies
    )
    $deployments = [ordered]@{}
    $tiers = [Collections.Generic.List[string]]::new()
    foreach ($part in @(([string]$Existing).Trim(',') -split ',' | Where-Object { $_ })) {
        if ($part -match '^deployment:([A-Za-z0-9._-]+)=(haiku|sonnet|opus|fable|mythos)$') { $deployments[$Matches[1]] = $Matches[2] }
        elseif ($part -match '^(standard|premium):(haiku|sonnet|opus|fable|mythos)=[1-9][0-9]*$') { $tiers.Add($part) }
        elseif ($part -match '^plan:') { }
        else { throw "The existing model-family-quotas value has an entry this script does not recognise: '$part'. Nothing was changed." }
    }
    foreach ($m in @($DeploymentFamilies | Where-Object { $_ })) {
        if ($deployments.Contains($m.Name) -and $deployments[$m.Name] -ne $m.Family) { throw "Deployment '$($m.Name)' already maps to $($deployments[$m.Name]), not $($m.Family)." }
        $deployments[$m.Name] = $m.Family
    }
    $parts = [Collections.Generic.List[string]]::new()
    foreach ($name in @(Sort-ClaudeFlowOrdinal -InputObject @($deployments.Keys))) { $parts.Add("deployment`:$name=$($deployments[$name])") }
    foreach ($t in $tiers) { $parts.Add($t) }
    $seen = @{}
    foreach ($e in @($PlanEntries | Sort-Object Plan, Family)) {
        $key = "plan:$($e.Plan):$($e.Family)"
        if ($seen.ContainsKey($key)) { throw "Duplicate plan model-family limit $key." }
        $seen[$key] = $true
        if ([long]$e.TokensPerMonth -le 0) { throw "Plan model-family limit $key must be positive." }
        $parts.Add("$key=$([long]$e.TokensPerMonth)")
    }
    if ($parts.Count) { return ',' + ($parts -join ',') + ',' }
    return ',,'
}
