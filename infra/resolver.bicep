// The entitlement resolver - the read side of ADR-0005, on the platform ADR-0011
// chose.
//
// resolver/src/index.mjs does no authentication of its own and says so: it
// relies on this template's App Service Authentication, so an unauthenticated
// request never reaches the code. Doing it in both places would mean two
// answers to the question of who may call, and eventually they would differ.
//
// Who may call is exactly one thing: the gateway's managed identity. The
// token must be issued by this tenant, for this resolver's own audience, to an
// application on the allow list - checked on the application id and, when
// given, on the object id as well. Anything else is refused with 401/403
// before the code runs.
//
// Where it may be called from is a second, independent control. With
// inboundAccess 'private' the app has no public endpoint at all and is reached
// through a private endpoint, which needs a gateway with outbound VNet
// integration (API Management Standard v2 or Premium v2). With 'public' the
// token check is the only control, which is what a Basic v2 gateway - no VNet
// integration - requires.
//
// There is no key or connection string anywhere in this file. The app reaches
// Cosmos, its own storage and Application Insights with its managed identity,
// and each of those has key authentication turned off.

@description('Prefix shared with the gateway and the projection.')
param namePrefix string

param location string = resourceGroup().location

@description('The Cosmos account projection.bicep created. Same resource group.')
param cosmosAccountName string

param databaseName string = 'claude'
param containerName string = 'entitlement'

@description('Entra tenant the projection is for. The resolver refuses records stamped with another.')
param tenantId string = subscription().tenantId

@description('Subnet for outbound traffic to the Cosmos private endpoint. Delegated to Microsoft.App/environments, /27 or larger, holding no private endpoints.')
param integrationSubnetId string

@description('Application (client) id of the Entra app registration that stands for the resolver. Tokens must be issued for it.')
param resolverAppId string

@description('Application (client) ids allowed to call. The gateway managed identity, and nothing else.')
@minLength(1)
param allowedCallerAppIds array

@description('Object ids allowed to call, checked as well as the application id. The same identities.')
param allowedCallerObjectIds array = []

@description('''
Where the resolver can be reached from.

  private   no public endpoint. Reached through a private endpoint, so the
            gateway needs outbound VNet integration (Standard v2 or Premium v2).
  public    reachable from the internet; the token check is the only control.
            What a Basic v2 gateway, which cannot integrate with a VNet, needs.
''')
@allowed([
  'private'
  'public'
])
param inboundAccess string = 'private'

@description('Subnet for the resolver private endpoint. Required when inboundAccess is private.')
param privateEndpointSubnetId string = ''

@description('privatelink.azurewebsites.net zone, linked to the VNet. Required when inboundAccess is private.')
param sitesDnsZoneId string = ''

@description('''
Private DNS zones for the resolver's own storage: blob, queue and table, as
projection-network.bicep outputs them. Given, the storage account has no public
endpoint and is reached through private endpoints in privateEndpointSubnetId.
Empty, it keeps a public endpoint that accepts Entra identities only.
''')
param blobDnsZoneId string = ''
param queueDnsZoneId string = ''
param tableDnsZoneId string = ''

@description('''
Instances kept warm. 0 bills nothing at rest but the first request after idle
pays a cold start, and the gateway gives the resolver 5 seconds. 1 removes the
cold start for a steady trickle; 2 or more keeps one warm through a burst.
''')
@minValue(0)
param alwaysReadyInstances int = 2

@description('HTTP requests per warm instance. Keep at least the gateway miss concurrency (100); coalescing shares same-identity Cosmos reads within each worker.')
@minValue(100)
@maxValue(200)
param httpConcurrency int = 100

@minValue(1)
@maxValue(1000)
param maximumInstanceCount int = 100

@allowed([
  512
  2048
  4096
])
param instanceMemoryMB int = 2048

@description('Log Analytics workspace for the resolver telemetry. A new one is created when empty.')
param logAnalyticsWorkspaceId string = ''

