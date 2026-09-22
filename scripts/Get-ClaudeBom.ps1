<#
.SYNOPSIS
    Lists what this accelerator actually deployed, and what it costs to keep.

.DESCRIPTION
    A resource group usually holds more than one thing. On the reference
    deployment it held 68 resources, six of which belong to this gateway - so a
    bill of materials written by hand from the design drifts from what is really
    there, and a screenshot of the resource group answers the wrong question.

    This reads the live deployment and reports only the gateway's own resources,
    separating three things that get conflated:

      created     resources this accelerator deploys and you pay for
      reused      resources it attaches to but did not create - the Foundry
                  account is yours and was there first
      configured  things that are not resources at all: named values, the API
                  policy, saved KQL functions, Entra groups, a role assignment.
                  These carry no bill, which is most of why the footprint is
                  small

.EXAMPLE
    ./scripts/Get-ClaudeBom.ps1
    ./scripts/Get-ClaudeBom.ps1 -AsJson
    ./scripts/Get-ClaudeBom.ps1 -WithPrices
#>
[CmdletBinding()]
param(
    [string]$ResourceGroup = $(if ($env:CLAUDE_RG) { $env:CLAUDE_RG } else { 'rg-contosohub' }),
    [string]$ApimName,
    [switch]$WithPrices,
    [string]$Region,
    [switch]$AsJson
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ApimNamedValue.ps1')
. (Join-Path $PSScriptRoot 'AzureRetailPrice.ps1')

if (-not $ApimName) {
    $found = @((az apim list -g $ResourceGroup --query "[].name" -o tsv 2>$null) -split "`n" | Where-Object { $_ })
    if ($found.Count -eq 1) { $ApimName = $found[0].Trim() }
    elseif ($found.Count -eq 0) { throw "No API Management instance in '$ResourceGroup'. Pass -ApimName." }
    else { throw ("$($found.Count) instances in '$ResourceGroup': " + ($found -join ', ') + ". Pass -ApimName.") }
}

# The gateway names everything after the APIM instance, which is what makes its
# own resources separable from whatever else shares the group.
$stem = $ApimName -replace '^apim-', ''

$all = az resource list -g $ResourceGroup --query "[].{name:name, type:type, sku:sku.name, id:id}" -o json 2>$null | ConvertFrom-Json
$mine = @($all | Where-Object { $_.name -like "*$stem*" -or $_.name -eq $ApimName })

# The workbook is named by a GUID, so it is found by reading it rather than by
# matching a name.
$sub = az account show --query id -o tsv
$tok = az account get-access-token --resource https://management.azure.com --query accessToken -o tsv
$hdr = @{ Authorization = "Bearer $tok" }
try {
    $wb = Invoke-RestMethod -Headers $hdr `
        -Uri "https://management.azure.com/subscriptions/$sub/resourceGroups/$ResourceGroup/providers/Microsoft.Insights/workbooks?api-version=2023-06-01&category=workbook"
    foreach ($w in ($wb.value | Where-Object { $_.properties.displayName -like '*Claude*' })) {
        if ($mine.id -notcontains $w.id) {
            $mine += [pscustomobject]@{ name = $w.properties.displayName; type = 'Microsoft.Insights/workbooks'; sku = $null; id = $w.id }
        }
    }
}
catch { }

# What the gateway attaches to but did not create.
$backend = az apim api show -g $ResourceGroup --service-name $ApimName --api-id claude-foundry --query serviceUrl -o tsv 2>$null
$foundry = if ($backend -match 'https://([^.]+)\.') { $Matches[1] } else { $null }

# Configuration, which is where most of this accelerator lives.
$nv = @()
try { $nv = @((az apim nv list -g $ResourceGroup --service-name $ApimName --query "[].name" -o tsv 2>$null) -split "`n" | Where-Object { $_ }) } catch { }
$fn = @()
try {
    $ws = @((az monitor log-analytics workspace list -g $ResourceGroup --query "[].name" -o tsv 2>$null) -split "`n" | Where-Object { $_ -like "*$stem*" })
    if ($ws.Count) {
        $s = Invoke-RestMethod -Headers $hdr `
            -Uri "https://management.azure.com/subscriptions/$sub/resourceGroups/$ResourceGroup/providers/Microsoft.OperationalInsights/workspaces/$($ws[0].Trim())/savedSearches?api-version=2020-08-01"
        $fn = @($s.value | Where-Object { $_.properties.category -eq 'Claude' } | ForEach-Object { $_.properties.functionAlias })
    }
}
catch { }

# What each thing costs to keep, stated as the shape of the bill rather than a
# number - prices are regional and change, and a hard-coded figure in a script
# is wrong somewhere by the time anyone reads it.
$COST = @{
    'Microsoft.ApiManagement/service'                            = 'per hour, by SKU and units - the whole cost of this accelerator'
    'Microsoft.Insights/components'                              = 'per GB ingested, after 5 GB free each month'
    'Microsoft.OperationalInsights/workspaces'                   = 'per GB ingested and retained; shares the Application Insights allowance'
    'Microsoft.Insights/workbooks'                               = 'nothing - a definition, billed only by the queries it runs'
    'microsoft.alertsmanagement/smartDetectorAlertRules'         = 'nothing - created with Application Insights, free'
    'Microsoft.CognitiveServices/accounts'                       = 'per token, on your existing Foundry agreement'
    # The entitlement projection, ADR-0011. Serverless bills per request unit
    # and per GB with no minimum, so an empty one is free - but a private
    # endpoint, which the governance baseline forces, bills per hour at rest.
    'Microsoft.DocumentDB/databaseAccounts'                      = 'per request unit and GB, no minimum - but its private endpoint bills hourly at rest'
    'Microsoft.Network/privateEndpoints'                         = 'per hour, whether used or not - the only line here that bills at rest'
    'Microsoft.Web/sites'                                        = 'per execution and GB-second, after a monthly free grant'
    'Microsoft.Web/serverfarms'                                  = 'per hour on Flex Consumption only when instances run'
}

$created = @($mine | Where-Object { $_.type -ne 'Microsoft.CognitiveServices/accounts' } | Sort-Object type)

# Which published meter each deployed resource bills on. The shapes above say
# what you are charged for; these say what the rate is, read live from
# https://prices.azure.com for the region the thing is actually in.
#
# Only the meters that dominate the bill are mapped. A resource with no entry
# reports its shape and no figure, which is honest - a bill of materials that
# omits a line silently understates the total, so anything unmapped is printed
# and marked rather than dropped.
#
# Claude tokens are deliberately absent. They are not published in this API -
# measured across 6,734 'Foundry Models' meters in four regions, none of which
# is a Claude meter - and they are usually the largest number on the bill. See
# config/price-book.json, and Measure-ClaudeUsage for what was actually spent.
function Get-ResourceMeter {
    param($Resource, $Account)
    switch ($Resource.type) {
        'Microsoft.ApiManagement/service' {
            if (-not $Resource.sku) { return $null }
            # ARM and the price list spell the same SKU differently: ARM says
            # 'BasicV2', the meter is 'Basic v2 Unit'. Passing the ARM name
            # through finds nothing, and a lookup that finds nothing on the
            # single largest line of the bill is worth spelling out rather than
            # leaving to a lucky match.
            $sku = $Resource.sku -replace 'V2$', ' v2'
            return @{ Service = 'API Management'; Meter = "$sku Unit"; Per = 'hour'; Monthly = $true }
        }
        'Microsoft.DocumentDB/databaseAccounts' {
            $serverless = $false
            if ($Account -and $Account.capabilities) {
                $serverless = @($Account.capabilities | Where-Object { $_.name -eq 'EnableServerless' }).Count -gt 0
            }
            if ($serverless) {
                return @{ Service = 'Azure Cosmos DB'; Meter = '1M RUs'; Per = 'million request units'; Monthly = $false }
            }
            return @{ Service = 'Azure Cosmos DB'; Meter = '100 RU/s'; Per = 'hour per 100 RU/s'; Monthly = $false }
        }
        'Microsoft.OperationalInsights/workspaces' {
            return @{ Service = 'Log Analytics'; Meter = 'Analytics Logs Data Ingestion'; Per = 'GB ingested'; Monthly = $false }
        }
        'Microsoft.Web/sites' {
            return @{ Service = 'Functions'; Meter = 'On Demand Execution Time'; Per = 'GB-second'; Monthly = $false }
        }
        default { return $null }
    }
}

$prices = @{}
$priceRegion = $Region
$priceNote = $null
if ($WithPrices) {
    if (-not $priceRegion) {
        $priceRegion = az group show -n $ResourceGroup --query location -o tsv 2>$null
        if ($priceRegion) { $priceRegion = $priceRegion.Trim() }
    }
    if (-not $priceRegion) {
        $priceNote = "could not read the region of '$ResourceGroup'; pass -Region"
    }
    else {
        # Cosmos bills differently by capability, not by SKU, so the account has
        # to be read before its meter can be chosen.
        $cosmosAccounts = @{}
        foreach ($r in @($created | Where-Object { $_.type -eq 'Microsoft.DocumentDB/databaseAccounts' })) {
            try {
                $cosmosAccounts[$r.name] = az cosmosdb show -g $ResourceGroup -n $r.name --query "{capabilities:capabilities}" -o json 2>$null | ConvertFrom-Json
            }
            catch { }
        }
        foreach ($r in $created) {
            $acct = if ($cosmosAccounts.ContainsKey($r.name)) { $cosmosAccounts[$r.name] } else { $null }
            $map = Get-ResourceMeter -Resource $r -Account $acct
            if (-not $map) { continue }
            $p = Get-AzureRetailPrice -ServiceName $map.Service -Region $priceRegion -MeterName $map.Meter
            if ($null -eq $p) {
                $reason = Get-AzureRetailPriceUnavailableReason
                $prices[$r.name] = @{ Known = $false; Why = $(if ($reason) { 'price API unreachable' } else { "no '$($map.Meter)' meter in $priceRegion" }) }
                continue
            }
            $entry = @{
                Known    = $true
                Unit     = $p.UnitPrice
                Measure  = $p.UnitOfMeasure
                Currency = $p.Currency
                Per      = $map.Per
                Tier     = $p.TierMinimum
                Monthly  = $(if ($map.Monthly) { ConvertTo-MonthlyPrice -HourlyPrice $p.UnitPrice } else { $null })
            }
            $prices[$r.name] = $entry
        }
    }
}

if ($AsJson) {
    [ordered]@{
        resourceGroup = $ResourceGroup
        apim          = $ApimName
        priceRegion   = $priceRegion
        created       = @($created | ForEach-Object {
                $n = $_.name
                [ordered]@{
                    type  = $_.type; name = $n; sku = $_.sku; cost = $COST[$_.type]
                    price = $(if ($prices.ContainsKey($n)) { $prices[$n] } else { $null })
                }
            })
        reused        = @(if ($foundry) { [ordered]@{ type = 'Microsoft.CognitiveServices/accounts'; name = $foundry; note = 'pre-existing; the gateway calls it and did not create it' } })
        configured    = [ordered]@{ namedValues = $nv.Count; savedFunctions = $fn; apiPolicy = 'infra/policy.xml' }
        tokens        = 'not priced here; Claude rates are not published in the Azure retail price API. See config/price-book.json.'
        groupTotal    = @($all).Count
    } | ConvertTo-Json -Depth 8
    exit 0
}

Write-Host ''
Write-Host ("Bill of materials - {0}" -f $ApimName) -ForegroundColor Cyan
Write-Host ("  {0} resource(s) in {1}; {2} belong to this gateway." -f @($all).Count, $ResourceGroup, $created.Count) -ForegroundColor DarkGray

Write-Host ''
Write-Host '  Created, and billed' -ForegroundColor Cyan
Write-Host ("  {0,-46} {1,-12} {2}" -f 'Type', 'SKU', 'What it costs')
Write-Host ('  ' + ('-' * 118)) -ForegroundColor DarkGray
foreach ($r in $created) {
    $short = ($r.type -split '/')[-1]
    Write-Host ("  {0,-46} {1,-12} {2}" -f $r.type, $(if ($r.sku) { $r.sku } else { '-' }), $COST[$r.type])
    if ($WithPrices -and $prices.ContainsKey($r.name)) {
        $p = $prices[$r.name]
        if (-not $p.Known) {
            Write-Host ("  {0,-46} {1,-12} {2}" -f '', '', "rate unknown - $($p.Why)") -ForegroundColor Yellow
        }
        elseif ($p.Monthly) {
            $line = "{0} {1:N5} per {2}  =  {0} {3:N2}/month at 730 h" -f $p.Currency, $p.Unit, $p.Measure, $p.Monthly
            Write-Host ("  {0,-46} {1,-12} {2}" -f '', '', $line) -ForegroundColor Green
        }
        else {
            $line = "{0} {1} per {2}" -f $p.Currency, $p.Unit, $p.Per
            if ($p.Tier -gt 0) { $line += "  (first $($p.Tier) included)" }
            Write-Host ("  {0,-46} {1,-12} {2}" -f '', '', $line) -ForegroundColor Green
        }
    }
}
if ($WithPrices) {
    Write-Host ''
    if ($priceNote) {
        Write-Host "  $priceNote" -ForegroundColor Yellow
    }
    else {
        Write-Host ("  List prices for {0}, read from prices.azure.com just now. No agreement, discount" -f $priceRegion) -ForegroundColor DarkGray
        Write-Host '  or reservation is applied, so treat these as an upper bound on infrastructure.' -ForegroundColor DarkGray
    }
    Write-Host '  Claude tokens are not in this total. Their rates are not published in that API,' -ForegroundColor DarkGray
    Write-Host '  and on a busy deployment they are the largest line on the bill by a wide margin.' -ForegroundColor DarkGray
}

Write-Host ''
Write-Host '  Reused, not created' -ForegroundColor Cyan
if ($foundry) {
    Write-Host ("  {0,-46} {1}" -f 'Microsoft.CognitiveServices/accounts', $foundry)
    Write-Host '    Your Foundry account. The gateway calls it with its managed identity and bills' -ForegroundColor DarkGray
    Write-Host '    on your existing agreement - removing the gateway does not remove it.' -ForegroundColor DarkGray
}
else { Write-Host '  could not read the backend from the API' -ForegroundColor Yellow }

Write-Host ''
Write-Host '  Configured, and free' -ForegroundColor Cyan
Write-Host ("  {0,-46} {1}" -f 'API Management named values', "$($nv.Count) - entitlement, budgets, business units, model lists")
Write-Host ("  {0,-46} {1}" -f 'API policy', 'infra/policy.xml - every control the gateway enforces')
Write-Host ("  {0,-46} {1}" -f 'Saved KQL functions', $(if ($fn.Count) { $fn -join ', ' } else { 'none published' }))
Write-Host ("  {0,-46} {1}" -f 'Entra groups', 'tiers, business units and teams - directory objects, no Azure bill')
Write-Host ("  {0,-46} {1}" -f 'Role assignment', 'Cognitive Services User, gateway identity on the Foundry account')

Write-Host ''
Write-Host '  Most of this accelerator is configuration rather than infrastructure, which is' -ForegroundColor DarkGray
Write-Host '  why the footprint is one API Management instance plus telemetry. Prices are' -ForegroundColor DarkGray
if ($WithPrices) {
    Write-Host '  regional and change, so they are read live rather than quoted; re-run to refresh.' -ForegroundColor DarkGray
}
else {
    Write-Host '  regional and change; pass -WithPrices to read them live for this region.' -ForegroundColor DarkGray
}
Write-Host ''
