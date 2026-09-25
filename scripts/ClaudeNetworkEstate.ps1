function Get-ClaudeNetworkResource {
    param([string]$Id)
    if(-not $Id){return $null}
    $version=switch -Regex ($Id){
        '/Microsoft.ApiManagement/service/[^/]+$' {'2024-05-01';break}
        '/Microsoft.CognitiveServices/accounts/[^/]+$' {'2024-10-01';break}
        '/Microsoft.OperationalInsights/workspaces/[^/]+$' {'2023-09-01';break}
        '/Microsoft.Insights/components/[^/]+$' {'2020-02-02';break}
        '/Microsoft.Insights/privateLinkScopes/[^/]+$' {'2021-07-01-preview';break}
        '/Microsoft.DocumentDB/databaseAccounts/[^/]+$' {'2024-05-15';break}
        '/Microsoft.Web/(sites|serverfarms)/[^/]+$' {'2023-12-01';break}
        '/Microsoft.KeyVault/vaults/[^/]+$' {'2023-07-01';break}
        '/Microsoft.Cdn/profiles/[^/]+$' {'2024-02-01';break}
        '/Microsoft.Network/privateDnsZones/[^/]+$' {'2020-06-01';break}
        '/Microsoft.Network/' {'2024-05-01';break}
        default {throw 'Resource type is not supported by network discovery.'}
    }
    return Invoke-ClaudeNetworkArm "https://management.azure.com${Id}?api-version=$version"
}

function Get-ClaudeNetworkLinkedComponents {
    param($Inventory,$Apim,[string]$ApiId,[string]$TurnstileResourceId,[string]$ProjectionResourceId)
    $apis=Get-ClaudeNetworkPages "https://management.azure.com$($Apim.id)/apis?api-version=2024-05-01"
    $api=@($apis|Where-Object{$_.name -eq $ApiId})
    if($api.Count -ne 1){throw 'Select one discovered governed API before planning network changes.'}
    $hostName=([uri]$api[0].properties.serviceUrl).DnsSafeHost
    $foundry=@($Inventory.DetailedResources|Where-Object{ $_.type -eq 'Microsoft.CognitiveServices/accounts' -and $hostName.StartsWith($_.name+'.',[StringComparison]::OrdinalIgnoreCase) })
    if($foundry.Count -ne 1){throw 'The API backend did not resolve to one discovered Foundry account. Include its subscription explicitly.'}
    $values=Get-ClaudeNetworkPages "https://management.azure.com$($Apim.id)/namedValues?api-version=2024-05-01"
    $plain=@{}
    foreach($value in $values){if(-not $value.properties.secret){$plain[$value.name]=[string]$value.properties.value}}
    $turnstile=$null;$resolver=$null
    if($TurnstileResourceId){$turnstile=Get-ClaudeNetworkResource $TurnstileResourceId}
    elseif($plain.ContainsKey('turnstile-integration')){
        . (Join-Path $PSScriptRoot 'ClaudeTurnstileGovernance.ps1')
        $connection=ConvertFrom-ClaudeTurnstileIntegrationValue $plain['turnstile-integration']
        $uri=[string]$connection['url']
        if($uri){
            $siteName=([uri]$uri).DnsSafeHost.Split('.')[0]
            $sites=@($Inventory.Resources|Where-Object{$_.type -eq 'Microsoft.Web/sites' -and $_.name -eq $siteName})
            if($sites.Count -eq 1){$turnstile=Get-ClaudeNetworkResource $sites[0].id}
        }
    }
    $resolverUrl=[string]$plain['entitlement-resolver-url']
    if($resolverUrl -and $resolverUrl -notmatch 'not-deployed\.invalid'){
        $siteName=([uri]$resolverUrl).DnsSafeHost.Split('.')[0]
        $sites=@($Inventory.Resources|Where-Object{$_.type -eq 'Microsoft.Web/sites' -and $_.name -eq $siteName})
        if($sites.Count -eq 1){$resolver=Get-ClaudeNetworkResource $sites[0].id}
    }
    $projection=if($ProjectionResourceId){Get-ClaudeNetworkResource $ProjectionResourceId}else{$null}
    $bindings=Resolve-ClaudeNetworkTelemetry $Apim.id
    $relatedEdges=@()
    $gatewayHost=([uri]$Apim.properties.gatewayUrl).DnsSafeHost
    foreach($g in @($Inventory.DetailedResources|Where-Object type -eq 'Microsoft.Network/applicationGateways')){
        if(@($g.properties.backendAddressPools|ForEach-Object{$_.properties.backendAddresses}|Where-Object{$_.fqdn -eq $gatewayHost}).Count){$relatedEdges+=$g}
    }
    return [pscustomobject]@{
        Gateway=$Apim;Api=$api[0];Foundry=$foundry[0];Turnstile=$turnstile
        Projection=$projection;Resolver=$resolver;Telemetry=$bindings;RelatedEdges=$relatedEdges
        ProjectionSource=[string]$plain['entitlement-source']
    }
}

