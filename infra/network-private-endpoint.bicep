targetScope = 'resourceGroup'

param name string
param location string = resourceGroup().location
param ownerId string
param subnetId string
param targetId string
param groupIds array
param privateDnsZoneIds array

resource endpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: name
  location: location
  tags: {
    'claude-network-owner': ownerId
  }
  properties: {
    subnet: {
      id: subnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'service'
        properties: {
          privateLinkServiceId: targetId
          groupIds: groupIds
          requestMessage: 'Governed Claude network edge'
        }
      }
    ]
  }
}

resource dns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: endpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [for (zoneId, index) in privateDnsZoneIds: {
      name: 'zone-${index}'
      properties: {
        privateDnsZoneId: zoneId
      }
    }]
  }
}

output id string = endpoint.id
output networkInterfaceId string = endpoint.properties.networkInterfaces[0].id
