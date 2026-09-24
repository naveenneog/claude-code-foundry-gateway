targetScope = 'resourceGroup'

param name string
param location string = resourceGroup().location
param ownerId string
param addressPrefix string
param edgePrefix string
param apimPrefix string
param endpointsPrefix string
param runnerPrefix string
param networkIsolation bool
param edgeRouteTableId string = ''
param apimRouteTableId string = ''
param dnsServers array = []
param ddosProtectionPlanId string = ''
param endpointsNsgId string = ''
param runnerNsgId string = ''

resource edgeNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: '${name}-edge'
  location: location
  tags: {
    'claude-network-owner': ownerId
  }
  properties: {
    securityRules: concat([
      {
        name: 'https'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
    ], networkIsolation ? [] : [
      {
        name: 'gateway-management'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '65200-65535'
          sourceAddressPrefix: 'GatewayManager'
          destinationAddressPrefix: '*'
        }
      }
    ])
  }
}

resource apimNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: '${name}-apim'
  location: location
  tags: {
    'claude-network-owner': ownerId
  }
  properties: {
    securityRules: [
      {
        name: 'key-vault-dependency'
        properties: {
          priority: 100
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: 'AzureKeyVault'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: name
  location: location
  tags: {
    'claude-network-owner': ownerId
  }
  properties: {
    addressSpace: {
      addressPrefixes: [
        addressPrefix
      ]
    }
    dhcpOptions: {
      dnsServers: dnsServers
    }
    enableDdosProtection: !empty(ddosProtectionPlanId)
    ddosProtectionPlan: empty(ddosProtectionPlanId) ? null : {
      id: ddosProtectionPlanId
    }
    subnets: [
      {
        name: 'edge'
        properties: {
          addressPrefix: edgePrefix
          networkSecurityGroup: {
            id: edgeNsg.id
          }
          routeTable: empty(edgeRouteTableId) ? null : {
            id: edgeRouteTableId
          }
          delegations: networkIsolation ? [
            {
              name: 'application-gateway'
              properties: {
                serviceName: 'Microsoft.Network/applicationGateways'
              }
            }
          ] : []
        }
      }
      {
        name: 'apim-integration'
        properties: {
          addressPrefix: apimPrefix
          networkSecurityGroup: {
            id: apimNsg.id
          }
          routeTable: empty(apimRouteTableId) ? null : {
            id: apimRouteTableId
          }
          delegations: [
            {
              name: 'apim'
              properties: {
                serviceName: 'Microsoft.Web/serverFarms'
              }
            }
          ]
        }
      }
      {
        name: 'private-endpoints'
        properties: {
          addressPrefix: endpointsPrefix
          privateEndpointNetworkPolicies: 'Disabled'
          networkSecurityGroup: empty(endpointsNsgId) ? null : {
            id: endpointsNsgId
          }
        }
      }
      {
        name: 'verification'
        properties: {
          addressPrefix: runnerPrefix
          networkSecurityGroup: empty(runnerNsgId) ? null : {
            id: runnerNsgId
          }
          delegations: [
            {
              name: 'container-instance'
              properties: {
                serviceName: 'Microsoft.ContainerInstance/containerGroups'
              }
            }
          ]
        }
      }
    ]
  }
}

output id string = vnet.id
output edgeSubnetId string = '${vnet.id}/subnets/edge'
output apimSubnetId string = '${vnet.id}/subnets/apim-integration'
output endpointsSubnetId string = '${vnet.id}/subnets/private-endpoints'
output runnerSubnetId string = '${vnet.id}/subnets/verification'
