# Regional comparison shapes, not a promise about an unchosen deployment.
# The actual Turnstile deployer still prices its explicit parameter file.
function Get-ClaudeFinOpsComparisonPrice {
    param([Parameter(Mandatory)][string]$Region, [Parameter(Mandatory)]$AumPrices)
    function Find-ComparisonMeter([string]$Service, [scriptblock]$Where) {
        $all = Get-AzureRetailMeter -ServiceName $Service -Region $Region
        if ($null -eq $all) { return $null }
        $match = @($all | Where-Object { $_.type -eq 'Consumption' } | Where-Object $Where |
            Sort-Object { [decimal]$_.tierMinimumUnits })
        if (-not $match.Count) { return $null }
        return [decimal]$match[-1].retailPrice
    }
    $b1 = Find-ComparisonMeter 'Azure App Service' { $_.skuName -eq 'B1' -and $_.productName -like '*Plan - Linux' }
    $observer = Find-ComparisonMeter 'Azure App Service' { $_.skuName -eq 'P0v3' -and $_.productName -like '*Plan - Linux' }
    $postgres = Find-ComparisonMeter 'Azure Database for PostgreSQL' { $_.skuName -eq 'B1MS' -and $_.productName -like '*Flexible Server*Compute*' }
    $disk = Find-ComparisonMeter 'Azure Database for PostgreSQL' { $_.meterName -eq 'Storage Data Stored' -and $_.productName -eq 'Azure Database for PostgreSQL Flex Server Storage' }
    $hub = Find-ComparisonMeter 'Event Hubs' { $_.meterName -eq 'Standard Throughput Unit' }
    $registry = Find-ComparisonMeter 'Container Registry' { $_.meterName -eq 'Basic Registry Unit' }
    $apim = Find-ComparisonMeter 'API Management' { $_.meterName -eq 'Standard v2 Unit' }
    $known = $true
    foreach ($price in @($b1, $postgres, $disk, $hub, $registry)) {
        if ($null -eq $price) { $known = $false }
    }
    $lean = if ($known) { 730 * ($b1 + $postgres + $hub) + 32 * $disk + ([decimal]730 / 24) * $registry } else { $null }
    $full = if ($null -ne $lean -and $null -ne $observer -and $null -ne $AumPrices.PrivateEndpointHourly -and $null -ne $AumPrices.DnsZoneMonthly) {
        $lean + 730 * $observer + 5 * 730 * $AumPrices.PrivateEndpointHourly + 4 * $AumPrices.DnsZoneMonthly
    } else { $null }
    return [pscustomobject]@{
        Region=$Region; PricedAtUtc=[datetime]::UtcNow.ToString('o')
        LeanMonthly=$lean; DedicatedPrivateMonthly=$full
        AdditionalStandardV2Monthly=$(if ($null -ne $apim) { 730 * $apim } else { $null })
        Basis='Lean: B1 Linux API, B1ms PostgreSQL/32 GB, Event Hubs 1 TU, Basic registry, on-demand observer, public network. Dedicated/private: P0v3 observer, five endpoints, four zones. Excludes model tokens, ingestion, operations and any additional APIM.'
    }
}
