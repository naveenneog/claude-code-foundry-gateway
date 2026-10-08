# Deploy the entitlement projection with private networking

## Quickstart

A new gateway gets the projection from the installer, which deploys it and switches the gateway to it
([ADR-0052](adr/0052-cosmos-default-installer.md)):

```powershell
./Install-ClaudeGateway.ps1
```

An existing gateway, from PowerShell 7 at the repository root, in order:

| Step | Command |
|---|---|
| Deploy, populate and compare; named values keep serving | `./scripts/Deploy-ClaudeProjection.ps1 -ResourceGroup <rg> -ApimName <apim> -NamePrefix <prefix>` |
| Switch, after the resolver checks, the compare and switch evidence | `./scripts/Deploy-ClaudeProjection.ps1 -ResourceGroup <rg> -ApimName <apim> -NamePrefix <prefix> -FlipAfterCleanCompare` |
| Publish one developer's change at once, after the Entra group change | `./scripts/Sync-ClaudeAccess.ps1 -ResourceGroup <rg> -ApimName <apim> -User <upn-or-object-id>` |
| The sync job, which applies group changes every 2 hours by default ([below](#scheduled-sync-job-p104)) | `./scripts/Deploy-ClaudeProjectionRenewal.ps1 -ResourceGroup <rg> -ApimName <apim> -NamePrefix <prefix> -AlertEmail <address>` |
| Change the sync job's interval | `./scripts/Set-ClaudeProjectionSyncSchedule.ps1 -ResourceGroup <rg> -ApimName <apim> -Interval <30m-12h or manual>` |

Rollback refreshes and compares the named values, then sets `entitlement-source` back to `named-value`
([switch](#switch-to-the-projection-p95)). A rollback to named values holds only a population within their
capacity, about 93 developers in business-unit membership and about 110 per tier list
([Scale](SCALE.md#what-runs-out-first)). The rest of this article covers each step, the network, the
rights used and the costs.

The gateway decides each developer's tier from two named values. A named value
holds 4,096 characters, which is about 93 to 110 object ids, so beyond roughly a
hundred developers entitlement has to move to the **projection**: one Cosmos DB
record per developer, read through a small resolver Function when the gateway's
cache misses.

This article deploys private endpoints for Cosmos DB and resolver storage. The
installer deploys a public, Entra-authenticated resolver on every tier
([ADR-0052](adr/0052-cosmos-default-installer.md)). `Deploy-ClaudeProjection.ps1` run on its own
makes the resolver inbound path private on Standard v2 and Premium v2. On
Basic v2, the resolver inbound path is public because Basic v2 has no outbound
VNet integration; the resolver is still Microsoft Entra-authenticated and allows
only the gateway managed identity. APIM ingress remains public and authenticated;
resolver telemetry uses public ingestion with Entra authentication. Making the
Foundry account private is a separate step below, not an effect of the
projection templates. It then points the gateway at the resolver
without changing anyone's access, ready for the
[migration runbook](SCALE.md#the-move-itself-step-by-step).
For the manual operator worksheet for the sync-based Cosmos entitlement, see
[Cosmos projection workbook](PROJECTION-WORKBOOK.md).

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
Developer ──Entra token──▶ API Management (public gateway)
                              │  managed identity token, audience api://<resolver-app>
                              ▼
                        Resolver (Flex Consumption)   ◀── public+Entra, or private endpoint on Standard/Premium v2
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
| Resolver Function | Built-in authentication: the gateway's identity only | Public endpoint by default from the installer, on every tier; private endpoint on Standard/Premium v2 with `-ResolverInboundAccess private`, the standalone deployer's default on those tiers | Basic publishing off, FTP off |
| Resolver storage | Entra only | Private endpoints (blob, queue, table) | Off (`allowSharedKeyAccess: false`) |
| Application Insights | Entra only | Public ingestion, identity required | Off (`DisableLocalAuth`) |
| Foundry account | The gateway's identity | Private endpoint | Unchanged by this article |

The resolver only reads, and it can read only the `entitlement` container. The
sync has a different identity that can only write that container. A compromised
resolver therefore cannot change who is entitled.

## Prerequisites

| Requirement | Detail |
|---|---|
| Gateway tier | Any v2 tier. The public resolver profile (the installer's default) uses `inboundAccess=public` with App Service Authentication and exact gateway managed-identity allow lists. The private resolver profile needs **Standard v2 or Premium v2** with outbound VNet integration. Cosmos remains private in both. |
| Roles | Owner, or Contributor plus User Access Administrator, on deployment resources; network join/write rights on the supplied VNet/subnets/DNS; application registration/assignment rights in Entra ID. Azure subscription Owner is not a directory role. |
| Resource providers | Registered: `Microsoft.App`, `Microsoft.DocumentDB`, `Microsoft.Web`, `Microsoft.ContainerInstance`, `Microsoft.Network`, `Microsoft.Storage`, `Microsoft.OperationalInsights`, `Microsoft.Insights` and `Microsoft.Authorization`. These cover the resources and delegations in `infra/projection.bicep:95`, `infra/projection-network.bicep:67` and `infra/resolver.bicep:137`. |
| Region capacity | Cosmos regional capacity cannot be checked in advance or reserved by preflight. Measured: Canada Central and Canada East both refused with `ServiceUnavailable ... high demand ... To request region access for your subscription, please follow this link https://aka.ms/cosmosdbquota`. A private endpoint can point at an account in another region, so a Cosmos DB account elsewhere still stays private in the VNet. |
| Subnets | See the next table. In most enterprises the network team creates them and hands over the resource IDs. |
| Tools | PowerShell **7 or later** for `Deploy-ClaudeProjection.ps1` and `Sync-ClaudeProjection.ps1`; Azure CLI/Bicep, Node/npm and a ZIP-capable `tar`. Bicep `build-params` with `using none` evaluates the existing storage name locally. Shared Graph membership callers that manage named values still support Windows PowerShell 5.1. |
| Switch evidence | The switch writes `entitlement-source` only after the resolver checks, a clean compare and a successful full sync within 24 hours for this Cosmos account and tenant, with no record the resolver would refuse ([ADR-0051](adr/0051-persistent-sync-based-cosmos-entitlement.md)). A full sync through the runner is enough; the sync job is optional. |

| Subnet | Size | Delegation | Notes |
|---|---|---|---|
| Gateway integration | /27 minimum, /24 recommended | `Microsoft.Web/serverFarms` | Needs a network security group. Only for Standard v2 and Premium v2. |
| Private endpoints | Reserve capacity for five projection endpoints plus any Foundry endpoint | None | Cosmos, resolver and resolver storage ×3; Foundry is separate |
| Resolver integration | /27 minimum (/26 used) | `Microsoft.App/environments` | Flex Consumption's own delegation, not `Microsoft.Web/serverFarms`. No private endpoints in it, and no underscore in its name. [Learn: subnet sizing and requirements](https://learn.microsoft.com/azure/azure-functions/flex-consumption-how-to#subnet-sizing-and-requirements) |
| Runner (optional) | /27 | `Microsoft.ContainerInstance/containerGroups` | The container that writes, compares and reads switch evidence from inside the network. |
| Optional sync job | /27 minimum | `Microsoft.App/environments` | Internal workload-profiles Container Apps environment, separate from the resolver subnet. `infra/projection-network.bicep` creates `renewal` at `10.10.3.64/27` in the default `10.10.0.0/16` plan and outputs `renewalSubnetId`; with an existing VNet, pass `renewalSubnetId`. |


### Optional sync job and switch evidence (P97)

The sync job applies group changes on its schedule ([Scheduled sync job](#scheduled-sync-job-p104)). To
publish one developer's change at once, add or remove the developer in the Entra group, then run:

```powershell
.\scripts\Sync-ClaudeAccess.ps1 -ResourceGroup <rg> -ApimName <apim> -User <name-or-object-id>
```

Without `-User`, the script syncs every entitled person. `-Store auto` follows the gateway's
`entitlement-source`; named values refresh the whole allow-list and report the requested developer's written
tier, while the projection sync reads the gateway named value `entitlement-projection-prefix`, exports a fresh
snapshot with the operator's Microsoft Entra sign-in, starts the in-VNet runner when it has stopped,
and writes Cosmos from inside the VNet. The runner uses `sleep 10800` and restart policy `Never`;
`az container start` starts a container group whose containers terminated on their own (Microsoft
Learn, updated 2025-11-17: https://learn.microsoft.com/azure/container-instances/container-instances-stop-start).

Projection records persist until a sync deletes or changes them. A job outage does not expire
existing access. Removing a person takes effect after the sync plus at most the gateway cache window
(`entitlement-cache-seconds`). A disabled Entra account cannot get new tokens; a default access token
lasts 60 to 90 minutes (Microsoft Learn, updated 2026-07-17:
https://learn.microsoft.com/entra/identity-platform/access-tokens).

`scripts/Deploy-ClaudeProjectionRenewal.ps1` deploys the optional sync job for very large
directories:

```powershell
.\scripts\Deploy-ClaudeProjectionRenewal.ps1 -ResourceGroup <rg> -ApimName <apim> -NamePrefix <prefix> -AlertEmail <address>
```

It deploys the registry and the job's identity, builds the image with `az acr build` from the sync package, which
holds `sync/` and `resolver/src/entitlement.mjs` at their repository paths, reads the image digest back
with `az acr manifest show-metadata`, then deploys the job with that digest
([ADR-0049](adr/0049-projection-renewal-deployment.md)). It runs every 2 hours by default; `-SyncInterval` sets
`30m`, `1h`, `2h`, `3h`, `4h`, `6h`, `8h`, `12h` or `manual` ([ADR-0058](adr/0058-scheduled-projection-sync.md)). A run on demand starts with `az containerapp job start`. The job needs Microsoft Graph application
permission `GroupMember.Read.All`, granted by a Privileged Role Administrator or Global Administrator
through `scripts/Grant-ClaudeProjectionRenewalGraphAccess.ps1`. A full sync through the runner sends its
snapshot with `Send-RunnerFile` (`scripts/ClaudeRunner.ps1`): gzip-compressed, in base64url parts of one
`az container exec` each, up to 16 at once, then assembled and checked with a SHA-256 on the runner
([ADR-0053](adr/0053-parallel-compressed-runner-transfer.md)). A snapshot of 500,000 developers is about
3,300 parts; the live measurement is in [P99 status](status/P99.md#live-run). A transfer that cannot end
10 minutes before the snapshot's 2-hour apply-by time is refused before it starts, or stopped when its
measured rate falls behind; nothing is written either way.

The script refuses before any write unless the gateway's `entitlement-projection-prefix` names this
projection. The job writes records without `expiresAt`, which a resolver published before
[ADR-0051](adr/0051-persistent-sync-based-cosmos-entitlement.md) refuses; `scripts/Deploy-ClaudeProjection.ps1`
publishes the current resolver before it records the prefix. A job deployed before ADR-0051 keeps its
older image, which writes `expiresAt` and takes no apply lock, until this script runs again.

The optional job still deploys its registry, image, identity, action group, diagnostic setting and
alerts. Failed-run and Graph-denied alerts always exist; the stale-success alert is emitted only when
a schedule is configured. Switch evidence does not read the job definition, image digest, action
group or receipt.

Outbound firewall or forced-tunnel rules must allow `login.microsoftonline.com`,
`graph.microsoft.com`, `management.azure.com`, the ACR login server and data endpoint, and the Cosmos
private endpoint through `privatelink.documents.azure.com`. The job writes status records into
`claude/entitlement` with partition key `projection-status::<tenantId>`,
`type=projection-reconciliation-status` and a seven-day TTL; resolver point reads by developer object
id cannot return them.

Deployment order: deploy the projection (`scripts/Deploy-ClaudeProjection.ps1`), sync the projection
(on demand through `scripts/Sync-ClaudeAccess.ps1`, or manually start the optional job after its Graph
grant), then run the [switch](#switch-to-the-projection-p95). Rollback refreshes and compares named
values, then sets `entitlement-source` back to `named-value`.

Switch evidence runs fixed repository code through `scripts/ClaudeRunner.ps1`. It requires the newest
successful full sync status for this account, database, container and tenant to have finished within
24 hours, and no live entitlement record the resolver would refuse. Invalid live records refuse with
a count and up to three SHA-256 object-id samples, never raw ids. A targeted sync writes a user-mode
status record and does not count as switch evidence.

### Scheduled sync job (P104)

The sync job applies Entra group changes without an operator
([ADR-0058](adr/0058-scheduled-projection-sync.md)). Each run reads the standard and premium tier groups and
every business-unit group in the gateway's `bu-registry` through Microsoft Graph, compares them with the
entitlement container and writes only the developers who were added, removed or moved to another tier or unit
(`sync/src/plan.mjs`). Membership in a business-unit group alone gives no access.

| `-SyncInterval` | Cron (UTC) | Runs a month | No-success alert range |
|---|---|---|---|
| `30m` | `*/30 * * * *` | 1,460 | 75 minutes |
| `1h` | `0 * * * *` | 730 | 135 minutes |
| `2h` (default) | `0 */2 * * *` | 365 | 255 minutes |
| `3h` | `0 */3 * * *` | 243 | 375 minutes |
| `4h` | `0 */4 * * *` | 183 | 495 minutes |
| `6h` | `0 */6 * * *` | 122 | 735 minutes |
| `8h` | `0 */8 * * *` | 91 | 975 minutes |
| `12h` | `0 */12 * * *` | 61 | 1,455 minutes |
| `manual` | none | runs only when started | no rule |

Runs a month use 730 hours (`scripts/AzureRetailPrice.ps1`). Container Apps evaluates cron expressions in UTC
([Jobs in Azure Container Apps](https://learn.microsoft.com/azure/container-apps/jobs), updated 2026-09-16).
Intervals shorter than 30 minutes are refused. 24 hours is not offered: its no-success range, 2 x 1,440 + 15
minutes, is longer than the 2 days a log search alert can read.

Timing:

- A developer added to a tier group gets access at the next run. A refusal the gateway cached for that
  developer before the run lasts at most 60 seconds (`infra/policy.xml:162`).
- A developer removed from every tier group loses access at the next run plus at most
  `entitlement-cache-seconds`, the time the gateway caches an allowed answer (3,600 seconds by default, `infra/main.bicep:158`; `infra/policy.xml:140`).

`Install-ClaudeGateway.ps1` deploys the job with the projection. `-ProjectionSyncInterval` takes the values
above or `none`, which deploys no job. Without the parameter, a re-run keeps the interval of the deployed job,
and a first install uses `2h`. A deployed cron outside the table stops a re-run before any write until
`-ProjectionSyncInterval` names an interval. With `none`, a deployed job is left as it is, and the review and
next steps name its schedule. A re-run that redeploys the job keeps its alert addresses (from the live action
group), its registry SKU, and the workspace and subnet of its renewal deployment, and changes only the job that
deployment created. When the action group has no address, the run uses the publisher address and says so. A
registry with public network access disabled, or a SKU other than Basic or Premium, stops the re-run before any
write, because the registry template would change it. A failed renewal deployment is deployed again with the
settings it recorded. The review before any write shows the interval, the runs a month and the
missed-run range. `-DeploySyncJob` is still accepted and has no effect.

Change the interval of a deployed job:

```powershell
.\scripts\Set-ClaudeProjectionSyncSchedule.ps1 -ResourceGroup <rg> -ApimName <apim> -Interval 30m
```

The script reads the deployed job's image digest and alert addresses, and the tier groups, workspace and subnet
that the `projection-renewal-<prefix>` deployment recorded. It prints the change and runs
`scripts/Deploy-ClaudeProjectionRenewal.ps1` with the same image, the new `-SyncInterval` and `-KeepRegistry`, so
the job's schedule and the no-success alert change together and the registry is not deployed again. It changes
only the job that deployment created, refuses a job whose tier groups differ from the recorded ones, and refuses
while the last renewal deployment has not succeeded. When the job already runs at the requested interval, the
script writes nothing unless the alert rules or the recorded schedule differ from the template (a scheduled job
has one no-success rule, a manual job none, and neither keeps P97's 45-minute rule); then it redeploys to repair
them. `-WhatIf` shows the change without writing. In the Azure
portal, run the same command in Azure Cloud Shell (PowerShell) from a clone of this repository. Changing the
job's cron expression alone leaves the no-success alert on the old range.

The job needs Microsoft Graph application permission `GroupMember.Read.All`. The deploy script reads whether the
job identity holds it, records `held`, `missing` or `unknown` in its receipt, and writes nothing in Graph. A
Privileged Role Administrator or Global Administrator grants it once with
`scripts/Grant-ClaudeProjectionRenewalGraphAccess.ps1 -PrincipalId <id>`. Until then each run stops at the Graph
stage, writes nothing, and fires the Graph-denied alert.

An unattended run that would delete more than max(10, 10% of the entitlement records) writes nothing and ends
with stage `removal-ceiling`, which fires the failed-run alert. Additions, tier changes and business-unit changes
have no limit. `Sync-ClaudeAccess.ps1` applies such a removal attended.

A run that takes longer than the interval overlaps the next execution. The later run waits up to 900 seconds
for the apply lock; if the earlier run still holds it, the later run stops before any write and the failed-run
alert fires ([U165](UNKNOWNS.md)).

Cost: USD 0.00003 per run-second for the job's 1 vCPU and 2 GiB (`eastus2` retail prices, read 2026-10-07)
above the subscription's monthly Container Apps free grant of 180,000 vCPU-seconds and 360,000 GiB-seconds,
which other Container Apps workloads share ([Billing in Azure Container Apps](https://learn.microsoft.com/azure/container-apps/billing), updated 2026-03-25).

### Switch to the projection (P95)

`scripts/Deploy-ClaudeProjection.ps1 -FlipAfterCleanCompare` runs `Invoke-ClaudeProjectionSwitch
-ResourceGroup <rg> -ApimName <apim> -NamePrefix <prefix>`. It deploys, publishes and applies nothing:

```powershell
pwsh -NoProfile -File .\scripts\Deploy-ClaudeProjection.ps1 `
  -ResourceGroup <rg> -ApimName <apim> -NamePrefix <prefix> -FlipAfterCleanCompare -WhatIf
```

1. Resolver checks: deployment `projection-resolver-<prefix>`, live resolver URL/audience named values,
   resolver site settings, and the resolver app's service principal. The deployer creates that service
   principal when it is missing because Entra refuses tokens for an app without one (`AADSTS500011`).
2. Drift check: `scripts/Compare-ClaudeEntitlement.ps1 -FailOnDrift` compares the gateway's named
   values with Entra and exports the gateway's decisions. A gateway with empty `allow-standard`,
   `allow-premium` and `bu-members` lists skips the named-value drift/compare path and compares the
   projection with a fresh Entra snapshot instead.
3. Runner compare: `apply-projection.mjs --compare` or `--compare-snapshot` reads the projection and
   writes nothing.
4. Evidence: a successful full sync in the last 24 hours and no record the resolver would refuse.
5. Backup: entitlement named values are written to a projection-switch backup.
6. One write: `entitlement-source` is set to `projection`.

A refusal leaves `entitlement-source` unchanged and writes no backup. `-WhatIf` runs through evidence
and stops before the backup. The guided Entitlement step reads the gateway named value
`entitlement-projection-prefix` and calls the same switch. `scripts/Restore-ClaudeGateway.ps1` does not
move `entitlement-source` to `projection`; it names this switch instead. A deployment of
`infra/main.bicep` with `entitlementSource=projection`, like the manual command in the [Azure CLI
guide](AZ-COMMANDS.md#10-optional-cosmos-projection), skips switch evidence.


#### Owner-attended live run

On 2026-10-06 `scripts/Test-ClaudeLiveProjection.ps1` ran the installer's projection path in a test
tenant on a disposable Basic v2 gateway: steps 1, 2 (with `-User`) and 4, then requests that returned
200, 403 after a removal and targeted sync, and 200 after re-adding. Steps 3 and 6, the optional job
and a full sync without `-User` have not run in a live tenant. Each row states what the step shows.

| Step | Command or place | Shows |
|---|---|---|
| 1. Projection | `scripts/Deploy-ClaudeProjection.ps1` without `-FlipAfterCleanCompare` ([one-command deployment](#one-command-deployment)) | Cosmos, the network, the resolver, `entitlement-projection-prefix`, the resolver named values, population and a clean compare |
| 2. Sync | `scripts/Sync-ClaudeAccess.ps1 -ResourceGroup <rg> -ApimName <apim>` or `az containerapp job start` for the optional job | A successful full sync status record exists in Cosmos |
| 3. Check | Step 1's command with `-FlipAfterCleanCompare -WhatIf` | Resolver checks, drift check, runner compare and switch evidence pass |
| 4. Switch | Step 3's command without `-WhatIf` | One write, the backup path and the rollback text |
| 5. Requests | Section 11 of the [Azure CLI guide](AZ-COMMANDS.md#11-verification) | Requests resolve through the projection |
| 6. Rollback, when needed | `scripts/Sync-ClaudeAccess.ps1`, `scripts/Compare-ClaudeEntitlement.ps1 -FailOnDrift`, then `entitlement-source` set to `named-value` | Named values serve again |

### One-command deployment

**Projection switching is evidence-gated.** With persistent records, a sync outage does not stop
developers. Switching uses `Invoke-ClaudeProjectionSwitch`, which checks resolver configuration,
drift, the runner compare and Cosmos evidence before writing `entitlement-source=projection`
([ADR-0051](adr/0051-persistent-sync-based-cosmos-entitlement.md)).

`-PreflightOnly` runs the same checks as a normal deployment, with no Azure writes, and exits
nonzero on any FAIL. The normal estimate is **30-90 seconds**, including **25 seconds**
between two Graph reads. Slow customer networks can extend it. Local temporary files are removed
after Bicep/name evaluation (`scripts/ClaudeProjectionChecks.ps1:27`).

```powershell
pwsh -NoProfile -File .\scripts\Deploy-ClaudeProjection.ps1 `
  -SubscriptionId <subscription-id> `
  -ResourceGroup <rg> -ApimName <apim> -NamePrefix <prefix> `
  -Location eastus2 -Sku BasicV2 -ResolverInboundAccess public `
  -ResolverAppId <resolver-app-id> -PreflightOnly
```

The report contains **check, result, evidence, remedy and who acts**, with stacked records on
narrow consoles, including 100-column terminals. Failed resource/Graph checks remain FAIL.
Unproven app-creation rights are WARN, not invented denial. The checks cover the PowerShell host,
local tools, selected subscription and gateway identity, two Graph probes, the required standard
group and optional premium group (confirmed absence passes with a note),
resolver registration, providers, inherited/group-aware resource-group roles and derived names.
The safe prefix is 1-37 lowercase letters/digits with separated hyphens and alphanumeric ends.
Cosmos, Function and storage names have global availability checks; an existing exact resource
in the target resource group is reusable. The storage hash uses ARM's canonical resource-group
id, not the casing of the typed argument. Regional capacity is a NOTE, not a PASS.

A run without `-PreflightOnly` performs these checks before its first app/resource write.
The following deployment leaves named values authoritative:

```powershell
pwsh -NoProfile -File .\scripts\Deploy-ClaudeProjection.ps1 `
  -SubscriptionId <subscription-id> `
  -ResourceGroup <rg> -ApimName <apim> -NamePrefix <prefix> `
  -Location eastus2 -Sku BasicV2 -ResolverInboundAccess public `
  -ResolverAppId <resolver-app-id>
```

For Standard v2 and Premium v2, omit `-ResolverInboundAccess` and the script
chooses `private`. The command deploys private Cosmos, projection networking and
the resolver, sets the gateway's `entitlement-resolver-url` and `entitlement-resolver-audience` to
the resolver's outputs, exports named-value decisions, populates from Entra, compares the
projection against those decisions and leaves `entitlement-source` unchanged. On a gateway whose
`entitlement-source` is already `projection`, the run redeploys the resolver the gateway calls, so it
stops after the preflight and before any write, `-PreflightOnly` and `-WhatIf` included, unless the
site `func-resolver-<prefix>` that the run redeploys serves the gateway's `entitlement-resolver-url` and the run's
resolver app is the one in its `entitlement-resolver-audience` (`scripts/ClaudeProjectionChecks.ps1:201-227`).
This one-command
path uses the gateway resource group for its projection resources. With `-FlipAfterCleanCompare` the command deploys nothing: it reads the gateway's
`entitlement-projection-prefix` and runs the [switch](#switch-to-the-projection-p95); `-WhatIf` runs
its checks and stops before the backup.
A declined deployment/population/comparison prerequisite aborts the run; it does not fall through
to a later step. `-WhatIf` without a switch request prints the planned operations without
writing Azure resources. It does not require creating an app merely to preview the plan
(`scripts/Deploy-ClaudeProjection.ps1:114-117`).

#### Resolver registration and the customer's Entra admin

With `-ResolverAppId`, the app must exist and expose `api://<id>`. Without it, an existing
unambiguous registration is reusable. A member user with explicitly true
`authorizationPolicy.defaultUserRolePermissions.allowedToCreateApps` has positive default-role
evidence. That read requires Graph `Policy.Read.All` and is skipped when an app id is supplied.
An unreadable policy, disabled default, guest or delegated/custom-role case is WARN:
"cannot confirm; if creation fails, the customer's admin creates the app and you pass
-ResolverAppId". Default-role policy is not effective-role enumeration. Explicit app-resource
or creation failures still stop the run rather than claiming success.

#### Rights used by the checks

| Check | Read permission or local capability |
|---|---|
| PowerShell, node/npm/tar, Bicep, prefix syntax | Local executable/repository access; no Azure role |
| Azure sign-in and subscription | An Azure CLI sign-in for the selected subscription |
| Gateway, resource group, providers, existing resources and global name availability | ARM read/name-availability access in the selected subscription and resource group; the required deployment roles are Owner, or Contributor plus User Access Administrator |
| Role assignments, including inherited/group roles | Azure role-assignment read access and Graph membership access for group expansion; eligibility alone is not an active assignment |
| Two Graph `/me` probes | Delegated `User.Read` or broader profile-read permission |
| Tier group collections and shared membership readers | `GroupMember.Read.All` or broader group/directory-read permission; service-principal detail can require application-read access |
| Gateway service principal; existing resolver app/id URI | Graph application/service-principal read permission, such as `Application.Read.All`, and applicable user/role access |
| Default app-registration policy, only when no existing app is selected | `Policy.Read.All`; unreadable policy produces WARN, and `-ResolverAppId` avoids this read |
| Switch (`-FlipAfterCleanCompare`) | API Management named-value read and write; ARM read of the resolver deployment and resolver site; the list action on the site's application settings (`Microsoft.Web/sites/config/list/action`, which the Reader role does not include); Graph read for the drift check; and Cosmos data read through the runner ([ADR-0051](adr/0051-persistent-sync-based-cosmos-entitlement.md)) |
| Projection sync (`Sync-ClaudeAccess.ps1`) | API Management named-value read; delegated Graph `GroupMember.Read.All` for a full sync, plus `User.ReadBasic.All` for `-User`; and, on `aci-projtest-<prefix>`, container group read, `Microsoft.ContainerInstance/containerGroups/start/action` and `Microsoft.ContainerInstance/containerGroups/containers/exec/action` |

A command run through `az container exec` runs as the runner's managed identity, which holds
Cosmos DB Built-in Data Contributor on `claude/entitlement`. Anyone who can run a projection sync can
therefore write any entitlement record, and the status record that switch evidence reads. That is the
same trust as write access to the named values `allow-standard`, `allow-premium` and `bu-members`,
so the runner's exec permission is an entitlement-write permission.

Sources, accessed 2026-09-29: [user GET](https://learn.microsoft.com/graph/api/user-get?view=graph-rest-1.0),
[group list](https://learn.microsoft.com/graph/api/group-list?view=graph-rest-1.0),
[application GET](https://learn.microsoft.com/graph/api/application-get?view=graph-rest-1.0),
[authorization policy GET](https://learn.microsoft.com/graph/api/authorizationpolicy-get?view=graph-rest-1.0)
and [delegated app roles](https://learn.microsoft.com/entra/identity/role-based-access-control/delegate-app-roles).

The admin's portal path is **https://entra.microsoft.com > Entra ID > App registrations >
New registration > Accounts in this organizational directory only > Register**. **Overview**
supplies the Application (client) ID. **Expose an API > Application ID URI** contains
`api://<that-client-id>`. The equivalent admin CLI sequence is:

```powershell
az login --tenant <tenant-id>
$appId = az ad app create --display-name claude-projection-resolver-<prefix> `
  --sign-in-audience AzureADMyOrg --query appId -o tsv
if ($LASTEXITCODE -ne 0 -or -not $appId) { throw 'Resolver registration failed; no update attempted.' }
az ad app update --id $appId --identifier-uris "api://$appId"
if ($LASTEXITCODE -ne 0) { throw 'Resolver identifier URI update failed.' }
az ad sp create --id $appId
if ($LASTEXITCODE -ne 0) { throw 'Resolver service principal creation failed.' }
```

Microsoft Entra ID issues no token for an application that has no service principal in the tenant
(AADSTS500011; [application and service principal objects](https://learn.microsoft.com/entra/identity-platform/app-objects-and-service-principals)).
A registration made in the portal gets one; `az ad app create` does not. The deployer creates the
service principal when it is missing, and the switch refuses without it.

The operator's deployment uses `-ResolverAppId $appId`. Azure subscription Owner is not an Entra
application-registration role. The deployer reports an actual creation failure, including
insufficient privileges, and never updates an empty id (`scripts/ClaudeProjectionChecks.ps1:8`).
Sources, accessed 2026-09-29:
[authorization policy GET](https://learn.microsoft.com/graph/api/authorizationpolicy-get?view=graph-rest-1.0),
[app registration](https://learn.microsoft.com/entra/identity-platform/quickstart-register-app),
[Azure CLI app commands](https://learn.microsoft.com/cli/azure/ad/app).

#### CAE and IP variation

The diagnostic recognizes
`Continuous access evaluation resulted in challenge with result: InteractionRequired and code: LocationConditionEvaluationSatisfied`.
It does not translate this, a 401/403 or a network error into "group not found". Only a successful,
empty Graph collection means an absent optional group (`scripts/ClaudeGraphMembership.ps1:45`).

The operator's sign-in and Graph requests need a consistent VPN state, fully on or fully off.
The network team's checks cover split tunneling and IPv4/IPv6 egress differences. The customer's
Entra admin reviews the observed addresses, the named location and, if approved by that admin,
a time-limited temporary exclusion. Azure Cloud Shell uses another network location and a
temporary host; Conditional Access still applies, private VNet access is not automatic, and an
interactive session is not a reconciler. Its documented idle timeout is 20 minutes.
Sources, accessed 2026-09-29:
[CAE IP address configuration](https://learn.microsoft.com/entra/identity/conditional-access/howto-continuous-access-evaluation-troubleshoot)
and [Cloud Shell overview](https://learn.microsoft.com/azure/cloud-shell/overview);
[Cloud Shell VNet isolation](https://learn.microsoft.com/azure/cloud-shell/vnet/overview)
describes its separate private-network deployment and associated resources/costs.

#### Basic v2 pictures, captured live

The lead's batch captured these on 2026-09-26 from a short-lived Basic v2 capture estate built
with the command above (synthetic entitlement records only), then removed. Each picture has a
record in `docs/guide/portal-captures.json`; names are replaced with demo values.

| Spec id | Manual blade to verify | Picture |
|---|---|---|
| `p61-basic-gateway-overview` | API Management > Overview; tier and gateway URL | ![Basic v2 API Management overview: Online, East US 2, Tier Basic v2, 1 unit](guide/p61-basic-gateway-overview.png) |
| `p61-basic-resolver-authentication` | Function app > Settings > Authentication | ![Resolver authentication: App Service authentication Enabled, Require authentication, unauthenticated requests return HTTP 401, Microsoft identity provider with the resolver app registration](guide/p61-basic-resolver-authentication.png) |
| `p61-basic-resolver-networking` | Function app > Settings > Networking | ![Resolver networking: public inbound enabled with no access restrictions (Entra authentication is the boundary on Basic v2), outbound virtual network integration into the resolver subnet](guide/p61-basic-resolver-networking.png) |
| `p61-basic-cosmos-networking` | Azure Cosmos DB account > Settings > Networking > Public access | ![Cosmos DB networking: Public network access Disabled](guide/p61-basic-cosmos-networking.png) |
| `p61-basic-named-values-flipped` | API Management > APIs > Named values > `entitlement-source` | ![The entitlement-source named value, type Plain, value projection after the clean comparison](guide/p61-basic-named-values-flipped.png) |

The resolver's inbound picture shows the documented Basic v2 risk: the endpoint is public, and
access depends on App Service authentication with the gateway's managed identity as the only
allowed caller ([ADR-0028](adr/0028-basic-v2-projection-resolver.md)).

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

![Live Networking blade of the projection's Cosmos DB account: Public access tab with Public network access set to Disabled, so no public traffic can reach it](guide/docs-review-cosmos-networking.png)

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

![Live resolver Authentication blade: App Service authentication Enabled, Require authentication, unauthenticated requests get HTTP 401, token store Disabled, and one Microsoft identity provider bound to the resolver's app registration](guide/docs-review-resolver-authentication.png)

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

![Live resolver Networking blade: public network access Disabled, one private endpoint, outbound virtual network integration into the resolver subnet with its network security group, and no NAT gateway or route](guide/docs-review-resolver-networking.png)

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

![Live Foundry Networking blade, Firewalls and virtual networks tab, with its Private endpoint connections and Network Injection tabs: this shared reference account still allows All networks, the state before this step](guide/docs-review-foundry-networking.png)

The reference account in this picture is shared with other workloads and is
still public. That is the state this step changes: after the private endpoint
and DNS are verified, select **Disabled** (or **Selected Networks and Private
Endpoints**), save, and repeat the verification above.

### Switch evidence

A successful full sync supplies switch evidence for 24 hours. The deployer, installer and guided
Entitlement step switch through `Invoke-ClaudeProjectionSwitch`, which deploys and applies nothing.
Evidence is read through the in-VNet runner and is destination-bound to the Cosmos account, database,
container and tenant. It requires no renewal receipt and no job definition. A targeted projection `-User` sync is
for one developer and does not count as switch evidence; named-value `-User` runs a whole-list refresh because
named values are rewritten as complete lists.

The switch refuses when a live entitlement record is one the resolver would refuse: wrong tenant,
unknown tier, malformed generation, missing or future `lastVerifiedAt`, or a status record reached
through the wrong query. The refusal reports a count and up to three SHA-256 object-id samples.


Apply/compare failure diagnostics expose counts and hashed samples, not raw email or unit values.
They contain at most 40 lines and 4,096 characters in total, counting the heading line and any
truncation marker, so at most 39 input-line summaries. Unstructured output is
represented by a length and digest; full private content remains in the authorized runner logs
(`scripts/ClaudeRunner.ps1:55`).

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

# Send a package, not a directory: Send-RunnerFile accepts one file. The package holds sync/ and
# resolver/src/entitlement.mjs, which sync/src/plan.mjs imports (ADR-0049).
$archive = Join-Path (Get-Location) ('backups\sync-' + [guid]::NewGuid().ToString('N') + '.tar.gz')
. ./scripts/ClaudeProjectionPackage.ps1
$null = New-ClaudeProjectionSyncArchive -Path $archive
. ./scripts/ClaudeRunner.ps1
Send-RunnerFile -ResourceGroup $rg -Name $runner -Path $archive -Destination /work/sync-source.tar.gz
Invoke-RunnerCommand -ResourceGroup $rg -Name $runner -Command "node -e require('fs').mkdirSync('/work',{recursive:true})"
Invoke-RunnerCommand -ResourceGroup $rg -Name $runner -Command 'tar -x -z -f /work/sync-source.tar.gz -C /work'
Invoke-RunnerCommand -ResourceGroup $rg -Name $runner -Command 'npm --prefix /work/sync ci --omit=dev --ignore-scripts'

# Now export using the GATEWAY resource group, copy, and apply before the snapshot apply-by deadline.
$accountResourceId = az cosmosdb show -n cosmos-<prefix> -g $rg --query id -o tsv
./scripts/Sync-ClaudeProjection.ps1 -Account cosmos-<prefix> -ApimName <apim> `
    -ResourceGroup '<gateway-resource-group>' -ExportPath .\backups\snapshot.json
Send-RunnerFile -ResourceGroup $rg -Name $runner -Path .\backups\snapshot.json -Destination /work/snapshot.json
Invoke-RunnerCommand -ResourceGroup $rg -Name $runner -Command `
    "node /work/sync/src/apply-projection.mjs --cosmos https://cosmos-<prefix>.documents.azure.com:443/ --tenant <tenant-id> --account-resource-id $accountResourceId --snapshot /work/snapshot.json"
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
unchanged run. That measurement was taken on 2026-09-24 under the previous lease model, where all 8
unchanged members were refreshed in 1.88 seconds. Under the persistent model, unchanged records are
not rewritten.

**B. The optional job reads Entra itself.** This path is for very large directories. The job's
identity needs the Microsoft Graph application permission `GroupMember.Read.All`, granted by a
Privileged Role Administrator or Global Administrator. The job runs `apply-projection.mjs --graph`
with the tier group ids and the gateway id from its environment, and reads `bu-registry` and
`bu-parents` on every run, in the deepest-first, then registry order of the named-value path. A hand
run of `--graph` takes `--standard`, `--premium` and ordered `--bu unit=group` arguments instead;
with neither `--bu` nor a gateway id it writes no business units, which does not reproduce the
exported unit mapping. Measured: an operator without a directory role is refused with
`Authorization_RequestDenied`.

`-ApimName` and `-ResourceGroup` make the PowerShell export read the gateway's registry and parent
ordering. In either path, compare against the gateway before cutover.

**Portal:** Entra > Enterprise applications > job identity > Permissions verifies the Graph grant;
Container Apps job > Execution history verifies manual or scheduled runs. The reference deployment
has not demonstrated a scheduled 500,000-member Graph scan ([U17](UNKNOWNS.md)); the sync-job deploy
script never grants Graph access itself.

### Freshness and operating envelope

A projection record remains valid until a later sync deletes or changes it. A complete directory
observation stamps `reconciliationGeneration` and `lastVerifiedAt`; malformed or future verification
metadata returns 503. Exported snapshots keep an apply-by deadline of 7,200 seconds from scan start,
so an old snapshot cannot replay old membership. A scan that fails writes nothing; a failed apply may
leave mixed generations and exits nonzero.

Removing a person takes a sync and then at most the gateway cache window
(`entitlement-cache-seconds`). A disabled Entra account cannot get new tokens; a default access token
lasts 60 to 90 minutes (Microsoft Learn, updated 2026-07-17:
https://learn.microsoft.com/entra/identity-platform/access-tokens). The bound is for new requests; it
does not interrupt an already-running model stream.

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
audience are different things. On a gateway whose `entitlement-source` is `projection`, a change to
these values moves every request to the new resolver at once. `scripts/Deploy-ClaudeProjection.ps1`
runs this step in its normal run; on a gateway whose `entitlement-source` is `projection`, it stops
before any write unless the run redeploys the resolver these values name, with the app in the
audience. The [switch](#switch-to-the-projection-p95) refuses unless both
are the outputs of `projection-resolver-<prefix>` and the site serves that URL.

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
| Revocation and freshness | Remove an isolated test identity, sync that identity, then test | Refusal after publication/cache; disabled accounts lose access when the current token expires |

## What the gateway does once it reads the projection

| Situation | Response | Measured |
|---|---|---|
| Entitled record present | Served; cached for `entitlement-cache-seconds` | Still served when removed from the named-value list, which proves the projection is the source |
| No record | `403 permission_error`; the refusal is cached for at most 60 seconds | Second call 567 ms, answered from cache |
| Record added back | Served once the refusal expires | 200 after the short cache |
| Resolver down, answer cached | Served until the window ends | 200 |
| Resolver down, window ended | `503`, `Retry-After: 5`, "the entitlement service did not answer" | 503, then 200 when it returned |
| Rolled back to named values | The lists decide again | 403 for anyone the lists had not been kept up to date for |

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Cosmos DB account creation fails with `ServiceUnavailable ... high demand` | The subscription has no capacity in that region | Request region access (aka.ms/cosmosdbquota) or use another region with the private endpoint in your VNet |
| Deployment fails with `InvalidResourceLocation` and `cosmos-<prefix> already exists in location X` | The resource group already has the projection Cosmos account in region X | Re-run with `-Location X`, or choose another prefix |
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
to the cost script. Neither total includes optional sync-job execution or directory reads.
At 500,000 members and hourly reconciliation, the write count is about
365 million/month. The measured create charge (5.9 RU) would cost $538.38 at
$0.25/million RU; that is an **illustration**, not a measured upsert or scheduled
sync bill. Include Graph, the runner, retries and telemetry in an operating quote.

For P61's 100-500 developer installer choice, run
`./scripts/Measure-ClaudeProjectionCost.ps1 -P61Scenarios`. On 2026-09-26 in
East US 2 it reported:

| Developers | Shape | Monthly list cost, excluding APIM | At rest |
|---:|---|---:|---:|
| 100 | Basic v2 public resolver, private Cosmos | $57.48 | $57.48 |
| 100 | Standard/Premium v2 private resolver, private Cosmos | $65.28 | $65.28 |
| 500 | Basic v2 public resolver, private Cosmos | $57.48 | $57.48 |
| 500 | Standard/Premium v2 private resolver, private Cosmos | $65.28 | $65.28 |

The Basic v2 row removes the resolver private endpoint and its DNS zone. It does
not make Cosmos public.

## Related

- [SCALE.md](SCALE.md): the migration runbook and what 500,000 developers need
- [ADR-0005](adr/0005-identity-projection.md): why a projection, and its failure rules
- [ADR-0011](adr/0011-projection-platform.md): why Cosmos DB serverless and Flex Consumption
- [ADR-0028](adr/0028-basic-v2-projection-resolver.md): Basic v2 public resolver and mitigations
- [NETWORK.md](NETWORK.md): what the developer clients themselves need to reach
