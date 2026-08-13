metadata description = 'Governed gateway for Claude Code on Microsoft Foundry: per-developer token budgets, tiering, and chargeback, with no model credential on any developer machine.'

targetScope = 'resourceGroup'

@description('Base name used to derive resource names. Must be globally unique for the API Management instance.')
@minLength(4)
@maxLength(28)
param namePrefix string = 'claudegw${uniqueString(resourceGroup().id)}'

@description('Location for all resources.')
param location string = resourceGroup().location

@description('Name of the existing Microsoft Foundry (AIServices) account that hosts your Claude deployments.')
param foundryAccountName string

@description('Resource group of the Foundry account. Defaults to this resource group.')
param foundryResourceGroup string = resourceGroup().name

@description('Publisher email shown on the API Management instance.')
param publisherEmail string

@description('Publisher name shown on the API Management instance.')
param publisherName string = 'AI Platform Team'

@description('API Management SKU. Anthropic Messages API token parsing requires a v2 tier; classic tiers count zero tokens and budgets never trigger.')
@allowed([
  'BasicV2'
  'StandardV2'
  'PremiumV2'
])
param apimSku string = 'BasicV2'

@description('API Management scale units.')
@minValue(1)
param apimCapacity int = 1

@description('Deployment name of the Sonnet-class model in Foundry.')
param sonnetDeployment string = 'claude-sonnet-5'

@description('Deployment name of the Opus-class model in Foundry.')
param opusDeployment string = 'claude-opus-5'

@description('Deployment used for the haiku alias and background tasks. Point at your Sonnet deployment if you have no Haiku deployment.')
param haikuDeployment string = 'claude-sonnet-5'

@description('Standard tier: tokens per minute, per developer.')
param tpmStandard int = 20000

@description('Standard tier: tokens per day, per developer.')
param quotaStandard int = 500000

@description('Premium tier: tokens per minute, per developer.')
param tpmPremium int = 80000

@description('Premium tier: tokens per day, per developer.')
param quotaPremium int = 5000000

@description('Request-rate ceiling per developer per minute. Stops a runaway agent loop that makes many small calls.')
param callsPerMinute int = 120

@description('Object ids allowed at the standard tier. Normally left empty and populated by Sync-ClaudeAccess.ps1 from an Entra group.')
param allowStandardOids array = []

@description('Object ids allowed at the premium tier.')
param allowPremiumOids array = []

var apimName = 'apim-${namePrefix}'
var appInsightsName = 'appi-${namePrefix}'
var workspaceName = 'log-${namePrefix}'
var apiId = 'claude-foundry'
var apiPath = 'claude'

// Sentinel commas make the policy's contains() check exact, so one object id
// cannot partially match another.
var allowStandardValue = ',${join(allowStandardOids, ',')},'
var allowPremiumValue = ',${join(allowPremiumOids, ',')},'

resource foundry 'Microsoft.CognitiveServices/accounts@2024-10-01' existing = {
  name: foundryAccountName
  scope: resourceGroup(foundryResourceGroup)
}

// ---------------------------------------------------------------------------
// Observability
// ---------------------------------------------------------------------------

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: workspaceName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: workspace.id
    IngestionMode: 'LogAnalytics'
    // Without WithDimensions the token metrics arrive as bare totals and the
    // per-developer breakdown that chargeback depends on is silently dropped.
    // The Bicep type definition omits this property, but the REST API accepts
    // it; see https://aka.ms/bicep-type-issues.
    #disable-next-line BCP037
    CustomMetricsOptedInType: 'WithDimensions'
  }
}

// ---------------------------------------------------------------------------
// Gateway
// ---------------------------------------------------------------------------

resource apim 'Microsoft.ApiManagement/service@2024-05-01' = {
  name: apimName
  location: location
  sku: {
    name: apimSku
    capacity: apimCapacity
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publisherEmail: publisherEmail
    publisherName: publisherName
  }
}

