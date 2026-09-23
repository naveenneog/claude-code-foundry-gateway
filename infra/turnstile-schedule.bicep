// The Turnstile export and sync on a schedule, as a managed identity with no secret.
//
// An Azure Container Apps job that starts on a cron schedule, runs one pass and exits. It
// holds no credential: it signs in as its own user-assigned managed identity, fetches this
// repository's scripts at a pinned commit, and reads everything else from the gateway's
// `turnstile-integration` named value. Grants are made by Connect-ClaudeTurnstile.ps1
// -ExporterPrincipalId <principalId output>, not here, so what the identity may do is
// decided in one place. scripts/Register-ClaudeTurnstileSchedule.ps1 deploys this and
// makes the grants in one command. docs/TURNSTILE.md, "Run it on a schedule".

@description('Region for the job. Defaults to the resource group\'s.')
param location string = resourceGroup().location

@description('The gateway\'s resource group, where its named values live.')
param gatewayResourceGroup string = resourceGroup().name

@description('The gateway\'s API Management instance.')
param gatewayApimName string

@description('Subscription the gateway is in, selected after the identity signs in.')
param subscriptionId string = subscription().subscriptionId

@description('Log Analytics workspace that receives the job\'s console output.')
param workspaceResourceId string

@description('Public Git repository holding the scripts.')
param repositoryUrl string

@description('The commit to run. A commit id rather than a branch, so what runs cannot change without a redeploy.')
param repositoryRef string

@description('When to run, in UTC. Hourly at seven minutes past by default: the export ends 15 minutes before it starts and looks back 120, so consecutive runs overlap.')
param cronExpression string = '7 * * * *'

@description('Also keep units, teams and budgets in step with Turnstile after each export.')
param governance bool = true

@description('Container image. It provides the Azure CLI; PowerShell is added at start.')
param image string = 'mcr.microsoft.com/azure-cli:2.90.0'

@description('PowerShell version added at start.')
param powershellVersion string = '7.6.6'

var suffix = take(uniqueString(resourceGroup().id, gatewayApimName), 8)

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-turnstile-${suffix}'
  location: location
}

resource environment 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: 'cae-turnstile-${suffix}'
  location: location
  properties: {
    // Logs go through a diagnostic setting rather than the workspace's shared key, so no key
    // is read or stored.
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

resource logs 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'job-console-to-workspace'
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

// PowerShell comes from its published release rather than a custom image, so there is no
// registry to run and nothing to rebuild when the scripts change.
var bootstrap = '''
set -euo pipefail
echo "turnstile schedule: start $(date -u +%Y-%m-%dT%H:%M:%SZ), commit ${REPO_REF}"
tdnf install -y git tar gzip libstdc++ >/dev/null 2>&1 || true
curl -fsSL "https://github.com/PowerShell/PowerShell/releases/download/v${PWSH_VERSION}/powershell-${PWSH_VERSION}-linux-x64.tar.gz" -o /tmp/pwsh.tgz
mkdir -p /opt/pwsh && tar -xzf /tmp/pwsh.tgz -C /opt/pwsh && chmod +x /opt/pwsh/pwsh
mkdir -p /work && cd /work && git init -q && git fetch -q --depth 1 "${REPO_URL}" "${REPO_REF}" && git checkout -q FETCH_HEAD
az login --identity --client-id "${AZURE_CLIENT_ID}" --allow-no-subscriptions --output none
az account set --subscription "${SUBSCRIPTION_ID}"
extra=""
if [ "${TURNSTILE_GOVERNANCE}" != "true" ]; then extra="-SkipGovernance"; fi
/opt/pwsh/pwsh -NoProfile -File ./scripts/Invoke-ClaudeTurnstileSchedule.ps1 -ResourceGroup "${CLAUDE_RG}" -ApimName "${CLAUDE_APIM}" ${extra}
'''

resource job 'Microsoft.App/jobs@2024-03-01' = {
  name: 'job-turnstile-${suffix}'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identity.id}': {}
    }
  }
  properties: {
    environmentId: environment.id
    workloadProfileName: 'Consumption'
    configuration: {
      triggerType: 'Schedule'
      replicaTimeout: 1800
      // No retry: the next run's window overlaps this one's, so a failed run is recovered by
      // the next rather than repeated.
      replicaRetryLimit: 0
      scheduleTriggerConfig: {
        cronExpression: cronExpression
        parallelism: 1
        replicaCompletionCount: 1
      }
    }
    template: {
      containers: [
        {
          name: 'turnstile'
          image: image
          command: [
            '/bin/bash'
            '-c'
            bootstrap
          ]
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          env: [
            { name: 'AZURE_CLIENT_ID', value: identity.properties.clientId }
            { name: 'SUBSCRIPTION_ID', value: subscriptionId }
            { name: 'CLAUDE_RG', value: gatewayResourceGroup }
            { name: 'CLAUDE_APIM', value: gatewayApimName }
            { name: 'REPO_URL', value: repositoryUrl }
            { name: 'REPO_REF', value: repositoryRef }
            { name: 'PWSH_VERSION', value: powershellVersion }
            { name: 'TURNSTILE_GOVERNANCE', value: governance ? 'true' : 'false' }
            // PowerShell's globalization needs ICU, which the image does not carry. Invariant
            // mode is enough: the scripts format numbers, not locale-specific text.
            { name: 'DOTNET_SYSTEM_GLOBALIZATION_INVARIANT', value: '1' }
          ]
        }
      ]
    }
  }
}

output principalId string = identity.properties.principalId
output clientId string = identity.properties.clientId
output jobName string = job.name
output environmentName string = environment.name
