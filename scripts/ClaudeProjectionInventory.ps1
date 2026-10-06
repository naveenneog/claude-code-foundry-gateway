function New-ClaudeProjectionInventoryResource {
    param(
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Sku,
        [Parameter(Mandatory)][string]$Region,
        [Parameter(Mandatory)][string]$Template,
        [Parameter(Mandatory)][string]$Purpose
    )
    [pscustomobject]@{
        Type = $Type
        Name = $Name
        Sku = $Sku
        Region = $Region
        Template = $Template
        Purpose = $Purpose
    }
}

function New-ClaudeProjectionInventoryIdentity {
    param(
        [Parameter(Mandatory)][string]$Principal,
        [Parameter(Mandatory)][string]$Role,
        [Parameter(Mandatory)][string]$Scope,
        [Parameter(Mandatory)][string]$Purpose
    )
    [pscustomobject]@{
        Principal = $Principal
        Role = $Role
        Scope = $Scope
        Purpose = $Purpose
    }
}

function Get-ClaudeProjectionDerivedName {
    param([Parameter(Mandatory)][string]$Prefix)
    return "$Prefix<13 characters from the resource group id and prefix>"
}

function Assert-ClaudeProjectionInventoryPrefix {
    param([Parameter(Mandatory)][string]$NamePrefix)
    if ($NamePrefix -cnotmatch '^[a-z0-9](?:[a-z0-9]|-(?=[a-z0-9])){0,36}$') {
        throw "NamePrefix '$NamePrefix' is not the projection prefix: 1-37 lowercase letters or digits, separated by single hyphens."
    }
}

