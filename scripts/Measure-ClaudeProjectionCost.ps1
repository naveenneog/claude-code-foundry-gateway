<#
.SYNOPSIS
    What the entitlement projection would cost to run.

.DESCRIPTION
    ADR-0005 decided that entitlement becomes a durable projection queried off
    the request path. ADR-0011 decided it runs on Cosmos DB serverless with an
    Azure Function resolver. This is what that costs.

    The figure is computed rather than quoted, because the only number that
    matters is one nobody can look up: the **cache miss rate**. APIM caches a
    composite entitlement record, so the resolver is not called per request - it
    is called per miss. Cost scales with misses, and misses scale with how long
    the cached record is trusted, which is the staleness window ADR-0005 makes
    the operator choose.

    A worked default is supplied so the shape is visible, but every input is a
    parameter. Do not read the total as a quote for your deployment.

    Rates are parameters too, defaulted to the published US list price with the
    date they were read. They are regional and they change; a hard-coded figure
    in a script goes stale silently, which is the same reason the token price
    book moved to config/price-book.json.

.PARAMETER Developers
    Total entitled identities. Drives storage only - one small record each.

.PARAMETER DailyActive
    How many of them call Claude on a working day. This, not headcount, is what
    the cost follows.

.PARAMETER CacheMinutes
    How long APIM trusts a cached entitlement record. This is the staleness
    window: shorter means fresher revocation and more misses, so it is the dial
    that trades money against how long a revoked developer keeps working.

.EXAMPLE
    ./scripts/Measure-ClaudeProjectionCost.ps1 -Developers 500000 -DailyActive 50000

.EXAMPLE
    ./scripts/Measure-ClaudeProjectionCost.ps1 -Developers 500 -DailyActive 120 -AsJson
