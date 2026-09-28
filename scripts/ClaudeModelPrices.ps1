# Dated deployment-price mappings. No rate is inferred from a model family.
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
        foreach ($key in ($script:ClaudePriceBook.Keys | Sort-Object)) {
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
    return $doc
}

function Get-ClaudeDeploymentPrice {
    param([Parameter(Mandatory = $true)]$Deployment, [Parameter(Mandatory = $true)]$Book)
    $names = @($Book.models.PSObject.Properties.Name)
    $key = ''
    if ([string]$Deployment.name -in $names) { $key = [string]$Deployment.name }
    elseif ($Deployment.sku -eq 'GlobalStandard') {
        $normal = ([string]$Deployment.model -replace '(?<=\d)\.(?=\d)', '-')
        $candidates = @($names | Where-Object { ($_ -replace '(?<=\d)\.(?=\d)', '-') -eq $normal })
        $rates = @($candidates | ForEach-Object {
            $rate = $Book.models.$_
            '{0}:{1}' -f ([decimal]$rate.inputPerM).ToString([Globalization.CultureInfo]::InvariantCulture), ([decimal]$rate.outputPerM).ToString([Globalization.CultureInfo]::InvariantCulture)
        } | Sort-Object -Unique)
        if ($rates.Count -gt 1) { throw "Conflicting price entries for '$($Deployment.model)': $($candidates -join ', '). A deployment-specific price resolves this ambiguity." }
        if ($candidates.Count) { $key = @($candidates | Sort-Object)[0] }
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
