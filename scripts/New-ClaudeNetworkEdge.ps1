<#
.SYNOPSIS
    Discovers and deploys a dedicated Application Gateway WAF v2 edge.
.DESCRIPTION
    Private and hybrid profiles require a v2 gateway that reaches private
    backends. The existing gateway policy is preserved and restricted to the
    edge's source addresses. No shared gateway, subnet, vault or WAF policy is
    overwritten. A local state file records ownership and rollback before writes.
    Run with -DiscoverOnly first, or -WhatIf to inspect the selected plan.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [string]$SubscriptionId,
    [string[]]$DiscoverySubscriptionId = @(),
    [string]$InventoryPath,
    [switch]$DiscoverOnly,
    [string]$ApimId,
    [string]$ApiId,
    [ValidateSet('public','private','hybrid')][string]$NetworkProfile,
    [ValidateSet('public','private')][string]$BackendAccess,
    [string]$EdgeResourceGroup,
    [string]$Name,
    [string]$Location,
    [string]$WorkspaceId,
    [string]$VnetId,
    [string]$EdgeSubnetId,
    [string]$EndpointsSubnetId,
    [string]$ApimIntegrationSubnetId,
    [string]$AddressPrefix,
    [switch]$IpamConfirmed,
    [string[]]$PrivateDnsZoneId = @(),
    [string]$PublicIpId,
    [string]$ListenerHostName,
    [string]$KeyVaultId,
    [string]$CertificateName,
    [switch]$TestCertificate,
    [string]$ManagedRuleSet,
    [ValidateSet('Detection','Prevention')][string]$WafMode = 'Detection',
    [string]$GlobalWafPolicyId,
    [string]$MessagesWafPolicyId,
    [string]$ExclusionsPath,
    [ValidateRange(128,2000)][int]$BodyLimitKb = 2000,
    [ValidateRange(21,86400)][int]$BackendTimeoutSeconds = 600,
    [ValidateRange(1,10)][int]$MinimumCapacity = 2,
    [ValidateRange(2,125)][int]$MaximumCapacity = 10,
    [string]$EdgeRouteTableId,
    [string]$ApimRouteTableId,
    [string]$DdosProtectionPlanId,
    [switch]$EnableNetworkIsolation,
    [switch]$CloseFoundryPublicAccess,
    [switch]$ConfirmApimChange,
    [string]$StatePath,
    [switch]$NonInteractive
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ClaudeNetwork.ps1')
. (Join-Path $PSScriptRoot 'ClaudeNetworkPolicy.ps1')
$root = Split-Path $PSScriptRoot -Parent
function Read-EdgeValue([string]$Label,[string]$Value,[string]$Recommendation) {
    if ($Value) { return $Value }
    if ($NonInteractive) { throw "Pass $Label explicitly for a non-interactive deployment." }
    $answer = Read-Host "$Label [$Recommendation]"
    if ($answer) { return $answer }
    if ($Recommendation) { return $Recommendation }
    throw "$Label is required."
}
function Pick-Resource([string]$Type,[string]$Selection,[string]$Label,[string]$Consequence,[switch]$New) {
    $options = Get-ClaudeNetworkResourceOptions -Inventory $inventory -Type $Type -Consequence $Consequence
    if ($New) { $options = @([pscustomobject]@{ id='new'; label='Create a dedicated resource'; consequence=$Consequence; value=$null }) + $options }
    return (Select-ClaudeNetworkOption -Options $options -SelectedId $Selection -RecommendedId $(if ($New) {'new'}) -Prompt $Label -NonInteractive:$NonInteractive)
}

if (-not $SubscriptionId) {
    $subscriptions = Invoke-ClaudeNetworkAz @('account','list')
    $options = @($subscriptions | Where-Object { $_.state -eq 'Enabled' } | ForEach-Object {
        [pscustomobject]@{id=$_.id;label=$_.name;consequence='Resources and their costs belong to this subscription.';value=$_}
    })
    $current = @($subscriptions | Where-Object { $_.isDefault })[0]
    $SubscriptionId = (Select-ClaudeNetworkOption -Options $options -RecommendedId $current.id -Prompt Subscription -NonInteractive:$NonInteractive).id
}
if ($InventoryPath) {
    $inventory = Get-Content $InventoryPath -Raw | ConvertFrom-Json
    if ($inventory.SubscriptionId -ne $SubscriptionId) { throw 'Inventory belongs to a different subscription.' }
    if ([DateTime]::UtcNow - [DateTime]::Parse($inventory.RetrievedUtc).ToUniversalTime() -gt [TimeSpan]::FromMinutes(30)) { throw 'Inventory is older than 30 minutes; rediscover before deployment.' }
}
else { $inventory = Get-ClaudeNetworkInventory -SubscriptionId $SubscriptionId -DiscoverySubscriptionId $DiscoverySubscriptionId }
if ($DiscoverOnly) { $inventory; return }