#>
[CmdletBinding()]
param(
    [int]$Developers = 500000,
    # Zero means "derive it", which is the case that matters: the previous
    # default was a fixed 50,000, so asking for 500 developers costed 50,000
    # active ones and overstated a small deployment by a hundredfold. The
    # headline figure it was taken from - 500,000 developers, 50,000 active - is
    # a tenth, so that is the share used when nobody says otherwise.
    [int]$DailyActive = 0,
    [int]$ActiveHoursPerDay = 8,
    [int]$WorkingDaysPerMonth = 22,
    [int]$CacheMinutes = 60,

    # Bytes per projection record: tenantId, oid, tier, businessUnit,
    # authorized, mappingVersion, effectiveFrom, lastVerifiedAt - plus Cosmos
    # system properties, which are the larger half of a document this small.
    [int]$BytesPerRecord = 400,

    # Request units for one point read of a small document. A point read by id
    # and partition key is the cheapest operation Cosmos offers.
    [decimal]$RuPerLookup = 1.0,

    # ---- published US list rates, read 2026-09-17 ----
    # Cosmos DB serverless: billed per request unit consumed and per GB stored,
    # with no minimum. https://azure.microsoft.com/pricing/details/cosmos-db/serverless/
    [decimal]$UsdPerMillionRu = 0.25,
    [decimal]$UsdPerGbMonth = 0.25,
    # Functions Consumption: a free grant per subscription per month, then per
    # execution. https://azure.microsoft.com/pricing/details/functions/
    [decimal]$UsdPerMillionExecutions = 0.20,
    [long]$FreeExecutionsPerMonth = 1000000,

    # Private networking. Measured 2026-09-17: deploying the projection to the
    # reference subscription produced an account with publicNetworkAccess
    # Disabled, enforced above the resource group - an update to enable it
    # reported success and changed nothing.
    #
    # An accelerator aimed at organisations with six-figure developer counts has
    # to assume that baseline rather than the absence of it, so this defaults on.
    #
    # It has two consequences, and the second is the expensive one:
    #   - Cosmos needs a private endpoint, billed per hour whether used or not
    #   - the resolver needs VNet integration, which the Consumption (Y1) plan
    #     does not support. Flex Consumption does, and keeps per-execution
    #     billing. https://learn.microsoft.com/azure/azure-functions/flex-consumption-plan
    [bool]$PrivateNetworking = $true,
    # https://azure.microsoft.com/pricing/details/private-link/
    [decimal]$UsdPerEndpointHour = 0.01,
    # Five, as deployed and measured 2026-09-23 (docs/SECURE-PROJECTION.md):
    # Cosmos, the resolver's own inbound endpoint, and the resolver's storage
    # account three times - blob, queue and table - because an Azure Policy
    # made that account private and the Functions host needs all three. This
    # used to be 1, which priced only the Cosmos endpoint.
    [int]$PrivateEndpoints = 5,
    # One zone per endpoint type: documents, azurewebsites, blob, queue, table.
    # $0.50 per zone per month for the first 25, retail API 2026-09-23.
    [int]$PrivateDnsZones = 5,
    [decimal]$UsdPerZoneMonth = 0.50,

    # Instances kept warm so the first lookup after idle does not pay a cold
    # start against the gateway's 5-second timeout. 0 removes the line and
    # accepts the cold start. Flex Consumption bills a warm instance at the
    # always-ready baseline rate per GB-second whether it is used or not:
    # $0.000005, retail API 2026-09-23, canadacentral.
    [int]$AlwaysReadyInstances = 1,
    [decimal]$InstanceMemoryGb = 2,
    [decimal]$UsdPerAlwaysReadyGbSecond = 0.000005,

    [switch]$AsJson,

    # Where to price. Redundancy choices are regional - serverless in
    # westeurope is $0.305 per million request units against $0.25 in eastus2 -
    # so the comparison is worthless without one.
    [string]$Region = 'eastus2',

    # Show what each redundancy choice costs and what it buys, rather than
    # costing only the shape that is deployed. This is a decision an
    # organisation makes once, usually without a number in front of it.
    [switch]$CompareRedundancy,

    # Provisioned throughput to price the redundant options at. 400 RU/s is the
    # minimum Cosmos sells and already far more than this projection uses -
    # measured below at well under 1 RU/s average - so the redundant options are
    # priced at the floor rather than at anything derived from the workload.
    [int]$Throughput = 400
)

$ErrorActionPreference = 'Stop'

# Derive the active population when it was not given, and refuse a figure that
# cannot be true. More active developers than developers is always a mistake,
# and silently costing it produces a number nobody can sanity-check.
if (-not $PSBoundParameters.ContainsKey('DailyActive') -or $DailyActive -le 0) {
    $DailyActive = [int][math]::Max(1, [math]::Round($Developers * 0.1))
}
if ($DailyActive -gt $Developers) {
    throw "DailyActive ($DailyActive) is larger than Developers ($Developers). Nothing was costed."
}

# A developer misses the cache once per window while they are active, so the
# window length is what sets the miss count - not how much they use Claude.
# Someone making 500 calls an hour and someone making 5 both miss once.
$missesPerActiveDay = [math]::Ceiling(($ActiveHoursPerDay * 60) / [double]$CacheMinutes)
$missesPerMonth     = [long]($DailyActive * $missesPerActiveDay * $WorkingDaysPerMonth)

# One miss is one resolver invocation and one Cosmos point read.
$executions = $missesPerMonth
$ruConsumed = [decimal]$missesPerMonth * $RuPerLookup

$billableExecutions = [math]::Max(0, $executions - $FreeExecutionsPerMonth)
$functionUsd = [math]::Round(([decimal]$billableExecutions / 1000000) * $UsdPerMillionExecutions, 2)
$cosmosRuUsd = [math]::Round(($ruConsumed / 1000000) * $UsdPerMillionRu, 2)

