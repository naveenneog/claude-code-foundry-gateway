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

@description('Organisation-wide ceiling: total tokens per month across every developer. This is a soft cap - the llm-token-limit policy allows high-concurrency requests to temporarily exceed it, so it bounds spend rather than guaranteeing it. The default is roughly one premium developer\'s month, which fails safe: raise it deliberately before a wider rollout.')
param quotaOrg int = 100000000

@description('Models the standard tier may call, comma-delimited with sentinel commas (",claude-sonnet-5,"). Empty means every deployed model. Enforced at the gateway, before the request reaches Foundry, so it cannot be bypassed by editing a client.')
param modelsStandard string = ''

@description('As modelsStandard, for the premium tier.')
param modelsPremium string = ''

@description('Request-rate ceiling per developer per minute. Stops a runaway agent loop that makes many small calls.')
param callsPerMinute int = 120

@description('Object ids allowed at the standard tier. Normally left empty and populated by Sync-ClaudeAccess.ps1 from an Entra group.')
param allowStandardOids array = []

@description('Object ids allowed at the premium tier.')
param allowPremiumOids array = []

@description('Grant the gateway identity Cognitive Services User on the Foundry account. Set false when an equivalent assignment already exists - Azure rejects a second assignment for the same principal, role and scope even under a different name, which is what a reused gateway hits.')
param grantFoundryRole bool = true

@description('Existing allow list to preserve, in sentinel form (",oid1,oid2,"). Install-ClaudeGateway.ps1 reads this off the gateway before redeploying. Empty means derive from allowStandardOids.')
param allowStandardValueExisting string = ''

@description('As allowStandardValueExisting, for the premium tier.')
param allowPremiumValueExisting string = ''

@description('Existing per-user daily quota overrides to preserve, in sentinel form (",oid=tokens,"). Install-ClaudeGateway.ps1 reads this off the gateway before redeploying so overrides set by Set-ClaudeBudget.ps1 survive. Empty means no overrides.')
param quotaOverridesExisting string = ''

@description('Name of an existing API Management instance to reuse. It must be a v2 SKU and must live in this resource group. Leave empty to create one named apim-{namePrefix}.')
param existingApimName string = ''

var apimName = empty(existingApimName) ? 'apim-${namePrefix}' : existingApimName
var appInsightsName = 'appi-${namePrefix}'
var workspaceName = 'log-${namePrefix}'
var apiId = 'claude-foundry'
var apiPath = 'claude'

// Sentinel commas make the policy's contains() check exact, so one object id
// cannot partially match another.
//
// Entitlement lives in these two named values, and Sync-ClaudeAccess.ps1 owns
// them after the first deployment. The template must therefore never assert its
// own idea of them on a redeploy: `what-if` against a live gateway showed this
// resetting ',<oid>,<oid>,' back to ',,' - silently revoking everyone. The
// installer reads the current values and passes them straight back.
var allowStandardValue = empty(allowStandardValueExisting) ? ',${join(allowStandardOids, ',')},' : allowStandardValueExisting
var allowPremiumValue = empty(allowPremiumValueExisting) ? ',${join(allowPremiumOids, ',')},' : allowPremiumValueExisting

// Per-user daily quota overrides, in the same sentinel form and owned the same
// way: Set-ClaudeBudget.ps1 writes them after the first deployment, so a
// redeploy has to hand back what is already there rather than assert ',,'.
var quotaOverridesValue = empty(quotaOverridesExisting) ? ',,' : quotaOverridesExisting

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

var createApim = empty(existingApimName)

// Two declarations of the same resource, deliberately.
//
// A first attempt simply pointed the existing resource declaration at the
// reused name and let ARM update in place. `what-if` showed why that is wrong:
// a PUT asserts the whole resource, so every property the template does not
// mention is reset to its default. Against a real gateway that meant
// customProperties - the TLS hardening - being cleared, re-enabling TLS 1.0,
// TLS 1.1 and SSL 3.0, plus natGatewayState switched off and both developer
// portals switched on.
//
// So the service is only ever written when this template owns it. When reusing,
// apimNew is skipped entirely and `apim` is a read-only reference, which makes
// the deployment strictly additive: the API, its policies, named values and the
// logger, and nothing else.
resource apimNew 'Microsoft.ApiManagement/service@2024-05-01' = if (createApim) {
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

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimName
}

resource apimLogger 'Microsoft.ApiManagement/service/loggers@2024-05-01' = {
  parent: apim
  name: 'appinsights'
  // `existing` declarations cannot carry dependsOn, so the children state the
  // dependency instead. ARM ignores a dependency on a resource whose condition
  // is false, so this is inert when reusing.
  dependsOn: [
    apimNew
  ]
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
  dependsOn: [
    apimNew
  ]
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
  { key: 'quota-org', value: string(quotaOrg) }
  { key: 'quota-overrides', value: quotaOverridesValue }
  { key: 'models-standard', value: empty(modelsStandard) ? ',,' : modelsStandard }
  { key: 'models-premium', value: empty(modelsPremium) ? ',,' : modelsPremium }
  { key: 'calls-per-minute', value: string(callsPerMinute) }
  { key: 'allow-standard', value: allowStandardValue }
  { key: 'allow-premium', value: allowPremiumValue }
]

resource apimNamedValues 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = [
  for nv in namedValues: {
    parent: apim
    name: nv.key
    dependsOn: [
      apimNew
    ]
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

// Conditional because Azure refuses a second role assignment for the same
// principal, role and scope - even under a different name - and returns
// RoleAssignmentExists. A gateway created by an earlier run, by deploy.ps1, or
// by hand carries an assignment with a random name, whereas this module's name
// is derived from guid(scope, principal, role). Deploying over it collides.
//
// `what-if` does not catch this. A nested deployment at another scope comes
// back as Unsupported, so the plan looked clean and the failure only appeared
// at deploy time.
//
// Install-ClaudeGateway.ps1 checks for an equivalent assignment and passes
// false when one is already in place.
module foundryRole 'foundry-role.bicep' = if (grantFoundryRole) {
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
