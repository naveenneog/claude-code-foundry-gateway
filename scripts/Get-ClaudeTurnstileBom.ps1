<#
.SYNOPSIS
    What the Turnstile deployment costs to keep, from what is deployed and today's list prices.

.DESCRIPTION
    Reads the resource group that the gateway's Turnstile connection names
    (Connect-ClaudeTurnstile.ps1), lists what is actually there, and prices it from
    https://prices.azure.com for the region each resource is in. Nothing about the
    deployment or its prices is written into this script.

    Two kinds of line, kept apart because they behave differently:

      at rest   billed by the hour whether or not anyone uses Turnstile: the database,
                the App Service plans, Event Hubs throughput units, the registry,
                private endpoints and private DNS zones. These make up the monthly floor.
      usage     billed by what flows through: Event Hubs ingress, Log Analytics
                ingestion, Functions on Flex Consumption. Priced from the last 30 days
                where Azure reports the quantity, and otherwise given as a rate.

    A price that cannot be found is reported as not known, never as zero
    (AzureRetailPrice.ps1). Claude tokens are not part of this bill: they are the
    gateway's, see Get-ClaudeBom.ps1 and config/price-book.json.

.EXAMPLE
    ./scripts/Get-ClaudeTurnstileBom.ps1

.EXAMPLE
    ./scripts/Get-ClaudeTurnstileBom.ps1 -TurnstileResourceGroup rg-turnstile -AsJson