var siteName = 'func-resolver-${namePrefix}'
var planName = 'plan-resolver-${namePrefix}'
var storageName = take('stres${uniqueString(resourceGroup().id, namePrefix)}', 24)
var deploymentContainer = 'deploymentpackage'
var isPrivate = inboundAccess == 'private'
var storagePrivate = !empty(blobDnsZoneId)
var storageEndpoints = storagePrivate ? [
  {
    service: 'blob'
    zone: blobDnsZoneId
  }
  {
    service: 'queue'
    zone: queueDnsZoneId
  }
  {
    service: 'table'
    zone: tableDnsZoneId
  }
] : []

// Built-in role ids. Cosmos data-plane roles are not Azure RBAC roles; they
// live on the account and are assigned there.
var cosmosDataReader = '00000000-0000-0000-0000-000000000001'
var storageBlobDataOwner = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
var monitoringMetricsPublisher = '3913510d-42f4-4e42-8a64-420c390055eb'

resource cosmos 'Microsoft.DocumentDB/databaseAccounts@2024-05-15' existing = {
  name: cosmosAccountName
}

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = if (empty(logAnalyticsWorkspaceId)) {
  name: 'log-resolver-${namePrefix}'
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: 'appi-resolver-${namePrefix}'
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: empty(logAnalyticsWorkspaceId) ? workspace.id : logAnalyticsWorkspaceId
    // Telemetry is accepted only from an Entra-authenticated sender, so the
    // connection string in the app settings is not a credential.
    DisableLocalAuth: true
  }
}

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    // Identity only. The Functions host, the deployment package and anyone
    // browsing the account all need an Entra role; a leaked key would be
    // useless because there is no key path.
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    // Stated rather than left to default. Measured: a policy set it to
    // Disabled anyway, and the deployment then failed with a 403 that read
    // like a missing role until the private endpoints below existed.
    publicNetworkAccess: storagePrivate ? 'Disabled' : 'Enabled'
  }
}

resource storageEndpoint 'Microsoft.Network/privateEndpoints@2023-11-01' = [for e in storageEndpoints: {
  name: 'pe-${storageName}-${e.service}'
  location: location
  properties: {
    subnet: {
      id: privateEndpointSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'pe-${storageName}-${e.service}'
        properties: {
          privateLinkServiceId: storage.id
          groupIds: [
            e.service
          ]
        }
      }
    ]
  }
}]

resource storageEndpointDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = [for (e, i) in storageEndpoints: {
  parent: storageEndpoint[i]
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: e.service
        properties: {
          privateDnsZoneId: e.zone
        }
      }
    ]
  }
}]

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
}

resource packageContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: deploymentContainer
  properties: {
    publicAccess: 'None'
  }
}

resource plan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: planName
  location: location
  kind: 'functionapp'
  sku: {
    tier: 'FlexConsumption'
    name: 'FC1'
  }
  properties: {
    reserved: true
  }
}

resource site 'Microsoft.Web/sites@2024-04-01' = {
  name: siteName
  location: location
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    publicNetworkAccess: isPrivate ? 'Disabled' : 'Enabled'
    virtualNetworkSubnetId: integrationSubnetId
    siteConfig: {
      minTlsVersion: '1.2'
      scmMinTlsVersion: '1.2'
      ftpsState: 'Disabled'
      http20Enabled: true
      appSettings: [
        {
          // The host's own storage, reached with the managed identity. The
          // accountName form is what tells the host to use an identity rather
          // than a connection string.
          name: 'AzureWebJobsStorage__accountName'
          value: storage.name
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
        {
          // Required because the component refuses unauthenticated telemetry.
          name: 'APPLICATIONINSIGHTS_AUTHENTICATION_STRING'
          value: 'Authorization=AAD'
        }
        {
          name: 'COSMOS_ENDPOINT'
          value: cosmos.properties.documentEndpoint
        }
        {
          name: 'COSMOS_DATABASE'
          value: databaseName
        }
        {
          name: 'COSMOS_CONTAINER'
          value: containerName
        }
        {
          name: 'PROJECTION_TENANT_ID'
          value: tenantId
        }
      ]
    }
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${storage.properties.primaryEndpoints.blob}${deploymentContainer}'
          authentication: {
            type: 'SystemAssignedIdentity'
          }
        }
      }
      scaleAndConcurrency: {
        triggers: {
          http: {
            perInstanceConcurrency: httpConcurrency
          }
        }
        maximumInstanceCount: maximumInstanceCount
        instanceMemoryMB: instanceMemoryMB
        alwaysReady: alwaysReadyInstances > 0 ? [
          {
            name: 'http'
            instanceCount: alwaysReadyInstances
          }
        ] : []
      }
      runtime: {
        name: 'node'
        version: '22'
      }
    }
  }
  dependsOn: [
    packageContainer
    storageEndpointDns
  ]
}

