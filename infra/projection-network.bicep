// Private networking for the entitlement projection.
//
// Measured 2026-09-17: the reference subscription enforces
// publicNetworkAccess Disabled on Cosmos above the resource group, so the data
// plane is unreachable from anywhere outside a VNet. ADR-0011 records that and
// prices the endpoint; this is the template that actually creates it.
//
// Two shapes, because enterprises and evaluations arrive differently:
//
//   new VNet        nothing passed in. The template creates a VNet with the
//                   three subnets the projection needs. Good for an evaluation.
//   existing VNet   vnetId and endpointsSubnetId passed in. The network team
//                   owns the address plan and hands over subnets; this creates
//                   only the private endpoint, the private DNS zones and their
//                   links. Nothing here changes the VNet itself, so a later
//                   redeploy of the network team's own template cannot fight
//                   with this one over subnet lists.
//
// It can also create a container group in the VNet, because a private
// endpoint on its own does not let anyone test: something has to sit inside the
// network to do the reading and, since the account is private, the writing.
// That is the runner, and it is optional - set runnerEnabled false for the
// production shape.

@description('Prefix shared with the gateway.')
param namePrefix string

param location string = resourceGroup().location

@description('The Cosmos account the private endpoint points at.')
param cosmosAccountName string

@description('Existing VNet to link the private DNS zones to. Leave empty to create a new VNet.')
param vnetId string = ''

@description('Existing subnet for private endpoints. Required with vnetId.')
param endpointsSubnetId string = ''

@description('Existing subnet delegated to Microsoft.ContainerInstance/containerGroups, for the runner. Required with vnetId when runnerEnabled.')
param runnerSubnetId string = ''

@description('Address space when creating a VNet.')
param vnetAddressPrefix string = '10.10.0.0/16'

@description('Create the in-VNet container used to write the projection and run the capacity test. Not part of the production shape.')
param runnerEnabled bool = true

@description('Image for the runner. Node, because the capacity test and the importer are written against the Cosmos JavaScript SDK.')
param runnerImage string = 'mcr.microsoft.com/devcontainers/javascript-node:22'

var createVnet = empty(vnetId)
var vnetName = 'vnet-${namePrefix}'
var peName = 'pe-cosmos-${namePrefix}'
var runnerName = 'aci-projtest-${namePrefix}'
// The zone names are fixed by Azure. A private endpoint for Cosmos SQL resolves
// through privatelink.documents.azure.com; a Function app's through
// privatelink.azurewebsites.net. Getting either wrong leaves the name resolving
// to the public address, which then refuses the connection - the failure looks
// like a firewall problem rather than a DNS one.
var dnsZoneName = 'privatelink.documents.azure.com'
var sitesZoneName = 'privatelink.azurewebsites.net'

resource cosmos 'Microsoft.DocumentDB/databaseAccounts@2024-05-15' existing = {
  name: cosmosAccountName
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = if (createVnet) {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: [
      {
        name: 'endpoints'
        properties: {
          addressPrefix: cidrSubnet(vnetAddressPrefix, 24, 1)
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
      {
        name: 'runner'
        properties: {
          addressPrefix: cidrSubnet(vnetAddressPrefix, 24, 2)
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
      {
        // The resolver's outbound path to the Cosmos endpoint. Flex
        // Consumption needs its own delegation, Microsoft.App/environments -
        // not Microsoft.Web/serverFarms, which is what API Management v2 and
        // the older Functions plans use - and at least a /27. It cannot also
        // hold private endpoints. Learn, flex-consumption-how-to, "Subnet
        // sizing and requirements".
        name: 'resolver'
        properties: {
          addressPrefix: cidrSubnet(vnetAddressPrefix, 26, 12)
          delegations: [
            {
              name: 'flex'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
        }
      }
    ]
  }
}

var linkedVnetId = createVnet ? vnet.id : vnetId
var peSubnetId = createVnet ? '${vnet.id}/subnets/endpoints' : endpointsSubnetId
var runnerSubnet = createVnet ? '${vnet.id}/subnets/runner' : runnerSubnetId

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name: peName
  location: location
  properties: {
    subnet: {
      id: peSubnetId
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
  name: '${namePrefix}-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: linkedVnetId
    }
  }
}

// For the resolver's own private endpoint. Created here so the zone and its
// link belong to the network, and resolver.bicep only has to point at it.
resource sitesZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: sitesZoneName
  location: 'global'
}

resource sitesLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: sitesZone
  name: '${namePrefix}-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: linkedVnetId
    }
  }
}

// The resolver's own storage - host state and its deployment package - is
// private as well. Measured 2026-09-23: an Azure Policy in the reference
// subscription sets publicNetworkAccess Disabled on every new storage account,
// and the resolver's deployment then failed with a 403 until blob, queue and
// table endpoints existed. With them, the platform deployed the package
// through the VNet. Blob, queue and table because the Functions host requires
// all three (Learn, functions-networking-options, "Restrict your storage
// account to a virtual network").
var storageZoneNames = [
  'privatelink.blob.${environment().suffixes.storage}'
  'privatelink.queue.${environment().suffixes.storage}'
  'privatelink.table.${environment().suffixes.storage}'
]

resource storageZones 'Microsoft.Network/privateDnsZones@2020-06-01' = [for z in storageZoneNames: {
  name: z
  location: 'global'
}]

resource storageLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = [for (z, i) in storageZoneNames: {
  parent: storageZones[i]
  name: '${namePrefix}-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: linkedVnetId
    }
  }
}]

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
        id: runnerSubnet
      }
    ]
    containers: [
      {
        name: 'runner'
        properties: {
          image: runnerImage
          // Idle. The work is copied in and run with `az container exec`, so
          // the image does not have to carry it and a change to the work does
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
    dnsLink
  ]
}

output vnetName string = createVnet ? vnetName : last(split(vnetId, '/'))
output vnetId string = linkedVnetId
output endpointsSubnetId string = peSubnetId
output resolverSubnetId string = createVnet ? '${vnet.id}/subnets/resolver' : ''
output sitesDnsZoneId string = sitesZone.id
output blobDnsZoneId string = storageZones[0].id
output queueDnsZoneId string = storageZones[1].id
output tableDnsZoneId string = storageZones[2].id
output privateEndpointName string = privateEndpoint.name
output runnerName string = runnerEnabled ? runnerName : ''
output runnerPrincipalId string = runnerEnabled ? runner!.identity.principalId : ''
