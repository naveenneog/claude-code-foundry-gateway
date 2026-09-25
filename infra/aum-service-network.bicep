@description('A new isolated service VNet. Never modifies or peers the gateway VNet.')
param namePrefix string
param location string = resourceGroup().location
@description('Administrator-selected, non-overlapping RFC1918 /24 from discovered address space.')
param addressPrefix string
param privateApi bool

resource network 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: 'vnet-aum-${namePrefix}'
  location: location
  tags: { component: 'aum-service' }
  properties: {
    addressSpace: { addressPrefixes: [addressPrefix] }
    subnets: [
      {
        name: 'integration'
        properties: {
          addressPrefix: cidrSubnet(addressPrefix, 26, 0)
          delegations: [{
            name: 'functions-flex'
            properties: { serviceName: 'Microsoft.App/environments' }
          }]
        }
      }
      {
        name: 'endpoints'
        properties: {
          addressPrefix: cidrSubnet(addressPrefix, 27, 2)
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
    ]
  }
}
var zones = concat(['privatelink.blob.core.windows.net', 'privatelink.table.core.windows.net'],
  privateApi ? ['privatelink.azurewebsites.net'] : [])
resource zone 'Microsoft.Network/privateDnsZones@2020-06-01' = [for name in zones: {
  name: name
  location: 'global'
  tags: { component: 'aum-service' }
}]
resource link 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = [for (name, i) in zones: {
  parent: zone[i]
  name: 'aum-${namePrefix}'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: network.id }
  }
}]
output integrationSubnetId string = '${network.id}/subnets/integration'
output privateEndpointSubnetId string = '${network.id}/subnets/endpoints'
output blobDnsZoneId string = zone[0].id
output tableDnsZoneId string = zone[1].id
output sitesDnsZoneId string = privateApi ? zone[2].id : ''
var zoneIds = [for name in zones: resourceId('Microsoft.Network/privateDnsZones', name)]
output resourceIds array = concat([network.id], zoneIds)
