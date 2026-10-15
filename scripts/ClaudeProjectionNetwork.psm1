Set-StrictMode -Version 2

function Get-ClaudeProjectionNetworkOptions {
    @(
        [pscustomobject]@{
            Value = 'managed'
            Label = 'Managed projection VNet'
            Detail = 'Creates an isolated VNet, five dedicated subnets and projection-owned private DNS zones.'
            Recommended = $true
        }
        [pscustomobject]@{
            Value = 'existing'
            Label = 'Existing customer VNet'
            Detail = 'Uses explicit VNet, endpoint, runner, resolver, renewal and APIM integration subnet resource IDs after read-only validation.'
            Recommended = $false
        }
    )
}

function Resolve-ClaudeProjectionNetworkSelection {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][ValidateSet('managed','existing','')][string]$Mode = '',
        [string]$VnetId,
        [string]$EndpointsSubnetId,
        [string]$RunnerSubnetId,
        [string]$ResolverSubnetId,
        [string]$RenewalSubnetId,
        [string]$ApimSubnetId,
        [string]$CosmosDnsZoneId,
        [string]$SitesDnsZoneId,
        [string]$BlobDnsZoneId,
        [string]$QueueDnsZoneId,
        [string]$TableDnsZoneId,
        [switch]$NonInteractive,
        [scriptblock]$Selector
    )
    $ids = [ordered]@{
        VnetId = $VnetId
        EndpointsSubnetId = $EndpointsSubnetId
        RunnerSubnetId = $RunnerSubnetId
        ResolverSubnetId = $ResolverSubnetId
        RenewalSubnetId = $RenewalSubnetId
        ApimSubnetId = $ApimSubnetId
    }
    $zoneIds = [ordered]@{
        CosmosDnsZoneId = @{ Value = $CosmosDnsZoneId; Namespace = 'privatelink.documents.azure.com' }
        SitesDnsZoneId = @{ Value = $SitesDnsZoneId; Namespace = 'privatelink.azurewebsites.net' }
        BlobDnsZoneId = @{ Value = $BlobDnsZoneId; Namespace = 'privatelink.blob.core.windows.net' }
        QueueDnsZoneId = @{ Value = $QueueDnsZoneId; Namespace = 'privatelink.queue.core.windows.net' }
        TableDnsZoneId = @{ Value = $TableDnsZoneId; Namespace = 'privatelink.table.core.windows.net' }
    }
    $hasIds = @($ids.Values | Where-Object { $_ }).Count -gt 0 -or @($zoneIds.Values | Where-Object { $_.Value }).Count -gt 0
    if (-not $Mode) {
        if ($hasIds) { $Mode = 'existing' }
        elseif ($NonInteractive -or -not $Selector) { $Mode = 'managed' }
        else { $Mode = [string](& $Selector @(Get-ClaudeProjectionNetworkOptions)) }
    }
    if ($Mode -notin @('managed','existing')) {
        throw "Projection network mode must be managed or existing. Nothing was changed."
    }
    if ($Mode -eq 'managed') {
        if ($hasIds) { throw 'Projection network mode managed does not accept customer VNet or subnet IDs. Remove the IDs or choose existing. Nothing was changed.' }
        return [pscustomobject]@{
            Mode = 'managed'
            VnetId = ''
            EndpointsSubnetId = ''
            RunnerSubnetId = ''
            ResolverSubnetId = ''
            RenewalSubnetId = ''
            ApimSubnetId = ''
            CosmosDnsZoneId = ''
            SitesDnsZoneId = ''
            BlobDnsZoneId = ''
            QueueDnsZoneId = ''
            TableDnsZoneId = ''
        }
    }
    $missing = @($ids.GetEnumerator() | Where-Object { -not $_.Value } | ForEach-Object Key)
    if ($missing.Count) {
        throw "Projection network mode existing requires explicit IDs for: $($missing -join ', '). No subnet names are inferred. Nothing was changed."
    }
    foreach ($entry in $ids.GetEnumerator()) {
        $kind = if ($entry.Key -eq 'VnetId') { 'virtualNetworks/[^/]+$' } else { 'virtualNetworks/[^/]+/subnets/[^/]+$' }
        if ([string]$entry.Value -notmatch "^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.Network/$kind") {
            throw "$($entry.Key) is not a complete Azure resource ID. Nothing was changed."
        }
    }
    $vnetSubscription = Get-ClaudeProjectionNetworkSubscription $VnetId
    foreach ($entry in $zoneIds.GetEnumerator()) {
        if (-not $entry.Value.Value) { continue }
        $expected = [regex]::Escape([string]$entry.Value.Namespace)
        if ([string]$entry.Value.Value -notmatch "^/subscriptions/([^/]+)/resourceGroups/[^/]+/providers/Microsoft\.Network/privateDnsZones/$expected$") {
            throw "$($entry.Key) must be the complete resource ID of $($entry.Value.Namespace). Nothing was changed."
        }
        if (-not [string]::Equals([string]$Matches[1], $vnetSubscription, [StringComparison]::OrdinalIgnoreCase)) {
            throw "$($entry.Key) must be in the selected VNet subscription $vnetSubscription. Nothing was changed."
        }
    }
    [pscustomobject]@{
        Mode = 'existing'
        VnetId = $VnetId
        EndpointsSubnetId = $EndpointsSubnetId
        RunnerSubnetId = $RunnerSubnetId
        ResolverSubnetId = $ResolverSubnetId
        RenewalSubnetId = $RenewalSubnetId
        ApimSubnetId = $ApimSubnetId
        CosmosDnsZoneId = $CosmosDnsZoneId
        SitesDnsZoneId = $SitesDnsZoneId
        BlobDnsZoneId = $BlobDnsZoneId
        QueueDnsZoneId = $QueueDnsZoneId
        TableDnsZoneId = $TableDnsZoneId
    }
}

