<#
.SYNOPSIS
    Prices the selected regional edge and optional enterprise network components.
.DESCRIPTION
    Uses the Azure Retail Prices API, not stored tariffs. Monthly means 730
    hours. Traffic, telemetry and Claude inference are not silently priced as
    zero. A reused firewall or resolver is a shared cost, not a free service.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)][ValidatePattern('^[a-z0-9]+$')][string]$Region,
    [ValidateSet('BasicV2','StandardV2','PremiumV2')][string]$ApimSku = 'StandardV2',
    [ValidateRange(0,1250)][int]$CapacityUnits = 20,
    [ValidateRange(0,10)][int]$PublicIps = 1,
    [ValidateRange(0,1000)][int]$PrivateEndpoints = 3,
    [ValidateRange(0,1000)][int]$PrivateDnsZones = 5,
    [switch]$IncludeFirewall,
    [switch]$IncludeDnsResolver,
    [switch]$IncludeDdosPlan,
    [switch]$IncludeVerifier,
    [switch]$AsJson
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'AzureRetailPrice.ps1')
if (-not $PSCmdlet.ShouldProcess('Azure Retail Prices API','Read current public commercial list prices; no subscription changes')) { return }
function Catalog([string]$Service) {
    $filter = "serviceName eq '$($Service.Replace("'","''"))'"
    $url = 'https://prices.azure.com/api/retail/prices?$filter=' + [uri]::EscapeDataString($filter)
    $rows = @()
    while ($url) {
        if ($url -notmatch '^https://prices\.azure\.com/') { throw 'Unexpected price continuation host.' }
        $page = Invoke-RestMethod -Uri $url -TimeoutSec 45
        $rows += @($page.Items)
        $url = $page.NextPageLink
    }
    return ,$rows
}
function Line([string]$Name,$Price,[decimal]$Quantity,[string]$Billing) {
    $known = $null -ne $Price
    $rate = if ($known) { [decimal]$Price.UnitPrice } else { $null }
    $hourly = if ($known) { if ($Billing -eq 'month') { $rate*$Quantity/730 } else { $rate*$Quantity } } else { $null }
    $monthly = if ($known) { if ($Billing -eq 'month') { $rate*$Quantity } else { $hourly*730 } } else { $null }
    return [pscustomobject]@{name=$Name;known=$known;quantity=$Quantity;rate=$rate;rateUnit=$Billing;hourlyUsd=$hourly;monthlyUsd=$monthly;meter=$(if($known){$Price.MeterName}else{$null});publishedRegion=$(if($known){$Price.Region}else{$null})}
}
function From-Catalog($Rows,[string]$Meter,[string]$PublishedRegion) {
    $matches = @($Rows | Where-Object { $_.type -eq 'Consumption' -and $_.meterName -eq $Meter -and $_.armRegionName -eq $PublishedRegion -and [decimal]$_.tierMinimumUnits -eq 0 })
    if ($matches.Count -ne 1) { return $null }
    return [pscustomobject]@{UnitPrice=[decimal]$matches[0].retailPrice;MeterName=$Meter;Region=$PublishedRegion}
}
$dns = Catalog 'Azure DNS'
$lines = @()
$lines += Line 'Application Gateway WAF v2 fixed' (Get-AzureRetailPrice -ServiceName 'Application Gateway' -Region $Region -ProductName 'Application Gateway WAF v2' -MeterName 'Standard Fixed Cost' -SkuName Standard -Tier First) 1 'hour'
$lines += Line 'WAF v2 capacity (chosen quantity)' (Get-AzureRetailPrice -ServiceName 'Application Gateway' -Region $Region -ProductName 'Application Gateway WAF v2' -MeterName 'Standard Capacity Units' -SkuName Standard -Tier First) $CapacityUnits 'hour'
$lines += Line 'Standard public IPv4' (Get-AzureRetailPrice -ServiceName 'Virtual Network' -Region $Region -ProductName 'IP Addresses' -MeterName 'Standard IPv4 Static Public IP' -SkuName Standard -Tier First) $PublicIps 'hour'
$lines += Line 'Private endpoints' (Get-AzureRetailPrice -ServiceName 'Virtual Network' -Region Global -ProductName 'Virtual Network Private Link' -MeterName 'Standard Private Endpoint' -Tier First) $PrivateEndpoints 'hour'
$lines += Line 'Private DNS zones (first 25 tariff)' (From-Catalog $dns 'Private Zone' '') $PrivateDnsZones 'month'
$lines += Line 'APIM baseline (not an incremental edge cost)' (Get-AzureRetailPrice -ServiceName 'API Management' -Region $Region -MeterName (($ApimSku -replace 'V2',' v2')+' Unit') -Tier First) 1 'hour'
if ($IncludeFirewall) { $lines += Line 'Azure Firewall Standard fixed' (Get-AzureRetailPrice -ServiceName 'Azure Firewall' -Region $Region -MeterName 'Standard Deployment' -Tier First) 1 'hour' }
if ($IncludeDnsResolver) {
    $lines += Line 'DNS Private Resolver inbound endpoint' (From-Catalog $dns 'Private Resolver Inbound Endpoint' '') 1 'month'
    $lines += Line 'DNS Private Resolver outbound endpoint' (From-Catalog $dns 'Private Resolver Outbound Endpoint' '') 1 'month'
    $lines += Line 'DNS Private Resolver ruleset' (From-Catalog $dns 'Private Resolver DNS Forwarding Ruleset' '') 1 'month'
}
if ($IncludeDdosPlan) { $lines += Line 'DDoS Network Protection plan' (Get-AzureRetailPrice -ServiceName 'Azure DDOS Protection' -Region $Region -MeterName 'Network Protection Plan' -Tier First) 1 'hour' }
if ($IncludeVerifier) {
    $lines += Line 'Temporary verifier CPU' (Get-AzureRetailPrice -ServiceName 'Container Instances' -Region $Region -ProductName 'Container Instances' -MeterName 'Standard vCPU Duration' -Tier First) 1 'hour'
    $lines += Line 'Temporary verifier memory' (Get-AzureRetailPrice -ServiceName 'Container Instances' -Region $Region -ProductName 'Container Instances' -MeterName 'Standard Memory Duration' -Tier First) 2 'hour'
}
$known = @($lines | Where-Object known)
$hourly = [decimal]0
foreach ($line in $known) { $hourly += [decimal]$line.hourlyUsd }
$result = [pscustomobject]@{
    retrievedUtc=[DateTime]::UtcNow.ToString('o');region=$Region;currency='USD';monthlyHours=730;lines=$lines
    completeFixedCost=(@($lines | Where-Object { -not $_.known }).Count -eq 0);knownHourlySubtotal=$hourly;knownMonthlySubtotal=$hourly*730
    notIncluded=@('Foundry Claude tokens: not published as model-specific retail meters; use your agreement and the token ledger.','Traffic processing and egress; Log Analytics ingestion and retention; Key Vault operations; VPN/ExpressRoute; optional application compute and databases.','Front Door Premium is an alternative, not included in this Application Gateway subtotal.','Discounts, included allowances, taxes and invoice reconciliation. Capacity units must match the planned and measured load.')
}
if ($AsJson) { $result | ConvertTo-Json -Depth 20 }
else {
    Write-Host ("USD list prices in {0}, read {1}. 730 h/month; not an invoice." -f $Region,$result.retrievedUtc)
    $lines | Format-Table name,quantity,known,hourlyUsd,monthlyUsd,publishedRegion -AutoSize
    Write-Host ("Known fixed subtotal: USD {0:N4}/hour; {1:N2}/month." -f $result.knownHourlySubtotal,$result.knownMonthlySubtotal)
    if (-not $result.completeFixedCost) { Write-Warning 'At least one fixed meter is unknown. This is not a complete subtotal.' }
    $result.notIncluded | ForEach-Object { Write-Host "Not included: $_" }
}
