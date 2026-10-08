@description('Deploys a five-minute USD budget reconciler job for gateways that do not use the AUM service.')
param location string = resourceGroup().location

@description('Existing gateway API Management resource ID.')
param gatewayResourceId string

@description('Existing Log Analytics workspace ARM resource ID.')
param workspaceResourceId string

@description('Log Analytics workspace customer ID used by the reconciler query API.')
param workspaceCustomerId string

@description('Public Git repository holding this accelerator.')
param repositoryUrl string

@description('Full commit ID to run; branches and tags are refused by the caller.')
param repositoryRef string

@description('Five-minute UTC cron for the scheduled reconciler.')
param cronExpression string = '*/5 * * * *'

@description('Container image. It provides Python for the reconciler. The tag is pinned.')
param image string = 'python:3.12.11-slim-bookworm'

@description('Optional existing Container Apps environment. Empty creates a dedicated Consumption environment.')
param existingEnvironmentId string = ''

@description('Tags applied to owned resources.')
param tags object = {}

var suffix = take(uniqueString(resourceGroup().id, gatewayResourceId, workspaceResourceId), 10)
var gatewayName = last(split(gatewayResourceId, '/'))
var workspaceName = last(split(workspaceResourceId, '/'))

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-usd-reconcile-${suffix}'
  location: location
  tags: tags
}

resource environment 'Microsoft.App/managedEnvironments@2024-03-01' = if (empty(existingEnvironmentId)) {
  name: 'cae-usd-reconcile-${suffix}'
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'azure-monitor'
    }
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
  }
}

resource logs 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (empty(existingEnvironmentId)) {
  name: 'usd-reconciler-console'
  scope: environment
  properties: {
    workspaceId: workspaceResourceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
  }
}

resource gateway 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: gatewayName
}

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: workspaceName
}

resource workspaceReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(workspaceResourceId, identity.id, 'usd-reconcile-workspace-reader')
  scope: workspace
  properties: {
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '73c42c96-874c-492b-b04d-ab87d138a893')
  }
}

resource writerRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: guid(gatewayResourceId, 'usd-reconciler-writer')
  properties: {
    roleName: 'Claude USD reconciler writer ${suffix}'
    type: 'CustomRole'
    description: 'Reads and writes only APIM named values for the scheduled USD budget reconciler.'
    assignableScopes: [
      resourceGroup().id
    ]
    permissions: [
      {
        actions: [
          'Microsoft.ApiManagement/service/read'
          'Microsoft.ApiManagement/service/namedValues/read'
          'Microsoft.ApiManagement/service/namedValues/write'
          'Microsoft.ApiManagement/service/operationresults/read'
        ]
        notActions: []
        dataActions: []
        notDataActions: []
      }
    ]
  }
}

resource gatewayWriter 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(gateway.id, identity.id, 'usd-reconcile-named-values')
  scope: gateway
  properties: {
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: writerRole.id
  }
}

var bootstrap = '''
set -euo pipefail
echo "usd reconciler: start $(date -u +%Y-%m-%dT%H:%M:%SZ), commit ${REPO_REF}"
mkdir -p /work
cd /work
python3 - <<'PY'
import glob
import os
import shutil
import tarfile
import urllib.request

repo = os.environ["REPO_URL"].removesuffix(".git")
ref = os.environ["REPO_REF"]
archive = f"{repo}/archive/{ref}.tar.gz"
urllib.request.urlretrieve(archive, "repo.tgz")
with tarfile.open("repo.tgz", "r:gz") as package:
    package.extractall(".")
extracted = glob.glob("claude-code-foundry-gateway-*")
if len(extracted) != 1:
    raise SystemExit(f"Expected one extracted repository, found {extracted!r}")
if os.path.exists("repo"):
    shutil.rmtree("repo")
os.rename(extracted[0], "repo")
PY
cd repo
python3 -m pip --version >/dev/null 2>&1 || python3 -m ensurepip --upgrade
python3 -m pip install -q -r service/aum/requirements.txt
PYTHONPATH=service/aum python3 -m aum_service.usd_command --gateway-id "${GATEWAY_ID}" --workspace-id "${WORKSPACE_ID}" --managed-identity
'''

resource job 'Microsoft.App/jobs@2024-03-01' = {
  name: 'job-usd-reconcile-${suffix}'
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identity.id}': {}
    }
  }
  properties: {
    environmentId: empty(existingEnvironmentId) ? environment.id : existingEnvironmentId
    workloadProfileName: 'Consumption'
    configuration: {
      replicaTimeout: 1800
      replicaRetryLimit: 0
      triggerType: 'Schedule'
      scheduleTriggerConfig: {
        cronExpression: cronExpression
        parallelism: 1
        replicaCompletionCount: 1
      }
    }
    template: {
      containers: [
        {
          name: 'usd-reconciler'
          image: image
          command: [
            '/bin/bash'
            '-c'
            replace(bootstrap, '\r', '')
          ]
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          env: [
            { name: 'AZURE_CLIENT_ID', value: identity.properties.clientId }
            { name: 'REPO_URL', value: repositoryUrl }
            { name: 'REPO_REF', value: repositoryRef }
            { name: 'GATEWAY_ID', value: gatewayResourceId }
            { name: 'WORKSPACE_ID', value: workspaceCustomerId }
            { name: 'DOTNET_SYSTEM_GLOBALIZATION_INVARIANT', value: '1' }
          ]
        }
      ]
    }
  }
  dependsOn: [
    gatewayWriter
    workspaceReader
  ]
}

output jobName string = job.name
output environmentName string = empty(existingEnvironmentId) ? environment.name : last(split(existingEnvironmentId, '/'))
output identityId string = identity.id
output principalId string = identity.properties.principalId
output clientId string = identity.properties.clientId
output gatewayRoleDefinitionId string = writerRole.id
output cronExpression string = cronExpression
