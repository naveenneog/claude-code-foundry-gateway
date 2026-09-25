targetScope = 'resourceGroup'

param name string
param location string = resourceGroup().location
param ownerId string
param subnetId string
param image string = 'mcr.microsoft.com/devcontainers/javascript-node:22'
@minValue(600)
@maxValue(86400)
param lifetimeSeconds int = 10800

resource runner 'Microsoft.ContainerInstance/containerGroups@2023-05-01' = {
  name: name
  location: location
  tags: {
    'claude-network-owner': ownerId
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    osType: 'Linux'
    restartPolicy: 'Never'
    subnetIds: [
      {
        id: subnetId
      }
    ]
    containers: [
      {
        name: 'runner'
        properties: {
          image: image
          command: [
            '/bin/sh'
            '-c'
            'sleep ${lifetimeSeconds}'
          ]
          resources: {
            requests: {
              cpu: 1
              memoryInGB: 2
            }
          }
        }
      }
    ]
  }
}

output id string = runner.id
output principalId string = runner.identity.principalId
