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

@description('''
Who can reach the projection over the network.

  public          reachable from anywhere the data-plane role allows. The sync
                  runs from an administrator's machine, which is the common case.
  selected-ips    reachable only from the addresses in allowedIpAddresses.
  private-only    reachable only through a private endpoint. Nothing with a
                  public address reaches it, including an administrator laptop,
                  so the sync must then run from inside the network.

Stated here rather than left to default, because an Azure Policy will otherwise
decide it silently and the failure arrives later as a 403 that reads like a
missing role.
''')
@allowed([
  'public'
  'selected-ips'
  'private-only'
])
param networkAccess string = 'public'

@description('Addresses allowed when networkAccess is selected-ips. Cosmos also needs the Azure portal ranges if anyone will browse data there.')
param allowedIpAddresses array = []

@description('''
How many copies of the projection Azure keeps.

  single      one region, one copy. The projection rebuilds from Entra in
              minutes, so this is a considered choice rather than a cheap one.
  zone        three availability zones in one region. Survives a zone failure.
              Requires provisioned throughput - serverless is single-zone only.
  multi-region  a second region with automatic failover. Also requires
              provisioned throughput.

Serverless bills per request and has no floor, which suits a deployment that has
onboarded nobody yet. The moment redundancy is wanted, throughput becomes a
standing monthly cost whether anyone signs in or not.
''')
@allowed([
  'single'
  'zone'
  'multi-region'
])
param redundancy string = 'single'

@description('Second region when redundancy is multi-region.')
param secondaryLocation string = ''

@description('Provisioned RU/s when redundancy is not single. 400 is the minimum and serves far more than this projection needs.')
@minValue(400)
param throughput int = 400

var accountName = 'cosmos-${namePrefix}'
var databaseName = 'claude'
var containerName = 'entitlement'

// Serverless cannot be zone redundant or multi-region, so the redundancy choice
// decides the billing model as well. That is the trade made visible rather than
// discovered after deployment.
var isServerless = redundancy == 'single'

var secondary = redundancy == 'multi-region' && !empty(secondaryLocation) ? [
  {
    locationName: secondaryLocation
    failoverPriority: 1
    isZoneRedundant: false
  }
] : []

var accountLocations = concat([
  {
    locationName: location
    failoverPriority: 0
    isZoneRedundant: redundancy != 'single'
  }
], secondary)

resource account 'Microsoft.DocumentDB/databaseAccounts@2024-05-15' = {
  name: accountName
  location: location
  kind: 'GlobalDocumentDB'
  properties: {
    databaseAccountOfferType: 'Standard'
    // Serverless bills per request unit consumed and per GB stored, with no
    // minimum, and cannot be made redundant. Redundancy therefore switches the
    // billing model to provisioned throughput - a standing cost whether anyone
    // signs in or not. The operator chooses; this only makes the consequence
    // follow from the choice rather than from a default.
    capabilities: isServerless ? [
      {
        name: 'EnableServerless'
      }
    ] : []
    locations: accountLocations
    enableAutomaticFailover: redundancy == 'multi-region'
    // Stated rather than defaulted. Left unset an Azure Policy decides it, and
    // the sync then fails with a 403 that reads like a missing role.
    publicNetworkAccess: networkAccess == 'private-only' ? 'Disabled' : 'Enabled'
    ipRules: [for ip in allowedIpAddresses: {
      ipAddressOrRange: ip
    }]
    isVirtualNetworkFilterEnabled: networkAccess == 'selected-ips'
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
    // Throughput belongs to the database only when the account is not
    // serverless; serverless rejects it outright.
    options: isServerless ? {} : {
      throughput: throughput
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
output networkAccessChosen string = networkAccess
output redundancyChosen string = redundancy
// Serverless bills only what is used; provisioned throughput bills whether
// anyone signs in or not. Reported so the bill of materials can say which.
output billingModel string = isServerless ? 'serverless (per request)' : 'provisioned (${throughput} RU/s standing)'
