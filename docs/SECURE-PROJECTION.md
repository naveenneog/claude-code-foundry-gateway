# Deploy the entitlement projection with private networking

The gateway decides each developer's tier from two named values. A named value
holds 4,096 characters, which is about 93 to 110 object ids, so beyond roughly a
hundred developers entitlement has to move to the **projection**: one Cosmos DB
record per developer, read through a small resolver Function when the gateway's
cache misses.

This article deploys private endpoints for Cosmos DB, the resolver and resolver
storage. APIM ingress remains public and authenticated; resolver telemetry uses
public ingestion with Entra authentication. Making the Foundry account private
is a separate step below, not an effect of the projection templates.
It then points the gateway at the resolver
without changing anyone's access, ready for the
[migration runbook](SCALE.md#the-move-itself-step-by-step).

For private gateway ingress, Application Gateway WAF, corporate DNS/routing
and the placement of the other services, see the
[enterprise network design](NETWORK-ENTERPRISE.md). A private resolver alone
does not restrict the gateway's public ingress.

The original steps, results and errors were measured on 2026-09-23 against an
API Management Premium v2 gateway in Canada Central. P19 freshness and admission
changes, and the 500,000-record measurement, are dated 2026-09-24 below. The Cosmos DB account was
in East US 2, reached through a private endpoint in the gateway's VNet.

## Architecture

See [Architecture](ARCHITECTURE.md) for the full gateway; this is the optional
entitlement read/write path, not the inference or reporting topology.

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

**Portal:** APIM > Network > Outbound VNet integration > select the approved
integration subnet. Verify the resulting VNet/subnet and routing/DNS with the
network owner. This is outbound integration, not a private client ingress.

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
| Gateway tier | **Standard v2 or Premium v2** for this private runbook. **Basic v2** cannot reach a private resolver; `inboundAccess=public` is a separate, explicitly approved profile, not a private deployment. |
| Roles | Owner, or Contributor plus User Access Administrator, on deployment resources; network join/write rights on the supplied VNet/subnets/DNS; application registration/assignment rights in Entra ID. Azure subscription Owner is not a directory role. |
| Resource provider | `Microsoft.App` registered: `az provider show -n Microsoft.App --query registrationState` |
| Region capacity | Check Cosmos DB account creation in your region **before** planning around it. Measured: Canada Central and Canada East both refused with `ServiceUnavailable ... high demand ... To request region access for your subscription, please follow this link https://aka.ms/cosmosdbquota`. A private endpoint can point at an account in another region, so a Cosmos DB account elsewhere still stays private in your VNet. |
| Subnets | See the next table. In most enterprises the network team creates them and hands over the resource IDs. |
| Tools | Azure CLI/Bicep, PowerShell, Node/npm and a ZIP-capable `tar`; package scripts from the repository root |
| Rollout approval | A fresh configuration backup, a tested rollback while named-value lists still fit, and an owner for scheduled reconciliation/expiry alerts |

| Subnet | Size | Delegation | Notes |
|---|---|---|---|
| Gateway integration | /27 minimum, /24 recommended | `Microsoft.Web/serverFarms` | Needs a network security group. Only for Standard v2 and Premium v2. |
| Private endpoints | Reserve capacity for five projection endpoints plus any Foundry endpoint | None | Cosmos, resolver and resolver storage ×3; Foundry is separate |
| Resolver integration | /27 minimum (/26 used) | `Microsoft.App/environments` | Flex Consumption's own delegation, not `Microsoft.Web/serverFarms`. No private endpoints in it, and no underscore in its name. [Learn: subnet sizing and requirements](https://learn.microsoft.com/azure/azure-functions/flex-consumption-how-to#subnet-sizing-and-requirements) |
| Runner (optional) | /27 | `Microsoft.ContainerInstance/containerGroups` | The container that writes and tests the projection from inside the network. |

### Collect the inputs

Use [Operations](OPERATIONS.md#1-select-the-gateway-and-workspace) to identify
the tenant, subscription, gateway name/ID and resource group. In this runbook,
`<rg>` is the projection resource group; the templates expect their Cosmos
account in the same group. For a gateway in another group use its own group
on `az apim` and gateway script commands.

**Portal:** VNet > Subnets supplies subnet IDs; each Private DNS zone > Overview
supplies its resource ID. Resource group > Deployments > deployment > Outputs
shows the IDs/names returned by each template. Do not confuse an app/client ID
with a service-principal object ID.

Use a controlled project-local working folder for parameter files and snapshots.
They carry deployment/identity data even when they contain no secret; never
commit the populated files. Replace every `<placeholder>` before running.

## Deploy

**Portal route for Bicep steps:** Azure portal > Deploy a custom template >
Build your own template in the editor accepts ARM JSON, not Bicep. Build the
selected template with `az bicep build --file <bicep-file> --stdout` into a
controlled file, then upload its JSON, supply the same parameters, Review +
create, and verify deployment outputs. This produces the same resources.
There is no portal button that builds a local Bicep module tree or packages Node
source. Per-resource verification and manual equivalents follow each step.

### 1. Create the projection store

```powershell
az deployment group create -g <rg> --template-file infra/projection.bicep `
  --parameters namePrefix=<prefix> networkAccess=private-only location=<region>
```

**Portal/manual:** create an Azure Cosmos DB for NoSQL serverless account with
local authentication disabled and public network access disabled; database
`claude`, container `entitlement`, partition key `/oid`. Check the template for
its indexing/backup and role definitions before substituting a hand-built store.
Verify Overview/Networking and Data Explorer from the private network. Prefer
the template route to keep its role definitions and settings together.

Measured: 132 seconds. The account came up with `publicNetworkAccess: Disabled`,
key authentication off and TLS 1.2.

`private-only` is now the template default. Public and selected-IP profiles
still require an explicit `networkAccess=public` or `networkAccess=selected-ips`;
this does not override an Azure Policy that enforces private networking.

**Pending batch capture (`docs-review-cosmos-networking`).**

Planned image: `docs/guide/docs-review-cosmos-networking.png` — the
projection account's Networking public-access controls.

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

**Portal:** use the compiled-template route, or create the Cosmos SQL private
endpoint in the endpoints subnet and link `privatelink.documents.azure.com` to
the VNet. Create/link the Function and blob/queue/table zones named by the
template. Review Private endpoints > DNS configuration and connection status.
The evaluation VNet includes resolver, endpoint and runner subnets, **not an APIM
integration subnet**; the network owner must add the latter before step 7.

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

**Portal:** Entra ID > App registrations > New registration > single tenant;
Expose an API > Application ID URI `api://<client-id>`. Enterprise applications
> the app > Properties > Assignment required = Yes. The gateway managed
identity's service-principal assignment is a Microsoft Graph operation; the
Users and groups picker is not a substitute for this workload assignment.
An authorised directory operator must perform the assignment if you cannot.
Verify the assigned principal and both allowlist IDs before deploying.

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

Create `resolver.params.json` in your controlled working folder. Include all
required values, not only the optional network settings:

```json
{
  "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "namePrefix": { "value": "<prefix>" },
    "location": { "value": "<resolver-region>" },
    "cosmosAccountName": { "value": "cosmos-<prefix>" },
    "tenantId": { "value": "<tenant-id>" },
    "integrationSubnetId": { "value": "<resolver-subnet-id>" },
    "resolverAppId": { "value": "<resolver-application-client-id>" },
    "allowedCallerAppIds": { "value": ["<gateway-identity-application-id>"] },
    "allowedCallerObjectIds": { "value": ["<gateway-identity-object-id>"] },
    "inboundAccess": { "value": "public" },
    "privateEndpointSubnetId": { "value": "<private-endpoint-subnet-id>" },
    "sitesDnsZoneId": { "value": "<sites-zone-id>" },
    "blobDnsZoneId": { "value": "<blob-zone-id>" },
    "queueDnsZoneId": { "value": "<queue-zone-id>" },
    "tableDnsZoneId": { "value": "<table-zone-id>" },
    "alwaysReadyInstances": { "value": 2 },
    "httpConcurrency": { "value": 100 }
  }
}
```

The initial public publish window requires security approval. If policy forbids
it, keep `inboundAccess=private` from deployment and publish from a network-
connected agent instead of opening an exception.

```powershell
az deployment group create -g <rg> --template-file infra/resolver.bicep --parameters '@resolver.params.json'
```

Measured: 103 seconds.

**Portal:** use Custom deployment with the compiled resolver template and this
parameter file. Verify Function App > Authentication (Entra, required
authentication and allowed principals), Networking (integration/storage paths)
and Identity. The template also creates Cosmos read access for the resolver;
do not replace it with a broad writer role.

In **Authentication**, verify the Microsoft identity provider and that
unauthenticated requests require authentication. Inspect the configured tenant,
audience and allowed caller identities against the discovered gateway identity;
do not widen the allowlist to make a failing request succeed.

**Pending batch capture (`docs-review-resolver-authentication`).**

Planned image: `docs/guide/docs-review-resolver-authentication.png` — the
resolver's configured identity provider.

### 5. Publish the resolver code

```powershell
$stage = Join-Path (Get-Location) ('backups\resolver-package-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage -Force | Out-Null
Copy-Item resolver\host.json, resolver\package.json $stage
Copy-Item resolver\src $stage -Recurse
Push-Location $stage
try {
    npm install --omit=dev
    if ($LASTEXITCODE -ne 0) { throw 'Resolver dependency installation failed' }
    tar -a -c -f resolver.zip host.json package.json src node_modules
    if ($LASTEXITCODE -ne 0) { throw 'Resolver ZIP creation failed' }
    az functionapp deployment source config-zip -g <rg> -n func-resolver-<prefix> --src resolver.zip
    if ($LASTEXITCODE -ne 0) { throw 'Resolver publish failed; keep the stage for diagnostics' }
}
finally { Pop-Location }
# Remove $stage after successful deployment and verification, not before.
```

Zip with `tar`, not `Compress-Archive`, which can write paths with backslashes
that break extraction on Linux. Measured: 149 seconds, with the storage account
already private, because the platform writes the package through the VNet.

**Portal/manual:** Function App > Deployment Center / deployment logs can inspect
publication, but editing a JavaScript file in the portal does not package its
npm dependencies. Use an approved local/network-connected build agent for this
step and verify deployment success plus Function App > Functions.

### 6. Close the resolver's public endpoint

Redeploy step 4 with `inboundAccess=private` and `sitesDnsZoneId` from step 2.
Measured: 105 seconds. The resolver then resolves to a private address inside the
VNet (10.61.1.12 here), and from outside it answers `403 Web App - Unavailable`.

To publish new code after this, run step 5 from a machine that reaches the
private endpoint. Reopening inbound access requires a separately approved
change and a verified close afterwards, not an automatic troubleshooting step.

**Portal:** Function App > Networking > Private endpoint connections shows the
endpoint; Public network access must be Disabled after the deployment. Test
resolution and a request from inside and outside before proceeding.

Verify **Virtual network integration** names the approved resolver subnet and
the private endpoint is approved. The subnet and DNS-zone IDs come from the
network deployment outputs, not a screenshot or another environment.

**Pending batch capture (`docs-review-resolver-networking`).**

Planned image: `docs/guide/docs-review-resolver-networking.png` — resolver
VNet integration and private-endpoint entry points.

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

### 7a. Make Foundry private if that is your requirement

The projection templates do **not** create Foundry's private endpoint or disable
its public access. **Portal:** Foundry account > Networking > Private endpoint
connections > create/approve the endpoint in the approved subnet and configure
its DNS zones; verify APIM can resolve and call the account privately. Only then
disable public network access. Validate other legitimate consumers before this
change; a shared account is not owned exclusively by this accelerator.

**Verify:** a gateway request still succeeds and an outside direct request is
refused. If it fails, inspect private DNS from the APIM network before reopening
public access. [Network](NETWORK.md) distinguishes client and backend routes.

**Pending batch capture (`docs-review-foundry-networking`).**

Planned image: `docs/guide/docs-review-foundry-networking.png` — Foundry's
public-network-access setting.

### 8. Populate the projection from inside the network

Cosmos DB has no public endpoint, so the write runs inside the VNet. There are two
ways, and they differ in who reads Entra ID.

**A. Resolve outside, write inside.** For an operator who cannot obtain Graph
application consent. No credential crosses into the network, only object ids and
tiers:

```powershell
# Prepare the runner before exporting a time-limited snapshot.
$rg = '<projection-resource-group>'
$runner = 'aci-projtest-<prefix>'
$runnerOid = az container show -g $rg -n $runner --query identity.principalId -o tsv
az cosmosdb sql role assignment create -g $rg -a cosmos-<prefix> `
    --role-definition-id 00000000-0000-0000-0000-000000000002 `
    --principal-id $runnerOid --scope /dbs/claude/colls/entitlement

# Send a package, not a directory: Send-RunnerFile accepts one file.
$archive = Join-Path (Get-Location) ('backups\sync-' + [guid]::NewGuid().ToString('N') + '.tar.gz')
tar -c -z -f $archive -C sync package.json src
if ($LASTEXITCODE -ne 0) { throw 'Sync package creation failed' }
. ./scripts/ClaudeRunner.ps1
Send-RunnerFile -ResourceGroup $rg -Name $runner -Path $archive -Destination /work/sync-source.tar.gz
Invoke-RunnerCommand -ResourceGroup $rg -Name $runner -Command "node -e require('fs').mkdirSync('/work/sync',{recursive:true})"
Invoke-RunnerCommand -ResourceGroup $rg -Name $runner -Command 'tar -x -z -f /work/sync-source.tar.gz -C /work/sync'
Invoke-RunnerCommand -ResourceGroup $rg -Name $runner -Command 'npm --prefix /work/sync install --omit=dev'

# Now export using the GATEWAY resource group, copy, and apply before expiry.
./scripts/Sync-ClaudeProjection.ps1 -Account cosmos-<prefix> -ApimName <apim> `
    -ResourceGroup '<gateway-resource-group>' -ExportPath .\backups\snapshot.json
Send-RunnerFile -ResourceGroup $rg -Name $runner -Path .\backups\snapshot.json -Destination /work/snapshot.json
Invoke-RunnerCommand -ResourceGroup $rg -Name $runner -Command `
    'node /work/sync/src/apply-projection.mjs --cosmos https://cosmos-<prefix>.documents.azure.com:443/ --tenant <tenant-id> --snapshot /work/snapshot.json'
```

The runner needs **Cosmos DB Built-in Data Contributor** scoped to this container,
not Azure's similarly named management-plane role. Review every remote command's
output: `Invoke-RunnerCommand` returns text, not a reliable remote exit-code
contract. Require the apply's JSON `ok: true` and zero failed writes, then compare.

**Portal/manual:** Container instance > Containers > Connect opens an in-network
shell; Identity provides its principal ID. Copy an approved source package and
fresh snapshot to that environment, then run the same writer there. Cosmos
Data Explorer can inspect records from an authorised private-network client,
but hand-editing records is not a directory reconciliation. Use the CLI/ARM
data-role assignment above; do not substitute an IAM management role.
Delete local/runner snapshots and packages after verification under your data
handling policy; they contain person-to-unit mappings.

Historical measurement: 8 records written in 1.5 seconds, then no writes on an
unchanged run. With expiring leases, unchanged members must also be renewed:
measured 2026-09-24, all 8 unchanged members refreshed in 1.88 seconds.

**B. The job reads Entra itself.** The intended unattended path, which still
requires a separately provisioned and monitored schedule.
The job's identity needs the Microsoft Graph application permission
`GroupMember.Read.All`, which a tenant administrator grants once. Then run
`apply-projection.mjs --graph` instead of `--snapshot`, including explicit
`--standard`, `--premium` and ordered `--bu unit=group` arguments.
The Node Graph path does not read APIM's business-unit registry by itself:
build the unit list in deepest-first, then registry precedence order and keep it
current. Missing `--bu` arguments do not reproduce the exported unit mapping.
Measured: an operator
without a directory role is refused with `Authorization_RequestDenied`.

`-ApimName` and `-ResourceGroup` make the PowerShell export read the gateway's
registry and parent ordering. In either path, compare against the gateway before
cutover; do not infer equivalence from a successful write.

**Portal:** Entra > Enterprise applications > job identity > Permissions verifies
the Graph grant; the chosen scheduler's Executions/Runs blade verifies cadence.
The reference deployment has not demonstrated a scheduled 500,000-member Graph
scan ([U17](UNKNOWNS.md)); no portal wizard or installer here silently supplies it.

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

Use the gateway's resource group on these two commands. **Portal:** APIM > APIs
> Named values > `entitlement-resolver-url` and `entitlement-resolver-audience` >
Edit. Copy their values from the resolver deployment outputs; the URL and token
audience are different things.

`entitlement-source` is still `named-value`, so nothing reads the projection yet.
Continue with [the migration runbook](SCALE.md#the-move-itself-step-by-step).
Its step 4 compares the projection with the gateway before anything is flipped.

## Verify

| Check | How | Expected (measured) |
|---|---|---|
| Resolver with no token | `GET https://func-resolver-<prefix>.azurewebsites.net/api/entitlement/<oid>` before step 6 | `401` |
| A user asks for a resolver token | `az account get-access-token --resource api://<resolver-app-id>` | Refused: `AADSTS50105 ... to block users unless they are specifically granted` |
| Resolver from outside after step 6 | The same GET | `403 Web App - Unavailable` |
| Cosmos DB from inside the network | DNS lookup in the runner | The approved private endpoint address, not a public endpoint |
| Foundry directly, after making it private | `POST https://<account>.services.ai.azure.com/anthropic/v1/messages` | `403 Public access is disabled. Please configure private endpoint.` |
| The gateway, end to end | A request after completing comparison and cutover in Scale | `200`, tier from the projection; before the flip, success still proves only the named-value path |
| Revocation and freshness | Remove an isolated test identity, reconcile, then test; separately observe an expired test lease | Refusal after publication/cache; `503` for expiry, never stale admission |

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
| A setting comes back different from what the template asked for, and the deployment still reports success | An Azure Policy with a Modify effect rewrote the request, possibly through a management-group assignment not shown by a narrower list | Read the resource's activity log for `Microsoft.Authorization/policies/modify/action`. Its `policies` property names the assignment and definition. The templates state private values themselves rather than depending on a tenant-specific policy |
| `AADSTS50105` requesting a resolver token | Assignment is required, and the identity is not assigned | Expected for anything but the gateway. For the gateway, repeat the assignment in step 3 |
| Every developer gets `503` right after a gateway redeploy | An installer from before 2026-09-23 wrote the service without its VNet integration. An ARM what-if predicted `virtualNetworkType` External -> None, so the private resolver became unreachable | Re-apply step 7. The current installer reads the integration, public access, portals and protocol settings back and keeps them. Verified by re-running it against the Premium v2 gateway: it printed `preserving VNet mode: External`, finished, and the integration was still there |
| An unentitled developer gets `503 ... not a problem with your access` | A policy from before 2026-09-23 treated the resolver's 404 as an outage | Redeploy the current `infra/policy.xml` |
| `az container exec` truncates or splits a command | Exec runs without a shell, URL-decodes the command (`+` becomes a space) and refuses 5,000 characters or more (`InvalidCommandLength`) | Use `scripts/ClaudeRunner.ps1`, which sends base64url in chunks and checks a SHA-256 |
| A named value change takes effect late | On Premium v2 a named value write took 38 to 41 seconds | Wait for the write to return, then allow a few seconds more |
| Foundry answers `429 RateLimitReached` at low traffic | In the measured Haiku Global Standard deployment, one unit was **1 request and 1,000 tokens per minute**. Other model/deployment types must be read, not assumed | Inspect the actual deployment `rateLimits`; size requests and tokens. See [SCALE.md](SCALE.md) |

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
