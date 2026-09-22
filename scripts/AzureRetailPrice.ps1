<#
.SYNOPSIS
    Reads Azure list prices from the public retail price API.

.DESCRIPTION
    The bill of materials used to describe each line as a shape - "per hour, by
    SKU and units" - because a number hard-coded in a script is wrong somewhere
    by the time anyone reads it. Prices are regional and they change.

    They are also published. https://prices.azure.com needs no credential, no
    subscription and no agreement, so the shape can be replaced with the real
    figure for the SKU actually deployed in the region actually deployed.

    That covers infrastructure only. Claude token rates are NOT in this API -
    measured, not assumed: 6,734 'Foundry Models' meters across eastus, eastus2,
    westus and swedencentral contain no Claude, Anthropic, Sonnet, Opus or Haiku
    meter. Token rates stay in config/price-book.json with the date they were
    read. Do not wire this module to them; it would report Claude as free.

    Three ways this API returns a wrong number quietly, all three measured, and
    all three are why this module exists rather than a two-line Invoke-RestMethod
    at each call site:

      1. contains() is not supported and does not error. It returns an empty
         set. A lookup built on contains(meterName,'Claude') finds nothing and
         reads as 'no charge' rather than 'unsupported operator'. This module
         filters server-side with eq only, and narrows client-side.

      2. A Free Tier row shadows the real meter. Cosmos '100 RU/s' in eastus is
         published twice: skuName 'RUs' at $0.008, and skuName 'Free Tier' at
         $0. Whichever the service returns first, taking the first match is a
         coin toss that can price a provisioned account at nothing.

      3. Tiered meters start at zero. 'Standard v2 Calls' is $0 up to
         tierMinimumUnits 5000 and $0.03 above it. The first row is a real
         price for the first tier, and the wrong one to quote as a rate.

    So the guarantee here is narrow and deliberate: a lookup that cannot find a
    price returns $null. It never returns 0. Callers must treat $null as 'not
    known' and say so, because on a cost report those two mean the opposite
    things and only one of them is safe to believe.

.NOTES
    No authentication. Safe to call from anywhere with outbound HTTPS. Results
    are cached per process, keyed by service and region, so a bill of materials
    that prices eight resources makes one call per distinct service.
#>

Set-StrictMode -Version Latest

$script:RetailPriceEndpoint = 'https://prices.azure.com/api/retail/prices'
$script:RetailPriceCache = @{}
$script:RetailPriceUnavailable = $null

function Get-AzureRetailMeter {
    <#
    .SYNOPSIS
        Every consumption meter for one service in one region.

    .DESCRIPTION
        Pages the API to exhaustion and caches the result. Filtering happens in
        the caller, not here, because the only server-side operator that works
        reliably is eq and over-filtering server-side is how the empty-set trap
        gets reintroduced.

        Returns $null - not an empty array - when the API cannot be reached, so
        that 'the network was down' cannot be mistaken for 'this service has no
        meters'. An empty array is a real answer and means the service and
        region combination does not exist.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ServiceName,
        [Parameter(Mandatory = $true)][string]$Region,
        [int]$TimeoutSec = 90
    )

    # Returned with the comma operator throughout. PowerShell unrolls a
    # collection on return, so `return $items` on an empty array reaches the
    # caller as $null - which would make 'this service has no meters here'
    # indistinguishable from 'the API could not be reached', the one distinction
    # this function exists to preserve. Measured: 'Private Link' in eastus is a
    # real service with zero meters, and reported itself unreachable until this
    # was fixed. The comma wraps the array so it survives the return.
    $key = "$ServiceName|$Region"
    if ($script:RetailPriceCache.ContainsKey($key)) {
        $hit = $script:RetailPriceCache[$key]
        if ($null -eq $hit) { return $null }
        return , $hit
    }

    # eq only. See note 1 in the file header.
    $filter = "serviceName eq '$($ServiceName -replace "'", "''")' and armRegionName eq '$($Region -replace "'", "''")'"
    $url = $script:RetailPriceEndpoint + '?$filter=' + [uri]::EscapeDataString($filter)

    $items = @()
    $page = 0
    try {
        while ($url -and $page -lt 20) {
            $resp = Invoke-RestMethod -Uri $url -TimeoutSec $TimeoutSec -ErrorAction Stop
            $items += @($resp.Items)
            $page++
            $url = $resp.NextPageLink
        }
    }
    catch {
        # Cached as $null so a second caller in the same run does not pay the
        # timeout again. The distinction from an empty result is the point.
        $script:RetailPriceUnavailable = $_.Exception.Message
        $script:RetailPriceCache[$key] = $null
        return $null
    }

    $script:RetailPriceCache[$key] = $items
    return , $items
}

