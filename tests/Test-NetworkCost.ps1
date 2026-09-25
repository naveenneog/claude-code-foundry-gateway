$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$script:fail=0
$global:NetworkCostTestQueries=0
function Assert([string]$Name,[bool]$Pass) {
    if($Pass){Write-Host "  [OK] $Name"}else{Write-Host "  [FAIL] $Name";$script:fail++}
}
function Row($Service,$Region,$Product,$Sku,$Meter,$Price) {
    [pscustomobject]@{serviceName=$Service;armRegionName=$Region;productName=$Product;skuName=$Sku;meterName=$Meter;retailPrice=$Price;unitOfMeasure='1 Hour';currencyCode='USD';tierMinimumUnits=0;type='Consumption'}
}
$global:NetworkCostTestRows=@(
    (Row 'Application Gateway' regiona 'Application Gateway WAF v2' Standard 'Standard Fixed Cost' 0.36),
    (Row 'Application Gateway' regiona 'Application Gateway WAF v2 - Discounted' Standard 'Standard Fixed Cost' 0.20),
    (Row 'Application Gateway' regiona 'Application Gateway WAF v2' Standard 'Standard Capacity Units' 0.0144),
    (Row 'Virtual Network' regiona 'IP Addresses' Standard 'Standard IPv4 Static Public IP' 0.005),
    (Row 'Virtual Network' Global 'Virtual Network Private Link' Standard 'Standard Private Endpoint' 0.01),
    (Row 'API Management' regiona 'API Management' 'Standard v2' 'Standard v2 Unit' 0.9589),
    (Row 'Azure DNS' '' 'Azure DNS' Private 'Private Zone' 0.50)
)
function Invoke-RestMethod {
    param($Uri,$TimeoutSec,$ErrorAction)
    $global:NetworkCostTestQueries++
    $decoded=[uri]::UnescapeDataString($Uri)
    $selected=$global:NetworkCostTestRows
    if($decoded -match "serviceName eq '([^']+)'"){$service=$Matches[1];$selected=@($selected|Where-Object serviceName -eq $service)}
    if($decoded -match "armRegionName eq '([^']*)'"){$region=$Matches[1];$selected=@($selected|Where-Object armRegionName -eq $region)}
    return [pscustomobject]@{Items=@($selected);NextPageLink=$null}
}
$tool=Join-Path $root 'scripts\Get-ClaudeNetworkCost.ps1'
$result=(& $tool -Region regiona -CapacityUnits 10 -AsJson)|ConvertFrom-Json
Assert 'all six fixed meters are explicitly priced' ($result.completeFixedCost -and $result.lines.Count -eq 6)
Assert 'discounted WAF pricing is not accidentally selected' ($result.lines[0].rate -eq 0.36)
Assert 'global Private Link meter is used without pretending it is regional' ($result.lines[3].rate -eq 0.01 -and $result.lines[3].publishedRegion -eq 'Global')
Assert 'DNS monthly price is not multiplied by 730 twice' ($result.lines[4].monthlyUsd -eq 2.5)
$expected=[decimal]0.36+[decimal]0.144+[decimal]0.005+[decimal]0.03+([decimal]2.5/730)+[decimal]0.9589
Assert 'fixed subtotal uses quantities and consistent hourly units' ([math]::Abs($result.knownHourlySubtotal-$expected) -lt 0.0000001)
$before=$global:NetworkCostTestQueries
& $tool -Region regiona -WhatIf | Out-Null
Assert 'cost WhatIf performs no lookup or write' ($global:NetworkCostTestQueries -eq $before)
$global:NetworkCostTestRows=@($global:NetworkCostTestRows|Where-Object meterName -ne 'Standard IPv4 Static Public IP')
$unknown=(& $tool -Region regiona -AsJson)|ConvertFrom-Json
Assert 'missing tariff is unknown, not a free public IP' (-not $unknown.completeFixedCost -and $null -eq $unknown.lines[2].rate)
Remove-Variable NetworkCostTestRows,NetworkCostTestQueries -Scope Global
if($script:fail){exit 1}
Write-Host 'Network cost contract holds.'
exit 0
