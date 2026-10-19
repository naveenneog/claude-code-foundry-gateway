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