$storageGb   = [math]::Round(([decimal]$Developers * $BytesPerRecord) / 1073741824, 4)
$storageUsd  = [math]::Round($storageGb * $UsdPerGbMonth, 2)

# The private endpoints, their DNS zones and a warm resolver instance are the
# lines that bill whether anyone calls the gateway or not. Everything else is
# pay-per-use, so these are the floor - and at a small deployment they are the
# whole bill.
$networkUsd = if ($PrivateNetworking) {
    [math]::Round([decimal]$PrivateEndpoints * $UsdPerEndpointHour * 730, 2)
} else { [decimal]0 }
$dnsUsd = if ($PrivateNetworking) {
    [math]::Round([decimal]$PrivateDnsZones * $UsdPerZoneMonth, 2)
} else { [decimal]0 }
$alwaysReadyUsd = [math]::Round([decimal]$AlwaysReadyInstances * $InstanceMemoryGb * 730 * 3600 * $UsdPerAlwaysReadyGbSecond, 2)

$totalUsd = $functionUsd + $cosmosRuUsd + $storageUsd + $networkUsd + $dnsUsd + $alwaysReadyUsd

# Peak demand against the serverless ceiling. Serverless caps at 5,000 RU/s per
# physical partition and, unlike provisioned throughput, offers no guaranteed
# throughput or latency:
# https://learn.microsoft.com/azure/cosmos-db/serverless-performance
$peakMissesPerSecond = [math]::Round($missesPerMonth / ([double]$WorkingDaysPerMonth * $ActiveHoursPerDay * 3600), 2)
$serverlessCeilingRuPerSecond = 5000

if ($AsJson) {
    [ordered]@{
        inputs = [ordered]@{
            developers = $Developers; daily_active = $DailyActive
            active_hours_per_day = $ActiveHoursPerDay; working_days_per_month = $WorkingDaysPerMonth
            cache_minutes = $CacheMinutes
        }
        derived = [ordered]@{
            misses_per_active_day = $missesPerActiveDay
            misses_per_month = $missesPerMonth
            storage_gb = $storageGb
            average_ru_per_second = $peakMissesPerSecond
        }
        monthly_usd = [ordered]@{
            functions = $functionUsd; cosmos_request_units = $cosmosRuUsd
            cosmos_storage = $storageUsd; private_endpoint = $networkUsd
            private_dns_zones = $dnsUsd; resolver_always_ready = $alwaysReadyUsd
            at_rest = ($networkUsd + $dnsUsd + $alwaysReadyUsd); total = $totalUsd
        }
        rates_read = '2026-09-17 (usage) and 2026-09-23 (endpoints, zones, always ready), published US list price'
        caveats = @(
            'Serverless offers no guaranteed throughput or latency.',
            'Cache misses, not requests, drive the usage lines.',
            'Endpoints, zones and the always-ready instance bill at rest; they are the floor.',
            'Excludes egress, private endpoint data processing and Log Analytics ingestion.',
            'Private networking assumed on: Consumption (Y1) has no VNet integration, so the resolver needs Flex Consumption.'
        )
    } | ConvertTo-Json -Depth 6
    exit 0
}