// No publishing by user name and password. Deployment is by Entra identity
// only, the same as every other path into this app.
resource scmBasicAuth 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2024-04-01' = {
  parent: site
  name: 'scm'
  properties: {
    allow: false
  }
}

resource ftpBasicAuth 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2024-04-01' = {
  parent: site
  name: 'ftp'
  properties: {
    allow: false
  }
}

resource auth 'Microsoft.Web/sites/config@2024-04-01' = {
  parent: site
  name: 'authsettingsV2'
  properties: {
    platform: {
      enabled: true
    }
    globalValidation: {
      requireAuthentication: true
      // An API, not a web page: no redirect to a sign-in page, just 401.
      unauthenticatedClientAction: 'Return401'
    }
    httpSettings: {
      requireHttps: true
    }
    identityProviders: {
      azureActiveDirectory: {
        enabled: true
        registration: {
          openIdIssuer: 'https://sts.windows.net/${tenantId}/v2.0'
          clientId: resolverAppId
        }
        validation: {
          allowedAudiences: [
            'api://${resolverAppId}'
            resolverAppId
          ]
          defaultAuthorizationPolicy: {
            allowedApplications: allowedCallerAppIds
            allowedPrincipals: empty(allowedCallerObjectIds) ? {} : {
              identities: allowedCallerObjectIds
            }
          }
        }
      }
    }
    login: {
      tokenStore: {
        enabled: false
      }
    }
  }
}

// Read, on the one container, and nothing else. The writer - the sync - has
// its own identity and its own role; a compromised resolver cannot change who
// is entitled.
resource cosmosReader 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2024-05-15' = {
  parent: cosmos
  name: guid(cosmos.id, site.id, cosmosDataReader)
  properties: {
    roleDefinitionId: '${cosmos.id}/sqlRoleDefinitions/${cosmosDataReader}'
    principalId: site.identity.principalId
    scope: '${cosmos.id}/dbs/${databaseName}/colls/${containerName}'
  }
}

resource storageRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storage
  name: guid(storage.id, site.id, storageBlobDataOwner)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataOwner)
    principalId: site.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource telemetryRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: appInsights
  name: guid(appInsights.id, site.id, monitoringMetricsPublisher)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringMetricsPublisher)
    principalId: site.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2023-11-01' = if (isPrivate) {
  name: 'pe-${siteName}'
  location: location
  properties: {
    subnet: {
      id: privateEndpointSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'pe-${siteName}'
        properties: {
          privateLinkServiceId: site.id
          groupIds: [
            'sites'
          ]
        }
      }
    ]
  }
}

resource privateDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = if (isPrivate) {
  parent: privateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'sites'
        properties: {
          privateDnsZoneId: sitesDnsZoneId
        }
      }
    ]
  }
}

output siteName string = site.name
output resolverUrl string = 'https://${site.properties.defaultHostName}/api'
output resolverAudience string = 'api://${resolverAppId}'
output principalId string = site.identity.principalId
output storageName string = storage.name
output inboundAccessChosen string = inboundAccess
