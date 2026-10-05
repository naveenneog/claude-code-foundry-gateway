// Optional entitlement projection sync job for ADR-0051.
// The Container Apps environment is internal and uses its own delegated subnet. The registry and
// the job identity come from infra/projection-registry.bicep, deployed before the image build.

@description('Prefix shared with the projection resources: the same 1-37 characters scripts/Deploy-ClaudeProjection.ps1 accepts.')
@minLength(1)
@maxLength(37)
param namePrefix string

param location string = resourceGroup().location

@description('Cosmos account that owns the claude/entitlement container.')
param cosmosAccountName string

@description('Subnet id delegated to Microsoft.App/environments. Use a separate at-least-/27 subnet, not the resolver subnet.')
param containerAppsSubnetId string

@description('Log Analytics workspace id for job logs and scheduled query alerts.')
param logAnalyticsWorkspaceId string

@description('Email receivers for the required action group. Admission refuses a switch if the deployed action group is missing.')
param actionGroupEmailReceivers array

@description('Registry from infra/projection-registry.bicep that holds the sync image.')
param acrName string

@description('User-assigned identity from infra/projection-registry.bicep that the job runs as.')
param identityName string

@description('Digest-pinned projection sync image, for example sha256:<digest>.')
param syncImageDigest string

@description('Five-field cron expression for an optional scheduled sync. Empty means a manual on-demand job.')
param cronExpression string = ''

@description('Entra tenant id written to every projection record.')
param tenantId string = subscription().tenantId

@description('Object id of the standard tier group. The job reads its members on every run.')
param standardGroupId string

@description('Object id of the premium tier group, or none when the gateway has no premium tier.')
param premiumGroupId string

@description('Resource id of the API Management gateway. The job reads its bu-registry and bu-parents named values on every run.')
param gatewayResourceId string

@description('Expected entrypoint recorded in status and checked before admission.')
param entrypoint string = 'node /app/sync/src/apply-projection.mjs'

var databaseName = 'claude'
var containerName = 'entitlement'
// Container Apps names are 2-32 characters (U118); a literal start and uniqueString's 13 characters fit
// any prefix. The claude-projection-prefix tag names the prefix.
var environmentName = 'cae-renew-${uniqueString(resourceGroup().id, namePrefix)}'
var jobName = 'caj-renew-${uniqueString(resourceGroup().id, namePrefix)}'
var actionGroupName = 'ag-projection-renewal-${namePrefix}'
var isScheduled = !empty(cronExpression)
var tags = {
  'claude-projection-prefix': namePrefix
}

resource cosmos 'Microsoft.DocumentDB/databaseAccounts@2024-05-15' existing = {
  name: cosmosAccountName
}

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: acrName
}

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: identityName
}

resource environment 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: environmentName
  location: location
  tags: tags
  properties: {
    // Console lines reach the workspace through the diagnostic setting below, in the
    // ContainerAppConsoleLogs table with a JobName column (U107). The legacy log-analytics
    // destination would need the workspace's shared key.
    appLogsConfiguration: {
      destination: 'azure-monitor'
    }
    vnetConfiguration: {
      internal: true
      infrastructureSubnetId: containerAppsSubnetId
    }
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
  }
}

resource environmentLogs 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'projection-renewal-console'
  scope: environment
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
  }
}

resource cosmosWriter 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2024-05-15' = {
  parent: cosmos
  name: guid(cosmos.id, identity.id, databaseName, containerName, 'writer')
  properties: {
    principalId: identity.properties.principalId
    roleDefinitionId: '${cosmos.id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002'
    scope: '${cosmos.id}/dbs/${databaseName}/colls/${containerName}'
  }
}

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: actionGroupName
  location: 'global'
  properties: {
    groupShortName: 'projrenew'
    enabled: true
    emailReceivers: [for (receiver, i) in actionGroupEmailReceivers: {
      name: 'email-${i}'
      emailAddress: receiver
      useCommonAlertSchema: true
    }]
  }
}

