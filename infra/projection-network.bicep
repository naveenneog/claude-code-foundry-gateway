// Private networking for the entitlement projection.
//
// Measured 2026-09-17: the reference subscription enforces
// publicNetworkAccess Disabled on Cosmos above the resource group, so the data
// plane is unreachable from anywhere outside a VNet. ADR-0011 records that and
// prices the endpoint; this is the template that actually creates it.
//
// It also creates a container group in the same VNet, because a private
// endpoint on its own does not let anyone test: something has to sit inside the
// network to do the reading. That is the load-test runner, and it is optional -
// set runnerEnabled false for the production shape.

@description('Prefix shared with the gateway.')
param namePrefix string

param location string = resourceGroup().location

@description('The Cosmos account the private endpoint points at.')
param cosmosAccountName string

@description('Create the in-VNet container used to run the capacity test. Not part of the production shape.')
param runnerEnabled bool = true

@description('Image for the runner. Node, because the capacity test is written against the Cosmos JavaScript SDK.')
param runnerImage string = 'mcr.microsoft.com/devcontainers/javascript-node:22'

var vnetName = 'vnet-${namePrefix}'
var peName = 'pe-cosmos-${namePrefix}'
var runnerName = 'aci-projtest-${namePrefix}'
// The zone name is fixed by Azure: a private endpoint for Cosmos SQL resolves
// through privatelink.documents.azure.com. Getting it wrong leaves the name
// resolving to the public address, which then refuses the connection - the
// failure looks like a firewall problem rather than a DNS one.
var dnsZoneName = 'privatelink.documents.azure.com'

resource cosmos 'Microsoft.DocumentDB/databaseAccounts@2024-05-15' existing = {
  name: cosmosAccountName
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.10.0.0/16'
      ]
    }
    subnets: [
      {
        name: 'endpoints'
        properties: {
          addressPrefix: '10.10.1.0/24'
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
      {
        name: 'runner'
        properties: {
          addressPrefix: '10.10.2.0/24'
          // A container group needs the subnet delegated to it, and the
          // delegation is exclusive - nothing else can live here.
          delegations: [
            {
              name: 'aci'
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

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name: peName
  location: location
  properties: {
    subnet: {
      id: vnet.properties.subnets[0].id
    }
    privateLinkServiceConnections: [
      {
        name: peName
        properties: {
          privateLinkServiceId: cosmos.id
          // 'Sql' is the group for the Cosmos NoSQL data plane. The account
          // also publishes per-region groups; the account-level one is what a
          // client using the SDK needs.
          groupIds: [
            'Sql'
          ]
        }
      }
    ]
  }
}

resource dnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: dnsZoneName
  location: 'global'
}

resource dnsLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: dnsZone
  name: '${vnetName}-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnet.id
    }
  }
}

// Without this the endpoint exists and nothing resolves to it. The A records
// are written by Azure from the endpoint's own IP configuration, so this is the
// piece that makes the private address the answer to the public name.
resource dnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = {
  parent: privateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'cosmos'
        properties: {
          privateDnsZoneId: dnsZone.id
        }
      }
    ]
  }
}

resource runner 'Microsoft.ContainerInstance/containerGroups@2023-05-01' = if (runnerEnabled) {
  name: runnerName
  location: location
  // System-assigned, so the runner reaches Cosmos the same way the gateway
  // reaches Foundry. The account has local auth disabled; there is no key to
  // use even if we wanted one.
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    osType: 'Linux'
    // Never restart. This runs a test and exits; a restart policy of Always
    // would re-run the load indefinitely and bill for it.
    restartPolicy: 'Never'
    subnetIds: [
      {
        id: vnet.properties.subnets[1].id
      }
    ]
    containers: [
      {
        name: 'runner'
        properties: {
          image: runnerImage
          // Idle. The test is copied in and run with `az container exec`, so
          // the image does not have to carry it and a change to the test does
          // not mean a rebuild.
          command: [
            '/bin/sh'
            '-c'
            'sleep 10800'
          ]
          resources: {
            requests: {
              cpu: 2
              memoryInGB: 4
            }
          }
        }
      }
    ]
  }
  dependsOn: [
    dnsGroup
  ]
}

output vnetName string = vnet.name
output privateEndpointName string = privateEndpoint.name
output runnerName string = runnerEnabled ? runnerName : ''
output runnerPrincipalId string = runnerEnabled ? runner.identity.principalId : ''
