<#
.SYNOPSIS
    Produces a priced, explicit administrator network decision review.
.DESCRIPTION
    Read-only. Choices may be supplied as a JSON object for unattended review.
    Unsupported combinations are shown with blockers, never partially applied.
    WhatIf prints the same review and performs no Azure write.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory=$true)][string]$SubscriptionId,
    [Parameter(Mandatory=$true)][string]$ApimId,
    [Parameter(Mandatory=$true)][string]$ApiId,
    [string]$InventoryPath,
    [string[]]$DiscoverySubscriptionId=@(),
    [string]$ChoicesPath,
    [System.Collections.IDictionary]$Choices=@{},
    [System.Collections.IDictionary]$DeploymentParameters=@{},
    [string]$TurnstileResourceId,
    [string]$ProjectionResourceId,
    [string]$WorkspaceId,
    [Parameter(Mandatory=$true)][ValidateRange(1,90)][int]$LookbackDays,
    [string[]]$PrivateClientCidrs=@(),
    [string[]]$ExistingEdgeSourceCidrs=@(),
    [switch]$BackendPathValidated,
    [switch]$NonInteractive,
    [switch]$AsJson
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'ClaudeNetwork.ps1')
. (Join-Path $PSScriptRoot 'ClaudeNetworkImpact.ps1')
. (Join-Path $PSScriptRoot 'ClaudeNetworkPricing.ps1')
. (Join-Path $PSScriptRoot 'ClaudeNetworkDecisions.ps1')
. (Join-Path $PSScriptRoot 'ClaudeNetworkEstate.ps1')
. (Join-Path $PSScriptRoot 'ClaudeNetworkReview.ps1')
. (Join-Path $PSScriptRoot 'ClaudeNetworkManifest.ps1')
if($ChoicesPath){
    $data=Get-Content $ChoicesPath -Raw|ConvertFrom-Json
    $Choices=@{};foreach($property in $data.PSObject.Properties){$Choices[$property.Name]=$property.Value}
}
if($InventoryPath){
    $inventory=Get-Content $InventoryPath -Raw|ConvertFrom-Json
    if($inventory.SubscriptionId -ne $SubscriptionId -or -not(Test-ClaudeNetworkInventoryFresh $inventory.RetrievedUtc)){throw 'Refresh the selected subscription inventory before planning.'}
}else{$inventory=Get-ClaudeNetworkInventory -SubscriptionId $SubscriptionId -DiscoverySubscriptionId $DiscoverySubscriptionId}
if(@($inventory.DetailedResources|Where-Object id -eq $ApimId).Count -ne 1){throw 'The gateway was not uniquely discovered in the selected scope.'}
$apim=Get-ClaudeNetworkResource $ApimId
$estate=Get-ClaudeNetworkLinkedComponents -Inventory $inventory -Apim $apim -ApiId $ApiId -TurnstileResourceId $TurnstileResourceId -ProjectionResourceId $ProjectionResourceId
$gatewayRegion=($apim.location -replace ' ','').ToLowerInvariant()
$regionalMeters=Get-ClaudeNetworkPriceCatalog -ServiceName 'Application Gateway' -ProductName 'Application Gateway WAF v2'
$regionOptions=@()
foreach($location in @($inventory.Locations|Where-Object{$inventory.GatewayLocations -contains $_.displayName -or $inventory.GatewayLocations -contains $_.name})){
    $rate=Find-ClaudeNetworkRate -Rows $regionalMeters -ProductName 'Application Gateway WAF v2' -MeterName 'Standard Fixed Cost' -SkuName Standard -Region $location.name -Basis hour
    $imp=New-ClaudeNetworkImplications 'Keeps regional/residency choice explicit; this selection alone moves no existing resource.' 'Use only advertised regional services/SKUs; private integration is tied to the APIM region.' 'Another region is a new deployment and cutover, not automatic HA.' 'Operate regional resources and review cross-region routing/data transfer.' 'A mismatch with existing private integration can make backends unreachable.' 'Retain the original deployment until clients/DNS are moved; existing resources cannot be relocated in place.' 'Actual region availability, capacity, IPAM and the selected service network requirements.'
    $regionOptions+=New-ClaudeNetworkDecisionOption $location.name $location.displayName @((New-ClaudeNetworkCostItem ('region/'+$location.name) 'Regional WAF fixed fee comparison only; final edge/capacity choice priced separately' $rate 0 1)) $imp $location.name
}
$regionDecision=Select-ClaudeNetworkDecision -Key region -Title 'Choose a discovered region (regional WAF fixed fee shown for comparison)' -Options $regionOptions -SelectedId ([string]$Choices['region']) -RecommendedId $gatewayRegion -Region 'per-option region' -NonInteractive:$NonInteractive
$region=$regionDecision.Selected.id
$book=Get-ClaudeNetworkRateBook -Region $region -FrontDoorPriceZone ([string]$Choices['frontdoor-price-zone'])
$decisions=New-Object System.Collections.Generic.List[object]
$actions=New-Object System.Collections.Generic.List[object]
$costs=New-Object System.Collections.Generic.List[object]
$blockers=New-Object System.Collections.Generic.List[string]
$warnings=New-Object System.Collections.Generic.List[string]
$snapshots=New-Object System.Collections.Generic.List[object]
$decisions.Add($regionDecision)
foreach($warning in $book.Warnings){$warnings.Add($warning)}
function Decide([string]$Key,[string]$Title,[string]$Kind,[string]$Current='none',[bool]$Private=$true){
    $options=Get-ClaudeNetworkActionChoices -Kind $Kind -Book $book -Current $Current -PrivateSupported $Private
    $d=Select-ClaudeNetworkDecision -Key $Key -Title $Title -Options $options -SelectedId ([string]$Choices[$Key]) -Region $region -NonInteractive:$NonInteractive
    $decisions.Add($d)
    return $d.Selected.id
}
function Action([string]$Verb,[string]$Target,[string]$Property,$Before,$After,[string]$DecisionKey,[bool]$Reduce=$false){
    $actions.Add([pscustomobject]@{Verb=$Verb;Target=$Target;Property=$Property;Before=$Before;After=$After;DecisionKey=$DecisionKey;AccessReducing=$Reduce})
}
function ConfigurationCost([string]$Key,[string]$Label){
    $costs.Add((New-ClaudeNetworkCostItem $Key $Label $book.Rates.configuration 1 1))
}
$topology=Decide topology 'Choose the topology' topology
$cap=Get-ClaudeApimNetworkCapability $apim.sku.name $apim.properties.virtualNetworkType
$currentEdge=if($estate.RelatedEdges.Count){'application-gateway'}else{'none'}
$reuseEdge=$estate.RelatedEdges.Count -eq 1 -and $estate.RelatedEdges[0].name -eq $DeploymentParameters['Name'] -and ($estate.RelatedEdges[0].id -split '/')[4] -eq $DeploymentParameters['EdgeResourceGroup']
$edgeOptions=Get-ClaudeNetworkActionChoices -Kind edge -Book $book -Current $currentEdge -CurrentCapacityUnits $(if($estate.RelatedEdges.Count){10*[int]$estate.RelatedEdges[0].properties.autoscaleConfiguration.minCapacity}else{0}) -CapacityUnits $(if($DeploymentParameters.Contains('MinimumCapacity')){10*[int]$DeploymentParameters['MinimumCapacity']}else{20}) -PrivateSupported $cap.PrivateEndpoint -ReuseCurrentEdge:$reuseEdge
$edgeDecision=Select-ClaudeNetworkDecision -Key edge -Title 'Choose the edge, including no edge' -Options $edgeOptions -SelectedId ([string]$Choices['edge']) -Region $region -NonInteractive:$NonInteractive
$decisions.Add($edgeDecision);$edge=$edgeDecision.Selected.id
foreach($line in $edgeDecision.Selected.Costs){$costs.Add($line)}
$baselineRows=Get-AzureRetailMeter -ServiceName 'API Management' -Region $gatewayRegion
$baselineRate=Find-ClaudeNetworkRate -Rows $baselineRows -ProductName 'API Management' -MeterName (($apim.sku.name -replace 'V2',' v2')+' Unit') -Region $gatewayRegion -Basis hour
if(-not $baselineRate.Known){
    $baselineRows=Get-ClaudeNetworkPriceCatalog -ServiceName 'API Management' -MeterName (($apim.sku.name -replace 'V2',' v2')+' Unit')
    $baselineRate=Find-ClaudeNetworkRate -Rows $baselineRows -ProductName 'API Management' -MeterName (($apim.sku.name -replace 'V2',' v2')+' Unit') -Region $gatewayRegion -Basis hour
}
$costs.Add((New-ClaudeNetworkCostItem $apim.id 'Existing APIM allocation (not newly charged)' $baselineRate ([decimal]$apim.sku.capacity) ([decimal]$apim.sku.capacity) -Shared))
if($edge -eq 'front-door' -and $topology -ne 'public'){$blockers.Add('Front Door has public ingress, not an internal-only or dual-listener frontend. Choose public or the regional gateway.')}
if($region -ne $gatewayRegion -and $topology -ne 'public'){$blockers.Add('Private integration must be in the APIM subscription and region; review a separate cross-region network design.')}
$components=[ordered]@{gateway=$apim;foundry=$estate.Foundry;turnstile=$estate.Turnstile;projection=$estate.Projection}
$workspaces=@($inventory.DetailedResources|Where-Object type -eq 'Microsoft.OperationalInsights/workspaces')
$workspaceSelection=if($WorkspaceId){$WorkspaceId}else{[string]$Choices['workspace']}
$d=Get-ClaudeNetworkResourceChoice -Key workspace -Title 'Choose the actual Log Analytics destination' -Resources $workspaces -Book $book -SelectedId $workspaceSelection -NonInteractive:$NonInteractive
$decisions.Add($d);$WorkspaceId=$d.Selected.value.id
$components['logs']=Get-ClaudeNetworkResource $WorkspaceId
$access=@{};$impactActions=@()
foreach($key in $components.Keys){
    $resource=$components[$key]
    if(-not $resource){
        $none=New-ClaudeNetworkDecisionOption 'not-deployed' 'Not deployed or explicitly outside this plan' @((New-ClaudeNetworkCostItem "$key/absent" 'No component introduced' $book.Rates.configuration 0 0)) (New-ClaudeNetworkImplications 'No new exposure or role is introduced.' 'The optional component remains unavailable.' 'No new dependency.' 'No new component to operate.' 'Its optional features remain unavailable; unrelated resources are not guessed by name.' 'Select its real resource ID in a later review.' 'A discovered connected component or explicitly supplied resource ID is required.') $null
        $d=Select-ClaudeNetworkDecision -Key "$key-access" -Title "$key access" -Options @($none) -SelectedId ([string]$Choices["$key-access"]) -Region $region -NonInteractive:$NonInteractive
        $decisions.Add($d);$access[$key]='not-deployed';continue
    }
    $current=Get-ClaudeNetworkCurrentAccess $resource
    $support=if($key -eq 'gateway'){$cap.PrivateEndpoint -or $cap.Internal}else{$true}
    $accessOptions=Get-ClaudeNetworkActionChoices -Kind access -Book $book -Current $current -PrivateSupported $support
    $peExisting=@($resource.properties.privateEndpointConnections|Where-Object{$_.properties.privateLinkServiceConnectionState.status -eq 'Approved'}).Count
    foreach($option in $accessOptions){
        if($option.id -eq 'private'){
            $needed=if($current -eq 'private' -or $peExisting -gt 0){0}else{1}
            $zoneNumber=switch($key){'foundry'{3}'logs'{5}default{1}}
            $option.Costs=@(
                (New-ClaudeNetworkCostItem "$key/access-private-connection" "$key private connection minimum; existing connectivity must be verified" $book.Rates['private-endpoint'] $peExisting ($peExisting+$needed)),
                (New-ClaudeNetworkCostItem "$key/access-private-dns" "$key additional DNS when no reusable path exists" $book.Rates['dns-zone'] 0 ($needed*$zoneNumber))
            )
        }elseif($peExisting){
            $option.Costs=@($option.Costs)+@(New-ClaudeNetworkCostItem "$key/retained-private-connections" 'Existing endpoints are retained, not silently deleted for savings' $book.Rates['private-endpoint'] $peExisting $peExisting -Shared)
        }
    }
    $accessDecision=Select-ClaudeNetworkDecision -Key "$key-access" -Title "$key public/private decision (currently $current)" -Options $accessOptions -SelectedId ([string]$Choices["$key-access"]) -Region $region -NonInteractive:$NonInteractive
    $decisions.Add($accessDecision);$access[$key]=$accessDecision.Selected.id
    $desired=if($access[$key] -eq 'preserve'){$current}else{$access[$key]}
    $snapshots.Add([pscustomobject]@{Id=$resource.id;Etag=$resource.etag;PublicState=$current})
    ConfigurationCost "$key/access-control" "$key access setting; service and connection costs separate"
    if($desired -eq $current){Action Retain $resource.id 'network access' $current $current "$key-access"}
    else{
        Action Change $resource.id 'network access' $current $desired "$key-access" ($desired -eq 'private')
        if($desired -eq 'private'){
            $peCount=if($key -eq 'logs'){1}else{1}
            $zoneCount=switch($key){'foundry'{3}'logs'{5}default{1}}
            $existing=@($resource.properties.privateEndpointConnections|Where-Object{$_.properties.privateLinkServiceConnectionState.status -eq 'Approved'}).Count
            if($key -notin @('gateway','foundry')){
                $costs.Add((New-ClaudeNetworkCostItem "$key/new-private-endpoint" "$key private connection when new" $book.Rates['private-endpoint'] 0 $peCount))
                $costs.Add((New-ClaudeNetworkCostItem "$key/new-dns" "$key DNS zones when new" $book.Rates['dns-zone'] 0 $zoneCount))
            }
            if($existing){$warnings.Add("$key already has private connections. Choose reachable reuse or an isolated DNS boundary; do not overwrite shared answers.")}
        }
        if($key -notin @('gateway','foundry')){$blockers.Add("$key access conversion requires its service-specific private endpoint/integration readiness review. This regional edge command will not silently convert the optional estate.")}
        if($key -eq 'gateway' -and $desired -eq 'private'){$impactActions+='GatewayPrivate'}
        if($key -eq 'foundry' -and $desired -eq 'private'){$impactActions+='FoundryPrivate'}
    }
}
if($edge -ne 'none'){
    $impactActions+='EdgeOnly'
    Action Change $apim.id 'inference source restriction' 'discovered existing service policy' $edge edge $true
}
$network=Decide network 'Choose network ownership' network
$subnets=Decide subnets 'Choose subnet ownership' network
$dns=Decide dns 'Choose private DNS ownership' dns
$firewall=Decide firewall 'Choose egress firewall use' firewall
$certificate=Decide certificate 'Choose the TLS certificate source' certificate
$mode=Decide 'waf-mode' 'Choose WAF enforcement' 'waf-mode'
$effectiveGateway=if($access.gateway -eq 'preserve'){Get-ClaudeNetworkCurrentAccess $apim}else{$access.gateway}
$effectiveFoundry=if($access.foundry -eq 'preserve'){Get-ClaudeNetworkCurrentAccess $estate.Foundry}else{$access.foundry}
if($topology -ne 'public' -and $effectiveGateway -ne 'private'){$blockers.Add('The selected private/hybrid topology requires private gateway access; choose that component option explicitly.')}
$needsVnet=$edge -eq 'application-gateway' -or $effectiveGateway -eq 'private' -or $effectiveFoundry -eq 'private'
if($needsVnet){
    if($network -eq 'create'){
        $DeploymentParameters['VnetId']='new'
        if(-not $DeploymentParameters['AddressPrefix']){
            $used=@($inventory.DetailedResources|Where-Object type -eq 'Microsoft.Network/virtualNetworks'|ForEach-Object{$_.properties.addressSpace.addressPrefixes})
            $free=Get-ClaudeNetworkFreePrefix -Existing $used
            $options=@($free|ForEach-Object{
                New-ClaudeNetworkDecisionOption $_ $_ @((New-ClaudeNetworkCostItem 'network/ipam' 'Address selection; no Azure meter' $book.Rates.configuration 0 0)) (New-ClaudeNetworkImplications 'No observed VNet overlap, but on-premises IPAM is not discoverable here.' 'Reserves address space for explicitly chosen subnets.' 'Overlaps can prevent peering and cause outages.' 'Confirm corporate and future reservations with IPAM.' 'Unseen overlapping routes can strand clients.' 'A later renumbering requires workload migration; not an instant undo.' 'Explicit administrator IPAM approval.') $_
            })
            $d=Select-ClaudeNetworkDecision -Key address-prefix -Title 'Choose discovered unused address space' -Options $options -SelectedId ([string]$Choices['address-prefix']) -Region $region -NonInteractive:$NonInteractive
            $decisions.Add($d);$DeploymentParameters['AddressPrefix']=$d.Selected.id
        }
        if($subnets -ne 'create'){$blockers.Add('A new VNet has no existing subnets to reuse. Choose create subnets explicitly.')}
        if(-not $DeploymentParameters['IpamConfirmed']){$blockers.Add('The proposed new address plan needs explicit IPAM approval before applying.')}
    }else{
        $vnets=@($inventory.DetailedResources|Where-Object{$_.type -eq 'Microsoft.Network/virtualNetworks' -and $_.location -eq $region})
        $vnetChoice=Get-ClaudeNetworkResourceChoice -Key vnet -Title 'Choose the real VNet to reuse' -Resources $vnets -Book $book -SelectedId $(if($DeploymentParameters['VnetId']){[string]$DeploymentParameters['VnetId']}else{[string]$Choices['vnet']}) -NonInteractive:$NonInteractive
        $decisions.Add($vnetChoice);$DeploymentParameters['VnetId']=$vnetChoice.Selected.id
        if($subnets -eq 'create'){$blockers.Add('Creating subnets in a shared VNet requires the network-owner subnet change plan; the regional executor reuses existing subnets without replacing that VNet.')}
        foreach($subnetChoice in @(@{key='edge-subnet';parameter='EdgeSubnetId'},@{key='endpoint-subnet';parameter='EndpointsSubnetId'},@{key='integration-subnet';parameter='ApimIntegrationSubnetId'})){
            $options=@($vnetChoice.Selected.value.properties.subnets|ForEach-Object{[pscustomobject]@{id=$_.id;name="$($_.name) | $($_.properties.addressPrefix)";location=$region;sku=$null;properties=$_.properties}})
            $selected=if($DeploymentParameters[$subnetChoice.parameter]){[string]$DeploymentParameters[$subnetChoice.parameter]}else{[string]$Choices[$subnetChoice.key]}
            $d=Get-ClaudeNetworkResourceChoice -Key $subnetChoice.key -Title 'Choose the actual subnet (delegation/capacity rechecked by executor)' -Resources $options -Book $book -SelectedId $selected -NonInteractive:$NonInteractive
            $decisions.Add($d);$DeploymentParameters[$subnetChoice.parameter]=$d.Selected.id
        }
    }
}
if($edge -eq 'application-gateway' -and $topology -ne 'private'){
    $ips=@($inventory.DetailedResources|Where-Object{$_.type -eq 'Microsoft.Network/publicIPAddresses' -and $_.location -eq $region})
    $d=Get-ClaudeNetworkResourceChoice -Key public-ip -Title 'Choose public IP reuse or creation' -Resources $ips -Book $book -SelectedId $(if($DeploymentParameters['PublicIpId']){[string]$DeploymentParameters['PublicIpId']}else{[string]$Choices['public-ip']}) -AllowNew -RateKey public-ip -NonInteractive:$NonInteractive
    $decisions.Add($d);$DeploymentParameters['PublicIpId']=$d.Selected.id
}
if($edge -eq 'application-gateway' -and $certificate -in @('key-vault','import')){
    $vaults=@($inventory.DetailedResources|Where-Object type -eq 'Microsoft.KeyVault/vaults')
    $d=Get-ClaudeNetworkResourceChoice -Key vault -Title 'Choose the existing certificate vault' -Resources $vaults -Book $book -SelectedId $(if($DeploymentParameters['KeyVaultId']){[string]$DeploymentParameters['KeyVaultId']}else{[string]$Choices['vault']}) -NonInteractive:$NonInteractive
    $decisions.Add($d);$DeploymentParameters['KeyVaultId']=$d.Selected.id
    if(-not $DeploymentParameters['CertificateName']){$blockers.Add('Select an enabled exportable certificate on a routed administrator before approving an existing/imported certificate plan.')}
}
if($dns -eq 'reuse' -and -not $DeploymentParameters['PrivateDnsZoneId']){
    $zones=@($inventory.DetailedResources|Where-Object type -eq 'Microsoft.Network/privateDnsZones')
    $selected=@()
    foreach($zoneName in @('privatelink.azure-api.net','privatelink.cognitiveservices.azure.com','privatelink.openai.azure.com','privatelink.services.ai.azure.com','privatelink.vaultcore.azure.net')){
        if(($zoneName -eq 'privatelink.azure-api.net' -and $effectiveGateway -ne 'private') -or ($zoneName -match 'cognitiveservices|openai|services.ai' -and $effectiveFoundry -ne 'private') -or ($zoneName -eq 'privatelink.vaultcore.azure.net' -and $certificate -ne 'evaluation-ca')){continue}
        $d=Get-ClaudeNetworkResourceChoice -Key "dns:$zoneName" -Title "Choose shared DNS: $zoneName" -Resources @($zones|Where-Object name -eq $zoneName) -Book $book -SelectedId ([string]$Choices["dns:$zoneName"]) -RateKey dns-zone -NonInteractive:$NonInteractive
        $decisions.Add($d);$selected+=$d.Selected.id
    }
    $DeploymentParameters['PrivateDnsZoneId']=$selected
}
if($edge -eq 'none' -and $certificate -ne 'key-vault'){$warnings.Add('No edge is selected. Certificate/WAF choices are review context only; no certificate or WAF is introduced.')}
if($edge -eq 'application-gateway' -and $certificate -eq 'front-door-managed'){$blockers.Add('Front Door managed TLS cannot be installed on Application Gateway.')}
if($edge -eq 'front-door' -and $certificate -ne 'front-door-managed'){$blockers.Add('This Front Door plan requires its managed-domain certificate path; custom-vault domains require a separate approved domain plan.')}
if($firewall -ne 'none'){
    $fd=@($decisions|Where-Object Key -eq firewall)[0]
    foreach($line in $fd.Selected.Costs){$costs.Add($line)}
    $blockers.Add('The selected firewall path requires an approved policy, next hop, return route and dependency verification; no firewall or route is silently installed.')
}
if($edge -eq 'front-door'){$blockers.Add('Front Door is a priced manual deployment option in this packet. Follow the documented origin approval/WAF flow; this regional executor must not partially apply it.')}
if($edge -eq 'none' -and @($actions|Where-Object Verb -eq Change).Count){$blockers.Add('No-edge access conversion needs a verified direct private/public path before applying; use the service-specific change plan. A retain-only no-edge plan changes nothing.')}
$ruleOptions=@()
foreach($r in @($inventory.WafRuleSets|Where-Object{$_.properties.ruleSetType -in @('OWASP','Microsoft_DefaultRuleSet')})){
    $id="$($r.properties.ruleSetType)/$($r.properties.ruleSetVersion)"
    $imp=New-ClaudeNetworkImplications 'Changes web-attack detection, not Entra authorization or prompt safety.' 'Use the selected available managed-rule version; exclusion IDs are version-specific.' 'New rules can reject previously valid code traffic.' 'Replay Detection/Prevention tests and preserve the previous version for rollback.' 'Unreviewed rules or stale exclusions can block native clients.' 'Restore the previous version and its reviewed exclusions, not a global Allow.' 'Available service rule set, matching exclusions, scrubbed logs and a real client replay.'
    $compatible=($r.properties.ruleSetType -eq 'Microsoft_DefaultRuleSet' -and [version]$r.properties.ruleSetVersion -ge [version]'2.1') -or ($r.properties.ruleSetType -eq 'OWASP' -and [version]$r.properties.ruleSetVersion -ge [version]'3.2')
    $ruleOptions+=New-ClaudeNetworkDecisionOption $id $id @((New-ClaudeNetworkCostItem 'waf/rules' 'Rule configuration; edge cost unchanged' $book.Rates.configuration 1 1)) $imp $r.properties $compatible 'This rule version cannot provide the selected independent body-inspection/enforcement controls for large Claude requests.'
}
$rule=Select-ClaudeNetworkDecision -Key 'rule-set' -Title 'Choose the discovered WAF rule set' -Options $ruleOptions -SelectedId ([string]$Choices['rule-set']) -Region $region -NonInteractive:$NonInteractive
$decisions.Add($rule)
if($edge -eq 'application-gateway'){
    $name=[string]$DeploymentParameters['Name'];$rg=[string]$DeploymentParameters['EdgeResourceGroup']
    if(-not $name -or -not $rg){$blockers.Add('Supply the administrator-selected edge name/resource group and resource IDs in DeploymentParameters before applying.')}
    $DeploymentParameters['SubscriptionId']=$SubscriptionId;$DeploymentParameters['ApimId']=$ApimId
    $resources=Get-ClaudeNetworkPlannedResources -Parameters $DeploymentParameters -Inventory $inventory -Book $book -FoundryId $estate.Foundry.id -EffectiveGatewayAccess $effectiveGateway -EffectiveFoundryAccess $effectiveFoundry -Topology $topology -NetworkMode $network -DnsMode $dns -CertificateSource $certificate
    foreach($action in $resources.Actions){$actions.Add($action)}
    foreach($line in $resources.Costs){$costs.Add($line)}
}
$warnings.Add('Fixed infrastructure and known usage tariffs are not an invoice. Traffic, log volume, certificate issuance/operations and overlap during migration need explicit workload forecasts.')
$warnings.Add('Corporate VPN/ExpressRoute reachability is not proved by a CIDR suggestion. The administrator must approve IPAM, routing, DNS and private path dependencies.')
$impact=$null
if($impactActions.Count){
    $impact=Get-ClaudeNetworkImpact -ApimId $ApimId -LookbackDays $LookbackDays -PrivateClientCidrs $PrivateClientCidrs -EdgeSourceCidrs $ExistingEdgeSourceCidrs -Actions @($impactActions|Sort-Object -Unique) -BackendPathValidated:$BackendPathValidated
}
$parameters=@{}
foreach($key in $DeploymentParameters.Keys){$parameters[$key]=$DeploymentParameters[$key]}
if(-not $parameters.ContainsKey('BodyLimitKb')){$parameters.BodyLimitKb=2000}
if(-not $parameters.ContainsKey('BackendTimeoutSeconds')){$parameters.BackendTimeoutSeconds=600}
if(-not $parameters.ContainsKey('MinimumCapacity')){$parameters.MinimumCapacity=2}
if(-not $parameters.ContainsKey('MaximumCapacity')){$parameters.MaximumCapacity=10}
$parameters.SubscriptionId=$SubscriptionId;$parameters.ApimId=$ApimId;$parameters.ApiId=$ApiId
$parameters.NetworkProfile=$topology;$parameters.Location=$region;$parameters.WorkspaceId=$WorkspaceId
$parameters.BackendAccess=if($access.gateway -eq 'preserve'){Get-ClaudeNetworkCurrentAccess $apim}else{$access.gateway}
$parameters.FoundryAccess=$access.foundry;$parameters.LogsAccess=$access.logs;$parameters.TurnstileAccess=$access.turnstile;$parameters.ProjectionAccess=$access.projection
$parameters.EdgeType=$edge;$parameters.NetworkMode=$network;$parameters.SubnetMode=$subnets;$parameters.DnsMode=$dns;$parameters.FirewallMode=$firewall
$parameters.CertificateSource=$certificate;$parameters.WafMode=$mode;$parameters.ManagedRuleSet=$rule.Selected.id
$parameters.LookbackDays=$LookbackDays;$parameters.PrivateClientCidrs=$PrivateClientCidrs;$parameters.ExistingEdgeSourceCidrs=$ExistingEdgeSourceCidrs
$warnings.Add(("Reviewed protocol settings: HTTPS/443; response buffering off; backend timeout {0}s; inspected/enforced JSON {1}KB; minimum/maximum gateway instances {2}/{3}. These are visible settings, not an unreviewed deployment target." -f $parameters.BackendTimeoutSeconds,$parameters.BodyLimitKb,$parameters.MinimumCapacity,$parameters.MaximumCapacity))
$review=New-ClaudeNetworkReview -Region $region -Decisions $decisions.ToArray() -Actions $actions.ToArray() -CostItems $costs.ToArray() -Impact $impact -Parameters $parameters -Blockers $blockers.ToArray() -Snapshots $snapshots.ToArray() -Warnings $warnings.ToArray()
if($AsJson){$review|ConvertTo-Json -Depth 90}else{Show-ClaudeNetworkReview $review;$review}
