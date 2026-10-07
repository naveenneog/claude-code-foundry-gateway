metadata description = 'Optional Azure AI Content Safety account for Claude request screening.'

targetScope = 'resourceGroup'

@description('Globally unique Content Safety account name.')
param accountName string

@description('Azure region that supports Content harms and Prompt Shields.')
param location string

@description('Object id of the API Management system-assigned managed identity.')
param apimPrincipalId string

@allowed([
  'Enabled'
  'Disabled'
])
param publicNetworkAccess string = 'Enabled'

var cognitiveServicesUserRoleId = 'a97b65f3-24c7-4388-baec-2e87135dc908' // Cognitive Services User

resource contentSafety 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: accountName
  location: location
  kind: 'ContentSafety'
  sku: {
    name: 'S0'
  }
  properties: {
    customSubDomainName: accountName
    disableLocalAuth: true
    publicNetworkAccess: publicNetworkAccess
  }
}

resource apimContentSafetyUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(contentSafety.id, apimPrincipalId, cognitiveServicesUserRoleId)
  scope: contentSafety
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesUserRoleId)
    principalId: apimPrincipalId
    principalType: 'ServicePrincipal'
  }
}

output endpoint string = 'https://${contentSafety.name}.cognitiveservices.azure.com'
output contentSafetyRoleAssignmentId string = apimContentSafetyUser.id
