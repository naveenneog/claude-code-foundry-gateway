targetScope = 'resourceGroup'

param name string
param location string = resourceGroup().location
param ownerId string

@allowed([
  'Detection'
  'Prevention'
])
param wafMode string = 'Prevention'

@description('Select a managed rule set returned by the subscription discovery API.')
param ruleSetType string
param ruleSetVersion string

@description('Rule-scoped exclusions measured for the Messages route, not the global policy.')
param exclusions array = []
param customRules array = []

@minValue(128)
@maxValue(2000)
param bodyLimitKb int = 2000

resource policy 'Microsoft.Network/ApplicationGatewayWebApplicationFirewallPolicies@2024-05-01' = {
  name: name
  location: location
  tags: {
    'claude-network-owner': ownerId
  }
  properties: {
    policySettings: {
      state: 'Enabled'
      mode: wafMode
      requestBodyCheck: true
      requestBodyEnforcement: true
      maxRequestBodySizeInKb: bodyLimitKb
      requestBodyInspectLimitInKB: bodyLimitKb
      fileUploadEnforcement: true
      fileUploadLimitInMb: 100
    }
    customRules: customRules
    managedRules: {
      exclusions: exclusions
      managedRuleSets: [
        {
          ruleSetType: ruleSetType
          ruleSetVersion: ruleSetVersion
        }
      ]
    }
  }
}

output id string = policy.id