$apim = (Pick-Resource 'Microsoft.ApiManagement/service' $ApimId 'API Management' 'Only the explicitly selected instance is changed. Read its SKU and network mode before choosing.').value
$ApimId = $apim.id
if (($ApimId -split '/')[2] -ne $SubscriptionId) { throw 'The selected APIM must be in the deployment subscription.' }
$apim = Invoke-ClaudeNetworkArm "https://management.azure.com${ApimId}?api-version=2024-05-01"
$cap = Get-ClaudeApimNetworkCapability $apim.sku.name $apim.properties.virtualNetworkType
$profiles = @(
    [pscustomobject]@{id='private';label='A: internal-only private listener';consequence='Corporate VPN/ExpressRoute and private DNS required; no internet listener.'},
    [pscustomobject]@{id='public';label='B: internet HTTPS listener with WAF';consequence='Public IP is billed. Entra, entitlement and budgets still apply.'},
    [pscustomobject]@{id='hybrid';label='C: public and private HTTPS listeners';consequence='Split DNS and two client paths; one policy and one governed backend.'}
)
$NetworkProfile = (Select-ClaudeNetworkOption -Options $profiles -SelectedId $NetworkProfile -RecommendedId $(if($cap.OutboundIntegration){'private'}else{'public'}) -Prompt 'Network profile' -NonInteractive:$NonInteractive).id
[void](Assert-ClaudeNetworkSku $apim.sku.name $NetworkProfile)
$backendOptions = @([pscustomobject]@{id='public';label='Public APIM origin, edge IP allowlist';consequence='Basic v2 fallback. Public DNS remains; bypass must return 403.'})
if ($cap.PrivateEndpoint) { $backendOptions = @([pscustomobject]@{id='private';label='Private Link origin, public access disabled';consequence='Endpoint billed hourly. Private DNS and VNet connectivity required.'}) + $backendOptions }
if ($NetworkProfile -ne 'public') { $backendOptions = @($backendOptions | Where-Object id -eq 'private') }
$BackendAccess = (Select-ClaudeNetworkOption -Options $backendOptions -SelectedId $BackendAccess -RecommendedId $(if($cap.PrivateEndpoint){'private'}else{'public'}) -Prompt 'APIM origin access' -NonInteractive:$NonInteractive).id
if ($cap.Internal) { throw 'This script does not convert Premium v2 injection to integration. Use the existing private VIP as a manually configured origin; see NETWORK-ENTERPRISE.' }
$Location = if ($Location) { $Location } else { ($apim.location -replace ' ','').ToLowerInvariant() }
if ($inventory.GatewayLocations -notcontains $Location -and @($inventory.Locations | Where-Object { $_.name -eq $Location -and $inventory.GatewayLocations -contains $_.displayName }).Count -eq 0) { throw 'Application Gateway is not listed in the selected region.' }
$available = Get-ClaudeNetworkSkuLocation -Skus $inventory.ApimSkus -Sku $apim.sku.name
Write-Host ("APIM {0}: {1} currently unrestricted region(s); deployed in {2}." -f $apim.sku.name,$available.Count,$apim.location)

$apis = Get-ClaudeNetworkPages "https://management.azure.com${ApimId}/apis?api-version=2024-05-01"
$apiOptions = @($apis | Where-Object { $_.properties.serviceUrl -match '^https://' } | ForEach-Object { [pscustomobject]@{id=$_.name;label="$($_.name) | /$($_.properties.path)";consequence='The backend is discovered from this API, not guessed from its name.';value=$_} })
$api = (Select-ClaudeNetworkOption -Options $apiOptions -SelectedId $ApiId -Prompt 'Governed Claude API' -NonInteractive:$NonInteractive).value
$apiPolicy = Invoke-ClaudeNetworkArm "https://management.azure.com${ApimId}/apis/$($api.name)/policies/policy?api-version=2024-05-01"
if ($apiPolicy.properties.value -notmatch '<inbound>\s*<base\s*/>') { throw 'The API must inherit its service policy first in inbound; otherwise the edge restriction can be bypassed.' }
foreach ($otherApi in @($apis | Where-Object { $_.name -ne $api.name })) {
    $otherPolicy = Invoke-ClaudeNetworkArm "https://management.azure.com${ApimId}/apis/$($otherApi.name)/policies/policy?api-version=2024-05-01" -AllowNotFound
    if ($otherPolicy -and $otherPolicy.properties.value -notmatch '<inbound>\s*<base\s*/>') { throw 'Another API does not inherit service inbound policy first. Fix inheritance before claiming APIM accepts only the edge.' }
}
$foundryHost = ([uri]$api.properties.serviceUrl).DnsSafeHost
$foundry = @($inventory.DetailedResources | Where-Object { $_.type -eq 'Microsoft.CognitiveServices/accounts' -and $foundryHost.StartsWith($_.name+'.',[StringComparison]::OrdinalIgnoreCase) })
if ($foundry.Count -ne 1) { throw 'Could not uniquely discover the API Foundry account. Include its subscription in discovery.' }
$foundry = Invoke-ClaudeNetworkArm "https://management.azure.com$($foundry[0].id)?api-version=2024-10-01"
$privateFoundry = $NetworkProfile -ne 'public' -or $CloseFoundryPublicAccess -or $foundry.properties.publicNetworkAccess -eq 'Disabled'
if ($privateFoundry -and -not $cap.OutboundIntegration) { throw 'This APIM SKU cannot reach a private Foundry account.' }
if ($privateFoundry -and $foundry.properties.publicNetworkAccess -ne 'Disabled' -and -not $CloseFoundryPublicAccess) { throw 'Private profile would close a shared Foundry account. Pass -CloseFoundryPublicAccess only after reviewing every consumer.' }
if ($privateFoundry -and $Location -ne ($apim.location -replace ' ','').ToLowerInvariant()) { throw 'APIM integration and its VNet must be in the same region and subscription as APIM.' }