function Add-ClaudeProjectionBaseResources {
    param(
        [AllowEmptyCollection()][Collections.Generic.List[object]]$Resources,
        [Parameter(Mandatory)][string]$NamePrefix,
        [Parameter(Mandatory)][string]$Location,
        [Parameter(Mandatory)][string]$ResolverInboundAccess
    )
    $cosmos = "cosmos-$NamePrefix"
    $vnet = "vnet-$NamePrefix"
    $cosmosPe = "pe-cosmos-$NamePrefix"
    $runner = "aci-projtest-$NamePrefix"
    $site = "func-resolver-$NamePrefix"
    $plan = "plan-resolver-$NamePrefix"
    $storage = Get-ClaudeProjectionDerivedName 'stres'
    $projection = 'infra\projection.bicep'
    $network = 'infra\projection-network.bicep'
    $resolver = 'infra\resolver.bicep'

    [void]$Resources.Add((New-ClaudeProjectionInventoryResource 'Microsoft.DocumentDB/databaseAccounts' $cosmos 'Standard offer; serverless capability; local auth disabled; Session consistency; public network disabled by private-only deployment' $Location $projection 'Cosmos DB account for the entitlement projection'))
    [void]$Resources.Add((New-ClaudeProjectionInventoryResource 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases' "$cosmos/claude" 'serverless database; provisioned throughput only when redundancy is not single' $Location $projection 'Projection database'))
    [void]$Resources.Add((New-ClaudeProjectionInventoryResource 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers' "$cosmos/claude/entitlement" 'partition key /oid; defaultTtl -1; index includes /oid/? only' $Location $projection 'Entitlement records container'))

    [void]$Resources.Add((New-ClaudeProjectionInventoryResource 'Microsoft.Network/virtualNetworks' $vnet 'address space 10.10.0.0/16' $Location $network 'Projection private network when no existing VNet is supplied'))
    [void]$Resources.Add((New-ClaudeProjectionInventoryResource 'Microsoft.Network/privateEndpoints' $cosmosPe 'groupIds Sql' $Location $network 'Private endpoint for the Cosmos SQL data plane'))
    [void]$Resources.Add((New-ClaudeProjectionInventoryResource 'Microsoft.Network/privateDnsZones' 'privatelink.documents.azure.com' 'n/a' 'global' $network 'Private DNS zone for Cosmos SQL'))
    [void]$Resources.Add((New-ClaudeProjectionInventoryResource 'Microsoft.Network/privateDnsZones/virtualNetworkLinks' "privatelink.documents.azure.com/$NamePrefix-link" 'registration disabled' 'global' $network 'Links the Cosmos private DNS zone to the projection VNet'))
    [void]$Resources.Add((New-ClaudeProjectionInventoryResource 'Microsoft.Network/privateDnsZones' 'privatelink.azurewebsites.net' 'n/a' 'global' $network 'Private DNS zone for the resolver site endpoint'))
    [void]$Resources.Add((New-ClaudeProjectionInventoryResource 'Microsoft.Network/privateDnsZones/virtualNetworkLinks' "privatelink.azurewebsites.net/$NamePrefix-link" 'registration disabled' 'global' $network 'Links the sites private DNS zone to the projection VNet'))
    foreach ($service in @('blob', 'queue', 'table')) {
        $zone = "privatelink.$service.core.windows.net"
        [void]$Resources.Add((New-ClaudeProjectionInventoryResource 'Microsoft.Network/privateDnsZones' $zone 'n/a' 'global' $network "Private DNS zone for resolver storage $service endpoints"))
    }
    foreach ($service in @('blob', 'queue', 'table')) {
        $zone = "privatelink.$service.core.windows.net"
        [void]$Resources.Add((New-ClaudeProjectionInventoryResource 'Microsoft.Network/privateDnsZones/virtualNetworkLinks' "$zone/$NamePrefix-link" 'registration disabled' 'global' $network "Links the resolver storage $service private DNS zone to the projection VNet"))
    }
    [void]$Resources.Add((New-ClaudeProjectionInventoryResource 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups' "$cosmosPe/default" 'cosmos zone config' $Location $network 'Binds the Cosmos private endpoint to its private DNS zone'))
    [void]$Resources.Add((New-ClaudeProjectionInventoryResource 'Microsoft.ContainerInstance/containerGroups' $runner 'Linux; image mcr.microsoft.com/devcontainers/javascript-node:22; 2 CPU; 4 GB; restart Never; command /bin/sh -c sleep 10800' $Location $network 'In-VNet runner for projection apply and private connectivity tests'))

    [void]$Resources.Add((New-ClaudeProjectionInventoryResource 'Microsoft.OperationalInsights/workspaces' "log-resolver-$NamePrefix" 'PerGB2018; 30 day retention' $Location $resolver 'Resolver telemetry workspace when no workspace is supplied'))
    [void]$Resources.Add((New-ClaudeProjectionInventoryResource 'Microsoft.Insights/components' "appi-resolver-$NamePrefix" 'web; local auth disabled; workspace-based' $Location $resolver 'Application Insights component for the resolver'))
    [void]$Resources.Add((New-ClaudeProjectionInventoryResource 'Microsoft.Storage/storageAccounts' $storage 'Standard_LRS StorageV2; shared key disabled; OAuth default; public network disabled because storage private DNS zones are supplied' $Location $resolver 'Functions host and deployment package storage'))
    foreach ($service in @('blob', 'queue', 'table')) {
        [void]$Resources.Add((New-ClaudeProjectionInventoryResource 'Microsoft.Network/privateEndpoints' "pe-$storage-$service" "groupIds $service" $Location $resolver "Private endpoint for resolver storage $service"))
    }
    foreach ($service in @('blob', 'queue', 'table')) {
        [void]$Resources.Add((New-ClaudeProjectionInventoryResource 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups' "pe-$storage-$service/default" "$service zone config" $Location $resolver "Binds resolver storage $service private endpoint to private DNS"))
    }
    [void]$Resources.Add((New-ClaudeProjectionInventoryResource 'Microsoft.Storage/storageAccounts/blobServices' "$storage/default" 'n/a' $Location $resolver 'Default blob service for the deployment package'))
    [void]$Resources.Add((New-ClaudeProjectionInventoryResource 'Microsoft.Storage/storageAccounts/blobServices/containers' "$storage/default/deploymentpackage" 'publicAccess None' $Location $resolver 'Blob container for the Functions deployment package'))
    [void]$Resources.Add((New-ClaudeProjectionInventoryResource 'Microsoft.Web/serverfarms' $plan 'FlexConsumption FC1; Linux reserved' $Location $resolver 'Flex Consumption plan for the resolver Function app'))
    [void]$Resources.Add((New-ClaudeProjectionInventoryResource 'Microsoft.Web/sites' $site "functionapp,linux; Node 22; alwaysReady=2; httpConcurrency=100; maximumInstanceCount=100; instanceMemoryMB=2048; inboundAccess=$ResolverInboundAccess" $Location $resolver 'Resolver Function app that reads the projection'))
    [void]$Resources.Add((New-ClaudeProjectionInventoryResource 'Microsoft.Web/sites/basicPublishingCredentialsPolicies' "$site/scm" 'allow false' $Location $resolver 'Disables SCM basic publishing credentials'))
    [void]$Resources.Add((New-ClaudeProjectionInventoryResource 'Microsoft.Web/sites/basicPublishingCredentialsPolicies' "$site/ftp" 'allow false' $Location $resolver 'Disables FTP basic publishing credentials'))
    [void]$Resources.Add((New-ClaudeProjectionInventoryResource 'Microsoft.Web/sites/config' "$site/authsettingsV2" 'App Service Authentication enabled; unauthenticated requests return 401' $Location $resolver 'Allows only the gateway managed identity to call the resolver audience'))
    [void]$Resources.Add((New-ClaudeProjectionInventoryResource 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments' "$cosmos/sqlRoleAssignments/<guid for $site reader>" 'Cosmos DB Built-in Data Reader' $Location $resolver 'Lets the resolver read only the entitlement container'))
    [void]$Resources.Add((New-ClaudeProjectionInventoryResource 'Microsoft.Authorization/roleAssignments' "$storage/roleAssignments/<guid for $site blob owner>" 'Storage Blob Data Owner' 'global' $resolver 'Lets the resolver managed identity read and write its deployment package container'))
    [void]$Resources.Add((New-ClaudeProjectionInventoryResource 'Microsoft.Authorization/roleAssignments' "appi-resolver-$NamePrefix/roleAssignments/<guid for $site metrics publisher>" 'Monitoring Metrics Publisher' 'global' $resolver 'Lets the resolver send Entra-authenticated telemetry'))
    if ($ResolverInboundAccess -eq 'private') {
        $resolverPe = "pe-$site"
        [void]$Resources.Add((New-ClaudeProjectionInventoryResource 'Microsoft.Network/privateEndpoints' $resolverPe 'groupIds sites' $Location $resolver 'Private endpoint for inbound resolver access'))
        [void]$Resources.Add((New-ClaudeProjectionInventoryResource 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups' "$resolverPe/default" 'sites zone config' $Location $resolver 'Binds the resolver private endpoint to privatelink.azurewebsites.net'))
    }
}

function Add-ClaudeProjectionSyncResources {
    param(
        [AllowEmptyCollection()][Collections.Generic.List[object]]$Resources,
        [Parameter(Mandatory)][string]$NamePrefix,
        [Parameter(Mandatory)][string]$Location
    )
    $registry = 'infra\projection-registry.bicep'
    $renewal = 'infra\projection-renewal.bicep'
    $acr = Get-ClaudeProjectionDerivedName 'acr'
    $identity = "id-projection-renewal-$NamePrefix"
    $environment = Get-ClaudeProjectionDerivedName 'cae-renew-'
    $job = Get-ClaudeProjectionDerivedName 'caj-renew-'
    $actionGroup = "ag-projection-renewal-$NamePrefix"
    $cosmos = "cosmos-$NamePrefix"

    [void]$Resources.Add((New-ClaudeProjectionInventoryResource 'Microsoft.ContainerRegistry/registries' $acr 'Basic; admin user disabled; public network enabled' $Location $registry 'Container registry for the optional sync image'))
    [void]$Resources.Add((New-ClaudeProjectionInventoryResource 'Microsoft.ManagedIdentity/userAssignedIdentities' $identity 'n/a' $Location $registry 'User-assigned identity for the optional sync job'))
    [void]$Resources.Add((New-ClaudeProjectionInventoryResource 'Microsoft.Authorization/roleAssignments' "$acr/roleAssignments/<guid for $identity AcrPull>" 'AcrPull' 'global' $registry 'Lets the sync job identity pull the projection sync image'))

    [void]$Resources.Add((New-ClaudeProjectionInventoryResource 'Microsoft.App/managedEnvironments' $environment 'internal; azure-monitor logs; Consumption workload profile' $Location $renewal 'Internal Container Apps environment for the optional sync job'))
    [void]$Resources.Add((New-ClaudeProjectionInventoryResource 'Microsoft.Insights/diagnosticSettings' "$environment/projection-renewal-console" 'allLogs enabled' $Location $renewal 'Routes sync job console logs to the supplied Log Analytics workspace'))
    [void]$Resources.Add((New-ClaudeProjectionInventoryResource 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments' "$cosmos/sqlRoleAssignments/<guid for $identity writer>" 'Cosmos DB Built-in Data Contributor' $Location $renewal 'Lets the optional sync job write entitlement records'))
    [void]$Resources.Add((New-ClaudeProjectionInventoryResource 'Microsoft.Insights/actionGroups' $actionGroup 'short name projrenew; email receivers from deployment parameters' 'global' $renewal 'Notifies operators about optional sync job alerts'))
    [void]$Resources.Add((New-ClaudeProjectionInventoryResource 'Microsoft.App/jobs' $job 'Manual trigger by default; replicaTimeout 3600; replicaRetryLimit 0; image claude-projection-sync@sha256; 1 CPU; 2Gi memory; entrypoint node /app/sync/src/apply-projection.mjs' $Location $renewal 'Optional projection sync job'))
    [void]$Resources.Add((New-ClaudeProjectionInventoryResource 'Microsoft.Resources/deployments' "projection-renewal-reader-$NamePrefix" 'nested resource group deployment' $Location $renewal 'Deploys the gateway named-value reader role for the sync job identity'))
    foreach ($alert in @('graph-read-denied', 'renewal-failed')) {
        [void]$Resources.Add((New-ClaudeProjectionInventoryResource 'Microsoft.Insights/scheduledQueryRules' "sqr-projection-$NamePrefix-$alert" 'PT5M evaluation over PT45M; severity 2; Count > 0' $Location $renewal "Alert for optional sync job $alert condition"))
    }
}

function Get-ClaudeProjectionResourcePlan {
    param(
        [Parameter(Mandatory)][string]$NamePrefix,
        [Parameter(Mandatory)][string]$Location,
        [Parameter(Mandatory)][ValidateSet('BasicV2','StandardV2','PremiumV2')][string]$Sku,
        [Parameter(Mandatory)][ValidateSet('public','private')][string]$ResolverInboundAccess,
        [switch]$IncludeSyncJob
    )
    Assert-ClaudeProjectionInventoryPrefix -NamePrefix $NamePrefix

    $resources = [Collections.Generic.List[object]]::new()
    Add-ClaudeProjectionBaseResources -Resources $resources -NamePrefix $NamePrefix -Location $Location -ResolverInboundAccess $ResolverInboundAccess
    if ($IncludeSyncJob) { Add-ClaudeProjectionSyncResources -Resources $resources -NamePrefix $NamePrefix -Location $Location }

    $storage = Get-ClaudeProjectionDerivedName 'stres'
    $site = "func-resolver-$NamePrefix"
    $runner = "aci-projtest-$NamePrefix"
    $cosmos = "cosmos-$NamePrefix"
    $acr = Get-ClaudeProjectionDerivedName 'acr'
    $renewalIdentity = "id-projection-renewal-$NamePrefix"
    $privateEndpoints = @("pe-cosmos-$NamePrefix", "pe-$storage-blob", "pe-$storage-queue", "pe-$storage-table")
    if ($ResolverInboundAccess -eq 'private') { $privateEndpoints += "pe-$site" }

    $identities = [Collections.Generic.List[object]]::new()
    [void]$identities.Add((New-ClaudeProjectionInventoryIdentity "claude-projection-resolver-$NamePrefix" 'Entra app registration and service principal' 'tenant' 'Resolver audience api://<app id>; the gateway obtains tokens for this app'))
    [void]$identities.Add((New-ClaudeProjectionInventoryIdentity $runner 'System-assigned managed identity' $runner 'Runner identity used for private projection apply work'))
    [void]$identities.Add((New-ClaudeProjectionInventoryIdentity $runner 'Cosmos DB Built-in Data Contributor' "$cosmos/dbs/claude/colls/entitlement" 'Runner writes the initial projection snapshot through the data plane'))
    [void]$identities.Add((New-ClaudeProjectionInventoryIdentity $site 'System-assigned managed identity' $site 'Resolver identity used for Cosmos, storage and telemetry access'))
    [void]$identities.Add((New-ClaudeProjectionInventoryIdentity $site 'Cosmos DB Built-in Data Reader' "$cosmos/dbs/claude/colls/entitlement" 'Resolver reads entitlement records and cannot write them'))
    [void]$identities.Add((New-ClaudeProjectionInventoryIdentity $site 'Storage Blob Data Owner' $storage 'Functions host accesses the deployment package with Entra authentication'))
    [void]$identities.Add((New-ClaudeProjectionInventoryIdentity $site 'Monitoring Metrics Publisher' "appi-resolver-$NamePrefix" 'Resolver sends Entra-authenticated Application Insights telemetry'))
    [void]$identities.Add((New-ClaudeProjectionInventoryIdentity 'gateway managed identity' 'Allowed caller application and principal' $site 'App Service Authentication admits only the gateway identity to the resolver'))
    if ($IncludeSyncJob) {
        [void]$identities.Add((New-ClaudeProjectionInventoryIdentity $renewalIdentity 'User-assigned managed identity' $renewalIdentity 'Optional sync job runtime identity'))
        [void]$identities.Add((New-ClaudeProjectionInventoryIdentity $renewalIdentity 'AcrPull' $acr 'Optional sync job pulls the projection sync image'))
        [void]$identities.Add((New-ClaudeProjectionInventoryIdentity $renewalIdentity 'Cosmos DB Built-in Data Contributor' "$cosmos/dbs/claude/colls/entitlement" 'Optional sync job writes full projection refreshes'))
        [void]$identities.Add((New-ClaudeProjectionInventoryIdentity $renewalIdentity 'Custom named-value reader role' 'API Management gateway' 'Optional sync job reads bu-registry and bu-parents named values; no writes and no secret list action'))
        [void]$identities.Add((New-ClaudeProjectionInventoryIdentity $renewalIdentity 'Microsoft Graph GroupMember.Read.All application permission' 'tenant admin consent' 'Optional scheduled sync reads tier group membership after tenant administrator consent'))
    }

    $runnerInfo = [pscustomobject]@{
        Name = $runner
        Enabled = $true
        Image = 'mcr.microsoft.com/devcontainers/javascript-node:22'
        Cpu = 2
        MemoryGB = 4
        Command = '/bin/sh -c sleep 10800'
        Lifetime = '10800 seconds'
    }

    [pscustomobject]@{
        Resources = @($resources)
        Network = [pscustomobject]@{
            VirtualNetwork = "vnet-$NamePrefix"
            AddressSpace = '10.10.0.0/16'
            Subnets = @(
                [pscustomobject]@{ Name = 'endpoints'; Prefix = '10.10.1.0/24'; Delegation = ''; Purpose = 'Private endpoints' }
                [pscustomobject]@{ Name = 'runner'; Prefix = '10.10.2.0/24'; Delegation = 'Microsoft.ContainerInstance/containerGroups'; Purpose = 'ACI projection runner' }
                [pscustomobject]@{ Name = 'resolver'; Prefix = '10.10.3.0/26'; Delegation = 'Microsoft.App/environments'; Purpose = 'Resolver Flex Consumption outbound integration' }
                [pscustomobject]@{ Name = 'renewal'; Prefix = '10.10.3.64/27'; Delegation = 'Microsoft.App/environments'; Purpose = 'Optional sync job Container Apps environment' }
            )
            PrivateEndpoints = @($privateEndpoints)
            PrivateDnsZones = @('privatelink.documents.azure.com', 'privatelink.azurewebsites.net', 'privatelink.blob.core.windows.net', 'privatelink.queue.core.windows.net', 'privatelink.table.core.windows.net')
            ResolverAccess = $ResolverInboundAccess
            Runner = $runnerInfo
            GatewaySku = $Sku
        }
        Identities = @($identities)
    }
}

function Format-ClaudeProjectionResourcePlan {
    param([Parameter(Mandatory)]$Plan)
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add('Resources:')
    $lines.Add('Type | Name | SKU | Region | Template | Purpose')
    foreach ($resource in @($Plan.Resources)) {
        $lines.Add(('{0} | {1} | {2} | {3} | {4} | {5}' -f $resource.Type, $resource.Name, $resource.Sku, $resource.Region, $resource.Template, $resource.Purpose))
    }
    $lines.Add('')
    $lines.Add('Network:')
    $lines.Add(('Virtual network {0} uses address space {1}.' -f $Plan.Network.VirtualNetwork, $Plan.Network.AddressSpace))
    foreach ($subnet in @($Plan.Network.Subnets)) {
        $delegation = if ($subnet.Delegation) { $subnet.Delegation } else { 'none' }
        $lines.Add(('Subnet {0} uses {1}, delegation {2}, for {3}.' -f $subnet.Name, $subnet.Prefix, $delegation, $subnet.Purpose))
    }
    $lines.Add(('Private endpoints: {0}.' -f ((@($Plan.Network.PrivateEndpoints) -join ', '))))
    $lines.Add(('Private DNS zones: {0}.' -f ((@($Plan.Network.PrivateDnsZones) -join ', '))))
    $lines.Add(('Resolver inbound access is {0}.' -f $Plan.Network.ResolverAccess))
    $lines.Add(('Runner {0} uses image {1}, {2} CPU, {3} GB memory, command {4}, lifetime {5}.' -f $Plan.Network.Runner.Name, $Plan.Network.Runner.Image, $Plan.Network.Runner.Cpu, $Plan.Network.Runner.MemoryGB, $Plan.Network.Runner.Command, $Plan.Network.Runner.Lifetime))
    $lines.Add('')
    $lines.Add('Identities and role assignments:')
    $lines.Add('Principal | Role | Scope | Purpose')
    foreach ($identity in @($Plan.Identities)) {
        $lines.Add(('{0} | {1} | {2} | {3}' -f $identity.Principal, $identity.Role, $identity.Scope, $identity.Purpose))
    }
    return $lines.ToArray()
}
