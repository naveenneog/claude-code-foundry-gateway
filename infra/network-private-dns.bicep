targetScope = 'resourceGroup'

param name string
param ownerId string
param vnetId string
param createZone bool
param linkName string

resource newZone 'Microsoft.Network/privateDnsZones@2020-06-01' = if (createZone) {
  name: name
  location: 'global'
  tags: {
    'claude-network-owner': ownerId
  }
}

resource zone 'Microsoft.Network/privateDnsZones@2020-06-01' existing = {
  name: name
}

resource link 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: zone
  name: linkName
  location: 'global'
  tags: {
    'claude-network-owner': ownerId
  }
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnetId
    }
  }
  dependsOn: [
    newZone
  ]
}

output id string = zone.id
output linkId string = link.id