function Get-ClaudeProjectionNetworkSubscription {
    param([Parameter(Mandatory)][string]$ResourceId)
    if ($ResourceId -notmatch '^/subscriptions/([^/]+)/') { throw "Resource ID '$ResourceId' has no subscription." }
    return $Matches[1]
}

function ConvertTo-ClaudeProjectionNetworkLocationKey {
    param([AllowEmptyString()][string]$Location)
    return (($Location -replace '[^A-Za-z0-9]', '').ToLowerInvariant())
}

function Get-ClaudeProjectionSubnetPrefix {
    param([Parameter(Mandatory)][object]$Subnet)
    $prefix = [string]$Subnet.properties.addressPrefix
    if (-not $prefix) {
        $prefixes = @($Subnet.properties.addressPrefixes)
        if ($prefixes.Count -eq 1) { $prefix = [string]$prefixes[0] }
    }
    if ($prefix -notmatch '^[0-9.]+/([0-9]{1,2})$') { throw "Subnet $($Subnet.id) must expose one IPv4 address prefix." }
    return [pscustomobject]@{ Cidr = $prefix; Length = [int]$Matches[1] }
}

function Get-ClaudeProjectionSubnetDelegations {
    param([Parameter(Mandatory)][object]$Subnet)
    return @(@($Subnet.properties.delegations) | ForEach-Object { [string]$_.properties.serviceName } | Where-Object { $_ })
}

function Assert-ClaudeProjectionSubnetDelegation {
    param([object]$Subnet,[string]$Role,[string]$Required,[switch]$None)
    $actual = @(Get-ClaudeProjectionSubnetDelegations $Subnet)
    if ($None) {
        if ($actual.Count) { throw "$Role subnet must have no delegation; found $($actual -join ', ')." }
        return
    }
    if ($actual.Count -ne 1 -or $actual[0] -cne $Required) {
        throw "$Role subnet must be delegated only to $Required; found $(if ($actual.Count) { $actual -join ', ' } else { 'none' })."
    }
}

