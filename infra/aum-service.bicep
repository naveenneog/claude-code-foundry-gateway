@description('Administrator-selected resource-name prefix. No deployment name is a default.')
param namePrefix string
param location string = resourceGroup().location
param tenantId string = subscription().tenantId
param clientId string
param apimResourceId string
param workspaceResourceId string
param workspaceCustomerId string
param writerRoleDefinitionId string

@allowed([0, 1])
param alwaysReadyInstances int
@allowed(['LRS', 'ZRS', 'GRS'])
param storageRedundancy string
param enableInsights bool
@allowed(['public', 'private'])
param inboundAccess string
@allowed(['public', 'private'])
param storageAccess string = inboundAccess

@description('Reuse only a service-owned account with shared key already disabled; blank creates a dedicated account.')
param existingStorageName string = ''
@description('Reuse only an empty FC1 plan in this resource group and region; blank creates a dedicated plan.')
param existingPlanName string = ''
param integrationSubnetId string = ''
param privateEndpointSubnetId string = ''
param sitesDnsZoneId string = ''
param blobDnsZoneId string = ''
param tableDnsZoneId string = ''

var storageName = empty(existingStorageName) ? take('staum${uniqueString(resourceGroup().id, namePrefix)}', 24) : existingStorageName
var planName = empty(existingPlanName) ? 'plan-aum-${namePrefix}' : existingPlanName
var siteName = 'func-aum-${namePrefix}'
var private = inboundAccess == 'private'
var storagePrivate = private || storageAccess == 'private'
var packageContainerName = 'aum-package-${namePrefix}'
// Built-in platform role identifiers, not deployment identifiers.
var blobOwner = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b' // Storage Blob Data Owner: Functions timer host.
var tableContributor = '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
var metricsPublisher = '3913510d-42f4-4e42-8a64-420c390055eb'

