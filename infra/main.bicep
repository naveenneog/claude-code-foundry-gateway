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

// Network and portal state the gateway already has. This template writes the
// service whenever it created it, and an ARM PUT replaces what it does not
// state: a what-if against a Premium v2 gateway with outbound VNet integration
// (2026-09-23) predicted virtualNetworkType External -> None, the
// virtualNetworkConfiguration deleted, publicNetworkAccess and customProperties
// removed, and both portals Disabled -> Enabled. A private deployment would
// then fail every request after an ordinary re-run. Install-ClaudeGateway.ps1
// reads the live values and passes them back, the same way it preserves the
// named values; a new gateway gets the defaults below, which are what Azure
// gives a new v2 instance.
@description('Keep the gateway\'s VNet mode. External with a Microsoft.Web/serverFarms subnet is outbound integration (Standard v2, Premium v2).')
@allowed([
  'None'
  'External'
  'Internal'
])
param apimVirtualNetworkType string = 'None'

@description('Subnet for apimVirtualNetworkType. Empty when None.')
param apimSubnetId string = ''

@allowed([
  'Enabled'
  'Disabled'
])
param apimPublicNetworkAccess string = 'Enabled'

@allowed([
  'Enabled'
  'Disabled'
])
param apimDeveloperPortalStatus string = 'Disabled'

@allowed([
  'Enabled'
  'Disabled'
])
param apimLegacyPortalStatus string = 'Disabled'

@description('Protocol and cipher settings the gateway already has. Empty for a new gateway.')
param apimCustomProperties object = {}

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

@description('Business unit registry to preserve, in sentinel form (",id=Group:tokens,"). Set-ClaudeBusinessUnit.ps1 owns this after the first deployment, so Install-ClaudeGateway.ps1 reads it off the gateway and hands it back rather than resetting it.')
param buRegistryExisting string = ''

@description('Business unit membership to preserve, in sentinel form (",oid=id,"). Sync-ClaudeAccess.ps1 owns this after the first deployment.')
param buMembersExisting string = ''

@description('Business unit parent map to preserve, in sentinel form (",team=parent,"). A unit that names a parent is a team, and a request is charged to the team and to its parent. Set-ClaudeBusinessUnit.ps1 owns this after the first deployment.')
param buParentsExisting string = ''

@description('Budget enforcement exceptions to preserve: ",sales=allowance:10,sales-emea=notify,". Absent units are strict; ",," keeps every budget strict.')
param buModesExisting string = ''

@description('Preserve dated USD budgets (base64 JSON). Empty leaves the optional USD control disabled.')
param usdBudgetsExisting string = ''

@description('Preserve the USD reconciler snapshot (base64 JSON), including stops and its freshness deadline.')
param usdBudgetStateExisting string = ''

@description('What happens to a developer who belongs to no business unit. "allow" serves them and records the usage against no budget; "deny" refuses. The default is allow because no developer has a business unit at the moment this first deploys, and deny would refuse every request. Move to deny once assignment is complete - Get-ClaudeBusinessUnit.ps1 reports how many are unassigned.')
@allowed([
  'allow'
  'deny'
])
param buUnassigned string = 'allow'
@description('Request-rate ceiling per developer per minute. Stops a runaway agent loop that makes many small calls.')
param callsPerMinute int = 120

@description('Where the gateway reads entitlement from. Leave on named-value until a projection exists and the shadow comparison reports no drift - see docs/adr/0013-gateway-outlives-instance.md.')
@allowed([
  'named-value'
  'projection'
])
param entitlementSource string = 'named-value'

@description('Base URL of the entitlement resolver. Only read when entitlementSource is projection. The placeholder is deliberate - an empty named value is awkward to reason about, and this one is obviously unset if it ever appears in a trace.')
param entitlementResolverUrl string = 'https://resolver-not-deployed.invalid'

@description('Entra audience the gateway asks for a managed identity token against, when calling the resolver. Separate from the URL on purpose: the two often differ, and conflating them produces a token the resolver rejects.')
param entitlementResolverAudience string = 'https://resolver-not-deployed.invalid'

