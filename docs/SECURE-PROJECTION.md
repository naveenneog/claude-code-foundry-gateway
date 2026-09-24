# Deploy the entitlement projection with private networking

The gateway decides each developer's tier from two named values. A named value
holds 4,096 characters, which is about 93 to 110 object ids, so beyond roughly a
hundred developers entitlement has to move to the **projection**: one Cosmos DB
record per developer, read through a small resolver Function when the gateway's
cache misses.

This article deploys the projection with **no public endpoint anywhere**:
Cosmos DB, the resolver, the resolver's storage and the Foundry account are all
reached through private endpoints. It then points the gateway at the resolver
without changing anyone's access, ready for the
[migration runbook](SCALE.md#the-move-itself-step-by-step).

The original steps, results and errors were measured on 2026-09-23 against an
API Management Premium v2 gateway in Canada Central. P19 freshness and admission
changes, and the 500,000-record measurement, are dated 2026-09-24 below. The Cosmos DB account was
in East US 2, reached through a private endpoint in the gateway's VNet.

## Architecture

```text
Developer ──Entra token──▶ API Management (public gateway, outbound VNet integration)
                              │  managed identity token, audience api://<resolver-app>
                              ▼
                        Resolver (Flex Consumption)   ◀── private endpoint only
                              │  managed identity, read only, one container
                              ▼
                        Cosmos DB (serverless)        ◀── private endpoint only
                              ▲
Sync job in the VNet ─────────┘  its own identity, write only, one container
```

| Component | Authenticates with | Reachable from | Key authentication |
|---|---|---|---|
| Cosmos DB account | Entra only | Private endpoint | Off (`disableLocalAuth`) |
| Resolver Function | Built-in authentication: the gateway's identity only | Private endpoint | Basic publishing off, FTP off |
| Resolver storage | Entra only | Private endpoints (blob, queue, table) | Off (`allowSharedKeyAccess: false`) |
| Application Insights | Entra only | Public ingestion, identity required | Off (`DisableLocalAuth`) |
| Foundry account | The gateway's identity | Private endpoint | Unchanged by this article |

The resolver only reads, and it can read only the `entitlement` container. The
sync has a different identity that can only write that container. A compromised
resolver therefore cannot change who is entitled.

## Prerequisites

| Requirement | Detail |
|---|---|
| Gateway tier | **Standard v2 or Premium v2** for a private resolver, because the gateway needs outbound VNet integration. **Basic v2** cannot integrate with a VNet, so deploy the resolver with `inboundAccess=public` there: the token check is then the only control. |
| Roles | Owner, or Contributor plus User Access Administrator, on the resource group. Permission to create an app registration in Entra ID. |
| Resource provider | `Microsoft.App` registered: `az provider show -n Microsoft.App --query registrationState` |
| Region capacity | Check Cosmos DB account creation in your region **before** planning around it. Measured: Canada Central and Canada East both refused with `ServiceUnavailable ... high demand ... To request region access for your subscription, please follow this link https://aka.ms/cosmosdbquota`. A private endpoint can point at an account in another region, so a Cosmos DB account elsewhere still stays private in your VNet. |
| Subnets | See the next table. In most enterprises the network team creates them and hands over the resource IDs. |

| Subnet | Size | Delegation | Notes |
|---|---|---|---|
| Gateway integration | /27 minimum, /24 recommended | `Microsoft.Web/serverFarms` | Needs a network security group. Only for Standard v2 and Premium v2. |
| Private endpoints | /27 holds the eight endpoints used here | None | Cosmos, resolver, resolver storage ×3, Foundry. |
| Resolver integration | /27 minimum (/26 used) | `Microsoft.App/environments` | Flex Consumption's own delegation, not `Microsoft.Web/serverFarms`. No private endpoints in it, and no underscore in its name. [Learn: subnet sizing and requirements](https://learn.microsoft.com/azure/azure-functions/flex-consumption-how-to#subnet-sizing-and-requirements) |
| Runner (optional) | /27 | `Microsoft.ContainerInstance/containerGroups` | The container that writes and tests the projection from inside the network. |

## Deploy

### 1. Create the projection store

```powershell
az deployment group create -g <rg> --template-file infra/projection.bicep `
  --parameters namePrefix=<prefix> networkAccess=private-only location=<region>
```

Measured: 132 seconds. The account came up with `publicNetworkAccess: Disabled`,
key authentication off and TLS 1.2.

`private-only` is now the template default. Public and selected-IP profiles
still require an explicit `networkAccess=public` or `networkAccess=selected-ips`;
this does not override an Azure Policy that enforces private networking.

### 2. Connect it to your network

Pass the subnets you were given. The template creates only the Cosmos private
endpoint, the private DNS zones and their links. It does not change the VNet, so
a later redeploy of the network team's own template cannot conflict with it.

```powershell
az deployment group create -g <rg> --template-file infra/projection-network.bicep `
  --parameters namePrefix=<prefix> location=<vnet-region> cosmosAccountName=cosmos-<prefix> `
    vnetId=<vnet-id> endpointsSubnetId=<pe-subnet-id> runnerSubnetId=<runner-subnet-id> runnerEnabled=true
```

Leave out `vnetId` and the subnet IDs, and the template creates a VNet of its
own for an evaluation instead. The outputs include the zone IDs that step 4
needs: `sitesDnsZoneId`, `blobDnsZoneId`, `queueDnsZoneId` and `tableDnsZoneId`.

### 3. Register the resolver's identity

The gateway asks Entra for a token whose audience is the resolver. That needs an
app registration, and **assignment required**, so that no other identity in the
tenant can even obtain such a token:

```powershell
$app = az ad app create --display-name claude-resolver-<prefix> --sign-in-audience AzureADMyOrg -o json | ConvertFrom-Json
az ad app update --id $app.appId --identifier-uris "api://$($app.appId)"
$sp = az ad sp create --id $app.appId -o json | ConvertFrom-Json
az ad sp update --id $sp.id --set appRoleAssignmentRequired=true

# Let the gateway's managed identity request tokens for it
$apimOid = az apim show -g <rg> -n <apim> --query identity.principalId -o tsv
@{ principalId = $apimOid; resourceId = $sp.id; appRoleId = '00000000-0000-0000-0000-000000000000' } |
  ConvertTo-Json | Set-Content assign.json
az rest --method post --url "https://graph.microsoft.com/v1.0/servicePrincipals/$($sp.id)/appRoleAssignedTo" `
  --headers Content-Type=application/json --body '@assign.json'
```

The gateway identity's **application id** goes into the resolver's allow list in
the next step: `az ad sp show --id $apimOid --query appId -o tsv`.

### 4. Deploy the resolver

Deploy it with a public endpoint first, so the code can be published in step 5.
Built-in authentication protects it from the first second.

| Parameter | Value |
|---|---|
| `integrationSubnetId` | The resolver integration subnet |
| `resolverAppId` | The app registration from step 3 |
| `allowedCallerAppIds` | `[ <gateway identity application id> ]`, and nothing else |
| `allowedCallerObjectIds` | `[ <gateway identity object id> ]`, checked as well |
| `inboundAccess` | `public` now, `private` in step 6 |
| `privateEndpointSubnetId` | The private endpoint subnet |
| `blobDnsZoneId`, `queueDnsZoneId`, `tableDnsZoneId` | From step 2. With these, the resolver's storage has no public endpoint |
| `alwaysReadyInstances` | `2` (current default). One instance at the platform's default concurrency failed the first burst in U18 |
| `httpConcurrency` | `100` per instance (current default), sized to the gateway's 100 concurrent admitted misses |

```powershell
az deployment group create -g <rg> --template-file infra/resolver.bicep --parameters '@resolver.params.json'
```

Measured: 103 seconds.

### 5. Publish the resolver code

```powershell
Copy-Item resolver\host.json, resolver\package.json $stage; Copy-Item resolver\src $stage -Recurse
cd $stage; npm install --omit=dev
tar -a -c -f resolver.zip host.json package.json src node_modules
az functionapp deployment source config-zip -g <rg> -n func-resolver-<prefix> --src resolver.zip
```

Zip with `tar`, not `Compress-Archive`, which can write paths with backslashes
that break extraction on Linux. Measured: 149 seconds, with the storage account
already private, because the platform writes the package through the VNet.

### 6. Close the resolver's public endpoint

Redeploy step 4 with `inboundAccess=private` and `sitesDnsZoneId` from step 2.
Measured: 105 seconds. The resolver then resolves to a private address inside the
VNet (10.61.1.12 here), and from outside it answers `403 Web App - Unavailable`.

To publish new code after this, run step 5 from a machine that reaches the
private endpoint, or reopen inbound access for the duration.

### 7. Integrate the gateway with the VNet

Standard v2 and Premium v2 only. The gateway stays public; its outbound traffic
now uses the VNet, including its DNS, so it resolves the private endpoints:

```powershell
@{ properties = @{ virtualNetworkType = 'External'; virtualNetworkConfiguration = @{ subnetResourceId = '<integration-subnet-id>' } } } |
  ConvertTo-Json -Depth 5 | Set-Content vnet.json
az rest --method patch --url "https://management.azure.com<apim-id>?api-version=2024-05-01" `
  --headers Content-Type=application/json --body '@vnet.json'
```

Measured on Premium v2: applied in under 30 seconds, and a request every
16 seconds throughout was never refused by the gateway.

> [!IMPORTANT]
> After any redeploy of the gateway, confirm the integration is still there:
> `az apim show -g <rg> -n <apim> --query virtualNetworkType`. Without it the
> gateway cannot reach the private resolver or a private Foundry account, and every
> request fails. The installer preserves it from 2026-09-23 on: a re-run printed
> `preserving VNet mode: External (snet-apim)` and left it in place.

### 8. Populate the projection from inside the network

Cosmos DB has no public endpoint, so the write runs inside the VNet. There are two
ways, and they differ in who reads Entra ID.

**A. Resolve outside, write inside.** For an operator who cannot obtain Graph
application consent. No credential crosses into the network, only object ids and
tiers:

```powershell
# On your machine: read the groups with your own sign-in, write a snapshot
./scripts/Sync-ClaudeProjection.ps1 -Account cosmos-<prefix> -ApimName <apim> -ResourceGroup <rg> -ExportPath snapshot.json

# Copy it into the runner and apply it with the runner's own identity
. ./scripts/ClaudeRunner.ps1
Send-RunnerFile -ResourceGroup <rg> -Name aci-projtest-<prefix> -Path snapshot.json -Destination /work/snapshot.json
Invoke-RunnerCommand -ResourceGroup <rg> -Name aci-projtest-<prefix> -Command `
  'node /work/sync/src/apply-projection.mjs --cosmos https://cosmos-<prefix>.documents.azure.com:443/ --tenant <tenant-id> --snapshot /work/snapshot.json'
```

Copy the `sync` folder in the same way, then run
`npm --prefix /work/sync install --omit=dev` in the runner once. Give the runner's
identity **Cosmos DB Built-in Data Contributor** on the one container:

```powershell
az cosmosdb sql role assignment create -g <rg> -a cosmos-<prefix> `
  --role-definition-id 00000000-0000-0000-0000-000000000002 `
  --principal-id <runner-principal-id> --scope /dbs/claude/colls/entitlement
```

Historical measurement: 8 records written in 1.5 seconds, then no writes on an
unchanged run. With expiring leases, unchanged members must also be renewed:
measured 2026-09-24, all 8 unchanged members refreshed in 1.88 seconds.

**B. The job reads Entra itself.** The enterprise default for a scheduled sync.
The job's identity needs the Microsoft Graph application permission
`GroupMember.Read.All`, which a tenant administrator grants once. Then run
`apply-projection.mjs --graph` instead of `--snapshot`. Measured: an operator
without a directory role is refused with `Authorization_RequestDenied`.

Both ways assign business units exactly as the named-value path does: deepest
first, then registry order, first match wins. `-ApimName` and `-ResourceGroup`
make the export read the registry from the gateway itself.

### Freshness and operating envelope

**Two hours from scan start is the maximum stale-authorization window**, not
two hours plus the gateway's cache. Each complete directory observation stamps
`reconciliationGeneration`, `lastVerifiedAt` and absolute epoch-second
`expiresAt`. The resolver enforces the lease; the gateway clips its cache TTL
and rechecks expiry on every hit. Expired or malformed freshness returns 503,
not user-not-found and never stale access. Existing unleased records must be
reconciled before upgrading the resolver and gateway.

Use `-MaxAgeSeconds` on the export/PowerShell writer or `--max-age-seconds` with
the Node `--graph` writer to shorten the lease (60–7,200 seconds). Import never
extends the snapshot's expiry. A scan that fails writes nothing; a failed apply
may leave multiple generations, each retaining its own expiry, and exits nonzero.
`-KeepOrphans`/`--keep-orphans` never renew an orphan's lease.

Schedule a fresh reconciliation at least hourly for the default two-hour lease,
with enough time for the directory scan and all writes. Alert on nonzero exit
and on the oldest remaining lease, rather than assuming a running job is fresh.
If that workload cannot complete before expiry, reduce scan/apply time or choose
a separately designed reconciliation scheme; do not silently serve expired data.
The bound is for **new requests**, subject to directory replication and clock
skew; it does not interrupt an already-running model stream.

APIM admits at most 100 concurrent resolver misses and 200 misses/second, with
retryable 429 above that approximate distributed envelope. Cache hits do not
consume this admission budget. The resolver coalesces same-identity in-flight
reads **per process**, never across hosts, and has no completed-result cache.
Its 3.5-second deadline and 2.5-second Cosmos transport timeout leave margin
inside APIM's five seconds. Two always-ready instances at HTTP concurrency 100
avoid depending on cold scale-out for an admitted burst. Greater production
load needs its own measurement and coordinated admission/warm-capacity sizing.

PowerShell and Node both consume every Cosmos continuation page before planning
removals; an empty page with a continuation is not end-of-data.

### 9. Point the gateway at the resolver

```powershell
. ./scripts/ApimNamedValue.ps1
Set-ApimNamedValue -ResourceGroup <rg> -ApimName <apim> -Id entitlement-resolver-url -Value 'https://func-resolver-<prefix>.azurewebsites.net/api'
Set-ApimNamedValue -ResourceGroup <rg> -ApimName <apim> -Id entitlement-resolver-audience -Value 'api://<resolver-app-id>'
```

`entitlement-source` is still `named-value`, so nothing reads the projection yet.
Continue with [the migration runbook](SCALE.md#the-move-itself-step-by-step).
Its step 4 compares the projection with the gateway before anything is flipped.

## Verify

| Check | How | Expected (measured) |
|---|---|---|
| Resolver with no token | `GET https://func-resolver-<prefix>.azurewebsites.net/api/entitlement/<oid>` before step 6 | `401` |
| A user asks for a resolver token | `az account get-access-token --resource api://<resolver-app-id>` | Refused: `AADSTS50105 ... to block users unless they are specifically granted` |
| Resolver from outside after step 6 | The same GET | `403 Web App - Unavailable` |
| Cosmos DB from inside the network | DNS lookup in the runner | A private address (10.61.1.7 here) |
| Foundry directly, after making it private | `POST https://<account>.services.ai.azure.com/anthropic/v1/messages` | `403 Public access is disabled. Please configure private endpoint.` |
| The gateway, end to end | A request through the gateway | `200`, tier from the projection |

## What the gateway does once it reads the projection

| Situation | Response | Measured |
|---|---|---|
| Entitled, unexpired record present | Served; cache duration is clipped to absolute expiry | Still served when removed from the named-value list, which proves the projection is the source |
| No record | `403 permission_error`; the refusal is cached for at most 60 seconds | Second call 567 ms, answered from cache |
| Record added back | Served once the refusal expires | 200 after the short cache |
| Resolver down, answer cached | Served until the window ends | 200 |
| Resolver down, window ended | `503`, `Retry-After: 5`, "the entitlement service did not answer" | 503, then 200 when it returned |
| Rolled back to named values | The lists decide again | 403 for anyone the lists had not been kept up to date for |
| Expired record, even with a longer cache setting | 503; run a complete reconciliation | 2026-09-24: a real test identity's lease shortened to 20 seconds with cache still 60; expected 403 before expiry, explicit projection-expired 503 after expiry, expected 403 after restoring the original record |

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Cosmos DB account creation fails with `ServiceUnavailable ... high demand` | The subscription has no capacity in that region | Request region access (aka.ms/cosmosdbquota) or use another region with the private endpoint in your VNet |
| Code publishing fails with `InaccessibleStorageException ... 403 (This request is not authorized to perform this operation.)` | The resolver's storage is private and has no endpoint the app can use. Here a management-group policy, `StorageAccount_PublicNetwork_Modify`, set it private at creation | Pass `blobDnsZoneId`, `queueDnsZoneId` and `tableDnsZoneId`. All three are needed |
| A setting comes back different from what the template asked for, and the deployment still reports success | An Azure Policy with a Modify effect rewrote the request. Measured: `CosmosDB_PublicNetwork_Modify` and `StorageAccount_PublicNetwork_Modify` in the initiative `MCAPSGovDeployPolicies`, assigned at a management group, which `az policy assignment list` did not show | Read the resource's activity log for `Microsoft.Authorization/policies/modify/action`. Its `policies` property names the assignment and definition. The templates here state the private values themselves, so they do not depend on it |
| `AADSTS50105` requesting a resolver token | Assignment is required, and the identity is not assigned | Expected for anything but the gateway. For the gateway, repeat the assignment in step 3 |
| Every developer gets `503` right after a gateway redeploy | An installer from before 2026-09-23 wrote the service without its VNet integration. An ARM what-if predicted `virtualNetworkType` External -> None, so the private resolver became unreachable | Re-apply step 7. The current installer reads the integration, public access, portals and protocol settings back and keeps them. Verified by re-running it against the Premium v2 gateway: it printed `preserving VNet mode: External`, finished, and the integration was still there |
| An unentitled developer gets `503 ... not a problem with your access` | A policy from before 2026-09-23 treated the resolver's 404 as an outage | Redeploy the current `infra/policy.xml` |
| `az container exec` truncates or splits a command | Exec runs without a shell, URL-decodes the command (`+` becomes a space) and refuses 5,000 characters or more (`InvalidCommandLength`) | Use `scripts/ClaudeRunner.ps1`, which sends base64url in chunks and checks a SHA-256 |
| A named value change takes effect late | On Premium v2 a named value write took 38 to 41 seconds | Wait for the write to return, then allow a few seconds more |
| Foundry answers `429 RateLimitReached` at low traffic | One capacity unit is **1 request and 1,000 tokens per minute**. The deployment's `rateLimits` at capacity 10 read `request 10` and `token 10000` per 60 seconds | Size capacity on requests as well as tokens. See [SCALE.md](SCALE.md) |

## Cost

Historical read-path estimate from `./scripts/Measure-ClaudeProjectionCost.ps1 -Developers 500000 -DailyActive 50000`
at published US list prices (usage read 2026-09-17; endpoints, zones and warm
instance read 2026-09-23):

| Line | Monthly | Bills at rest |
|---|---:|:---:|
| Private endpoints (5 × $0.01/hour) | $36.50 | yes |
| Private DNS zones (5 × $0.50) | $2.50 | yes |
| Resolver kept warm (1 × 2 GB at $0.000005/GB-second) | $26.28 | yes |
| Resolver executions | $1.56 | no |
| Cosmos DB request units | $2.20 | no |
| Cosmos DB storage | $0.05 | no |
| **Total** | **$69.09** | $65.28 of it |

That one-instance profile pays $65.28 at rest. `-AlwaysReadyInstances 0` removes $26.28 and accepts cold
starts. Not included: API Management itself ($700 a month for Standard v2,
$2,800 for Premium v2), the Foundry account's private endpoint and its three
zones ($8.80), and endpoint data processing at $0.01 per GB.

The current two-instance profile adds $26.28: **$91.56/month at rest**, and
$95.37 for the historical read-path assumptions. Pass `-AlwaysReadyInstances 2`
to the cost script. Neither total includes renewing every member's lease.
At 500,000 members and hourly reconciliation, the write count is about
365 million/month. The measured create charge (5.9 RU) would cost $538.38 at
$0.25/million RU; that is an **illustration**, not a measured upsert or scheduled
sync bill. Include Graph, the runner, retries and telemetry in an operating quote.

## Related

- [SCALE.md](SCALE.md): the migration runbook and what 500,000 developers need
- [ADR-0005](adr/0005-identity-projection.md): why a projection, and its failure rules
- [ADR-0011](adr/0011-projection-platform.md): why Cosmos DB serverless and Flex Consumption
- [NETWORK.md](NETWORK.md): what the developer clients themselves need to reach