function Get-ClaudeProjectionRequiredPrivateDnsZones {
    @(
        'privatelink.documents.azure.com'
        'privatelink.azurewebsites.net'
        'privatelink.blob.core.windows.net'
        'privatelink.queue.core.windows.net'
        'privatelink.table.core.windows.net'
    )
}

function Test-ClaudeProjectionNetworkPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][object]$Apim,
        [object]$VirtualNetwork,
        [System.Collections.IDictionary]$Subnets,
        [object]$ApimNetworkSecurityGroup,
        [AllowEmptyCollection()][object[]]$DnsZones = @(),
        [Parameter(Mandatory)][string]$ProjectionResourceGroupId,
        [Parameter(Mandatory)][string]$NamePrefix,
        [string]$DeploymentLocation
    )
    $requiredZones = @(Get-ClaudeProjectionRequiredPrivateDnsZones)
    if ($Plan.Mode -eq 'managed') {
        if ($DeploymentLocation -and
            (ConvertTo-ClaudeProjectionNetworkLocationKey $DeploymentLocation) -ne (ConvertTo-ClaudeProjectionNetworkLocationKey ([string]$Apim.location))) {
            throw "Projection network preflight refused: managed VNet region '$DeploymentLocation' does not match API Management region '$($Apim.location)'. Nothing was changed."
        }
        return [pscustomobject]@{
            Valid = $true
            Mode = 'managed'
            RequiredPrivateDnsZones = $requiredZones
            ReusedPrivateDnsZones = @()
            CreatedPrivateDnsZones = $requiredZones
            Summary = 'Create a managed projection VNet with five dedicated subnets; projection-network.bicep creates and owns the private DNS zones.'
        }
    }
    try {
        if (-not $VirtualNetwork -or -not $VirtualNetwork.id) { throw 'The selected VNet was not discovered.' }
        if (-not [string]::Equals([string]$VirtualNetwork.id, [string]$Plan.VnetId, [StringComparison]::OrdinalIgnoreCase)) { throw 'The discovered VNet ID does not match the selected VNet ID.' }
        $apimSubscription = Get-ClaudeProjectionNetworkSubscription ([string]$Apim.id)
        if (-not [string]::Equals((Get-ClaudeProjectionNetworkSubscription ([string]$Plan.VnetId)), $apimSubscription, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'The selected VNet is not in the API Management subscription.'
        }
        if ((ConvertTo-ClaudeProjectionNetworkLocationKey ([string]$VirtualNetwork.location)) -ne (ConvertTo-ClaudeProjectionNetworkLocationKey ([string]$Apim.location))) {
            throw "The selected VNet region '$($VirtualNetwork.location)' does not match API Management region '$($Apim.location)'."
        }
        $roleIds = [ordered]@{
            Endpoints = [string]$Plan.EndpointsSubnetId
            Runner = [string]$Plan.RunnerSubnetId
            Resolver = [string]$Plan.ResolverSubnetId
            Renewal = [string]$Plan.RenewalSubnetId
            Apim = [string]$Plan.ApimSubnetId
        }
        $distinct = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in $roleIds.GetEnumerator()) {
            if (-not $distinct.Add($entry.Value)) { throw "Subnet roles must use five distinct IDs; $($entry.Key) shares $($entry.Value)." }
            if (-not $entry.Value.StartsWith("$($Plan.VnetId)/subnets/", [StringComparison]::OrdinalIgnoreCase)) {
                throw "$($entry.Key) subnet does not belong to the selected VNet."
            }
            if (-not $Subnets -or -not $Subnets.Contains($entry.Key) -or -not $Subnets[$entry.Key]) {
                throw "$($entry.Key) subnet was not discovered."
            }
            if (-not [string]::Equals([string]$Subnets[$entry.Key].id, $entry.Value, [StringComparison]::OrdinalIgnoreCase)) {
                throw "$($entry.Key) discovery returned another subnet ID."
            }
        }
        Assert-ClaudeProjectionSubnetDelegation -Subnet $Subnets.Endpoints -Role 'Endpoint' -None
        $policies = [string]$Subnets.Endpoints.properties.privateEndpointNetworkPolicies
        if ($policies -notin @('Disabled','Enabled','NetworkSecurityGroupEnabled','RouteTableEnabled')) {
            throw "Endpoint subnet privateEndpointNetworkPolicies '$policies' is not an Azure-compatible value."
        }
        Assert-ClaudeProjectionSubnetDelegation -Subnet $Subnets.Runner -Role 'Runner' -Required 'Microsoft.ContainerInstance/containerGroups'
        Assert-ClaudeProjectionSubnetDelegation -Subnet $Subnets.Resolver -Role 'Resolver' -Required 'Microsoft.App/environments'
        Assert-ClaudeProjectionSubnetDelegation -Subnet $Subnets.Renewal -Role 'Renewal' -Required 'Microsoft.App/environments'
        Assert-ClaudeProjectionSubnetDelegation -Subnet $Subnets.Apim -Role 'APIM' -Required 'Microsoft.Web/serverFarms'
        $apimNsgId = if ($Subnets.Apim.properties.PSObject.Properties['networkSecurityGroup'] -and $Subnets.Apim.properties.networkSecurityGroup) {
            [string]$Subnets.Apim.properties.networkSecurityGroup.id
        } else { '' }
        if (-not $apimNsgId) { throw 'APIM subnet must have a network security group.' }
        if (-not $ApimNetworkSecurityGroup -or -not [string]::Equals([string]$ApimNetworkSecurityGroup.id, $apimNsgId, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'The APIM subnet network security group was not discovered.'
        }
        $keyVaultRule = @(@($ApimNetworkSecurityGroup.properties.securityRules) | Where-Object {
            [string]::Equals([string]$_.properties.direction, 'Outbound', [StringComparison]::OrdinalIgnoreCase) -and
            [string]::Equals([string]$_.properties.access, 'Allow', [StringComparison]::OrdinalIgnoreCase) -and
            ([string]$_.properties.protocol -in @('Tcp','*')) -and
            ([string]$_.properties.destinationAddressPrefix -eq 'AzureKeyVault') -and
            ([string]$_.properties.destinationPortRange -in @('443','*'))
        })
        if (-not $keyVaultRule.Count) { throw 'APIM subnet NSG must explicitly allow outbound TCP 443 to the AzureKeyVault service tag.' }
        foreach ($role in 'Resolver','Renewal','Apim') {
            $prefix = Get-ClaudeProjectionSubnetPrefix $Subnets[$role]
            if ($prefix.Length -gt 27) { throw "$role subnet $($prefix.Cidr) is smaller than /27." }
        }
        $zoneSelections = [ordered]@{
            'privatelink.documents.azure.com' = [string]$Plan.CosmosDnsZoneId
            'privatelink.azurewebsites.net' = [string]$Plan.SitesDnsZoneId
            'privatelink.blob.core.windows.net' = [string]$Plan.BlobDnsZoneId
            'privatelink.queue.core.windows.net' = [string]$Plan.QueueDnsZoneId
            'privatelink.table.core.windows.net' = [string]$Plan.TableDnsZoneId
        }
        $reusedZones = [Collections.Generic.List[string]]::new()
        foreach ($selection in $zoneSelections.GetEnumerator()) {
            if (-not $selection.Value) { continue }
            $discoveredZone = @($DnsZones | Where-Object {
                [string]::Equals([string]$_.Id, $selection.Value, [StringComparison]::OrdinalIgnoreCase)
            })
            if ($discoveredZone.Count -ne 1) {
                throw "$($selection.Key) was selected for reuse but its resource ID was not discovered exactly once."
            }
            $selectedLinks = @($discoveredZone[0].Links | Where-Object {
                [string]::Equals([string]$_.VirtualNetworkId, [string]$Plan.VnetId, [StringComparison]::OrdinalIgnoreCase)
            })
            if (-not $selectedLinks.Count) {
                throw "$($selection.Key) was selected for reuse but is not linked to the selected VNet."
            }
            $reusedZones.Add($selection.Key)
        }
        foreach ($zone in @($DnsZones)) {
            if ($requiredZones -notcontains [string]$zone.Name) { continue }
            foreach ($link in @($zone.Links)) {
                if (-not [string]::Equals([string]$link.VirtualNetworkId, [string]$Plan.VnetId, [StringComparison]::OrdinalIgnoreCase)) { continue }
                if ($zoneSelections[[string]$zone.Name] -and
                    [string]::Equals([string]$zone.Id, [string]$zoneSelections[[string]$zone.Name], [StringComparison]::OrdinalIgnoreCase)) {
                    continue
                }
                $ownedZoneId = "$ProjectionResourceGroupId/providers/Microsoft.Network/privateDnsZones/$($zone.Name)"
                $ownedLink = ([string]::Equals([string]$zone.Id, $ownedZoneId, [StringComparison]::OrdinalIgnoreCase) -and
                    [string]::Equals([string]$link.Name, "$NamePrefix-link", [StringComparison]::OrdinalIgnoreCase))
                if (-not $ownedLink) {
                    throw "Private DNS namespace $($zone.Name) already has a conflicting link to the selected VNet ($($zone.Id)/virtualNetworkLinks/$($link.Name)). P116 creates and owns its zones; central-zone reuse is not supported."
                }
            }
        }
        return [pscustomobject]@{
            Valid = $true
            Mode = 'existing'
            RequiredPrivateDnsZones = $requiredZones
            ReusedPrivateDnsZones = $reusedZones.ToArray()
            CreatedPrivateDnsZones = @($requiredZones | Where-Object { $reusedZones -notcontains $_ })
            Summary = "Use customer VNet $($Plan.VnetId) with five validated dedicated subnets; reuse $($reusedZones.Count) customer private DNS zone(s) and create $($requiredZones.Count - $reusedZones.Count)."
        }
    }
    catch {
        throw "Projection network preflight refused: $($_.Exception.Message) Nothing was changed."
    }
}

