// P121 test environment, stage 2 of 2: configuration (ADR-0067).
// Deploys the resolver, points the gateway at it, names the business units, and deploys the sync job on a
// test cron. Inputs come from resources.bicep's outputs and from Microsoft Graph (the gateway identity's
// application id, the group object ids), which scripts/Deploy-ClaudeTestEnvironment.ps1 reads.

@minLength(1)
@maxLength(20)
param namePrefix string

param location string = resourceGroup().location

param apimName string
param cosmosAccountName string
param workspaceId string
param resolverSubnetId string

@description('Private endpoint subnet and DNS zones for the resolver storage. A subscription policy can turn off public access to the storage account; the endpoints keep the deployment package reachable.')
param endpointsSubnetId string
param blobDnsZoneId string
param queueDnsZoneId string
param tableDnsZoneId string
param renewalSubnetId string
param acrName string
param jobIdentityName string

@description('Application id of the resolver app registration (Easy Auth audience).')
param resolverAppId string

@description('Application id of the gateway system identity, the resolver\'s only allowed caller.')
param gatewayAppId string

@description('Object id of the gateway system identity.')
param gatewayPrincipalId string

@description('Digest-pinned sync image in the registry, sha256:<digest>.')
param syncImageDigest string

param standardGroupId string
param premiumGroupId string

@description('bu-registry value: ,<id>=<group>:<tokens>,...')
param buRegistry string

@description('bu-parents value: ,<team>=<unit>,...')
param buParents string = ',,'

@description('Minutes between scheduled sync runs. The production table starts at 30 (ADR-0058); 5 is for tests.')
@minValue(5)
@maxValue(30)
param syncMinutes int = 5

param alertEmails array

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimName
}

module resolver '../resolver.bicep' = {
  name: 'test-resolver'
  params: {
    namePrefix: namePrefix
    location: location
    cosmosAccountName: cosmosAccountName
    integrationSubnetId: resolverSubnetId
    resolverAppId: resolverAppId
    allowedCallerAppIds: [
      gatewayAppId
    ]
    allowedCallerObjectIds: [
      gatewayPrincipalId
    ]
    inboundAccess: 'public'
    privateEndpointSubnetId: endpointsSubnetId
    blobDnsZoneId: blobDnsZoneId
    queueDnsZoneId: queueDnsZoneId
    tableDnsZoneId: tableDnsZoneId
    alwaysReadyInstances: 1
    logAnalyticsWorkspaceId: workspaceId
  }
}

// The keys are known when the deployment starts; two values come from the resolver deployment.
var gatewayValueKeys = [
  'entitlement-source'
  'entitlement-resolver-url'
  'entitlement-resolver-audience'
  'entitlement-projection-prefix'
  'bu-registry'
  'bu-parents'
]
var gatewayValues = {
  'entitlement-source': 'projection'
  'entitlement-resolver-url': resolver.outputs.resolverUrl
  'entitlement-resolver-audience': resolver.outputs.resolverAudience
  'entitlement-projection-prefix': namePrefix
  'bu-registry': buRegistry
  'bu-parents': buParents
}

resource namedValues 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = [
  for key in gatewayValueKeys: {
    parent: apim
    name: key
    properties: {
      displayName: key
      value: gatewayValues[key]
    }
  }
]

module syncJob '../projection-renewal.bicep' = {
  name: 'test-sync-job'
  params: {
    namePrefix: namePrefix
    location: location
    cosmosAccountName: cosmosAccountName
    containerAppsSubnetId: renewalSubnetId
    logAnalyticsWorkspaceId: workspaceId
    actionGroupEmailReceivers: alertEmails
    acrName: acrName
    identityName: jobIdentityName
    syncImageDigest: syncImageDigest
    cronExpression: '*/${syncMinutes} * * * *'
    noSuccessMinutes: 2 * syncMinutes + 15
    standardGroupId: standardGroupId
    premiumGroupId: premiumGroupId
    gatewayResourceId: apim.id
  }
}

output resolverUrl string = resolver.outputs.resolverUrl
output resolverSiteName string = resolver.outputs.siteName
output jobName string = syncJob.outputs.jobName
output cronExpression string = '*/${syncMinutes} * * * *'
