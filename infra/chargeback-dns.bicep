param zoneName string
param createZone bool
param virtualNetworkId string
param linkName string
param tags object

resource createdZone 'Microsoft.Network/privateDnsZones@2020-06-01' = if (createZone) {
  name: zoneName
  location: 'global'
  tags: tags
}
resource zone 'Microsoft.Network/privateDnsZones@2020-06-01' existing = {
  name: zoneName
}
resource link 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: zone
  name: linkName
  location: 'global'
  tags: tags
  properties: { registrationEnabled: false, virtualNetwork: { id: virtualNetworkId } }
  dependsOn: [createdZone]
}
output zoneId string = zone.id
output linkId string = link.id
