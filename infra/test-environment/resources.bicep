// P121 test environment, stage 1 of 2: resources (ADR-0067).
// Composes the existing modules: the gateway on Basic v2 with Foundry in another tenant (client credentials),
// the private Cosmos projection, its network (managed, or the customer's VNet, subnets and DNS zones; no runner)
// and the sync job's registry and identity.
// configuration.bicep then deploys the resolver, which needs the gateway identity's application id that only
// Microsoft Graph returns, the gateway's entitlement named values and the sync job.

@description('Prefix for the projection resources, 1-20 lower-case letters and digits.')
@minLength(1)
@maxLength(20)
param namePrefix string

param location string = resourceGroup().location

@description('Publisher email for API Management.')
param publisherEmail string

@description('Foundry account name in the other tenant; recorded only, the gateway uses foundryEndpoint.')
param foundryAccountName string

@description('Foundry account base endpoint, for example https://<account>.services.ai.azure.com/.')
param foundryEndpoint string

@description('Tenant id of the Foundry account.')
param foundryTenantId string

@description('Application (client) id that holds Cognitive Services User on the Foundry account.')
param foundryClientId string

@description('Client secret of foundryClientId. Written as a secret named value; never an output.')
@secure()
param foundryClientSecret string

@description('Model allowlists in the gateway form: ,a,b,')
param modelsStandard string
param modelsPremium string

param sonnetDeployment string = 'claude-sonnet-5'
param opusDeployment string = 'claude-opus-5'
param haikuDeployment string = 'claude-haiku-4-5'

// Customer networking (optional). Empty creates a managed VNet. With vnetId, all five subnet ids are required and the
// network team's address plan, delegations and NSGs are used unchanged (infra/projection-network.bicep); the script
// validates them first with the installer's preflight (scripts/ClaudeProjectionNetwork.psm1). A DNS zone id reuses a
// customer zone that is already linked to the VNet; empty creates and links a test-owned zone.
param vnetId string = ''
param endpointsSubnetId string = ''
param runnerSubnetId string = ''
param resolverSubnetId string = ''
param renewalSubnetId string = ''
param apimSubnetId string = ''
param cosmosDnsZoneId string = ''
param sitesDnsZoneId string = ''
param blobDnsZoneId string = ''
param queueDnsZoneId string = ''
param tableDnsZoneId string = ''

module gateway '../main.bicep' = {
  name: 'test-gateway'
  params: {
    namePrefix: 'claudegw${namePrefix}'
    location: location
    publisherEmail: publisherEmail
    apimSku: 'BasicV2'
    foundryAccountName: foundryAccountName
    foundryAuthenticationMode: 'client-credentials'
    foundryEndpoint: foundryEndpoint
    foundryTenantId: foundryTenantId
    foundryClientId: foundryClientId
    foundryClientSecret: foundryClientSecret
    grantFoundryRole: false
    modelsStandard: modelsStandard
    modelsPremium: modelsPremium
    sonnetDeployment: sonnetDeployment
    opusDeployment: opusDeployment
    haikuDeployment: haikuDeployment
    // A removal shows within a minute on a test gateway: infra/policy.xml caches an allowed answer this long.
    entitlementCacheSeconds: 60
  }
}

module projection '../projection.bicep' = {
  name: 'test-projection'
  params: {
    namePrefix: namePrefix
    location: location
    networkAccess: 'private-only'
  }
}

module network '../projection-network.bicep' = {
  name: 'test-projection-network'
  params: {
    namePrefix: namePrefix
    location: location
    cosmosAccountName: projection.outputs.accountName
    runnerEnabled: false
    vnetId: vnetId
    endpointsSubnetId: endpointsSubnetId
    runnerSubnetId: runnerSubnetId
    resolverSubnetId: resolverSubnetId
    renewalSubnetId: renewalSubnetId
    apimSubnetId: apimSubnetId
    cosmosDnsZoneId: cosmosDnsZoneId
    sitesDnsZoneId: sitesDnsZoneId
    blobDnsZoneId: blobDnsZoneId
    queueDnsZoneId: queueDnsZoneId
    tableDnsZoneId: tableDnsZoneId
  }
}

module registry '../projection-registry.bicep' = {
  name: 'test-projection-registry'
  params: {
    namePrefix: namePrefix
    location: location
  }
}

output apimName string = gateway.outputs.apimName
output gatewayUrl string = gateway.outputs.gatewayUrl
output apimPrincipalId string = gateway.outputs.apimPrincipalId
output workspaceId string = gateway.outputs.workspaceId
output cosmosAccountName string = projection.outputs.accountName
output cosmosEndpoint string = projection.outputs.documentEndpoint
output vnetId string = network.outputs.vnetId
output resolverSubnetId string = network.outputs.resolverSubnetId
output renewalSubnetId string = network.outputs.renewalSubnetId
output endpointsSubnetId string = network.outputs.endpointsSubnetId
output sitesDnsZoneId string = network.outputs.sitesDnsZoneId
output blobDnsZoneId string = network.outputs.blobDnsZoneId
output queueDnsZoneId string = network.outputs.queueDnsZoneId
output tableDnsZoneId string = network.outputs.tableDnsZoneId
output acrName string = registry.outputs.acrName
output acrLoginServer string = registry.outputs.acrLoginServer
output jobIdentityName string = registry.outputs.identityName
output jobIdentityClientId string = registry.outputs.identityClientId
output jobIdentityPrincipalId string = registry.outputs.identityPrincipalId
