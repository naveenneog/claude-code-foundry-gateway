$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$fail=0
function Assert([string]$Name,[bool]$Pass){if($Pass){Write-Host "  [OK] $Name"}else{Write-Host "  [FAIL] $Name";$script:fail++}}
function Throws([string]$Name,[scriptblock]$Action,[string]$Pattern){try{& $Action|Out-Null;Assert $Name $false}catch{Assert $Name ($_.Exception.Message -match $Pattern)}}
$pricing=Join-Path $root 'scripts\ClaudeNetworkPricing.ps1'
Assert 'decision pricing helper exists' (Test-Path $pricing)
if(-not(Test-Path $pricing)){exit 1}
. $pricing
$hour=[pscustomobject]@{Known=$true;Rate=[decimal]'0.01';Basis='hour';Unit='1 Hour';Currency='USD';RequestedRegion='regiona';PublishedRegion='Global';RetrievedUtc='2026-09-25T00:00:00.0000000Z';MeterName='Standard Private Endpoint';ProductName='Virtual Network Private Link'}
$month=[pscustomobject]@{Known=$true;Rate=[decimal]'0.50';Basis='month';Unit='zone-month';Currency='USD';RequestedRegion='regiona';PublishedRegion='Global';RetrievedUtc='2026-09-25T00:00:00.0000000Z';MeterName='Private Zone';ProductName='Azure DNS'}
$new=New-ClaudeNetworkCostItem -Key 'pe/foundry' -Label 'New endpoint' -Quote $hour -CurrentQuantity 0 -DesiredQuantity 1
Assert 'a new endpoint has an explicit hourly and monthly delta' ($new.DeltaHourly -eq [decimal]'0.01' -and $new.DeltaMonthly -eq [decimal]'7.30')
$reuse=New-ClaudeNetworkCostItem -Key 'dns/hub' -Label 'Shared zone' -Quote $month -CurrentQuantity 1 -DesiredQuantity 1 -Shared
Assert 'reuse shows its cost but has zero incremental change' ($reuse.CurrentMonthly -eq [decimal]'0.5' -and $reuse.DesiredMonthly -eq [decimal]'0.5' -and $reuse.DeltaMonthly -eq 0 -and $reuse.Shared)
$removed=New-ClaudeNetworkCostItem -Key 'pe/old' -Label 'Owned endpoint removal' -Quote $hour -CurrentQuantity 1 -DesiredQuantity 0
Assert 'an explicit removal has a negative delta' ($removed.DeltaMonthly -eq [decimal]'-7.30')
$unknown=[pscustomobject]@{Known=$false;Rate=$null;Basis='hour';Unit='unknown';Currency='USD';RequestedRegion='regiona';PublishedRegion='';RetrievedUtc='2026-09-25T00:00:00.0000000Z';MeterName='unavailable';ProductName='unavailable'}
$u=New-ClaudeNetworkCostItem -Key 'unknown' -Label 'Unpriced item' -Quote $unknown -CurrentQuantity 0 -DesiredQuantity 1
Assert 'unknown proposed price is never a zero' ($null -eq $u.DesiredMonthly -and $null -eq $u.DeltaMonthly)
$sum=Get-ClaudeNetworkCostDelta -Items @($new,$reuse,$new)
Assert 'one shared resource referenced by two choices is counted once' ($sum.Items.Count -eq 2 -and $sum.KnownDeltaMonthly -eq [decimal]'7.30')
Assert 'known totals separate current, desired and delta' ($sum.KnownCurrentMonthly -eq [decimal]'0.5' -and $sum.KnownDesiredMonthly -eq [decimal]'7.8')
$different=New-ClaudeNetworkCostItem -Key 'pe/foundry' -Label 'Contradictory quantity' -Quote $hour -CurrentQuantity 0 -DesiredQuantity 2
Throws 'contradictory plans for the same resource fail closed' {Get-ClaudeNetworkCostDelta -Items @($new,$different)} 'Conflicting'
Assert 'a subtotal announces unpriced resources' (-not (Get-ClaudeNetworkCostDelta -Items @($new,$u)).Complete)

