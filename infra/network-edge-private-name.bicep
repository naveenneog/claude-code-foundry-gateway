targetScope = 'resourceGroup'

@description('An exact-name zone avoids shadowing other corporate or Azure hostnames.')
param listenerHostName string
param privateIp string
param vnetId string
param ownerId string
param linkName string

resource zone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: listenerHostName
  location: 'global'
  tags: {
    'claude-network-owner': ownerId
  }
}

resource address 'Microsoft.Network/privateDnsZones/A@2020-06-01' = {
  parent: zone
  name: '@'
  properties: {
    ttl: 60
    aRecords: [
      {
        ipv4Address: privateIp
      }
    ]
    metadata: {
      'claude-network-owner': ownerId
    }
  }
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
}

output id string = zone.id