Write-Host ''
Write-Host 'Entitlement projection - running cost' -ForegroundColor Cyan
Write-Host ("  {0:n0} developers, {1:n0} active per day, {2}-minute cache" -f $Developers, $DailyActive, $CacheMinutes)
Write-Host ''
Write-Host ("  Cache misses     {0:n0}/month  ({1} per active developer per day)" -f $missesPerMonth, $missesPerActiveDay)
Write-Host ("  Projection size  {0:n2} GB" -f $storageGb)
Write-Host ''
Write-Host ("  {0,-26} {1,10}" -f $(if ($PrivateNetworking) { 'Azure Function (Flex)' } else { 'Azure Function (Consumption)' }), ('$' + ('{0:n2}' -f $functionUsd)))
Write-Host ("  {0,-26} {1,10}" -f 'Cosmos DB request units', ('$' + ('{0:n2}' -f $cosmosRuUsd)))
Write-Host ("  {0,-26} {1,10}" -f 'Cosmos DB storage', ('$' + ('{0:n2}' -f $storageUsd)))
if ($PrivateNetworking) {
    Write-Host ("  {0,-26} {1,10}" -f "Private endpoints ($PrivateEndpoints)", ('$' + ('{0:n2}' -f $networkUsd))) -ForegroundColor Yellow
    Write-Host ("  {0,-26} {1,10}" -f "Private DNS zones ($PrivateDnsZones)", ('$' + ('{0:n2}' -f $dnsUsd))) -ForegroundColor Yellow
}
if ($AlwaysReadyInstances -gt 0) {
    Write-Host ("  {0,-26} {1,10}" -f "Resolver kept warm ($AlwaysReadyInstances x $InstanceMemoryGb GB)", ('$' + ('{0:n2}' -f $alwaysReadyUsd))) -ForegroundColor Yellow
}
Write-Host ('  ' + ('-' * 38)) -ForegroundColor DarkGray
Write-Host ("  {0,-26} {1,10}" -f 'Total per month', ('$' + ('{0:n2}' -f $totalUsd))) -ForegroundColor Green
Write-Host ''
Write-Host '  Why it is this small' -ForegroundColor Cyan
Write-Host '    The resolver is called once per cache window per active developer,'
Write-Host '    not once per request. Someone making 500 calls an hour and someone'
Write-Host '    making 5 cost the same. Halving the cache window doubles this bill'
Write-Host '    and halves how long a revoked developer keeps working.'
Write-Host ''
Write-Host ("  Average {0:n2} RU/s against a serverless ceiling of {1:n0} RU/s per partition." -f $peakMissesPerSecond, $serverlessCeilingRuPerSecond) -ForegroundColor DarkGray
Write-Host '  Serverless gives no guaranteed throughput or latency. That is priced in' -ForegroundColor DarkGray
Write-Host '  here and is the reason the record is cached rather than read per call.' -ForegroundColor DarkGray
Write-Host ''
Write-Host '  Rates are published US list, read 2026-09-17 and 2026-09-23, and are regional.' -ForegroundColor DarkGray
Write-Host '  Yellow lines bill at rest. Excludes egress, endpoint data processing and' -ForegroundColor DarkGray
Write-Host '  Log Analytics ingestion.' -ForegroundColor DarkGray
Write-Host ''

