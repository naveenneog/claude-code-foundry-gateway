targetScope = 'resourceGroup'

param name string
param location string = resourceGroup().location
param ownerId string
param subnetId string
param backendHostName string
param listenerHostName string
param certificateSecretId string
param identityId string
param workspaceId string
param globalWafPolicyId string
param messagesWafPolicyId string
param messagesPaths array
param publicIpId string = ''
param privateFrontendIp string = ''

@allowed([
  'public'
  'private'
  'hybrid'
])
param networkProfile string

@minValue(21)
@maxValue(86400)
param backendTimeoutSeconds int = 600

@minValue(1)
@maxValue(10)
param minimumCapacity int = 2
@minValue(2)
@maxValue(125)
param maximumCapacity int = 10
param zones array = []

var gatewayId = resourceId('Microsoft.Network/applicationGateways', name)
var hasPublic = networkProfile != 'private'
var hasPrivate = networkProfile != 'public'
var frontends = concat(hasPublic ? [
  {
    name: 'public'
    properties: {
      publicIPAddress: {
        id: publicIpId
      }
    }
  }
] : [], hasPrivate ? [
  {
    name: 'private'
    properties: {
      privateIPAllocationMethod: 'Static'
      privateIPAddress: privateFrontendIp
      subnet: {
        id: subnetId
      }
    }
  }
] : [])

resource gateway 'Microsoft.Network/applicationGateways@2024-05-01' = {
  name: name
  location: location
  zones: zones
  tags: {
    'claude-network-owner': ownerId
  }
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identityId}': {}
    }
  }
  properties: {
    sku: {
      name: 'WAF_v2'
      tier: 'WAF_v2'
    }
    autoscaleConfiguration: {
      minCapacity: minimumCapacity
      maxCapacity: maximumCapacity
    }
    enableHttp2: true
    globalConfiguration: {
      enableRequestBuffering: true
      enableResponseBuffering: false
    }
    sslPolicy: {
      policyType: 'Predefined'
      policyName: 'AppGwSslPolicy20220101S'
    }
    gatewayIPConfigurations: [
      {
        name: 'edge-subnet'
        properties: {
          subnet: {
            id: subnetId
          }
        }
      }
    ]
    frontendIPConfigurations: frontends
    frontendPorts: [
      {
        name: 'https'
        properties: {
          port: 443
        }
      }
    ]
    sslCertificates: [
      {
        name: 'listener'
        properties: {
          keyVaultSecretId: certificateSecretId
        }
      }
    ]
    backendAddressPools: [
      {
        name: 'apim'
        properties: {
          backendAddresses: [
            {
              fqdn: backendHostName
            }
          ]
        }
      }
    ]
    backendHttpSettingsCollection: [
      {
        name: 'apim-https'
        properties: {
          port: 443
          protocol: 'Https'
          cookieBasedAffinity: 'Disabled'
          pickHostNameFromBackendAddress: true
          requestTimeout: backendTimeoutSeconds
          connectionDraining: {
            enabled: true
            drainTimeoutInSec: 600
          }
          probe: {
            id: '${gatewayId}/probes/apim-status'
          }
        }
      }
    ]
    probes: [
      {
        name: 'apim-status'
        properties: {
          protocol: 'Https'
          path: '/status-0123456789abcdef'
          pickHostNameFromBackendHttpSettings: true
          interval: 30
          timeout: 30
          unhealthyThreshold: 3
          match: {
            statusCodes: [
              '200'
            ]
          }
        }
      }
    ]
    httpListeners: [for frontend in frontends: {
      name: '${frontend.name}-https'
      properties: {
        frontendIPConfiguration: {
          id: '${gatewayId}/frontendIPConfigurations/${frontend.name}'
        }
        frontendPort: {
          id: '${gatewayId}/frontendPorts/https'
        }
        protocol: 'Https'
        hostName: listenerHostName
        requireServerNameIndication: true
        sslCertificate: {
          id: '${gatewayId}/sslCertificates/listener'
        }
      }
    }]
    rewriteRuleSets: [
      {
        name: 'trusted-client-address'
        properties: {
          rewriteRules: [
            {
              name: 'replace-client-address'
              ruleSequence: 10
              actionSet: {
                requestHeaderConfigurations: [
                  {
                    headerName: 'X-Claude-Client-IP'
                    headerValue: '{var_client_ip}'
                  }
                  {
                    headerName: 'X-Forwarded-For'
                    headerValue: '{var_client_ip}'
                  }
                ]
              }
            }
          ]
        }
      }
    ]
    urlPathMaps: [
      {
        name: 'claude'
        properties: {
          defaultBackendAddressPool: {
            id: '${gatewayId}/backendAddressPools/apim'
          }
          defaultBackendHttpSettings: {
            id: '${gatewayId}/backendHttpSettingsCollection/apim-https'
          }
          defaultRewriteRuleSet: {
            id: '${gatewayId}/rewriteRuleSets/trusted-client-address'
          }
          pathRules: [
            {
              name: 'messages'
              properties: {
                paths: messagesPaths
                backendAddressPool: {
                  id: '${gatewayId}/backendAddressPools/apim'
                }
                backendHttpSettings: {
                  id: '${gatewayId}/backendHttpSettingsCollection/apim-https'
                }
                rewriteRuleSet: {
                  id: '${gatewayId}/rewriteRuleSets/trusted-client-address'
                }
                firewallPolicy: {
                  id: messagesWafPolicyId
                }
              }
            }
          ]
        }
      }
    ]
    requestRoutingRules: [for (frontend, index) in frontends: {
      name: '${frontend.name}-route'
      properties: {
        priority: 100 + index
        ruleType: 'PathBasedRouting'
        httpListener: {
          id: '${gatewayId}/httpListeners/${frontend.name}-https'
        }
        urlPathMap: {
          id: '${gatewayId}/urlPathMaps/claude'
        }
      }
    }]
    firewallPolicy: {
      id: globalWafPolicyId
    }
    forceFirewallPolicyAssociation: true
  }
}

resource diagnostic 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'network-edge'
  scope: gateway
  properties: {
    workspaceId: workspaceId
    logAnalyticsDestinationType: 'Dedicated'
    logs: [
      {
        category: 'ApplicationGatewayAccessLog'
        enabled: true
      }
      {
        category: 'ApplicationGatewayFirewallLog'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

output id string = gateway.id
output endpoint string = 'https://${listenerHostName}'