#>
[CmdletBinding()]
param(
    [string]$TurnstileResourceGroup,
    [string]$ResourceGroup = $(& (Join-Path $PSScriptRoot 'Get-ClaudeGatewayTarget.ps1') ResourceGroup),
    [string]$ApimName,
    [switch]$AsJson
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ApimNamedValue.ps1')
. (Join-Path $PSScriptRoot 'AzureRetailPrice.ps1')
. (Join-Path $PSScriptRoot 'ClaudeTurnstile.ps1')
. (Join-Path $PSScriptRoot 'ClaudeTurnstileGovernance.ps1')

if (-not (az account show --query id -o tsv 2>$null)) { throw 'Not signed in. Run: az login' }
if (-not $TurnstileResourceGroup) {
    if (-not $ApimName) { $ApimName = az apim list -g $ResourceGroup --query "[0].name" -o tsv 2>$null }
    if (-not $ApimName) { throw "No API Management instance in $ResourceGroup. Pass -ApimName or -TurnstileResourceGroup." }
    $integration = ConvertFrom-ClaudeTurnstileIntegrationValue (Get-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id $script:TurnstileIntegrationNamedValue)
    $TurnstileResourceGroup = [string]$integration['resourceGroup']
    if (-not $TurnstileResourceGroup) { throw "$ApimName is not connected to Turnstile. Pass -TurnstileResourceGroup." }
}

$hoursPerMonth = 730
$lines = New-Object System.Collections.Generic.List[object]
function Add-Line($Name, $Kind, $Sku, $Units, $Rate, $Unit, $Monthly, $Basis) {
    $lines.Add([pscustomobject][ordered]@{
        Resource = $Name; Kind = $Kind; Sku = $Sku; Units = $Units
        Rate = $Rate; RateUnit = $Unit
        MonthlyUsd = $(if ($null -eq $Monthly) { $null } else { [math]::Round([decimal]$Monthly, 2) })
        Basis = $Basis
    })
}

# One published row, chosen client-side: the API's only reliable server-side
# operator is eq, and several meters here are spelled differently from ARM's SKU.
function Find-Meter([string]$Service, [string]$Region, [scriptblock]$Where) {
    $meters = Get-AzureRetailMeter -ServiceName $Service -Region $Region
    if ($null -eq $meters) { return $null }
    $rows = @($meters | Where-Object { $_.type -eq 'Consumption' } | Where-Object $Where)
    if (-not $rows.Count) { return $null }
    @($rows | Sort-Object { [decimal]$_.tierMinimumUnits })[-1]
}
function Get-FreeUnits([string]$Service, [string]$Region, [scriptblock]$Where) {
    $meters = Get-AzureRetailMeter -ServiceName $Service -Region $Region
    $rows = @($meters | Where-Object { $_.type -eq 'Consumption' } | Where-Object $Where | Sort-Object { [decimal]$_.tierMinimumUnits })
    if ($rows.Count -gt 1 -and [decimal]$rows[0].retailPrice -eq 0) { return [decimal]$rows[1].tierMinimumUnits }
    return [decimal]0
}

$resources = az resource list -g $TurnstileResourceGroup --query "[].{name:name, type:type, sku:sku.name, tier:sku.tier, capacity:sku.capacity, kind:kind, location:location, id:id}" -o json | ConvertFrom-Json
$since = [datetime]::UtcNow.AddDays(-30).ToString('yyyy-MM-ddTHH:mm:ssZ')
$until = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')

foreach ($r in $resources) {
    switch ($r.type) {
        'Microsoft.DBforPostgreSQL/flexibleServers' {
            $s = az postgres flexible-server show --ids $r.id --query "{sku:sku.name, tier:sku.tier, gb:storage.storageSizeGb, ha:highAvailability.mode}" -o json | ConvertFrom-Json
            $short = ($s.sku -replace '^Standard_', '').ToUpperInvariant()
            $m = Find-Meter 'Azure Database for PostgreSQL' $r.location { $_.skuName -eq $short -and $_.productName -like '*Flexible Server*Compute*' }
            $copies = if ($s.ha -and $s.ha -ne 'Disabled') { 2 } else { 1 }
            Add-Line $r.name 'at rest' "$($s.sku) ($($s.tier))" $copies $(if ($m) { [decimal]$m.retailPrice }) 'hour' $(if ($m) { [decimal]$m.retailPrice * $hoursPerMonth * $copies }) $(if ($m) { "compute, $($m.productName)" + $(if ($copies -gt 1) { ', high availability doubles it' } else { '' }) } else { "no published meter for $short; not known" })
            $st = Find-Meter 'Azure Database for PostgreSQL' $r.location { $_.meterName -eq 'Storage Data Stored' -and $_.productName -eq 'Azure Database for PostgreSQL Flex Server Storage' }
            Add-Line "$($r.name) storage" 'at rest' "$($s.gb) GB" $s.gb $(if ($st) { [decimal]$st.retailPrice }) 'GB-month' $(if ($st) { [decimal]$st.retailPrice * $s.gb }) 'provisioned storage, billed whether used or not'
        }
        'Microsoft.Web/serverFarms' {
            if ($r.tier -eq 'FlexConsumption') {
                $exec = Find-Meter 'Functions' $r.location { $_.meterName -eq 'On Demand Execution Time' }
                $freeGbs = Get-FreeUnits 'Functions' $r.location { $_.meterName -eq 'On Demand Execution Time' }
                $freeRuns = 10 * (Get-FreeUnits 'Functions' $r.location { $_.meterName -eq 'On Demand Total Executions' })
                Add-Line $r.name 'usage' 'FC1 (Flex Consumption)' 0 $(if ($exec) { [decimal]$exec.retailPrice }) 'GB-second' $null ("on demand only; the first {0:n0} GB-s and {1:n0} executions a month are free (per subscription). Not measured here" -f $freeGbs, $freeRuns)
                continue
            }
            $linux = "$($r.kind)" -match 'linux'
            $sku = [string]$r.sku
            $m = Find-Meter 'Azure App Service' $r.location { $_.skuName -eq $sku -and $(if ($linux) { $_.productName -like '*Plan - Linux' } else { $_.productName -notlike '*Linux*' }) }
            $workers = [int]$r.capacity
            Add-Line $r.name 'at rest' "$sku $(if ($linux) { 'Linux' } else { 'Windows' })" $workers $(if ($m) { [decimal]$m.retailPrice }) 'hour' $(if ($m) { [decimal]$m.retailPrice * $hoursPerMonth * $workers }) $(if ($m) { $m.productName } else { "no published meter for $sku; not known" })
        }
        'Microsoft.EventHub/namespaces' {
            $tu = Find-Meter 'Event Hubs' $r.location { $_.meterName -eq "$($r.sku) Throughput Unit" }
            Add-Line $r.name 'at rest' "$($r.sku), $($r.capacity) TU" $r.capacity $(if ($tu) { [decimal]$tu.retailPrice }) 'hour' $(if ($tu) { [decimal]$tu.retailPrice * $hoursPerMonth * [int]$r.capacity }) 'throughput units; auto-inflate adds units under load and bills them'
            $in = Find-Meter 'Event Hubs' $r.location { $_.meterName -eq "$($r.sku) Ingress Events" }
            $v = az monitor metrics list --resource $r.id --metric IncomingMessages --start-time $since --end-time $until --interval P1D --aggregation Total --query "value[0].timeseries[0].data[].total" -o tsv 2>$null
            $msgs = [decimal](($v | Where-Object { $_ } | ForEach-Object { [double]$_ } | Measure-Object -Sum).Sum)
            Add-Line "$($r.name) ingress" 'usage' "$msgs messages, 30 days" $msgs $(if ($in) { [decimal]$in.retailPrice }) 'million events' $(if ($in) { [decimal]$in.retailPrice * $msgs / 1000000 }) 'measured: IncomingMessages over the last 30 days'
        }
        'Microsoft.ContainerRegistry/registries' {
            $m = Find-Meter 'Container Registry' $r.location { $_.meterName -eq "$($r.sku) Registry Unit" }
            Add-Line $r.name 'at rest' $r.sku 1 $(if ($m) { [decimal]$m.retailPrice }) 'day' $(if ($m) { [decimal]$m.retailPrice * $hoursPerMonth / 24 }) 'registry unit, per day'
        }
        'Microsoft.Network/privateEndpoints' {
            $m = Find-Meter 'Virtual Network' 'Global' { $_.meterName -eq 'Standard Private Endpoint' }
            Add-Line $r.name 'at rest' 'private endpoint' 1 $(if ($m) { [decimal]$m.retailPrice }) 'hour' $(if ($m) { [decimal]$m.retailPrice * $hoursPerMonth }) 'per endpoint, whether used or not (published under region Global)'
        }
        'Microsoft.Network/privateDnsZones' {
            $m = Find-Meter 'Azure DNS' 'Zone 1' { $_.meterName -eq 'Private Zone' -and [decimal]$_.tierMinimumUnits -eq 0 }
            Add-Line $r.name 'at rest' 'private DNS zone' 1 $(if ($m) { [decimal]$m.retailPrice }) 'zone-month' $(if ($m) { [decimal]$m.retailPrice }) 'first 25 zones in a subscription (published under region Zone 1)'
        }
        'Microsoft.OperationalInsights/workspaces' {
            $m = Find-Meter 'Log Analytics' $r.location { $_.meterName -eq 'Analytics Logs Data Ingestion' }
            $gb = $null
            try {
                $q = @(Invoke-ClaudeLedgerQuery -WorkspaceResourceId $r.id -Kql 'Usage | where TimeGenerated > ago(30d) | where IsBillable == true | summarize gb = sum(Quantity) / 1000.0')
                $gb = if ($q.Count -and $null -ne $q[0].gb) { [math]::Round([decimal]$q[0].gb, 3) } else { [decimal]0 }
            }
            catch { $gb = $null }
            Add-Line $r.name 'usage' "$gb GB, 30 days" $gb $(if ($m) { [decimal]$m.retailPrice }) 'GB' $(if ($m -and $null -ne $gb) { [decimal]$m.retailPrice * $gb }) 'measured: billable ingestion over the last 30 days, at the rate after the free allowance'
        }
        default { }
    }
}

$others = @($resources | Where-Object { $_.type -in @('Microsoft.Storage/storageAccounts', 'Microsoft.KeyVault/vaults', 'Microsoft.Web/sites', 'Microsoft.Insights/components') })
foreach ($o in $others) {
    Add-Line $o.name 'usage' ($o.type -replace '^Microsoft\.', '') $null $null $null $null 'billed per transaction, GB or execution; small at this volume and not priced here'
}
$apim = @($resources | Where-Object type -eq 'Microsoft.ApiManagement/service')
if (-not $apim.Count) {
    Add-Line '(API Management)' 'shared' 'existing instance' $null $null $null $null 'Turnstile was deployed onto an existing API Management instance; its cost belongs to that instance'
}

$floor = ($lines | Where-Object { $_.Kind -eq 'at rest' -and $null -ne $_.MonthlyUsd } | Measure-Object MonthlyUsd -Sum).Sum
$usage = ($lines | Where-Object { $_.Kind -eq 'usage' -and $null -ne $_.MonthlyUsd } | Measure-Object MonthlyUsd -Sum).Sum
$unknown = @($lines | Where-Object { $_.Kind -eq 'at rest' -and $null -eq $_.MonthlyUsd })

$result = [pscustomobject][ordered]@{
    ResourceGroup    = $TurnstileResourceGroup
    PricedAtUtc      = $until
    AtRestMonthlyUsd = [math]::Round([decimal]$floor, 2)
    UsageMonthlyUsd  = [math]::Round([decimal]$usage, 2)
    NotKnown         = @($unknown | ForEach-Object { $_.Resource })
    Lines            = $lines.ToArray()
}
if ($AsJson) { return ($result | ConvertTo-Json -Depth 5) }

Write-Host ''
Write-Host "Turnstile in $TurnstileResourceGroup" -ForegroundColor Cyan
$lines | Sort-Object Kind, Resource | Format-Table Resource, Kind, Sku, @{ n = 'Rate'; e = { if ($null -ne $_.Rate) { '{0} /{1}' -f $_.Rate, $_.RateUnit } } }, @{ n = 'Monthly'; e = { if ($null -ne $_.MonthlyUsd) { '${0:n2}' -f $_.MonthlyUsd } } } -AutoSize | Out-String -Width 160 | Write-Host
Write-Host ('  At rest: ${0:n2} a month. Usage over the last 30 days: ${1:n2}.' -f $floor, $usage)
if ($unknown.Count) { Write-Host ("  Not known: $($unknown.Count) at-rest line(s) have no published price, so the floor is understated: " + (($unknown | ForEach-Object { $_.Resource }) -join ', ')) -ForegroundColor Yellow }
Write-Host "  List prices read from prices.azure.com at $until, 730 hours a month. No agreement or reservation discount." -ForegroundColor DarkGray
$result