# ---------------------------------------------------------------- redundancy
#
# What the three choices cost, and what each one buys. This is decided once,
# usually without a number in front of whoever decides it, and the number is
# not intuitive: the difference is not a percentage on a small bill, it is the
# difference between a bill that exists only when someone signs in and one that
# arrives every month whether or not anyone does.
#
# Priced live rather than quoted. The figures above are a dated snapshot, which
# is honest for a worked example and wrong for a decision.
if ($CompareRedundancy) {
    . (Join-Path $PSScriptRoot 'AzureRetailPrice.ps1')

    $serverless = Get-AzureRetailPrice -ServiceName 'Azure Cosmos DB' -Region $Region -MeterName '1M RUs'
    $provisioned = Get-AzureRetailPrice -ServiceName 'Azure Cosmos DB' -Region $Region -MeterName '100 RU/s' -SkuName 'RUs'
    $multiMaster = Get-AzureRetailPrice -ServiceName 'Azure Cosmos DB' -Region $Region -MeterName '100 Multi-master RU/s'

    Write-Host '  Redundancy, and what each choice costs' -ForegroundColor Cyan
    if (-not $serverless -or -not $provisioned -or -not $multiMaster) {
        Write-Host '  Could not read live prices - the retail price API was unreachable.' -ForegroundColor Yellow
        Write-Host '  No figures are shown rather than stale ones.' -ForegroundColor DarkGray
        Write-Host ''
    }
    else {
        $units = [math]::Ceiling($Throughput / 100)
        $singleMonthly = [math]::Round($provisioned.UnitPrice * $units * 730, 2)
        $multiMonthly = [math]::Round($multiMaster.UnitPrice * $units * 730, 2)
        # Zone redundancy has no meter of its own - measured: zero meters in
        # this service mention zone or availability. It is a multiplier on
        # provisioned throughput, so it is derived and labelled as derived
        # rather than presented as a published price.
        $zoneMonthly = [math]::Round($singleMonthly * 1.25, 2)

        Write-Host ("  Priced in {0} for {1} RU/s, at 730 hours." -f $Region, $Throughput) -ForegroundColor DarkGray
        Write-Host ''
        Write-Host ("  {0,-14} {1,12}  {2}" -f 'Choice', 'Per month', 'What it gives, and what it costs you')
        Write-Host ('  ' + ('-' * 104)) -ForegroundColor DarkGray

        Write-Host ("  {0,-14} {1,12}  {2}" -f 'single', ('$' + ('{0:n2}' -f ($cosmosRuUsd + $storageUsd))), 'serverless - billed per request unit, nothing at rest') -ForegroundColor Green
        Write-Host ("  {0,-14} {1,12}  {2}" -f '', '', 'No SLA on throughput or latency. Cannot be made redundant.')
        Write-Host ("  {0,-14} {1,12}  {2}" -f '', '', 'That figure is your measured usage above, not a fixed charge.') -ForegroundColor DarkGray

        Write-Host ("  {0,-14} {1,12}  {2}" -f 'zone', ('$' + ('{0:n2}' -f $zoneMonthly)), 'survives one datacentre failing, inside one region') -ForegroundColor Yellow
        Write-Host ("  {0,-14} {1,12}  {2}" -f '', '', 'Provisioned throughput, so this is charged whether used or not.')
        Write-Host ("  {0,-14} {1,12}  {2}" -f '', '', 'Derived at 1.25x provisioned - zone redundancy has no meter of its own.') -ForegroundColor DarkGray

        Write-Host ("  {0,-14} {1,12}  {2}" -f 'multi-region', ('$' + ('{0:n2}' -f ($multiMonthly * 2))), 'survives a region failing; writes accepted in both') -ForegroundColor Yellow
        Write-Host ("  {0,-14} {1,12}  {2}" -f '', '', ("Multi-master at `${0:n2} per region, shown for two." -f $multiMonthly))
        Write-Host ("  {0,-14} {1,12}  {2}" -f '', '', 'Add egress between regions, which is not priced here.') -ForegroundColor DarkGray

        Write-Host ''
        Write-Host '  The switch is the billing model, not a feature flag.' -ForegroundColor Cyan
        Write-Host '  Serverless cannot be zone-redundant or multi-region. Choosing either moves the' -ForegroundColor DarkGray
        Write-Host '  account to provisioned throughput, which bills for capacity rather than use -' -ForegroundColor DarkGray
        Write-Host '  so an idle projection stops being free. Changing it later means a new account' -ForegroundColor DarkGray
        Write-Host '  and a migration, because the capability is fixed when the account is created.' -ForegroundColor DarkGray
        Write-Host ''
        Write-Host '  Worth weighing against what the projection is for: entitlement is cached at' -ForegroundColor DarkGray
        Write-Host ("  the gateway for {0} minutes, so a resolver outage is not felt until a record" -f $CacheMinutes) -ForegroundColor DarkGray
        Write-Host '  expires. That is the argument for single, and it is an argument about your' -ForegroundColor DarkGray
        Write-Host '  tolerance rather than about Cosmos.' -ForegroundColor DarkGray
        Write-Host ''
        Write-Host ("  Live list prices for {0}, read just now from prices.azure.com." -f $Region) -ForegroundColor DarkGray
        Write-Host ''
    }
}

exit 0