resource job 'Microsoft.App/jobs@2024-03-01' = {
  name: jobName
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identity.id}': {}
    }
  }
  properties: {
    environmentId: environment.id
    configuration: union({
      triggerType: isScheduled ? 'Schedule' : 'Manual'
      replicaTimeout: 3600
      replicaRetryLimit: 0
      registries: [
        {
          server: acr.properties.loginServer
          identity: identity.id
        }
      ]
    }, isScheduled ? {
      scheduleTriggerConfig: {
        cronExpression: cronExpression
        parallelism: 1
        replicaCompletionCount: 1
      }
    } : {
      manualTriggerConfig: {
        parallelism: 1
        replicaCompletionCount: 1
      }
    })
    template: {
      containers: [
        {
          name: 'projection-renewal'
          image: '${acr.properties.loginServer}/claude-projection-sync@${syncImageDigest}'
          env: [
            {
              name: 'COSMOS_ENDPOINT'
              value: cosmos.properties.documentEndpoint
            }
            {
              name: 'PROJECTION_TENANT_ID'
              value: tenantId
            }
            {
              name: 'PROJECTION_ACCOUNT_RESOURCE_ID'
              value: cosmos.id
            }
            {
              name: 'PROJECTION_IMAGE_DIGEST'
              value: syncImageDigest
            }
            {
              name: 'PROJECTION_ENTRYPOINT'
              value: entrypoint
            }
            {
              // A user-assigned identity only: DefaultAzureCredential needs its client id (U112).
              name: 'AZURE_CLIENT_ID'
              value: identity.properties.clientId
            }
            {
              name: 'PROJECTION_STANDARD_GROUP_ID'
              value: standardGroupId
            }
            {
              name: 'PROJECTION_PREMIUM_GROUP_ID'
              value: premiumGroupId
            }
            {
              name: 'PROJECTION_GATEWAY_RESOURCE_ID'
              value: gatewayResourceId
            }
          ]
          command: []
          args: []
          resources: {
            cpu: 1
            memory: '2Gi'
          }
        }
      ]
    }
  }
  dependsOn: [
    cosmosWriter
    gatewayReader
    environmentLogs
  ]
}

// The gateway may live in another resource group; the read role is created and assigned there.
module gatewayReader 'projection-renewal-gateway-reader.bicep' = {
  name: 'projection-renewal-reader-${namePrefix}'
  scope: resourceGroup(split(gatewayResourceId, '/')[2], split(gatewayResourceId, '/')[4])
  params: {
    gatewayName: last(split(gatewayResourceId, '/'))
    principalId: identity.properties.principalId
    namePrefix: namePrefix
  }
}

// Each rule returns rows only when the optional sync job is unhealthy: a log search alert with Count
// aggregation counts rows, and a summarize without by returns one row even when nothing matched
// (U108). The fuzzy union with an empty table lets a rule deploy before the job's first console
// line exists (U109). The quoted events are the last lines sync/src/apply-projection.mjs prints
// (sync/src/events.mjs); tests/projection-renewal-runs.test.mjs matches them against real runs.
var renewalLogs = '''
union isfuzzy=true (datatable(TimeGenerated: datetime, JobName: string, Log: string) []), ContainerAppConsoleLogs
| where TimeGenerated > ago(45m) and JobName == "{jobName}"
'''

var alertDefinitions = [
  {
    name: 'graph-read-denied'
    description: 'The projection sync job could not read Microsoft Graph. Tenant-admin consent for GroupMember.Read.All may be missing.'
    query: '''
| where Log contains '"event":"projection-renewal-failed"'
| where Log contains '"stage":"graph"'
| project TimeGenerated, Log
'''
  }
  {
    name: 'renewal-failed'
    description: 'A projection sync job run failed: a Graph read was denied or failed, the business-unit read failed, or a Cosmos read or write failed. The line names the stage.'
    query: '''
| where Log contains '"event":"projection-renewal-failed"'
| project TimeGenerated, Log
'''
  }
]

resource noSuccessAlert 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = if (isScheduled) {
  name: 'sqr-projection-${namePrefix}-no-success-45m'
  location: location
  properties: {
    description: 'No successful scheduled projection sync in 45 minutes.'
    enabled: true
    scopes: [
      logAnalyticsWorkspaceId
    ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT45M'
    severity: 2
    criteria: {
      allOf: [
        {
          query: replace('''${renewalLogs}
| where Log contains '"event":"projection-renewal-succeeded"'
| summarize Succeeded = count()
| where Succeeded == 0
''', '{jobName}', jobName)
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [
        actionGroup.id
      ]
    }
  }
}

resource alerts 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = [for alert in alertDefinitions: {
  name: 'sqr-projection-${namePrefix}-${alert.name}'
  location: location
  properties: {
    description: alert.description
    enabled: true
    scopes: [
      logAnalyticsWorkspaceId
    ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT45M'
    severity: 2
    criteria: {
      allOf: [
        {
          query: replace('${renewalLogs}${alert.query}', '{jobName}', jobName)
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [
        actionGroup.id
      ]
    }
  }
}]

output jobName string = job.name
output jobResourceId string = job.id
output managedIdentityClientId string = identity.properties.clientId
output managedIdentityPrincipalId string = identity.properties.principalId
output actionGroupResourceId string = actionGroup.id
output acrLoginServer string = acr.properties.loginServer
output scheduleCron string = cronExpression
output triggerType string = isScheduled ? 'Schedule' : 'Manual'
