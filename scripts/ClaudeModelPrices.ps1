# Dated deployment-price mappings. No rate is inferred from a model family.
# Sort-ClaudeFlowOrdinal gives one order on Windows PowerShell 5.1 and PowerShell 7 (P76).
if (-not (Get-Command Sort-ClaudeFlowOrdinal -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'flow\FlowContract.ps1') }

function Get-ClaudeModelPriceBook {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (Test-Path -LiteralPath $Path) {
        $doc = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        if (-not $doc -or $doc.GetType().FullName -ne 'System.Management.Automation.PSCustomObject' -or
            -not $doc.models -or $doc.models.GetType().FullName -ne 'System.Management.Automation.PSCustomObject') {
            throw "Price book '$Path' needs a models object."
        }
    }
    else {
        $models = [ordered]@{}
        foreach ($key in @(Sort-ClaudeFlowOrdinal -InputObject @($script:ClaudePriceBook.Keys))) {
            $models[$key] = [pscustomobject]@{ inputPerM = $script:ClaudePriceBook[$key].InputPerM; outputPerM = $script:ClaudePriceBook[$key].OutputPerM }
        }
        $doc = [pscustomobject]@{
            date = $script:ClaudePriceBookDate
            source = 'Anthropic list prices, https://platform.claude.com/docs/en/about-claude/pricing'
            models = [pscustomobject]$models
        }
    }
    if (-not $doc.date -or -not $doc.source) { throw "Price book '$Path' needs its date and source." }
    $date = [datetime]::MinValue
    if (-not [datetime]::TryParseExact([string]$doc.date, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::None, [ref]$date)) { throw "Price book '$Path' date must be yyyy-MM-dd." }
    foreach ($p in $doc.models.PSObject.Properties) {
        foreach ($key in 'inputPerM', 'outputPerM') {
            $value = $p.Value.$key
            if ($null -eq $value -or $value -is [bool] -or $value -is [string] -or
                $value -is [System.Collections.IEnumerable] -or $value.GetType().FullName -eq 'System.Management.Automation.PSCustomObject') {
                throw "Price book '$Path': '$($p.Name)' needs a numeric $key rate."
            }
            if ([decimal]$value -lt 0) { throw "Price book '$Path': '$($p.Name)' has a negative $key rate." }
        }
    }
    $seen = @{}
    foreach ($p in $doc.models.PSObject.Properties) {
        $key = ConvertTo-ClaudePriceModelKey $p.Name
        if ($seen.ContainsKey($key)) { Write-Warning "Duplicate normalized price-book key '$key' in '$Path': $($seen[$key]) and $($p.Name)." }
        $seen[$key] = $p.Name
    }
    return $doc
}

function ConvertTo-ClaudePriceModelKey {
    param([AllowNull()][string]$Name)
    return ([regex]::Replace([string]$Name, '[^A-Za-z0-9]', '')).ToLowerInvariant()
}

