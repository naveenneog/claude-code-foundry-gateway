if (-not (Get-Command Get-AzureRetailMeter -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'AzureRetailPrice.ps1') }
$script:ClaudeNetworkCatalogCache=@{}

function Get-ClaudeNetworkPriceCatalog {
    param([string]$ServiceName,[string]$ProductName,[string]$MeterName)
    $terms=@()
    if($ServiceName){$terms+="serviceName eq '$($ServiceName.Replace("'","''"))'"}
    if($ProductName){$terms+="productName eq '$($ProductName.Replace("'","''"))'"}
    if($MeterName){$terms+="meterName eq '$($MeterName.Replace("'","''"))'"}
    if(-not $terms.Count){throw 'A bounded price-catalog filter is required.'}
    $key=$terms -join ' and '
    if($script:ClaudeNetworkCatalogCache.ContainsKey($key)){return ,$script:ClaudeNetworkCatalogCache[$key]}
    $url='https://prices.azure.com/api/retail/prices?$filter='+[uri]::EscapeDataString($key)
    $rows=@();$seen=@{}
    while($url){
        if($url -notmatch '^https://prices\.azure\.com/' -or $seen.ContainsKey($url)){throw 'Invalid or repeated retail-price continuation URL.'}
        $seen[$url]=$true
        $page=Invoke-RestMethod -Uri $url -TimeoutSec 60 -ErrorAction Stop
        $rows+=@($page.Items)
        $url=$page.NextPageLink
    }
    $script:ClaudeNetworkCatalogCache[$key]=$rows
    return ,$rows
}

function Find-ClaudeNetworkRate {
    param(
        [object[]]$Rows,[string]$ProductName,[string]$MeterName,[string]$SkuName,
        [string]$Region,[AllowEmptyString()][string]$PublishedRegion,
        [ValidateSet('hour','month','usage','configuration')][string]$Basis,
        [decimal]$TierMinimum=0
    )
    $scope=if($PSBoundParameters.ContainsKey('PublishedRegion')){$PublishedRegion}else{$Region}
    $found=@($Rows|Where-Object {
        $_.type -eq 'Consumption' -and $_.meterName -eq $MeterName -and $_.armRegionName -eq $scope -and
        (-not $ProductName -or $_.productName -eq $ProductName) -and
        (-not $SkuName -or $_.skuName -eq $SkuName)
    })
    $selectedTier=$TierMinimum
    if($Basis -eq 'usage' -and -not $PSBoundParameters.ContainsKey('TierMinimum') -and $found.Count){
        $selectedTier=(@($found|ForEach-Object{[decimal]$_.tierMinimumUnits}|Sort-Object)[-1])
    }
    $found=@($found|Where-Object{[decimal]$_.tierMinimumUnits -eq $selectedTier})
    $rates=@($found|ForEach-Object{[decimal]$_.retailPrice}|Sort-Object -Unique)
    $known=$found.Count -gt 0 -and $rates.Count -eq 1
    return [pscustomobject]@{
        Known=$known;Rate=$(if($known){$rates[0]}else{$null});Basis=$Basis
        Unit=$(if($known){$found[0].unitOfMeasure}else{'unavailable'})
        Currency='USD';RequestedRegion=$Region;PublishedRegion=$scope
        RetrievedUtc=[DateTime]::UtcNow.ToString('o');MeterName=$MeterName;ProductName=$ProductName
        Candidates=$found.Count;TierMinimum=$selectedTier;Source='https://prices.azure.com/api/retail/prices'
    }
}

function New-ClaudeNetworkConfigurationRate {
    param([string]$Region,[string]$Label='Configuration only')
    return [pscustomobject]@{Known=$true;Rate=[decimal]0;Basis='configuration';Unit='No separately billed resource';Currency='USD';RequestedRegion=$Region;PublishedRegion='';RetrievedUtc=[DateTime]::UtcNow.ToString('o');MeterName=$Label;ProductName='Configuration, related resources priced separately';Candidates=0;Source='No resource/meter introduced by this control alone'}
}

function New-ClaudeNetworkCostItem {
    param(
        [Parameter(Mandatory=$true)][string]$Key,[string]$Label,$Quote,
        [ValidateRange(0,10000000)][decimal]$CurrentQuantity,
        [ValidateRange(0,10000000)][decimal]$DesiredQuantity,[switch]$Shared
    )
    $current=$null;$desired=$null
    if($CurrentQuantity -eq 0){$current=[decimal]0}
    if($DesiredQuantity -eq 0){$desired=[decimal]0}
    if($Quote.Known -and $Quote.Basis -ne 'usage'){
        $factor=if($Quote.Basis -eq 'hour'){[decimal]730}else{[decimal]1}
        $current=[decimal]$Quote.Rate*$CurrentQuantity*$factor
        $desired=[decimal]$Quote.Rate*$DesiredQuantity*$factor
    }
    $known=$null -ne $current -and $null -ne $desired
    return [pscustomobject]@{
        Key=$Key;Label=$Label;Shared=[bool]$Shared;Quote=$Quote;CurrentQuantity=$CurrentQuantity;DesiredQuantity=$DesiredQuantity
        CurrentMonthly=$current;DesiredMonthly=$desired;DeltaMonthly=$(if($known){$desired-$current}else{$null})
        CurrentHourly=$(if($null -ne $current){$current/730}else{$null});DesiredHourly=$(if($null -ne $desired){$desired/730}else{$null})
        DeltaHourly=$(if($known){($desired-$current)/730}else{$null});Known=$known
    }
}

function Get-ClaudeNetworkCostDelta {
    param([object[]]$Items)
    $unique=@{}
    foreach($item in $Items){
        if(-not $item.Key){throw 'Every cost line needs a stable resource or capacity key.'}
        if($unique.ContainsKey($item.Key)){
            $prior=$unique[$item.Key]
            if($prior.CurrentQuantity -ne $item.CurrentQuantity -or $prior.DesiredQuantity -ne $item.DesiredQuantity -or $prior.Quote.Rate -ne $item.Quote.Rate -or $prior.Quote.Basis -ne $item.Quote.Basis){throw "Conflicting quantities or rates for cost key '$($item.Key)'."}
        }else{$unique[$item.Key]=$item}
    }
    $current=[decimal]0;$desired=[decimal]0;$delta=[decimal]0
    foreach($item in $unique.Values){
        if($null -ne $item.CurrentMonthly){$current+=$item.CurrentMonthly}
        if($null -ne $item.DesiredMonthly){$desired+=$item.DesiredMonthly}
        if($item.Known){$delta+=$item.DeltaMonthly}
    }
    return [pscustomobject]@{
        Items=@($unique.Values|Sort-Object Key);Complete=(@($unique.Values|Where-Object{-not $_.Known}).Count -eq 0)
        KnownCurrentMonthly=$current;KnownDesiredMonthly=$desired;KnownDeltaMonthly=$delta
        KnownCurrentHourly=$current/730;KnownDesiredHourly=$desired/730;KnownDeltaHourly=$delta/730
        Currency='USD';MonthlyHours=730
    }
}

function Get-ClaudeNetworkRateBook {
    param([Parameter(Mandatory=$true)][string]$Region,[string]$FrontDoorPriceZone)
    $rates=@{};$errors=@()
    $specs=@(
        @{key='appgw.fixed';service='Application Gateway';product='Application Gateway WAF v2';meter='Standard Fixed Cost';sku='Standard';basis='hour'},
        @{key='appgw.cu';service='Application Gateway';product='Application Gateway WAF v2';meter='Standard Capacity Units';sku='Standard';basis='hour'},
        @{key='public-ip';service='Virtual Network';product='IP Addresses';meter='Standard IPv4 Static Public IP';sku='Standard';basis='hour'},
        @{key='private-endpoint';service='Virtual Network';product='Virtual Network Private Link';meter='Standard Private Endpoint';scope='Global';basis='hour'},
        @{key='dns-zone';service='Azure DNS';product='Azure DNS';meter='Private Zone';scope='';catalog=$true;basis='month'},
        @{key='dns-inbound';service='Azure DNS';product='Azure DNS';meter='Private Resolver Inbound Endpoint';scope='';catalog=$true;basis='month'},
        @{key='dns-outbound';service='Azure DNS';product='Azure DNS';meter='Private Resolver Outbound Endpoint';scope='';catalog=$true;basis='month'},
        @{key='dns-ruleset';service='Azure DNS';product='Azure DNS';meter='Private Resolver DNS Forwarding Ruleset';scope='';catalog=$true;basis='month'},
        @{key='firewall.Standard';service='Azure Firewall';meter='Standard Deployment';basis='hour'},
        @{key='firewall.Premium';service='Azure Firewall';meter='Premium Deployment';basis='hour'},
        @{key='firewall.data';service='Azure Firewall';meter='Standard Data Processed';basis='usage'},
        @{key='apim.BasicV2';service='API Management';meter='Basic v2 Unit';basis='hour'},
        @{key='apim.StandardV2';service='API Management';meter='Standard v2 Unit';basis='hour'},
        @{key='apim.PremiumV2';service='API Management';meter='Premium v2 Unit';basis='hour'},
        @{key='verifier.cpu';service='Container Instances';product='Container Instances';meter='Standard vCPU Duration';basis='hour'},
        @{key='verifier.memory';service='Container Instances';product='Container Instances';meter='Standard Memory Duration';basis='hour'},
        @{key='logs.ingestion';service='Log Analytics';meter='Analytics Logs Data Ingestion';basis='usage'},
        @{key='vault.operations';service='Key Vault';product='Key Vault';meter='Operations';sku='Standard';basis='usage'}
    )
    foreach($spec in $specs){
        $scope=if($spec.ContainsKey('scope')){$spec.scope}else{$Region}
        $rows=@()
        try{
            if($spec.catalog){$rows=Get-ClaudeNetworkPriceCatalog -ServiceName $spec.service}
            else{$rows=Get-AzureRetailMeter -ServiceName $spec.service -Region $scope -TimeoutSec 45}
            if($null -eq $rows){throw 'Price source unavailable'}
        }catch{$errors+="$($spec.key): price source unavailable"}
        $rates[$spec.key]=Find-ClaudeNetworkRate -Rows $rows -ProductName $spec.product -MeterName $spec.meter -SkuName $spec.sku -Region $Region -PublishedRegion $scope -Basis $spec.basis
        if(-not $rates[$spec.key].Known){
            try{
                $specific=Get-ClaudeNetworkPriceCatalog -ServiceName $spec.service -ProductName $spec.product -MeterName $spec.meter
                $rates[$spec.key]=Find-ClaudeNetworkRate -Rows $specific -ProductName $spec.product -MeterName $spec.meter -SkuName $spec.sku -Region $Region -PublishedRegion $scope -Basis $spec.basis
            }catch{$errors+="$($spec.key): specific meter lookup also unavailable"}
        }
    }
    $fd=@()
    try{$fd=Get-ClaudeNetworkPriceCatalog -ServiceName 'Azure Front Door Service'}catch{$errors+='frontdoor: price source unavailable'}
    $zones=@($fd|Where-Object{$_.meterName -eq 'Premium Base Fees' -and $_.type -eq 'Consumption'}|ForEach-Object{$_.armRegionName}|Sort-Object -Unique)
    $fdBase=@($fd|Where-Object{$_.meterName -eq 'Premium Base Fees' -and $_.type -eq 'Consumption' -and $_.armRegionName -notmatch 'Gov'})
    $uniform=@($fdBase|ForEach-Object{[decimal]$_.retailPrice}|Sort-Object -Unique)
    if($FrontDoorPriceZone){
        $rates['frontdoor.base']=Find-ClaudeNetworkRate -Rows $fd -ProductName 'Azure Front Door' -MeterName 'Premium Base Fees' -Region $Region -PublishedRegion $FrontDoorPriceZone -Basis month
    }elseif($uniform.Count -eq 1){
        $rates['frontdoor.base']=[pscustomobject]@{Known=$true;Rate=$uniform[0];Basis='month';Unit='1/Month';Currency='USD';RequestedRegion=$Region;PublishedRegion='Uniform commercial-zone base fee';RetrievedUtc=[DateTime]::UtcNow.ToString('o');MeterName='Premium Base Fees';ProductName='Azure Front Door';Candidates=$fdBase.Count;Source='https://prices.azure.com/api/retail/prices'}
    }else{$rates['frontdoor.base']=Find-ClaudeNetworkRate -Rows @() -MeterName 'Premium Base Fees' -Region $Region -Basis month}
    foreach($meter in @('Premium Requests','Premium Data Transfer Out','Premium Data Transfer In')){
        $rates['frontdoor.'+$meter]=Find-ClaudeNetworkRate -Rows $fd -ProductName 'Azure Front Door' -MeterName $meter -Region $Region -PublishedRegion ([string]$FrontDoorPriceZone) -Basis usage
    }
    $rates['configuration']=New-ClaudeNetworkConfigurationRate $Region
    return [pscustomobject]@{Region=$Region;RetrievedUtc=[DateTime]::UtcNow.ToString('o');Currency='USD';Rates=$rates;FrontDoorPriceZones=$zones;Warnings=$errors}
}

function Format-ClaudeNetworkMoney {
    param($Value)
    if($null -eq $Value){return 'UNKNOWN'}
    return ('USD {0:0.00000}' -f [decimal]$Value)
}

function Show-ClaudeNetworkOptionCost {
    param([object[]]$Items,[string]$Region)
    $total=Get-ClaudeNetworkCostDelta $Items
    Write-Host ("     Current: {0}/h, {1}/month; proposed: {2}/h, {3}/month; delta: {4}/h, {5}/month." -f
        (Format-ClaudeNetworkMoney $(if($total.Complete){$total.KnownCurrentHourly}else{$null})),
        (Format-ClaudeNetworkMoney $(if($total.Complete){$total.KnownCurrentMonthly}else{$null})),
        (Format-ClaudeNetworkMoney $(if($total.Complete){$total.KnownDesiredHourly}else{$null})),
        (Format-ClaudeNetworkMoney $(if($total.Complete){$total.KnownDesiredMonthly}else{$null})),
        (Format-ClaudeNetworkMoney $(if($total.Complete){$total.KnownDeltaHourly}else{$null})),
        (Format-ClaudeNetworkMoney $(if($total.Complete){$total.KnownDeltaMonthly}else{$null})))
    foreach($item in $total.Items){
        Write-Host ("       {0}: {1}; meter scope {2}; selected region {3}; read {4}{5}" -f $item.Label,$item.Quote.MeterName,$item.Quote.PublishedRegion,$Region,$item.Quote.RetrievedUtc,$(if($item.Shared){'; shared/reused, not free'}else{''})) -ForegroundColor DarkGray
    }
}