resource newStorage 'Microsoft.Storage/storageAccounts@2023-05-01' = if (empty(existingStorageName)) {
  name: storageName
  location: location
  tags: { component: 'aum-service', 'aum-gateway': apimResourceId, 'aum-function': siteName }
  kind: 'StorageV2'
  sku: { name: 'Standard_${storageRedundancy}' }
  properties: {
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    publicNetworkAccess: storagePrivate ? 'Disabled' : 'Enabled'
  }
}
resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' existing = { name: storageName }
resource blobs 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
  dependsOn: [newStorage]
}
resource package 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobs
  name: packageContainerName
  properties: { publicAccess: 'None' }
}
resource control 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobs
  name: 'aum-control'
  properties: { publicAccess: 'None' }
}
resource tables 'Microsoft.Storage/storageAccounts/tableServices@2023-05-01' = {
  parent: storage
  name: 'default'
  dependsOn: [newStorage]
}
resource state 'Microsoft.Storage/storageAccounts/tableServices/tables@2023-05-01' = {
  parent: tables
  name: 'AumState'
}
resource newPlan 'Microsoft.Web/serverfarms@2024-04-01' = if (empty(existingPlanName)) {
  name: planName
  location: location
  kind: 'functionapp'
  sku: { name: 'FC1', tier: 'FlexConsumption' }
  properties: { reserved: true }
}
resource plan 'Microsoft.Web/serverfarms@2024-04-01' existing = { name: planName }
resource insights 'Microsoft.Insights/components@2020-02-02' = if (enableInsights) {
  name: 'appi-aum-${namePrefix}'
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: workspaceResourceId
    DisableLocalAuth: true
  }
}
var settings = [
  { name: 'AzureWebJobsStorage__accountName', value: storageName }
  { name: 'AUM_TENANT_ID', value: tenantId }
  { name: 'AUM_CLIENT_ID', value: clientId }
  { name: 'AUM_APIM_RESOURCE_ID', value: apimResourceId }
  { name: 'AUM_WORKSPACE_ID', value: workspaceCustomerId }
  { name: 'AUM_STORAGE_ACCOUNT', value: storageName }
]
resource site 'Microsoft.Web/sites@2025-03-01' = {
  name: siteName
  location: location
  kind: 'functionapp,linux'
  tags: { component: 'aum-service' }
  identity: { type: 'SystemAssigned' }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    publicNetworkAccess: private ? 'Disabled' : 'Enabled'
    virtualNetworkSubnetId: storagePrivate || private ? integrationSubnetId : null
    outboundVnetRouting: {
      allTraffic: storagePrivate
    }
    siteConfig: {
      minTlsVersion: '1.2'
      scmMinTlsVersion: '1.2'
      ftpsState: 'Disabled'
      appSettings: concat(settings, enableInsights ? [
        // Routing metadata, not a credential; local ingestion authentication is disabled.
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: insights.properties.ConnectionString }
        { name: 'APPLICATIONINSIGHTS_AUTHENTICATION_STRING', value: 'Authorization=AAD' }
      ] : [])
    }
    functionAppConfig: {
      runtime: { name: 'python', version: '3.12' }
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${storage.properties.primaryEndpoints.blob}${packageContainerName}'
          authentication: { type: 'SystemAssignedIdentity' }
        }
      }
      scaleAndConcurrency: {
        maximumInstanceCount: 40
        instanceMemoryMB: 512
        triggers: { http: { perInstanceConcurrency: 4 } }
        alwaysReady: alwaysReadyInstances == 1 ? [{ name: 'http', instanceCount: 1 }] : []
      }
    }
  }
  dependsOn: [newPlan, package, control, state]
}
resource scm 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2024-04-01' = {
  parent: site
  name: 'scm'
  properties: { allow: false }
}
resource ftp 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2024-04-01' = {
  parent: site
  name: 'ftp'
  properties: { allow: false }
}
resource storageRoles 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for role in [blobOwner, tableContributor]: {
  name: guid(storage.id, site.id, role)
  scope: storage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', role)
    principalId: site.identity.principalId
    principalType: 'ServicePrincipal'
  }
}]
resource telemetryRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (enableInsights) {
  name: guid(insights.id, site.id, metricsPublisher)
  scope: insights
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', metricsPublisher)
    principalId: site.identity.principalId
    principalType: 'ServicePrincipal'
  }
}
module gatewayAccess 'aum-gateway-access.bicep' = {
  name: 'aum-gateway-access'
  scope: resourceGroup(split(apimResourceId, '/')[2], split(apimResourceId, '/')[4])
  params: {
    gatewayName: last(split(apimResourceId, '/'))
    principalId: site.identity.principalId
    writerRoleDefinitionId: writerRoleDefinitionId
  }
}
module logsAccess 'aum-logs-access.bicep' = {
  name: 'aum-logs-access'
  scope: resourceGroup(split(workspaceResourceId, '/')[2], split(workspaceResourceId, '/')[4])
  params: {
    workspaceName: last(split(workspaceResourceId, '/'))
    principalId: site.identity.principalId
  }
}
var endpoints = concat(private ? [
  { name: 'sites', target: site.id, zone: sitesDnsZoneId }
] : [], storagePrivate ? [
  { name: 'blob', target: storage.id, zone: blobDnsZoneId }
  { name: 'table', target: storage.id, zone: tableDnsZoneId }
] : [])
resource endpoint 'Microsoft.Network/privateEndpoints@2023-11-01' = [for ep in endpoints: {
  name: 'pe-aum-${namePrefix}-${ep.name}'
  location: location
  properties: {
    subnet: { id: privateEndpointSubnetId }
    privateLinkServiceConnections: [{
      name: 'aum-${ep.name}'
      properties: { privateLinkServiceId: ep.target, groupIds: [ep.name] }
    }]
  }
}]
resource dns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = [for (ep, i) in endpoints: {
  parent: endpoint[i]
  name: 'default'
  properties: { privateDnsZoneConfigs: [{ name: ep.name, properties: { privateDnsZoneId: ep.zone } }] }
}]

output functionName string = site.name
output endpoint string = 'https://${site.properties.defaultHostName}'
output principalId string = site.identity.principalId
output storageName string = storage.name
output planName string = plan.name
output roleAssignmentIds array = [gatewayAccess.outputs.assignmentId, logsAccess.outputs.assignmentId]