function Invoke-ClaudeProjectionNetworkAz {
    param([Parameter(Mandatory)][string[]]$Arguments)
    if (Get-Command Invoke-ClaudeNetworkAz -ErrorAction SilentlyContinue) {
        return Invoke-ClaudeNetworkAz $Arguments
    }
    $output = & az @Arguments --only-show-errors --output json 2>&1
    $code = $LASTEXITCODE
    if ($code -ne 0) { throw "Azure CLI failed ($code): $($output -join "`n")" }
    if ($output) { return (($output -join "`n") | ConvertFrom-Json -ErrorAction Stop) }
}

function Get-ClaudeProjectionDnsDiscovery {
    param([Parameter(Mandatory)][string]$SubscriptionId)
    $zones = @(Invoke-ClaudeProjectionNetworkAz @('network','private-dns','zone','list','--subscription',$SubscriptionId))
    foreach ($zone in $zones) {
        if ([string]$zone.id -notmatch '/resourceGroups/([^/]+)/providers/Microsoft\.Network/privateDnsZones/([^/]+)$') { continue }
        $resourceGroup = $Matches[1]
        $zoneName = $Matches[2]
        $links = @(Invoke-ClaudeProjectionNetworkAz @('network','private-dns','link','vnet','list','-g',$resourceGroup,'-z',$zoneName,'--subscription',$SubscriptionId))
        [pscustomobject]@{
            Name = $zoneName
            Id = [string]$zone.id
            Links = @($links | ForEach-Object {
                [pscustomobject]@{
                    Name = [string]$_.name
                    VirtualNetworkId = [string]$_.virtualNetwork.id
                }
            })
        }
    }
}

function Invoke-ClaudeProjectionNetworkPreflight {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][object]$Apim,
        [Parameter(Mandatory)][string]$ProjectionResourceGroupId,
        [Parameter(Mandatory)][string]$NamePrefix,
        [string]$DeploymentLocation,
        [scriptblock]$DiscoverResource,
        [scriptblock]$DiscoverDnsZones
    )
    if ($Plan.Mode -eq 'managed') {
        return Test-ClaudeProjectionNetworkPlan -Plan $Plan -Apim $Apim -ProjectionResourceGroupId $ProjectionResourceGroupId -NamePrefix $NamePrefix -DeploymentLocation $DeploymentLocation
    }
    if (-not $DiscoverResource) {
        $DiscoverResource = { param($Id) Invoke-ClaudeProjectionNetworkAz @('resource','show','--ids',$Id) }
    }
    if (-not $DiscoverDnsZones) {
        $DiscoverDnsZones = { param($SubscriptionId) @(Get-ClaudeProjectionDnsDiscovery -SubscriptionId $SubscriptionId) }
    }
    $subnets = @{}
    $vnet = & $DiscoverResource ([string]$Plan.VnetId)
    foreach ($role in 'Endpoints','Runner','Resolver','Renewal','Apim') {
        $property = "${role}SubnetId"
        $subnets[$role] = & $DiscoverResource ([string]$Plan.$property)
    }
    $apimNsgId = if ($subnets.Apim.properties.PSObject.Properties['networkSecurityGroup'] -and $subnets.Apim.properties.networkSecurityGroup) {
        [string]$subnets.Apim.properties.networkSecurityGroup.id
    } else { '' }
    $apimNsg = if ($apimNsgId) { & $DiscoverResource $apimNsgId } else { $null }
    $subscription = Get-ClaudeProjectionNetworkSubscription ([string]$Apim.id)
    $zones = @(& $DiscoverDnsZones $subscription)
    Test-ClaudeProjectionNetworkPlan -Plan $Plan -Apim $Apim -VirtualNetwork $vnet -Subnets $subnets -ApimNetworkSecurityGroup $apimNsg -DnsZones $zones `
        -ProjectionResourceGroupId $ProjectionResourceGroupId -NamePrefix $NamePrefix -DeploymentLocation $DeploymentLocation
}

function Set-ClaudeProjectionApimOutboundIntegration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Apim,
        [Parameter(Mandatory)][string]$SubnetId,
        [Parameter(Mandatory)][string]$StateDirectory,
        [scriptblock]$InvokeArm
    )
    $url = "https://management.azure.com$($Apim.id)?api-version=2024-05-01"
    $etag = ''
    function Invoke-IntegrationArm {
        param([string]$Method,[object]$Body)
        if ($InvokeArm) { return & $InvokeArm $url $Method $Body $StateDirectory $etag }
        if (-not (Get-Command Invoke-ClaudeNetworkArm -ErrorAction SilentlyContinue)) { throw 'Invoke-ClaudeNetworkArm is not loaded.' }
        $arguments = @{ Url=$url; Method=$Method }
        if ($null -ne $Body) {
            $arguments['Body'] = $Body
            $arguments['StateDirectory'] = $StateDirectory
        }
        if ($Method -ne 'get' -and $etag) { $arguments['IfMatch'] = $etag }
        return Invoke-ClaudeNetworkArm @arguments
    }
    try {
        $baseline = Invoke-IntegrationArm 'get' $null
        if (-not $baseline -or -not $baseline.properties -or -not $baseline.identity) {
            throw 'API Management ARM discovery returned no complete service state.'
        }
        $etag = if ($baseline.PSObject.Properties['etag']) { [string]$baseline.etag } else { '' }
        $liveProperties = $baseline.properties
        $liveVnetType = if ($liveProperties.PSObject.Properties['virtualNetworkType']) { [string]$liveProperties.virtualNetworkType } else { '' }
        $liveSubnetId = if ($liveProperties.PSObject.Properties['virtualNetworkConfiguration'] -and $liveProperties.virtualNetworkConfiguration) {
            [string]$liveProperties.virtualNetworkConfiguration.subnetResourceId
        } else { '' }
        if ([string]::Equals($liveVnetType, 'External', [StringComparison]::OrdinalIgnoreCase) -and
            [string]::Equals($liveSubnetId, $SubnetId, [StringComparison]::OrdinalIgnoreCase)) {
            return [pscustomobject]@{ Changed = $false; SubnetId = $SubnetId; Result = $baseline }
        }
        $identity = [ordered]@{ type = [string]$baseline.identity.type }
        if (-not $identity.type -or $identity.type -eq 'None') {
            throw 'the gateway managed identity is missing.'
        }
        if ($baseline.identity.PSObject.Properties['userAssignedIdentities'] -and $baseline.identity.userAssignedIdentities) {
            $identity['userAssignedIdentities'] = $baseline.identity.userAssignedIdentities
        }
        $body = [ordered]@{
            identity = $identity
            properties = [ordered]@{
                virtualNetworkType = 'External'
                virtualNetworkConfiguration = [ordered]@{ subnetResourceId = $SubnetId }
            }
        }
        $null = Invoke-IntegrationArm 'patch' $body
        $current = $null
        foreach ($attempt in 1..120) {
            $current = Invoke-IntegrationArm 'get' $null
            $state = [string]$current.properties.provisioningState
            if ($state -eq 'Succeeded') { break }
            if ($state -eq 'Failed') { throw 'API Management reported provisioningState Failed.' }
            if ($attempt -eq 120) { throw "API Management outbound integration did not reach Succeeded; last state was '$state'." }
            Start-Sleep -Seconds 15
        }
        if (-not $current.identity.type -or [string]$current.identity.type -eq 'None') {
            throw 'API Management returned without its managed identity.'
        }
        $originalPrincipalId = if ($baseline.identity.PSObject.Properties['principalId']) { [string]$baseline.identity.principalId } else { '' }
        if ($originalPrincipalId -and -not [string]::Equals([string]$current.identity.principalId, $originalPrincipalId, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'API Management returned with a different managed identity principal.'
        }
        foreach ($propertyName in 'publicNetworkAccess','customProperties','hostnameConfigurations','developerPortalStatus','legacyPortalStatus') {
            if (-not $liveProperties.PSObject.Properties[$propertyName]) { continue }
            $before = $liveProperties.$propertyName | ConvertTo-Json -Depth 50 -Compress
            $after = $current.properties.$propertyName | ConvertTo-Json -Depth 50 -Compress
            if ($before -cne $after) { throw "API Management unrelated property '$propertyName' changed during outbound integration." }
        }
        if (-not [string]::Equals([string]$current.properties.virtualNetworkType, 'External', [StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals([string]$current.properties.virtualNetworkConfiguration.subnetResourceId, $SubnetId, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'API Management did not retain the requested outbound integration subnet.'
        }
    }
    catch {
        throw "APIM outbound VNet integration failed: $($_.Exception.Message) No resolver deployment was attempted."
    }
    return [pscustomobject]@{ Changed = $true; SubnetId = $SubnetId; Result = $current }
}

Export-ModuleMember -Function Get-ClaudeProjectionNetworkOptions,Resolve-ClaudeProjectionNetworkSelection,Get-ClaudeProjectionRequiredPrivateDnsZones,Test-ClaudeProjectionNetworkPlan,Invoke-ClaudeProjectionNetworkPreflight,Set-ClaudeProjectionApimOutboundIntegration