function Resolve-ClaudePriceBookKey {
    param([Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)]$Book)
    $literal = $Name.ToLowerInvariant()
    $target = ConvertTo-ClaudePriceModelKey $Name
    if (-not $target) { return '' }
    $names = @($Book.models.PSObject.Properties.Name)
    $normalizedMatches = @($names | Where-Object { [string]::Equals((ConvertTo-ClaudePriceModelKey $_), $target, [StringComparison]::Ordinal) })
    if ($normalizedMatches.Count -gt 1) {
        $rates = @(Sort-ClaudeFlowOrdinal -Unique -InputObject @($normalizedMatches | ForEach-Object {
            $rate = $Book.models.$_
            $cacheRead = if ($null -ne $rate.PSObject.Properties['cacheReadPerM']) { [decimal]$rate.cacheReadPerM } else { [decimal]$rate.inputPerM * [decimal]0.1 }
            $cacheWrite5m = if ($null -ne $rate.PSObject.Properties['cacheWrite5mPerM']) { [decimal]$rate.cacheWrite5mPerM } else { [decimal]$rate.inputPerM * [decimal]1.25 }
            $cacheWrite1h = if ($null -ne $rate.PSObject.Properties['cacheWrite1hPerM']) { [decimal]$rate.cacheWrite1hPerM } else { [decimal]$rate.inputPerM * [decimal]2 }
            '{0}:{1}:{2}:{3}:{4}' -f ([decimal]$rate.inputPerM).ToString([Globalization.CultureInfo]::InvariantCulture),
                ([decimal]$rate.outputPerM).ToString([Globalization.CultureInfo]::InvariantCulture),
                $cacheRead.ToString([Globalization.CultureInfo]::InvariantCulture),
                $cacheWrite5m.ToString([Globalization.CultureInfo]::InvariantCulture),
                $cacheWrite1h.ToString([Globalization.CultureInfo]::InvariantCulture)
        }))
        if ($rates.Count -gt 1) { throw "Conflicting price entries for '$Name': $($normalizedMatches -join ', '). A deployment-specific price resolves this ambiguity." }
    }
    $exact = @($names | Where-Object { [string]::Equals($_.ToLowerInvariant(), $literal, [StringComparison]::Ordinal) })
    if ($exact.Count -eq 1) { return [string]$exact[0] }
    $datedLiteral = [regex]::Replace($literal, '[-_.]*\d{8}$', '')
    if (-not [string]::Equals($datedLiteral, $literal, [StringComparison]::Ordinal)) {
        $datedExact = @($names | Where-Object { [string]::Equals($_.ToLowerInvariant(), $datedLiteral, [StringComparison]::Ordinal) })
        if ($datedExact.Count -eq 1) { return [string]$datedExact[0] }
    }
    $matches = $normalizedMatches
    if (-not $matches.Count -and $target.Length -gt 8 -and $target.Substring($target.Length - 8) -match '^\d{8}$') {
        $family = $target.Substring(0, $target.Length - 8)
        $matches = @($names | Where-Object { [string]::Equals((ConvertTo-ClaudePriceModelKey $_), $family, [StringComparison]::Ordinal) })
    }
    if ($matches.Count -eq 1) { return [string]$matches[0] }
    if ($matches.Count -gt 1) {
        $rates = @(Sort-ClaudeFlowOrdinal -Unique -InputObject @($matches | ForEach-Object {
            $rate = $Book.models.$_
            '{0}:{1}' -f ([decimal]$rate.inputPerM).ToString([Globalization.CultureInfo]::InvariantCulture), ([decimal]$rate.outputPerM).ToString([Globalization.CultureInfo]::InvariantCulture)
        }))
        if ($rates.Count -gt 1) { throw "Conflicting price entries for '$Name': $($matches -join ', '). A deployment-specific price resolves this ambiguity." }
        return [string](@(Sort-ClaudeFlowOrdinal -InputObject $matches)[0])
    }
    return ''
}

function Get-ClaudeDeploymentPrice {
    param([Parameter(Mandatory = $true)]$Deployment, [Parameter(Mandatory = $true)]$Book)
    $key = Resolve-ClaudePriceBookKey -Name ([string]$Deployment.name) -Book $Book
    if (-not $key -and $Deployment.sku -eq 'GlobalStandard') {
        $key = Resolve-ClaudePriceBookKey -Name ([string]$Deployment.model) -Book $Book
    }
    if (-not $key) {
        $reason = if ($Deployment.model -eq 'claude-opus-5-5') {
            'no approved entry; published cache reads are 0.05x, while current financial readers assume 0.1x'
        } elseif ($Deployment.sku -ne 'GlobalStandard') {
            "no deployment-specific price for SKU $($Deployment.sku)"
        } else { 'no exact deployment or unambiguous model entry' }
        return [pscustomobject]@{ Status = 'unpriced'; SourceKey = ''; InputPerM = $null; OutputPerM = $null; Detail = "unpriced ($reason); not free" }
    }
    $entry = $Book.models.$key
    $inputRate = ([decimal]$entry.inputPerM).ToString('0.####', [Globalization.CultureInfo]::InvariantCulture)
    $outputRate = ([decimal]$entry.outputPerM).ToString('0.####', [Globalization.CultureInfo]::InvariantCulture)
    [pscustomobject]@{
        Status = 'priced'; SourceKey = $key; InputPerM = [decimal]$entry.inputPerM; OutputPerM = [decimal]$entry.outputPerM
        Detail = "priced USD $inputRate input / $outputRate output per million; $($Book.date); source $($Book.source); entry $key"
    }
}
