// Read-only access to the gateway's named values for the projection renewal job (ADR-0049). Each
// run reads bu-registry and bu-parents, so a business unit added later reaches the projection
// without redeploying the job. Deployed at the gateway's resource group by
// infra/projection-renewal.bicep. Same shape as the chargeback job's catalog reader
// (infra/chargeback-reports.bicep): one read action, no writes and no secret-list action.

@description('Name of the API Management gateway whose named values the job reads.')
param gatewayName string

@description('Object id of the renewal job identity.')
param principalId string

@description('Prefix shared with the projection resources.')
param namePrefix string

resource gateway 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: gatewayName
}

resource readerRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: guid(resourceGroup().id, gatewayName, 'projection-renewal-named-value-reader')
  properties: {
    roleName: 'Claude projection renewal named-value reader ${take(uniqueString(resourceGroup().id, gatewayName), 10)}'
    type: 'CustomRole'
    description: 'Reads the gateway named values bu-registry and bu-parents for the projection renewal job (${namePrefix}). No writes and no secret-list action.'
    assignableScopes: [
      resourceGroup().id
    ]
    permissions: [
      {
        actions: [
          'Microsoft.ApiManagement/service/namedValues/read'
        ]
        notActions: []
        dataActions: []
        notDataActions: []
      }
    ]
  }
}

resource readerAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(gateway.id, principalId, 'projection-renewal-named-value-reader')
  scope: gateway
  properties: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: readerRole.id
  }
}
