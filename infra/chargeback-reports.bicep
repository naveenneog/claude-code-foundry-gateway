@description('Reports run in a dedicated Consumption environment, separate from Turnstile.')
param location string = resourceGroup().location
param gatewayApimName string
param workspaceResourceId string
param repositoryUrl string
param repositoryRef string
param cronExpression string = '0 6 1 * *'
param operatorObjectId string
@allowed(['User', 'ServicePrincipal'])
param operatorPrincipalType string = 'User'
param retentionDays int = 400
param image string = 'mcr.microsoft.com/azure-cli:2.90.0'
param powershellVersion string = '7.6.6'

var suffix = take(uniqueString(resourceGroup().id, gatewayApimName, 'reports'), 10)
var tags = {
  'claude-chargeback-gateway': gatewayApimName
  'claude-chargeback-owner': 'P50'
}
resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-reports-${suffix}'
  location: location
  tags: tags
}
resource adminIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-reports-admin-${suffix}'
  location: location
  tags: tags
}
resource network 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: 'vnet-reports-${suffix}'
  location: location
  tags: tags
  properties: {
    addressSpace: { addressPrefixes: ['10.87.0.0/24'] }
    subnets: [
      {
        name: 'jobs'
        properties: {
          addressPrefix: '10.87.0.0/26'
          delegations: [{ name: 'container-apps', properties: { serviceName: 'Microsoft.App/environments' } }]
        }
      }
      {
        name: 'endpoints'
        properties: { addressPrefix: '10.87.0.64/27', privateEndpointNetworkPolicies: 'Disabled' }
      }
    ]
  }
}
resource privateDns 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  // Azure public cloud: privatelink.blob.core.windows.net.
  name: 'privatelink.blob.${az.environment().suffixes.storage}'
  location: 'global'
  tags: tags
}
resource dnsLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: privateDns
  name: 'reports-${suffix}'
  location: 'global'
  properties: { registrationEnabled: false, virtualNetwork: { id: network.id } }
}
resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: 'streports${suffix}'
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: { name: 'Standard_LRS' }
  properties: {
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    publicNetworkAccess: 'Disabled'
    defaultToOAuthAuthentication: true
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    accessTier: 'Hot'
  }
}
resource endpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: 'pe-reports-blob-${suffix}'
  location: location
  tags: tags
  properties: {
    subnet: { id: '${network.id}/subnets/endpoints' }
    privateLinkServiceConnections: [{
      name: 'report-blobs'
      properties: { privateLinkServiceId: storage.id, groupIds: ['blob'] }
    }]
  }
}
resource dnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: endpoint
  name: 'default'
  properties: { privateDnsZoneConfigs: [{ name: 'blob', properties: { privateDnsZoneId: privateDns.id } }] }
}
resource blobs 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
  properties: {
    isVersioningEnabled: true
    deleteRetentionPolicy: { enabled: true, days: 7 }
    containerDeleteRetentionPolicy: { enabled: true, days: 7 }
  }
}
resource containers 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = [for name in ['configuration', 'reports']: {
  parent: blobs
  name: name
  properties: { publicAccess: 'None' }
}]
resource lifecycle 'Microsoft.Storage/storageAccounts/managementPolicies@2023-05-01' = {
  parent: storage
  name: 'default'
  properties: {
    policy: {
      rules: [
        {
          name: 'report-retention'
          enabled: true
          type: 'Lifecycle'
          definition: {
            filters: { blobTypes: ['blockBlob'], prefixMatch: ['reports/runs/', 'reports/outbox/'] }
            actions: {
              baseBlob: { delete: { daysAfterModificationGreaterThan: retentionDays } }
              version: { delete: { daysAfterCreationGreaterThan: retentionDays } }
              snapshot: { delete: { daysAfterCreationGreaterThan: retentionDays } }
            }
          }
        }
        {
          name: 'configuration-history'
          enabled: true
          type: 'Lifecycle'
          definition: {
            filters: { blobTypes: ['blockBlob'], prefixMatch: ['configuration/'] }
            actions: { version: { delete: { daysAfterCreationGreaterThan: retentionDays } } }
          }
        }
      ]
    }
  }
}
resource email 'Microsoft.Communication/emailServices@2023-03-31' = {
  name: 'email-reports-${suffix}'
  location: 'global'
  tags: tags
  properties: { dataLocation: 'United States' }
}
resource domain 'Microsoft.Communication/emailServices/domains@2023-03-31' = {
  parent: email
  name: 'AzureManagedDomain'
  location: 'global'
  properties: { domainManagement: 'AzureManaged', userEngagementTracking: 'Disabled' }
}
resource communication 'Microsoft.Communication/communicationServices@2023-03-31' = {
  name: 'acs-reports-${suffix}'
  location: 'global'
  tags: tags
  properties: { dataLocation: 'United States', linkedDomains: [domain.id] }
}
resource environment 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: 'cae-reports-${suffix}'
  location: location
  tags: tags
  properties: {
    vnetConfiguration: { infrastructureSubnetId: '${network.id}/subnets/jobs' }
    appLogsConfiguration: { destination: 'azure-monitor' }
    workloadProfiles: [{ name: 'Consumption', workloadProfileType: 'Consumption' }]
  }
}
resource logs 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: environment
  name: 'reports-console'
  properties: {
    workspaceId: workspaceResourceId
    logs: [{ categoryGroup: 'allLogs', enabled: true }]
  }
}
resource gateway 'Microsoft.ApiManagement/service@2024-05-01' existing = { name: gatewayApimName }
resource gatewayRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: guid(resourceGroup().id, gatewayApimName, 'reports-catalog-reader')
  properties: {
    roleName: 'Claude reports catalog reader ${suffix}'
    type: 'CustomRole'
    description: 'Read current non-secret budget catalog. No gateway writes or secret-list action.'
    assignableScopes: [resourceGroup().id]
    permissions: [{ actions: ['Microsoft.ApiManagement/service/namedValues/read'], notActions: [], dataActions: [], notDataActions: [] }]
  }
}
resource emailRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: guid(resourceGroup().id, gatewayApimName, 'reports-email-sender')
  properties: {
    roleName: 'Claude reports email sender ${suffix}'
    type: 'CustomRole'
    description: 'Entra email authorization at the dedicated ACS resource; no keys or delete. ACS has no send-only data action.'
    assignableScopes: [resourceGroup().id]
    permissions: [{
      actions: ['Microsoft.Communication/CommunicationServices/Read', 'Microsoft.Communication/CommunicationServices/Write']
      notActions: []
      dataActions: []
      notDataActions: []
    }]
  }
}
resource catalogReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(gateway.id, identity.id, 'reports-catalog')
  scope: gateway
  properties: { principalId: identity.properties.principalId, principalType: 'ServicePrincipal', roleDefinitionId: gatewayRole.id }
}
resource sender 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(communication.id, identity.id, 'reports-send')
  scope: communication
  properties: { principalId: identity.properties.principalId, principalType: 'ServicePrincipal', roleDefinitionId: emailRole.id }
}
// Storage Blob Data Reader for configuration; Storage Blob Data Contributor for archive/outbox.
resource workerBlobRoles 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for (name, i) in ['configuration', 'reports']: {
  name: guid(containers[i].id, identity.id)
  scope: containers[i]
  properties: {
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', i == 0 ? '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1' : 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
  }
}]
resource operatorBlobRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, operatorObjectId, 'reports-operator')
  scope: storage
  properties: {
    principalId: operatorObjectId
    principalType: operatorPrincipalType
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
  }
}
resource adminBlobRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(containers[0].id, adminIdentity.id, 'reports-config-writer')
  scope: containers[0]
  properties: {
    principalId: adminIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
  }
}
module workspaceReader 'chargeback-workspace-role.bicep' = {
  name: 'reports-workspace-${suffix}'
  scope: resourceGroup(split(workspaceResourceId, '/')[2], split(workspaceResourceId, '/')[4])
  params: { workspaceName: split(workspaceResourceId, '/')[8], principalId: identity.properties.principalId }
}
var bootstrap = '''
set -euo pipefail
echo "reports: start $(date -u +%Y-%m-%dT%H:%M:%SZ), commit ${REPO_REF}, mode ${REPORT_MODE}"
tdnf install -y git tar gzip libstdc++ >/dev/null 2>&1
mkdir -p /work /opt/pwsh
cd /work
curl -fsSL "https://github.com/PowerShell/PowerShell/releases/download/v${PWSH_VERSION}/powershell-${PWSH_VERSION}-linux-x64.tar.gz" -o pwsh.tgz
tar -xzf pwsh.tgz -C /opt/pwsh && chmod +x /opt/pwsh/pwsh && rm pwsh.tgz
git init -q && git fetch -q --depth 1 "${REPO_URL}" "${REPO_REF}" && git checkout -q FETCH_HEAD
az login --identity --client-id "${AZURE_CLIENT_ID}" --allow-no-subscriptions --output none
az account set --subscription "${SUBSCRIPTION_ID}"
/opt/pwsh/pwsh -NoProfile -File ./scripts/Invoke-ClaudeChargebackSchedule.ps1 -Mode "${REPORT_MODE}" -StorageAccount "${REPORT_STORAGE}"
'''
var specs = [
  { name: 'job-reports-${suffix}', mode: 'generator', cron: cronExpression }
  { name: 'job-reports-mail-${suffix}', mode: 'dispatcher', cron: '*/7 * * * *' }
  { name: 'job-reports-admin-${suffix}', mode: 'admin', cron: '' }
]
resource jobs 'Microsoft.App/jobs@2025-01-01' = [for spec in specs: {
  name: spec.name
  location: location
  tags: tags
  identity: { type: 'UserAssigned', userAssignedIdentities: { '${spec.mode == 'admin' ? adminIdentity.id : identity.id}': {} } }
  properties: {
    environmentId: environment.id
    workloadProfileName: 'Consumption'
    configuration: union({
      replicaTimeout: 3600
      replicaRetryLimit: 0
    }, spec.mode == 'generator' ? {
      triggerType: 'Schedule'
      scheduleTriggerConfig: { cronExpression: spec.cron, parallelism: 1, replicaCompletionCount: 1 }
    } : spec.mode == 'admin' ? {
      triggerType: 'Manual'
      manualTriggerConfig: { parallelism: 1, replicaCompletionCount: 1 }
    } : {
      triggerType: 'Event'
      eventTriggerConfig: {
        parallelism: 1
        replicaCompletionCount: 1
        scale: {
          minExecutions: 0
          maxExecutions: 1
          pollingInterval: 420
          rules: [{
            name: 'pending-reports'
            type: 'azure-blob'
            identity: identity.id
            metadata: {
              accountName: storage.name
              blobContainerName: 'reports'
              blobPrefix: 'outbox/'
              blobCount: '1'
              activationBlobCount: '0'
            }
          }]
        }
      }
    })
    template: {
      containers: [{
        name: 'reports'
        image: image
        command: ['/bin/bash', '-c', replace(bootstrap, '\r', '')]
        resources: { cpu: json('1.0'), memory: '2Gi' }
        env: [
          { name: 'AZURE_CLIENT_ID', value: spec.mode == 'admin' ? adminIdentity.properties.clientId : identity.properties.clientId }
          { name: 'SUBSCRIPTION_ID', value: subscription().subscriptionId }
          { name: 'CLAUDE_RG', value: resourceGroup().name }
          { name: 'CLAUDE_APIM', value: gatewayApimName }
          { name: 'CLAUDE_REPORT_WORKSPACE', value: workspaceResourceId }
          { name: 'REPORT_STORAGE', value: storage.name }
          { name: 'REPORT_MODE', value: spec.mode }
          { name: 'REPO_URL', value: repositoryUrl }
          { name: 'REPO_REF', value: repositoryRef }
          { name: 'PWSH_VERSION', value: powershellVersion }
          { name: 'DOTNET_SYSTEM_GLOBALIZATION_INVARIANT', value: '1' }
        ]
      }]
    }
  }
}]
output storageAccount string = storage.name
output endpoint string = 'https://${communication.properties.hostName}'
output senderAddress string = 'DoNotReply@${domain.properties.fromSenderDomain}'
output jobName string = jobs[0].name
output dispatcherJobName string = jobs[1].name
output adminJobName string = jobs[2].name
output environmentName string = environment.name
output principalId string = identity.properties.principalId
output communicationService string = communication.name
output emailService string = email.name
output identityName string = identity.name
output adminIdentityName string = adminIdentity.name
output networkName string = network.name
output privateEndpointName string = endpoint.name
