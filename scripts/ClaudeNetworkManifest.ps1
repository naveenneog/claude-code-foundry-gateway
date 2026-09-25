function Get-ClaudeNetworkPlannedResources {
    param(
        [System.Collections.IDictionary]$Parameters,$Inventory,$Book,
        [string]$FoundryId,[string]$EffectiveGatewayAccess,[string]$EffectiveFoundryAccess,
        [string]$Topology,[string]$NetworkMode,[string]$DnsMode,[string]$CertificateSource
    )
    $name=[string]$Parameters['Name']
    $rg="/subscriptions/$($Parameters['SubscriptionId'])/resourceGroups/$($Parameters['EdgeResourceGroup'])"
    $actions=New-Object System.Collections.Generic.List[object]
    $costs=New-Object System.Collections.Generic.List[object]
    function Add-Resource([string]$Id,[string]$Type,[string]$Decision,[string]$Detail,[string]$RateKey='configuration',[decimal]$Quantity=1,[switch]$Reuse){
        $exists=$Reuse -or @($Inventory.Resources|Where-Object id -eq $Id).Count -gt 0 -or @($Inventory.ResourceGroups|Where-Object id -eq $Id).Count -gt 0
        $verb=if($Reuse -or ($exists -and $Type -like 'Resource group*')){'Retain'}elseif($exists){'Change'}else{'Create'}
        $actions.Add([pscustomobject]@{Verb=$verb;Target=$Id;Property=$Type;Before=$(if($exists){'discovered existing resource'}else{'absent'});After=$Detail;DecisionKey=$Decision;AccessReducing=$false})
        $costs.Add((New-ClaudeNetworkCostItem -Key $Id -Label $Type -Quote $Book.Rates[$RateKey] -CurrentQuantity $(if($exists){$Quantity}else{0}) -DesiredQuantity $Quantity -Shared:$Reuse))
    }
    Add-Resource $rg 'Resource group (existing groups never deleted)' edge 'selected deployment scope'
    $vnetId=if($NetworkMode -eq 'create'){"$rg/providers/Microsoft.Network/virtualNetworks/$name"}else{[string]$Parameters['VnetId']}
    Add-Resource $vnetId 'Virtual network' network $(if($NetworkMode -eq 'create'){$Parameters['AddressPrefix']}else{'shared VNet kept unchanged'}) -Reuse:($NetworkMode -eq 'reuse')
    if($NetworkMode -eq 'create'){
        foreach($suffix in @('edge','apim')){
            Add-Resource "$rg/providers/Microsoft.Network/networkSecurityGroups/$name-$suffix" 'Network security group' subnets 'owned edge/integration rules'
        }
        foreach($subnet in @('edge','apim-integration','private-endpoints','verification')){
            Add-Resource "$vnetId/subnets/$subnet" 'Subnet' subnets ('reviewed purpose/delegation: '+$subnet)
        }
    }else{
        foreach($key in @('EdgeSubnetId','EndpointsSubnetId','ApimIntegrationSubnetId','VerificationSubnetId')){
            if($Parameters[$key]){Add-Resource $Parameters[$key] 'Existing subnet, unchanged' subnets 'reuse explicit ID' -Reuse}
        }
    }
    if($Topology -ne 'private'){
        $ip=if($Parameters['PublicIpId'] -eq 'new'){"$rg/providers/Microsoft.Network/publicIPAddresses/$name"}else{[string]$Parameters['PublicIpId']}
        Add-Resource $ip 'Public frontend IP' public-ip 'Standard static IPv4; chosen DNS label' public-ip 1 -Reuse:($Parameters['PublicIpId'] -ne 'new')
    }
    $identity="$rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$name"
    Add-Resource $identity 'Edge user-assigned identity' certificate 'read selected certificate; no developer credential'
    $vault=[string]$Parameters['KeyVaultId']
    if($CertificateSource -eq 'evaluation-ca'){
        $stem=$name.Replace('-','')
        $vault="$rg/providers/Microsoft.KeyVault/vaults/$($stem.Substring(0,[Math]::Min(20,$stem.Length)))kv"
        Add-Resource $vault 'Private evaluation Key Vault' certificate 'RBAC, private access, normal soft-delete retention'
        Add-Resource "$rg/providers/Microsoft.ContainerInstance/containerGroups/$name-verify" 'Temporary verifier CPU' certificate 'one CPU; automatic lifetime; remove after verification' verifier.cpu
        $costs.Add((New-ClaudeNetworkCostItem "$rg/verifier-memory" 'Temporary verifier memory' $Book.Rates['verifier.memory'] 0 2))
        $actions.Add([pscustomobject]@{Verb='Create';Target="$vault/certificates/listener";Property='Evaluation CA/server chain';Before='absent or owned test certificate';After='two-day chain; public CA only returned';DecisionKey='certificate';AccessReducing=$false})
        $actions.Add([pscustomobject]@{Verb='Create';Target="$vault/providers/Microsoft.Authorization/roleAssignments/[derived from verifier identity]";Property='Certificate Officer assignment';Before='absent or same assignment';After='private verifier identity only';DecisionKey='certificate';AccessReducing=$false})
    }else{Add-Resource $vault 'Existing certificate vault' certificate 'reuse approved certificate; no vault overwrite' -Reuse}
    $actions.Add([pscustomobject]@{Verb='Create';Target="$vault/providers/Microsoft.Authorization/roleAssignments/[derived from edge identity]";Property='Key Vault Secrets User assignment';Before='absent or same assignment';After='edge managed identity only';DecisionKey='certificate';AccessReducing=$false})
    $links=@()
    if($EffectiveGatewayAccess -eq 'private'){$links+=@{key='gateway';suffix='apim';target=$Parameters['ApimId'];zones=@('privatelink.azure-api.net')}}
    if($EffectiveFoundryAccess -eq 'private'){$links+=@{key='foundry';suffix='foundry';target=$FoundryId;zones=@('privatelink.cognitiveservices.azure.com','privatelink.openai.azure.com','privatelink.services.ai.azure.com')}}
    if($Topology -ne 'public' -or $CertificateSource -eq 'evaluation-ca'){$links+=@{key='certificate';suffix='vault';target=$vault;zones=@('privatelink.vaultcore.azure.net')}}
    foreach($link in $links){
        $decision=if($link.key -eq 'certificate'){'certificate'}else{$link.key+'-access'}
        Add-Resource "$rg/providers/Microsoft.Network/privateEndpoints/$name-$($link.suffix)" ("Private endpoint -> "+$link.target) $decision 'approved connection in the explicitly selected endpoint subnet' private-endpoint
        foreach($zone in $link.zones){
            $reuse=@($Parameters['PrivateDnsZoneId']|Where-Object{($_ -split '/')[-1] -eq $zone})
            $zoneId=if($reuse.Count){[string]$reuse[0]}else{"$rg/providers/Microsoft.Network/privateDnsZones/$zone"}
            Add-Resource $zoneId 'Private DNS zone' dns $zone dns-zone 1 -Reuse:($reuse.Count -gt 0)
            Add-Resource "$zoneId/virtualNetworkLinks/$name" 'Owned DNS VNet link' dns 'auto-registration off; chosen VNet only'
        }
    }
    if($Topology -ne 'public'){
        $hostname=[string]$Parameters['ListenerHostName']
        if(-not $hostname){$hostname='[selected public IP DNS output]'}
        Add-Resource "$rg/providers/Microsoft.Network/privateDnsZones/$hostname" 'Exact-name private listener zone' dns 'apex A record to selected private frontend, not a whole public suffix' dns-zone
        Add-Resource "$rg/providers/Microsoft.Network/privateDnsZones/$hostname/virtualNetworkLinks/$name" 'Private listener DNS VNet link' dns 'chosen VNet only'
    }
    foreach($pair in @(@{suffix='waf';parameter='GlobalWafPolicyId';decision='waf-mode'},@{suffix='messages-waf';parameter='MessagesWafPolicyId';decision='rule-set'})){
        $id=if($Parameters[$pair.parameter]){[string]$Parameters[$pair.parameter]}else{"$rg/providers/Microsoft.Network/ApplicationGatewayWebApplicationFirewallPolicies/$name-$($pair.suffix)"}
        Add-Resource $id 'WAF policy' $pair.decision 'chosen mode/rules; body checks/enforcement and log scrubbing' -Reuse:([bool]$Parameters[$pair.parameter])
    }
    Add-Resource "$rg/providers/Microsoft.Network/applicationGateways/$name" 'Application Gateway WAF_v2' edge 'chosen frontends; TLS verified; response buffering off; reviewed timeout'
    Add-Resource "$rg/providers/Microsoft.Network/applicationGateways/$name/providers/Microsoft.Insights/diagnosticSettings/network-edge" 'Diagnostic setting' workspace 'access and scrubbed WAF logs to selected workspace'
    return [pscustomobject]@{Actions=$actions.ToArray();Costs=$costs.ToArray()}
}