resource apimLogger 'Microsoft.ApiManagement/service/loggers@2024-05-01' = {
  parent: apim
  name: 'appinsights'
  properties: {
    loggerType: 'applicationInsights'
    description: 'Token metrics and request logs for the Claude gateway'
    resourceId: appInsights.id
    credentials: {
      instrumentationKey: appInsights.properties.InstrumentationKey
    }
  }
}

resource api 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  parent: apim
  name: apiId
  properties: {
    displayName: 'Claude on Foundry (governed)'
    path: apiPath
    protocols: [
      'https'
    ]
    serviceUrl: '${foundry.properties.endpoints['AI Foundry API']}anthropic'
    // Authorization comes from the caller's Entra ID token, not an APIM
    // subscription key: Claude Code cannot reliably send a custom key header,
    // and a shared key would destroy per-person attribution.
    subscriptionRequired: false
  }
}

resource messagesOperation 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: api
  name: 'messages'
  properties: {
    displayName: 'Create Message'
    method: 'POST'
    urlTemplate: '/v1/messages'
    responses: [
      {
        statusCode: 200
      }
    ]
  }
}

resource countTokensOperation 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: api
  name: 'count-tokens'
  properties: {
    displayName: 'Count Tokens'
    method: 'POST'
    urlTemplate: '/v1/messages/count_tokens'
    responses: [
      {
        statusCode: 200
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Policy parameters, so budgets are a config change rather than a redeploy
// ---------------------------------------------------------------------------

var namedValues = [
  { key: 'tenant-id', value: subscription().tenantId }
  { key: 'tpm-standard', value: string(tpmStandard) }
  { key: 'quota-standard', value: string(quotaStandard) }
  { key: 'tpm-premium', value: string(tpmPremium) }
  { key: 'quota-premium', value: string(quotaPremium) }
  { key: 'calls-per-minute', value: string(callsPerMinute) }
  { key: 'allow-standard', value: allowStandardValue }
  { key: 'allow-premium', value: allowPremiumValue }
]

resource apimNamedValues 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = [
  for nv in namedValues: {
    parent: apim
    name: nv.key
    properties: {
      displayName: nv.key
      value: nv.value
    }
  }
]

resource apiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-05-01' = {
  parent: api
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('policy.xml')
  }
  dependsOn: [
    apimNamedValues
    messagesOperation
    countTokensOperation
  ]
}

resource apiDiagnostic 'Microsoft.ApiManagement/service/apis/diagnostics@2024-05-01' = {
  parent: api
  name: 'applicationinsights'
  properties: {
    loggerId: apimLogger.id
    alwaysLog: 'allErrors'
    // metrics:true is what makes llm-emit-token-metric actually emit. Without
    // it the custom metric namespace never appears.
    metrics: true
    verbosity: 'information'
    httpCorrelationProtocol: 'W3C'
    sampling: {
      samplingType: 'fixed'
      percentage: 100
    }
  }
}

// ---------------------------------------------------------------------------
// The gateway identity is the only principal that may call Foundry
// ---------------------------------------------------------------------------

module foundryRole 'foundry-role.bicep' = {
  name: 'grant-apim-cognitive-services-user'
  scope: resourceGroup(foundryResourceGroup)
  params: {
    foundryAccountName: foundryAccountName
    principalId: apim.identity.principalId
  }
}

output apimName string = apim.name
output gatewayUrl string = '${apim.properties.gatewayUrl}/${apiPath}'
output apimPrincipalId string = apim.identity.principalId
output appInsightsName string = appInsights.name
output foundryEndpoint string = foundry.properties.endpoints['AI Foundry API']
output claudeCodeSettings object = {
  env: {
    CLAUDE_CODE_USE_FOUNDRY: '1'
    ANTHROPIC_FOUNDRY_BASE_URL: '${apim.properties.gatewayUrl}/${apiPath}'
    ANTHROPIC_DEFAULT_OPUS_MODEL: opusDeployment
    ANTHROPIC_DEFAULT_SONNET_MODEL: sonnetDeployment
    ANTHROPIC_DEFAULT_HAIKU_MODEL: haikuDeployment
  }
}
