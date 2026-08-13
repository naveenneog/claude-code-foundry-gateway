metadata description = 'Grants a principal the Cognitive Services User role on a Foundry account. Split into its own module so the assignment can target the Foundry resource group when it differs from the gateway resource group.'

targetScope = 'resourceGroup'

@description('Name of the existing Foundry (AIServices) account.')
param foundryAccountName string

@description('Object id of the principal to grant data-plane access to.')
param principalId string

// Cognitive Services User. Data-plane inference access without key management
// rights. Owner/Contributor are control-plane roles and do NOT grant this.
var cognitiveServicesUserRoleId = 'a97b65f3-24c7-4388-baec-2e87135dc908'

resource foundry 'Microsoft.CognitiveServices/accounts@2024-10-01' existing = {
  name: foundryAccountName
}

resource assignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: foundry
  name: guid(foundry.id, principalId, cognitiveServicesUserRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesUserRoleId)
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}

output roleAssignmentId string = assignment.id