@description('How long the gateway may serve an identity the directory has already changed, in seconds. This is the staleness bound, and it also sets the resolver cost, because cost follows cache misses rather than requests.')
@minValue(60)
@maxValue(86400)
param entitlementCacheSeconds int = 3600

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
var buRegistryValue = empty(buRegistryExisting) ? ',,' : buRegistryExisting
var buMembersValue = empty(buMembersExisting) ? ',,' : buMembersExisting
var buParentsValue = empty(buParentsExisting) ? ',,' : buParentsExisting
var buModesValue = empty(buModesExisting) ? ',,' : buModesExisting
var usdBudgetsValue = empty(usdBudgetsExisting) ? 'e30=' : usdBudgetsExisting
var usdBudgetStateValue = empty(usdBudgetStateExisting) ? 'e30=' : usdBudgetStateExisting

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
  properties: union({
    publisherEmail: publisherEmail
    publisherName: publisherName
    virtualNetworkType: apimVirtualNetworkType
    publicNetworkAccess: apimPublicNetworkAccess
    developerPortalStatus: apimDeveloperPortalStatus
    legacyPortalStatus: apimLegacyPortalStatus
  }, empty(apimSubnetId) ? {} : {
    virtualNetworkConfiguration: {
      subnetResourceId: apimSubnetId
    }
  }, empty(apimCustomProperties) ? {} : {
    customProperties: apimCustomProperties
  })
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
  { key: 'bu-registry', value: buRegistryValue }
  { key: 'bu-members', value: buMembersValue }
  { key: 'bu-parents', value: buParentsValue }
  { key: 'bu-modes', value: buModesValue }
  { key: 'usd-budgets', value: usdBudgetsValue }
  { key: 'usd-budget-state', value: usdBudgetStateValue }
  { key: 'bu-unassigned', value: buUnassigned }
  { key: 'calls-per-minute', value: string(callsPerMinute) }
  { key: 'allow-standard', value: allowStandardValue }
  { key: 'allow-premium', value: allowPremiumValue }
  // Where the gateway reads entitlement from. 'named-value' is the list path
  // this has always used; 'projection' is the resolver path from ADR-0011.
  //
  // Both paths live in the policy from this deployment onward, so moving a
  // gateway that is already carrying traffic is a change to this value and not
  // a policy deployment - see ADR-0013. The default keeps every existing
  // deployment on exactly the path it is on today.
  { key: 'entitlement-source', value: entitlementSource }
  { key: 'entitlement-resolver-url', value: entitlementResolverUrl }
  { key: 'entitlement-resolver-audience', value: entitlementResolverAudience }
  // How long the gateway may serve an identity the directory has already
  // changed. This is the staleness bound ADR-0005 requires, and it is also what
  // sets the resolver's cost, because cost follows cache misses.
  { key: 'entitlement-cache-seconds', value: string(entitlementCacheSeconds) }
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
    // The per-request chargeback ledger. The table is
    // ApiManagementGatewayLlmLog, which unlike a custom metric has no
    // cardinality cap and is correct for streamed requests - measured
    // 2026-09-15, where the quota scalar reported 11 tokens for a 41-token
    // streamed completion and the log reported 11 prompt and 30 completion.
    //
    // requests and responses are deliberately left unset. The table has
    // RequestMessages and ResponseMessages columns, and filling them would be
    // content capture through the back door. P15 keeps that opt-in.
    largeLanguageModel: {
      logs: 'enabled'
    }
    verbosity: 'information'
    httpCorrelationProtocol: 'W3C'
    sampling: {
      samplingType: 'fixed'
      percentage: 100
    }
  }
}

// ---------------------------------------------------------------------------
// Chargeback ledger - the resource log half
// ---------------------------------------------------------------------------

// GatewayLlmLogs is what populates ApiManagementGatewayLlmLog in the workspace.
// The API diagnostic above turns LLM logging on; this decides where the rows
// land. Both are needed - enabling only one and testing found an empty table.
//
// Only this category is enabled. GatewayLogs would add a row per request for
// every API on the instance, which is an ingestion bill for data this ledger
// does not read.
resource llmLogs 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'claude-llm-logs'
  scope: apim
  properties: {
    workspaceId: workspace.id
    logAnalyticsDestinationType: 'Dedicated'
    logs: [
      {
        category: 'GatewayLlmLogs'
        enabled: true
      }
    ]
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
