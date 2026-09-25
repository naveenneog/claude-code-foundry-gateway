param gatewayName string
param principalId string
param writerRoleDefinitionId string
resource gateway 'Microsoft.ApiManagement/service@2024-05-01' existing = { name: gatewayName }
resource writer 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: gateway
  name: guid(gateway.id, principalId, writerRoleDefinitionId)
  properties: {
    roleDefinitionId: writerRoleDefinitionId
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}
output assignmentId string = writer.id
