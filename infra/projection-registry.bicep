// Phase 1 of the projection renewal deployment (ADR-0049): the registry the job pulls its image
// from, and the identity the job runs as. Deployed before the image build, so the identity exists
// before the job and a tenant administrator can grant Graph access while the image builds, and
// the AcrPull grant has time to take effect before infra/projection-renewal.bicep creates the job.

@description('Prefix shared with the projection resources: the same 1-37 characters scripts/Deploy-ClaudeProjection.ps1 accepts.')
@minLength(1)
@maxLength(37)
param namePrefix string

param location string = resourceGroup().location

@description('Container registry SKU. Basic uses the public ACR endpoint with Entra authentication; Premium is required for a private endpoint.')
@allowed([
  'Basic'
  'Premium'
])
param acrSku string = 'Basic'

var acrName = 'acr${uniqueString(resourceGroup().id, namePrefix)}'
var identityName = 'id-projection-renewal-${namePrefix}'

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: acrName
  location: location
  sku: {
    name: acrSku
  }
  properties: {
    adminUserEnabled: false
    publicNetworkAccess: 'Enabled'
  }
}

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: identityName
  location: location
}

resource acrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, identity.id, 'acrpull')
  scope: acr
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

output acrName string = acr.name
output acrLoginServer string = acr.properties.loginServer
output acrSkuChosen string = acrSku
output identityName string = identity.name
output identityClientId string = identity.properties.clientId
output identityPrincipalId string = identity.properties.principalId
