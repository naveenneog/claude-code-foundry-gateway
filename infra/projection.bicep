// Entitlement projection - ADR-0005 (what it is), ADR-0011 (what it runs on).
//
// Deployed separately from main.bicep and read by nothing until the resolver
// exists. That is ADR-0009 phase 1: schema first, authorization unchanged.
//
// Serverless, so an accelerator that ships this to a customer with eight
// developers bills them nothing, and the same template serves 500,000. There is
// no capacity decision for the operator to get wrong.

@description('Prefix shared with the gateway, so the projection is findable next to it.')
param namePrefix string

param location string = resourceGroup().location

@description('Entra tenant the projection is for. Stored on every record so a record from another tenant cannot be honoured.')
param tenantId string = subscription().tenantId

var accountName = 'cosmos-${namePrefix}'
var databaseName = 'claude'
var containerName = 'entitlement'

resource account 'Microsoft.DocumentDB/databaseAccounts@2024-05-15' = {
  name: accountName
  location: location
  kind: 'GlobalDocumentDB'
  properties: {
    databaseAccountOfferType: 'Standard'
    // Serverless bills per request unit consumed and per GB stored, with no
    // minimum. Provisioned throughput would put a floor under a customer who
    // has not onboarded anyone yet.
    capabilities: [
      {
        name: 'EnableServerless'
      }
    ]
    // The projection is rebuildable from Entra in minutes, so paying to
    // replicate it is paying for something the sync already gives us.
    locations: [
      {
        locationName: location
        failoverPriority: 0
        isZoneRedundant: false
      }
    ]
    // Entra only. A key on a connection string is the credential this whole
    // accelerator exists to avoid - the gateway reaches Foundry with a managed
    // identity and it reaches this the same way.
    disableLocalAuth: true
    minimalTlsVersion: 'Tls12'
    consistencyPolicy: {
      // Session is the default and is enough: one writer (the sync) and readers
      // that already tolerate a bounded staleness window by design. Strong
      // would cost latency to remove a staleness we are choosing to keep.
      defaultConsistencyLevel: 'Session'
    }
  }
}

resource database 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2024-05-15' = {
  parent: account
  name: databaseName
  properties: {
    resource: {
      id: databaseName
    }
  }
}

resource container 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2024-05-15' = {
  parent: database
  name: containerName
  properties: {
    resource: {
      id: containerName
      // Partitioned on the object id, one logical partition per identity.
      //
      // The obvious alternative, /tenantId, puts every record in a single
      // logical partition. That caps at 20 GB and serialises every read for the
      // whole organisation behind one partition - it would look correct at
      // eight developers and fail at scale, which is the failure mode this
      // accelerator exists to avoid.
      //
      // Per-identity partitions also make the read a point read: id plus
      // partition key, which is the cheapest operation Cosmos offers at
      // roughly 1 RU.
      partitionKey: {
        paths: [
          '/oid'
        ]
        kind: 'Hash'
      }
      indexingPolicy: {
        // A point read does not use the index, and every other field here is
        // written far more often than it is queried. Indexing only the id keeps
        // the write cost of a full resync down.
        indexingMode: 'consistent'
        automatic: true
        includedPaths: [
          {
            path: '/oid/?'
          }
        ]
        excludedPaths: [
          {
            path: '/*'
          }
        ]
      }
    }
  }
}

output accountName string = account.name
output databaseName string = databaseName
output containerName string = containerName
output documentEndpoint string = account.properties.documentEndpoint
output projectionTenantId string = tenantId