function Get-AzureRetailPrice {
    <#
    .SYNOPSIS
        The unit price of one meter, or $null if it cannot be established.

    .DESCRIPTION
        Never returns 0 to mean 'not found'. A zero it returns is a zero the API
        published.

    .PARAMETER MeterName
        Matched exactly. The API's meter names are stable strings such as
        '1M RUs', '100 RU/s', 'Premium v2 Unit' - not descriptions. Read them
        from Get-AzureRetailMeter rather than guessing.

    .PARAMETER SkuName
        Narrows when one meter name is published under several SKUs. Required in
        practice wherever a Free Tier row exists.

    .PARAMETER IncludeFreeTier
        Off by default, which drops rows whose SKU is a free tier. See note 2 in
        the file header.

    .PARAMETER Tier
        Which row to take when a meter is tiered. 'Marginal' - the default -
        takes the highest tierMinimumUnits, the rate paid once any included
        allowance is used up, which is the honest number to plan with. 'First'
        takes tierMinimumUnits 0.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ServiceName,
        [Parameter(Mandatory = $true)][string]$Region,
        [Parameter(Mandatory = $true)][string]$MeterName,
        [string]$SkuName,
        [string]$ProductName,
        [switch]$IncludeFreeTier,
        [ValidateSet('Marginal', 'First')][string]$Tier = 'Marginal'
    )

    $meters = Get-AzureRetailMeter -ServiceName $ServiceName -Region $Region
    if ($null -eq $meters) { return $null }

    $rows = @($meters | Where-Object { $_.meterName -eq $MeterName -and $_.type -eq 'Consumption' })
    if ($SkuName) { $rows = @($rows | Where-Object { $_.skuName -eq $SkuName }) }
    if ($ProductName) { $rows = @($rows | Where-Object { $_.productName -eq $ProductName }) }
    if (-not $IncludeFreeTier) { $rows = @($rows | Where-Object { $_.skuName -notlike '*Free*' -and $_.productName -notlike '*Free*' }) }

    if ($rows.Count -eq 0) { return $null }

    $pick = if ($Tier -eq 'First') {
        @($rows | Sort-Object { [decimal]$_.tierMinimumUnits })[0]
    }
    else {
        @($rows | Sort-Object { [decimal]$_.tierMinimumUnits })[-1]
    }

    [pscustomobject]@{
        ServiceName   = $ServiceName
        Region        = $Region
        MeterName     = $pick.meterName
        SkuName       = $pick.skuName
        ProductName   = $pick.productName
        UnitPrice     = [decimal]$pick.retailPrice
        UnitOfMeasure = $pick.unitOfMeasure
        Currency      = $pick.currencyCode
        TierMinimum   = [decimal]$pick.tierMinimumUnits
        Candidates    = $rows.Count
        RetrievedUtc  = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
}

function Get-AzureRetailPriceUnavailableReason {
    <#
    .SYNOPSIS
        Why the last lookup could not reach the API, if it could not.
    #>
    return $script:RetailPriceUnavailable
}

function ConvertTo-MonthlyPrice {
    <#
    .SYNOPSIS
        An hourly meter as a monthly figure, at 730 hours.

    .DESCRIPTION
        730 is the Azure convention for an average month and is what the pricing
        calculator uses. Stated here rather than in each caller so every monthly
        figure in this repo is derived the same way.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][decimal]$HourlyPrice,
        [int]$Units = 1
    )
    return [math]::Round($HourlyPrice * 730 * $Units, 2)
}
