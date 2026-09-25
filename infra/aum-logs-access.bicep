param workspaceName string
param principalId string
var logsReader = '73c42c96-874c-492b-b04d-ab87d138a893'
resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = { name: workspaceName }
resource reader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: workspace
  name: guid(workspace.id, principalId, logsReader)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', logsReader)
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}
output assignmentId string = reader.id