$rows=@(
    [pscustomobject]@{serviceName='Application Gateway';productName='Application Gateway WAF v2';skuName='Standard';meterName='Standard Fixed Cost';armRegionName='regiona';type='Consumption';retailPrice=[decimal]'0.36';unitOfMeasure='1/Hour';currencyCode='USD';tierMinimumUnits=0},
    [pscustomobject]@{serviceName='Application Gateway';productName='Application Gateway WAF v2 - Discounted';skuName='Standard';meterName='Standard Fixed Cost';armRegionName='regiona';type='Consumption';retailPrice=[decimal]'0.2';unitOfMeasure='1/Hour';currencyCode='USD';tierMinimumUnits=0}
)
$quote=Find-ClaudeNetworkRate -Rows $rows -ProductName 'Application Gateway WAF v2' -MeterName 'Standard Fixed Cost' -Region regiona -Basis hour
Assert 'the rate uses the selected region and non-discounted product' ($quote.Known -and $quote.Rate -eq [decimal]'0.36' -and $quote.RequestedRegion -eq 'regiona')
Assert 'every quoted option carries retrieval date and billing scope' ($quote.RetrievedUtc -match 'Z$' -and $quote.PublishedRegion -eq 'regiona')
$missing=Find-ClaudeNetworkRate -Rows $rows -ProductName 'Application Gateway WAF v2' -MeterName 'Standard Fixed Cost' -Region regionb -Basis hour
Assert 'another region is not silently priced at the first region' (-not $missing.Known)
$usageRows=@(
    [pscustomobject]@{type='Consumption';meterName='Ingestion';armRegionName='regiona';productName='Logs';skuName='Analytics';retailPrice=0;unitOfMeasure='1 GB';currencyCode='USD';tierMinimumUnits=0},
    [pscustomobject]@{type='Consumption';meterName='Ingestion';armRegionName='regiona';productName='Logs';skuName='Analytics';retailPrice=[decimal]'2.76';unitOfMeasure='1 GB';currencyCode='USD';tierMinimumUnits=5}
)
$usage=Find-ClaudeNetworkRate -Rows $usageRows -ProductName Logs -MeterName Ingestion -Region regiona -Basis usage
Assert 'a shared free allowance never makes marginal telemetry look free' ($usage.Known -and $usage.Rate -eq [decimal]'2.76' -and $usage.TierMinimum -eq 5)
. (Join-Path $root 'scripts\ClaudeNetworkDecisions.ps1')
$rates=@{}
foreach($key in @('appgw.fixed','appgw.cu','frontdoor.base','dns-zone','firewall.Standard','firewall.Premium','public-ip','private-endpoint','verifier.cpu','verifier.memory')){$rates[$key]=$hour}
$rates.configuration=New-ClaudeNetworkConfigurationRate regiona
$book=[pscustomobject]@{Region='regiona';Rates=$rates}
foreach($kind in @('topology','edge','access','network','dns','firewall','certificate','waf-mode')){
    $options=Get-ClaudeNetworkActionChoices -Kind $kind -Book $book
    Assert "$kind presents choices with dated costs and all seven implications" ($options.Count -ge 2 -and @($options|Where-Object{-not $_.Costs -or -not $_.Implications.Security -or -not $_.Implications.Capability -or -not $_.Implications.Availability -or -not $_.Implications.Operations -or -not $_.Implications.Breaks -or -not $_.Implications.Rollback -or -not $_.Implications.Dependencies}).Count -eq 0)
}
$edgeChoices=Get-ClaudeNetworkActionChoices -Kind edge -Book $book -Current application-gateway -CurrentCapacityUnits 20
$none=@($edgeChoices|Where-Object id -eq none)[0]
Assert 'choosing no new edge does not invent savings from an unapproved deletion' ((Get-ClaudeNetworkCostDelta $none.Costs).KnownDeltaMonthly -eq 0)
$all=Get-ClaudeNetworkActionChoices -Kind topology -Book $book
Throws 'unattended runs cannot silently take even a recommended topology' {Select-ClaudeNetworkDecision -Key topology -Title Topology -Options $all -RecommendedId private -Region regiona -NonInteractive} 'explicitly'

if($fail){exit 1}
Write-Host 'Network decision pricing holds.'
exit 0