$EdgeResourceGroup = Read-EdgeValue '-EdgeResourceGroup' $EdgeResourceGroup ''
$Name = Read-EdgeValue '-Name' $Name ($apim.name + '-edge')
if ($Name -notmatch '^[a-z][a-z0-9-]{2,39}$' -or $EdgeResourceGroup -notmatch '^[a-zA-Z0-9._()-]{1,90}$') { throw 'Use an Azure-safe edge name (3-40 lowercase characters) and resource group.' }
if (-not $StatePath) { $StatePath = Join-Path $root ('.network-state\' + $Name + '.json') }
$StatePath = [IO.Path]::GetFullPath($StatePath)
$stateDirectory = Split-Path $StatePath -Parent
$state = if (Test-Path $StatePath) { Get-Content $StatePath -Raw | ConvertFrom-Json } else { $null }
if ($state -and ($state.ApimId -ne $ApimId -or $state.Name -ne $Name -or $state.ResourceGroup -ne $EdgeResourceGroup)) { throw 'State target mismatch. Use the original target or a different state file.' }
$owner = if ($state) { $state.OwnerId } else { [guid]::NewGuid().ToString() }
$rgId = "/subscriptions/$SubscriptionId/resourceGroups/$EdgeResourceGroup"
$gatewayId = "$rgId/providers/Microsoft.Network/applicationGateways/$Name"
$existing = Invoke-ClaudeNetworkArm "https://management.azure.com${gatewayId}?api-version=2024-05-01" -AllowNotFound
Assert-ClaudeNetworkOwnership -Resource $existing -OwnerId $owner
if ($MaximumCapacity -lt $MinimumCapacity) { throw 'Maximum capacity must not be below minimum capacity.' }
$workspace = (Pick-Resource 'Microsoft.OperationalInsights/workspaces' $WorkspaceId 'Log Analytics workspace' 'Access and firewall diagnostics are billed by ingestion and retention; avoid prompt content in exported evidence.').value
$WorkspaceId = $workspace.id

$vnets = Get-ClaudeNetworkResourceOptions -Inventory $inventory -Type 'Microsoft.Network/virtualNetworks' -Location $Location -Consequence 'Existing subnets are read only. Hub peerings and DNS servers must already route to the required services.'
$vnets = @([pscustomobject]@{id='new';label='Create an isolated spoke';consequence='Choose unused space; discovery cannot see on-premises IPAM.';value=$null}) + $vnets
if ($state -and -not $VnetId) { $VnetId = $state.VnetSelection }
$vnetChoice = Select-ClaudeNetworkOption -Options $vnets -SelectedId $VnetId -RecommendedId 'new' -Prompt 'Virtual network' -NonInteractive:$NonInteractive
$newVnet = $vnetChoice.id -eq 'new'
if ($newVnet) {
    $used = @($inventory.DetailedResources | Where-Object { $_.type -eq 'Microsoft.Network/virtualNetworks' -and $_.id -ne "$rgId/providers/Microsoft.Network/virtualNetworks/$Name" } | ForEach-Object { $_.properties.addressSpace.addressPrefixes })
    if ($state -and -not $AddressPrefix) { $AddressPrefix = $state.AddressPrefix }
    $free = Get-ClaudeNetworkFreePrefix -Existing $used
    $prefixOptions = @($free | ForEach-Object { [pscustomobject]@{id=$_;label=$_;consequence='No overlap in discovered VNets. Confirm corporate, peered and future address plans separately.'} })
    if ($AddressPrefix) {
        $range = Get-ClaudeNetworkCidr $AddressPrefix
        if ($range.Prefix -gt 22 -or -not (Test-ClaudeNetworkPrivateAddress (($AddressPrefix -split '/')[0]))) { throw 'A new spoke requires an RFC1918 /22 or larger.' }
        foreach ($u in $used) { if (Test-ClaudeNetworkOverlap $u $AddressPrefix) { throw "Address space overlaps a discovered VNet: $u" } }
    }
    else { $AddressPrefix = (Select-ClaudeNetworkOption -Options $prefixOptions -RecommendedId $free[0] -Prompt 'Unused address space' -NonInteractive:$NonInteractive).id }
    if (-not $IpamConfirmed -and -not $WhatIfPreference) {
        if ($NonInteractive -or (Read-Host 'IPAM approved this address range, including on-premises? Type yes') -ne 'yes') { throw 'Address plan must be explicitly approved with -IpamConfirmed.' }
    }
    $range = Get-ClaudeNetworkCidr $AddressPrefix
    $edgePrefix = "$(ConvertFrom-ClaudeNetworkNumber $range.First)/24"
    $apimPrefix = "$(ConvertFrom-ClaudeNetworkNumber ($range.First+256))/24"
    $pePrefix = "$(ConvertFrom-ClaudeNetworkNumber ($range.First+512))/26"
    $runnerPrefix = "$(ConvertFrom-ClaudeNetworkNumber ($range.First+576))/27"
    $VnetId = "$rgId/providers/Microsoft.Network/virtualNetworks/$Name"
    $EdgeSubnetId = "$VnetId/subnets/edge"
    $EndpointsSubnetId = "$VnetId/subnets/private-endpoints"
    $ApimIntegrationSubnetId = "$VnetId/subnets/apim-integration"
}
else {
    $VnetId = $vnetChoice.id
    $subnets = @($vnetChoice.value.properties.subnets)
    $options = @($subnets | Where-Object { @($_.properties.delegations | Where-Object { $_.properties.serviceName -ne 'Microsoft.Network/applicationGateways' }).Count -eq 0 -and -not $_.properties.privateEndpoints } | ForEach-Object { [pscustomobject]@{id=$_.id;label="$($_.name) | $($_.properties.addressPrefix)";value=$_;consequence='Dedicated Application Gateway subnet, /24 recommended; not modified.'} })
    $edgeSubnet = (Select-ClaudeNetworkOption -Options $options -SelectedId $EdgeSubnetId -Prompt 'Edge subnet' -NonInteractive:$NonInteractive).value
    $EdgeSubnetId = $edgeSubnet.id
    $edgePrefix = $edgeSubnet.properties.addressPrefix
    if ((Get-ClaudeNetworkCidr $edgePrefix).Prefix -gt 27) { throw 'Edge subnet is smaller than /27.' }
    if ($BackendAccess -eq 'private' -or $privateFoundry) {
        $options = @($subnets | Where-Object { -not $_.properties.delegations -and $_.id -ne $EdgeSubnetId } | ForEach-Object { [pscustomobject]@{id=$_.id;label="$($_.name) | $($_.properties.addressPrefix)";value=$_;consequence='Non-delegated private-endpoint subnet; addresses are billed per endpoint.'} })
        $EndpointsSubnetId = (Select-ClaudeNetworkOption -Options $options -SelectedId $EndpointsSubnetId -Prompt 'Endpoint subnet' -NonInteractive:$NonInteractive).id
    }
    if ($privateFoundry) {
        $options = @($subnets | Where-Object { $_.properties.delegations.properties.serviceName -contains 'Microsoft.Web/serverFarms' -and $_.properties.networkSecurityGroup.id } | ForEach-Object { [pscustomobject]@{id=$_.id;label="$($_.name) | $($_.properties.addressPrefix)";value=$_;consequence='Exclusive APIM integration subnet with an NSG; /27 minimum.'} })
        $ApimIntegrationSubnetId = (Select-ClaudeNetworkOption -Options $options -SelectedId $ApimIntegrationSubnetId -Prompt 'APIM integration subnet' -NonInteractive:$NonInteractive).id
    }
}
if ($privateFoundry -and $apim.properties.virtualNetworkConfiguration.subnetResourceId -and $apim.properties.virtualNetworkConfiguration.subnetResourceId -ne $ApimIntegrationSubnetId) { throw 'APIM already integrates with another subnet. Choose that VNet; this script will not move it.' }
$isolation = $inventory.NetworkIsolation -eq 'Registered' -or $EnableNetworkIsolation
if ($NetworkProfile -ne 'public' -and -not $isolation) { throw 'Private frontends require EnableApplicationGatewayNetworkIsolation. Review and pass -EnableNetworkIsolation, or register it first.' }
foreach ($routeId in @($EdgeRouteTableId,$ApimRouteTableId) | Where-Object { $_ }) {
    if (@($inventory.DetailedResources | Where-Object { $_.id -eq $routeId -and $_.type -eq 'Microsoft.Network/routeTables' }).Count -ne 1) { throw 'Route table was not discovered in the chosen scope.' }
    if (-not $newVnet) { throw 'Route tables on shared subnets are not changed. Have the network owner associate the selected table.' }
}
if ($EdgeRouteTableId -and -not $isolation) { throw 'Do not force-tunnel a legacy Application Gateway subnet. Enable network isolation before provisioning.' }
if ($DdosProtectionPlanId -and @($inventory.Resources | Where-Object { $_.id -eq $DdosProtectionPlanId -and $_.type -eq 'Microsoft.Network/ddosProtectionPlans' }).Count -ne 1) { throw 'DDoS plan was not discovered. Create or select the enterprise plan first.' }

$ruleOptions = @($inventory.WafRuleSets | Where-Object { $_.properties.ruleSetType -in @('Microsoft_DefaultRuleSet','OWASP') } | ForEach-Object {
    [pscustomobject]@{id="$($_.properties.ruleSetType)/$($_.properties.ruleSetVersion)";label="$($_.properties.ruleSetType) $($_.properties.ruleSetVersion)";value=$_.properties;consequence='Validate code prompts in Detection before changing to Prevention. Request inspection remains enabled.'}
})
$rule = (Select-ClaudeNetworkOption -Options $ruleOptions -SelectedId $ManagedRuleSet -RecommendedId 'Microsoft_DefaultRuleSet/2.1' -Prompt 'Available managed WAF rule set' -NonInteractive:$NonInteractive).value
if (($rule.ruleSetType -eq 'OWASP' -and [version]$rule.ruleSetVersion -lt [version]'3.2') -or ($rule.ruleSetType -eq 'Microsoft_DefaultRuleSet' -and [version]$rule.ruleSetVersion -lt [version]'2.1')) { throw 'Independent inspection/enforcement limits require CRS 3.2 or DRS 2.1 or later.' }
$exclusions = @()
if ($ExclusionsPath) { $exclusions = @(Get-Content $ExclusionsPath -Raw | ConvertFrom-Json) }
foreach ($exclusion in $exclusions) {
    if (-not $exclusion.exclusionManagedRuleSets -or $exclusion.selectorMatchOperator -eq 'EqualsAny') { throw 'Use measured rule-scoped exclusions; global or EqualsAny exclusions are refused.' }
}
if ($TestCertificate) {
    if ($KeyVaultId) { throw 'Test certificates are created only in a new dedicated vault, never an existing vault.' }
    $KeyVaultId = "$rgId/providers/Microsoft.KeyVault/vaults/$($Name.Replace('-','').Substring(0,[Math]::Min(20,$Name.Replace('-','').Length)))kv"
    $CertificateName = 'listener'
}
else {
    $vault = (Pick-Resource 'Microsoft.KeyVault/vaults' $KeyVaultId 'Certificate vault' 'Select an RBAC vault with an enabled, exportable PFX certificate. Cross-subscription vaults work through Bicep, not the portal picker.').value
    $KeyVaultId = $vault.id
    if (-not $vault.properties.enableRbacAuthorization) { throw 'This automated path requires an RBAC vault. Keep an access-policy vault unchanged and use the documented manual route.' }
    $certs = Invoke-ClaudeNetworkAz @('keyvault','certificate','list','--vault-name',$vault.name)
    $options = @($certs | Where-Object { $_.attributes.enabled } | ForEach-Object { [pscustomobject]@{id=($_.id -split '/')[-1];label=($_.id -split '/')[-1];value=$_;consequence='Versionless secret reference rotates when Key Vault renews the certificate.'} })
    $CertificateName = (Select-ClaudeNetworkOption -Options $options -SelectedId $CertificateName -Prompt Certificate -NonInteractive:$NonInteractive).id
    $ListenerHostName = Read-EdgeValue '-ListenerHostName' $ListenerHostName ''
}
if ($NetworkProfile -ne 'private') {
    $pipSelection = if ($PublicIpId) { $PublicIpId } elseif ($state) { $state.PublicIpSelection } else { $null }
    $pip = Pick-Resource 'Microsoft.Network/publicIPAddresses' $pipSelection 'Public IP' 'Standard static IPv4; existing assigned IPs are refused. Public IP and outbound transfer are billed.' -New
    if ($pip.value -and ($pip.value.sku.name -ne 'Standard' -or $pip.value.properties.ipConfiguration -or $pip.value.location -ne $Location)) { throw 'Select an unused Standard public IP in the edge region.' }
    $PublicIpId = if ($pip.id -eq 'new') { "$rgId/providers/Microsoft.Network/publicIPAddresses/$Name" } else { $pip.id }
}
else { $PublicIpId = ''; $ListenerHostName = Read-EdgeValue '-ListenerHostName' $ListenerHostName '' }
if ($ListenerHostName -and $ListenerHostName -notmatch '^(?=.{1,253}$)[a-zA-Z0-9](?:[a-zA-Z0-9.-]*[a-zA-Z0-9])$') { throw 'Invalid listener DNS name.' }
$plan = [ordered]@{ profile=$NetworkProfile; originAccess=$BackendAccess; apimId=$ApimId; apimSku=$apim.sku.name; foundryId=$foundry.id; foundryPrivate=$privateFoundry; region=$Location; resourceGroup=$EdgeResourceGroup; gatewayId=$gatewayId; vnetId=$VnetId; edgeSubnetId=$EdgeSubnetId; endpointSubnetId=$EndpointsSubnetId; workspaceId=$WorkspaceId; certificateVaultId=$KeyVaultId; listener=$ListenerHostName; wafMode=$WafMode; ruleSet="$($rule.ruleSetType)/$($rule.ruleSetVersion)"; bodyLimitKb=$BodyLimitKb; timeoutSeconds=$BackendTimeoutSeconds; responseBuffering=$false; newVnet=$newVnet; egressRouteTable=$EdgeRouteTableId; statePath=$StatePath }
$plan | ConvertTo-Json -Depth 10 | Write-Host
Write-Host 'Existing hub peerings, firewalls, route tables and private DNS zones are in discovery. No unseen IPAM range or internet route is inferred.'
if (-not $WhatIfPreference -and -not $ConfirmApimChange) { throw 'Review the plan, then pass -ConfirmApimChange. The service policy and public access of the selected APIM will change.' }
if (-not $PSCmdlet.ShouldProcess($gatewayId,'Deploy the selected edge, private connectivity and APIM restriction')) { return [pscustomobject]$plan }

if (-not $state) {
    $originalPolicy = Invoke-ClaudeNetworkArm "https://management.azure.com${ApimId}/policies/policy?api-version=2024-05-01" -AllowNotFound
    $state = [pscustomobject]@{
        Version=1; OwnerId=$owner; SubscriptionId=$SubscriptionId; ResourceGroup=$EdgeResourceGroup; Name=$Name; ApimId=$ApimId; ApiId=$api.name; ApiPath=$api.properties.path
        FoundryId=$foundry.id; FoundryOriginalPublicAccess=$foundry.properties.publicNetworkAccess; OriginalApimNetwork=$apim.properties; OriginalPolicy=$originalPolicy
        VnetSelection=$vnetChoice.id; VnetId=$VnetId; AddressPrefix=$AddressPrefix; PublicIpSelection=$(if($pip){$pip.id}else{''})
        CreatedUtc=[DateTime]::UtcNow.ToString('o'); OwnedResources=@(); NetworkProfile=$NetworkProfile; BackendAccess=$BackendAccess
        GatewayId=$gatewayId; WorkspaceId=$WorkspaceId; KeyVaultId=$KeyVaultId; Endpoint=''; Applied=$false; Removed=$false
    }
}
$state.NetworkProfile=$NetworkProfile; $state.BackendAccess=$BackendAccess
Write-ClaudeNetworkState $state $StatePath
function Track([string]$Id,[string]$ApiVersion,[string]$Kind = 'tag',[string]$PrincipalId = '') {
    if (@($state.OwnedResources | Where-Object id -eq $Id).Count -eq 0) {
        $state.OwnedResources += [pscustomobject]@{id=$Id;apiVersion=$ApiVersion;kind=$Kind;principalId=$PrincipalId}
        Write-ClaudeNetworkState $state $StatePath
    }
}
function Owned-Put([string]$Id,[string]$Version,[object]$Body) {
    $live = Invoke-ClaudeNetworkArm "https://management.azure.com${Id}?api-version=$Version" -AllowNotFound
    Assert-ClaudeNetworkOwnership -Resource $live -OwnerId $owner
    Track $Id $Version
    return Invoke-ClaudeNetworkArm "https://management.azure.com${Id}?api-version=$Version" -Method put -Body $Body -StateDirectory $stateDirectory
}
function Deploy([string]$Suffix,[string]$File,[hashtable]$Parameters,[string]$Group = $EdgeResourceGroup,[string]$Sub = $SubscriptionId) {
    return Invoke-ClaudeNetworkDeployment -SubscriptionId $Sub -ResourceGroup $Group -Name "$Name-$Suffix" -Template (Join-Path $root "infra\$File") -Parameters $Parameters -StateDirectory $stateDirectory
}
function Ensure-Zone([string]$ZoneName) {
    $specified = @($PrivateDnsZoneId | Where-Object { ($_ -split '/')[-1] -eq $ZoneName })
    $options = @($inventory.DetailedResources | Where-Object { $_.type -eq 'Microsoft.Network/privateDnsZones' -and $_.name -eq $ZoneName } | ForEach-Object { [pscustomobject]@{id=$_.id;label=$_.id;value=$_;consequence='Reuse the enterprise DNS namespace. Do not add a second isolated endpoint for the same account unless all links can route to it.'} })
    $options = @([pscustomobject]@{id='new';label='New isolated zone in the edge resource group';consequence='Use only for a new isolated VNet. Never link two zones with this name to the same VNet.'}) + $options
    $choice = if ($NonInteractive -and -not $specified.Count) { 'new' } elseif ($specified.Count) { $specified[0] } else { '' }
    $pick = Select-ClaudeNetworkOption -Options $options -SelectedId $choice -RecommendedId $(if($newVnet){'new'}) -Prompt "DNS: $ZoneName" -NonInteractive:$NonInteractive
    $id = if ($pick.id -eq 'new') { "$rgId/providers/Microsoft.Network/privateDnsZones/$ZoneName" } else { $pick.id }
    $parts = $id -split '/'
    $linkId = "$id/virtualNetworkLinks/$Name"
    $live = Invoke-ClaudeNetworkArm "https://management.azure.com${linkId}?api-version=2020-06-01" -AllowNotFound
    Assert-ClaudeNetworkOwnership -Resource $live -OwnerId $owner
    if ($pick.id -eq 'new') { Track $id '2020-06-01' }
    Track $linkId '2020-06-01'
    [void](Deploy ('dns-'+($ZoneName -replace '[^a-zA-Z0-9]','').Substring(0,[Math]::Min(28,($ZoneName -replace '[^a-zA-Z0-9]','').Length))) 'network-private-dns.bicep' @{name=$ZoneName;ownerId=$owner;vnetId=$VnetId;createZone=($pick.id -eq 'new');linkName=$Name} $parts[4] $parts[2])
    return $id
}
function Ensure-Endpoint([string]$Suffix,[string]$Target,[string[]]$Groups,[string[]]$Zones) {
    $id = "$rgId/providers/Microsoft.Network/privateEndpoints/$Name-$Suffix"
    Assert-ClaudeNetworkOwnership (Invoke-ClaudeNetworkArm "https://management.azure.com${id}?api-version=2024-05-01" -AllowNotFound) $owner
    Track $id '2024-05-01'
    [void](Deploy "pe-$Suffix" 'network-private-endpoint.bicep' @{name="$Name-$Suffix";ownerId=$owner;location=$Location;subnetId=$EndpointsSubnetId;targetId=$Target;groupIds=$Groups;privateDnsZoneIds=$Zones})
}
function Grant-VaultRole([string]$Principal,[string]$Role,[string]$PrincipalType) {
    $definition = @(Invoke-ClaudeNetworkAz @('role','definition','list','--name',$Role,'--subscription',$SubscriptionId))[0]
    $hash = [Security.Cryptography.SHA256]::Create()
    try { $bytes=$hash.ComputeHash([Text.Encoding]::UTF8.GetBytes("$KeyVaultId/$Principal/$Role")) } finally { $hash.Dispose() }
    $roleName = (New-Object Guid (,$bytes[0..15])).ToString()
    $id = "$KeyVaultId/providers/Microsoft.Authorization/roleAssignments/$roleName"
    Track $id '2022-04-01' 'role' $Principal
    [void](Invoke-ClaudeNetworkArm "https://management.azure.com${id}?api-version=2022-04-01" -Method put -Body @{properties=@{roleDefinitionId=$definition.id;principalId=$Principal;principalType=$PrincipalType}} -StateDirectory $stateDirectory)
}

$group = Invoke-ClaudeNetworkArm "https://management.azure.com${rgId}?api-version=2022-09-01" -AllowNotFound
if (-not $group) { [void](Invoke-ClaudeNetworkArm "https://management.azure.com${rgId}?api-version=2022-09-01" -Method put -Body @{location=$Location;tags=@{'claude-network-owner'=$owner}} -StateDirectory $stateDirectory) }
if ($EnableNetworkIsolation -and $inventory.NetworkIsolation -ne 'Registered') {
    [void](Invoke-ClaudeNetworkAz @('feature','register','--namespace','Microsoft.Network','--name','EnableApplicationGatewayNetworkIsolation','--subscription',$SubscriptionId))
    $deadline = [DateTime]::UtcNow.AddMinutes(35)
    do {
        Start-Sleep -Seconds 20
        $registration = Invoke-ClaudeNetworkAz @('feature','show','--namespace','Microsoft.Network','--name','EnableApplicationGatewayNetworkIsolation','--subscription',$SubscriptionId)
    } while ($registration.properties.state -ne 'Registered' -and [DateTime]::UtcNow -lt $deadline)
    if ($registration.properties.state -ne 'Registered') { throw 'Network isolation registration did not complete within 35 minutes.' }
}
if ($newVnet) {
    Assert-ClaudeNetworkOwnership (Invoke-ClaudeNetworkArm "https://management.azure.com${VnetId}?api-version=2024-05-01" -AllowNotFound) $owner
    foreach ($nsg in @("$Name-edge","$Name-apim")) { Track "$rgId/providers/Microsoft.Network/networkSecurityGroups/$nsg" '2024-05-01' }
    Track $VnetId '2024-05-01'
    [void](Deploy 'vnet' 'network-edge-vnet.bicep' @{name=$Name;location=$Location;ownerId=$owner;addressPrefix=$AddressPrefix;edgePrefix=$edgePrefix;apimPrefix=$apimPrefix;endpointsPrefix=$pePrefix;runnerPrefix=$runnerPrefix;networkIsolation=$isolation;edgeRouteTableId=$EdgeRouteTableId;apimRouteTableId=$ApimRouteTableId;ddosProtectionPlanId=$DdosProtectionPlanId})
}
if ($PublicIpId -and $pip.id -eq 'new') {
    $publicIp = Owned-Put $PublicIpId '2024-05-01' @{location=$Location;tags=@{'claude-network-owner'=$owner};sku=@{name='Standard'};properties=@{publicIPAllocationMethod='Static';publicIPAddressVersion='IPv4';idleTimeoutInMinutes=30;dnsSettings=@{domainNameLabel=$Name}}}
}
elseif ($PublicIpId) { $publicIp = Invoke-ClaudeNetworkArm "https://management.azure.com${PublicIpId}?api-version=2024-05-01" }
if (-not $ListenerHostName -and $TestCertificate) { $ListenerHostName = $publicIp.properties.dnsSettings.fqdn }
if (-not $ListenerHostName) { throw 'A resolvable listener name is required. Configure DNS before requesting a production certificate.' }
$identityId = "$rgId/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$Name"
$identity = Owned-Put $identityId '2023-01-31' @{location=$Location;tags=@{'claude-network-owner'=$owner}}
$vaultName = ($KeyVaultId -split '/')[-1]
if ($TestCertificate) {
    $account = Invoke-ClaudeNetworkAz @('account','show','--subscription',$SubscriptionId)
    $vault = Owned-Put $KeyVaultId '2023-07-01' @{location=$Location;tags=@{'claude-network-owner'=$owner};properties=@{tenantId=$account.tenantId;sku=@{family='A';name='standard'};enableRbacAuthorization=$true;enableSoftDelete=$true;softDeleteRetentionInDays=7;publicNetworkAccess='Enabled'}}
    $user = Invoke-ClaudeNetworkAz @('ad','signed-in-user','show')
    Grant-VaultRole $user.id 'Key Vault Certificates Officer' 'User'
    $certificate = $null
    try { $certificate = Invoke-ClaudeNetworkAz @('keyvault','certificate','show','--vault-name',$vaultName,'--name',$CertificateName) }
    catch { if ($_.Exception.Message -notmatch 'CertificateNotFound|Forbidden') { throw } }
    if (-not $certificate) {
        $policyPath = Join-Path $stateDirectory ('certificate-' + [guid]::NewGuid().ToString('N') + '.json')
        try {
            @{issuerParameters=@{name='Self'};keyProperties=@{exportable=$true;keyType='RSA';keySize=2048;reuseKey=$false};secretProperties=@{contentType='application/x-pkcs12'};x509CertificateProperties=@{subject="CN=$ListenerHostName";subjectAlternativeNames=@{dnsNames=@($ListenerHostName)};validityInMonths=1;keyUsage=@('digitalSignature','keyEncipherment');ekus=@('1.3.6.1.5.5.7.3.1')}} | ConvertTo-Json -Depth 10 | Set-Content $policyPath -Encoding utf8
            $deadline = [DateTime]::UtcNow.AddMinutes(5)
            do {
                try { $certificate=Invoke-ClaudeNetworkAz @('keyvault','certificate','create','--vault-name',$vaultName,'--name',$CertificateName,'--policy',('@'+$policyPath)); break }
                catch { if ($_.Exception.Message -notmatch 'Forbidden' -or [DateTime]::UtcNow -ge $deadline) { throw }; Start-Sleep -Seconds 15 }
            } while ($true)
        }
        finally { Remove-Item $policyPath -Force -ErrorAction SilentlyContinue }
    }
}
Grant-VaultRole $identity.properties.principalId 'Key Vault Secrets User' 'ServicePrincipal'
$certificate = Invoke-ClaudeNetworkAz @('keyvault','certificate','show','--vault-name',$vaultName,'--name',$CertificateName)
if (-not $certificate.attributes.enabled -or -not $certificate.policy.keyProperties.exportable -or $certificate.policy.secretProperties.contentType -ne 'application/x-pkcs12') { throw 'The certificate must be enabled with an exportable PFX private key.' }
$certificateSecretId = $certificate.sid -replace '/[^/]+/?$','/'
if ($TestCertificate) {
    $publicCert = Join-Path $stateDirectory "$Name-ca.pem"
    [void](Invoke-ClaudeNetworkAz @('keyvault','certificate','download','--vault-name',$vaultName,'--name',$CertificateName,'--file',$publicCert,'--encoding','PEM'))
    Write-Host "Test certificate only: use NODE_EXTRA_CA_CERTS=$publicCert. Never disable TLS validation."
}
if ($NetworkProfile -ne 'public') {
    $vaultZone = Ensure-Zone 'privatelink.vaultcore.azure.net'
    Ensure-Endpoint 'vault' $KeyVaultId @('vault') @($vaultZone)
}
if ($BackendAccess -eq 'private') {
    $zone = Ensure-Zone 'privatelink.azure-api.net'
    Ensure-Endpoint 'apim' $ApimId @('Gateway') @($zone)
}
if ($privateFoundry) {
    $zones = @()
    $groups = Get-ClaudeNetworkPages "https://management.azure.com$($foundry.id)/privateLinkResources?api-version=2024-10-01"
    $accountGroup = @($groups | Where-Object { $_.properties.groupId -eq 'account' })[0]
    if (-not $accountGroup) { throw 'The Foundry account did not advertise the account private-link group.' }
    foreach ($zoneName in $accountGroup.properties.requiredZoneNames) { $zones += Ensure-Zone $zoneName }
    Ensure-Endpoint 'foundry' $foundry.id @('account') $zones
    [void](Invoke-ClaudeNetworkArm "https://management.azure.com${ApimId}?api-version=2024-05-01" -Method patch -Body @{properties=@{virtualNetworkType='External';virtualNetworkConfiguration=@{subnetResourceId=$ApimIntegrationSubnetId}}} -StateDirectory $stateDirectory)
}
foreach ($entry in @(@{suffix='waf';existing=$GlobalWafPolicyId;exclusions=@()},@{suffix='messages-waf';existing=$MessagesWafPolicyId;exclusions=$exclusions})) {
    $id = if ($entry.existing) { $entry.existing } else { "$rgId/providers/Microsoft.Network/ApplicationGatewayWebApplicationFirewallPolicies/$Name-$($entry.suffix)" }
    if ($entry.existing) {
        $live = Invoke-ClaudeNetworkArm "https://management.azure.com${id}?api-version=2024-05-01"
        if ($live.properties.policySettings.mode -ne $WafMode -or -not $live.properties.policySettings.requestBodyCheck) { throw 'Existing WAF policy does not match the requested mode and inspection. It was not modified.' }
    }
    else {
        Assert-ClaudeNetworkOwnership (Invoke-ClaudeNetworkArm "https://management.azure.com${id}?api-version=2024-05-01" -AllowNotFound) $owner
        Track $id '2024-05-01'
        [void](Deploy $entry.suffix 'network-edge-waf.bicep' @{name="$Name-$($entry.suffix)";location=$Location;ownerId=$owner;wafMode=$WafMode;ruleSetType=$rule.ruleSetType;ruleSetVersion=$rule.ruleSetVersion;exclusions=$entry.exclusions;bodyLimitKb=$BodyLimitKb})
    }
    if ($entry.suffix -eq 'waf') { $GlobalWafPolicyId=$id } else { $MessagesWafPolicyId=$id }
}
Track $gatewayId '2024-05-01'
$privateIp = if ($NetworkProfile -ne 'public') { ConvertFrom-ClaudeNetworkNumber ((Get-ClaudeNetworkCidr $edgePrefix).Last-1) } else { '' }
[void](Deploy 'gateway' 'network-edge.bicep' @{name=$Name;location=$Location;ownerId=$owner;subnetId=$EdgeSubnetId;backendHostName=([uri]$apim.properties.gatewayUrl).DnsSafeHost;listenerHostName=$ListenerHostName;certificateSecretId=$certificateSecretId;identityId=$identityId;workspaceId=$WorkspaceId;globalWafPolicyId=$GlobalWafPolicyId;messagesWafPolicyId=$MessagesWafPolicyId;messagesPaths=@("/$($api.properties.path)/v1/messages","/$($api.properties.path)/v1/messages/*");publicIpId=$PublicIpId;privateFrontendIp=$privateIp;networkProfile=$NetworkProfile;backendTimeoutSeconds=$BackendTimeoutSeconds;minimumCapacity=$MinimumCapacity;maximumCapacity=$MaximumCapacity})
$currentPolicy = Invoke-ClaudeNetworkArm "https://management.azure.com${ApimId}/policies/policy?api-version=2024-05-01" -AllowNotFound
$policyText = if ($currentPolicy) { $currentPolicy.properties.value } else { '<policies><inbound></inbound><backend><forward-request /></backend><outbound></outbound><on-error></on-error></policies>' }
$cidrs = if ($BackendAccess -eq 'private') { @($edgePrefix) } else { @("$($publicIp.properties.ipAddress)/32") }
$restricted = Set-ClaudeNetworkPolicyText -Policy $policyText -AllowedCidrs $cidrs -EdgeId $owner
[void](Invoke-ClaudeNetworkArm "https://management.azure.com${ApimId}/policies/policy?api-version=2024-05-01" -Method put -Body @{properties=@{format='rawxml';value=$restricted}} -StateDirectory $stateDirectory)
if ($BackendAccess -eq 'private') { [void](Invoke-ClaudeNetworkArm "https://management.azure.com${ApimId}?api-version=2024-05-01" -Method patch -Body @{properties=@{publicNetworkAccess='Disabled'}} -StateDirectory $stateDirectory) }
if ($CloseFoundryPublicAccess) { [void](Invoke-ClaudeNetworkArm "https://management.azure.com$($foundry.id)?api-version=2024-10-01" -Method patch -Body @{properties=@{publicNetworkAccess='Disabled'}} -StateDirectory $stateDirectory) }
$state.Endpoint = "https://$ListenerHostName/$($api.properties.path)"
$state.Applied = $true
Write-ClaudeNetworkState $state $StatePath
Write-Host 'Deployment completed. Run Test-ClaudeNetworkEdge from each client boundary before distributing the endpoint.'
$state