function Get-ClaudeNetworkCurrentAccess {
    param($Resource)
    if(-not $Resource){return 'not-deployed'}
    if($Resource.type -eq 'Microsoft.OperationalInsights/workspaces'){
        if($Resource.properties.publicNetworkAccessForQuery -eq 'Disabled' -and $Resource.properties.publicNetworkAccessForIngestion -eq 'Disabled'){return 'private'}
        return 'public-or-mixed'
    }
    if($Resource.properties.publicNetworkAccess -eq 'Disabled'){return 'private'}
    return 'public'
}

function Get-ClaudeNetworkResourceChoice {
    param([string]$Key,[string]$Title,[object[]]$Resources,$Book,[string]$SelectedId,[switch]$AllowNew,[switch]$AllowNone,[switch]$NonInteractive,[string]$RateKey='configuration')
    $options=@()
    if($AllowNew){
        $cost=New-ClaudeNetworkCostItem "$Key/new" 'New selected resource' $Book.Rates[$RateKey] 0 1
        $i=New-ClaudeNetworkImplications 'Dedicated ownership; existing shared resources are not overwritten.' 'Adds the explicitly selected Azure capability.' 'Provisioning, region capacity and dependent services must succeed.' 'New lifecycle, billing, diagnostics and rollback ownership.' 'Provisioning can fail on policy/quota; no existing service is assumed replaceable.' 'Remove only the new owned resource after restoring consumers.' 'Approved region, name/address plan and required Azure permissions.'
        $options+=New-ClaudeNetworkDecisionOption new 'Create a new dedicated resource' @($cost) $i $null
    }
    if($AllowNone){
        $i=New-ClaudeNetworkImplications 'No new surface or permission is introduced.' 'Optional component is not added to this plan.' 'No new dependency; current limitations remain.' 'No new resource to operate.' 'Features that require this component remain unavailable.' 'Select and deploy it in a later reviewed plan.' 'The selected topology must not depend on the omitted component.'
        $options+=New-ClaudeNetworkDecisionOption none 'Not deployed / not part of this change' @((New-ClaudeNetworkCostItem "$Key/none" 'No resource selected' $Book.Rates.configuration 0 0)) $i $null
    }
    foreach($r in $Resources){
        $cost=New-ClaudeNetworkCostItem $r.id 'Existing resource allocation' $Book.Rates[$RateKey] 1 1 -Shared
        $i=New-ClaudeNetworkImplications 'Reuse the discovered resource without replacing shared configuration.' 'Retains its actual SKU, region and capabilities.' 'Inherits its present availability and capacity.' 'Coordinate its owner, references and maintenance windows.' 'A conflicting DNS link, delegation or capacity limit can prevent reuse.' 'Remove only newly owned associations; retain the existing resource.' 'Explicit access to this exact resource and validation of its dependencies.'
        $options+=New-ClaudeNetworkDecisionOption $r.id "$($r.name) | $($r.location) | $($r.sku.name)" @($cost) $i $r
    }
    return Select-ClaudeNetworkDecision -Key $Key -Title $Title -Options $options -SelectedId $SelectedId -Region $Book.Region -NonInteractive:$NonInteractive
}
