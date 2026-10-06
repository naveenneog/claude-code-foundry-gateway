# Cosmos entitlement projection operator workbook

This workbook gives the manual procedure to deploy, populate, switch to and operate the Cosmos DB entitlement projection, where access lasts until a sync moves or removes the person. The installer path is in [Setup](SETUP.md); this workbook gives the same steps by hand.

Sources: [ADR-0051](adr/0051-persistent-sync-based-cosmos-entitlement.md), [secure projection](SECURE-PROJECTION.md#one-command-deployment).

## Quickstart

Preflight checks the local tools, subscription, gateway, Graph access, resource providers, roles and names without Azure writes.

```powershell
pwsh -NoProfile -File .\scripts\Deploy-ClaudeProjection.ps1 `
  -SubscriptionId <subscription-id> `
  -ResourceGroup <rg> -ApimName <apim> -NamePrefix <prefix> `
  -Location <location> -Sku <sku> -ResolverInboundAccess <public-or-private> `
  -StandardGroup <standard-group> -PremiumGroup <premium-group> `
  -PreflightOnly
```

Deploy, populate and compare creates the projection, writes resolver named values, applies a full snapshot through the runner and leaves named values authoritative.

```powershell
pwsh -NoProfile -File .\scripts\Deploy-ClaudeProjection.ps1 `
  -SubscriptionId <subscription-id> `
  -ResourceGroup <rg> -ApimName <apim> -NamePrefix <prefix> `
  -Location <location> -Sku <sku> -ResolverInboundAccess <public-or-private> `
  -StandardGroup <standard-group> -PremiumGroup <premium-group>
```

Switch check runs the resolver checks, drift check, runner compare and switch evidence, with no backup and no write.

```powershell
pwsh -NoProfile -File .\scripts\Deploy-ClaudeProjection.ps1 `
  -ResourceGroup <rg> -ApimName <apim> -NamePrefix <prefix> `
  -StandardGroup <standard-group> -PremiumGroup <premium-group> `
  -FlipAfterCleanCompare -WhatIf
```

Switch performs the same evidence checks, writes a projection-switch backup and sets `entitlement-source` to `projection`.

```powershell
pwsh -NoProfile -File .\scripts\Deploy-ClaudeProjection.ps1 `
  -ResourceGroup <rg> -ApimName <apim> -NamePrefix <prefix> `
  -StandardGroup <standard-group> -PremiumGroup <premium-group> `
  -FlipAfterCleanCompare
```

After an Entra group change, targeted sync updates one developer.

```powershell
.\scripts\Sync-ClaudeAccess.ps1 -ResourceGroup <rg> -ApimName <apim> -User <upn-or-object-id>
```

Full sync reconciles every entitled developer and writes full-sync switch evidence.

```powershell
.\scripts\Sync-ClaudeAccess.ps1 -ResourceGroup <rg> -ApimName <apim>
```

Sources: [secure projection owner-attended run](SECURE-PROJECTION.md#owner-attended-live-run), [switch](SECURE-PROJECTION.md#switch-to-the-projection-p95), [ADR-0051 decisions](adr/0051-persistent-sync-based-cosmos-entitlement.md#decision).

## Roles

| Role | Work | Rights boundary |
|---|---|---|
| Operator | Preflight, deployment, population, compare, switch, targeted sync, full sync, rollback. | Azure deployment rights, APIM named-value read/write, delegated Graph reads, runner read/start/exec. |
| Entra administrator | App registration and group creation when the operator cannot create or assign them. | Application registration/assignment rights in Entra ID; Azure subscription Owner is not a directory role. |
| Privileged Role Administrator or Global Administrator | Optional sync job Graph application permission. | Grants Microsoft Graph application permission `GroupMember.Read.All` to the job identity. |
| Network team | Private resolver, VNet, subnets and DNS. | Supplies or approves VNet, subnet and private DNS resources. |

Sources: [secure projection prerequisites](SECURE-PROJECTION.md#prerequisites), [rights used by the checks](SECURE-PROJECTION.md#rights-used-by-the-checks), `scripts/Grant-ClaudeProjectionRenewalGraphAccess.ps1`.

## Prerequisites

| Requirement | Exact prerequisite |
|---|---|
| PowerShell | PowerShell 7 or later for projection deploy and projection snapshot export. |
| Azure CLI and Bicep | Azure CLI with Bicep; the Azure CLI guide was checked against Azure CLI 2.86.0 help and templates. |
| Node.js and npm | Local Node/npm for packaging; runner-side `npm --prefix /work/sync ci --omit=dev --ignore-scripts --no-audit --fund=false`. |
| Archive tool | A `tar` executable that writes the resolver and sync package archives. |
| Azure roles | Owner, or Contributor plus User Access Administrator, on deployment resources; network join/write rights on supplied VNet/subnets/DNS. |
| Resource providers | `Microsoft.App`, `Microsoft.DocumentDB`, `Microsoft.Web`, `Microsoft.ContainerInstance`, `Microsoft.Network`, `Microsoft.Storage`, `Microsoft.OperationalInsights`, `Microsoft.Insights`, `Microsoft.Authorization`. |
| Graph delegated reads | Full sync needs delegated `GroupMember.Read.All`; targeted `-User` also needs `User.ReadBasic.All`. |
| Switch permissions | APIM named-value read/write, resolver deployment and site reads, `Microsoft.Web/sites/config/list/action`, Graph drift read and Cosmos data read through the runner. |
| Runner permissions | Container group read, start and exec on `aci-projtest-<prefix>`. |
| Region | `-Location` equals the existing `cosmos-<prefix>` region when that account already exists. |

Sources: [secure projection prerequisites](SECURE-PROJECTION.md#prerequisites), [rights used by the checks](SECURE-PROJECTION.md#rights-used-by-the-checks), [ADR-0051 decision 5](adr/0051-persistent-sync-based-cosmos-entitlement.md#decision), [Azure CLI guide status](AZ-COMMANDS.md).

## Worksheet

| Value | Placeholder | Command that reads it when one exists |
|---|---|---|
| Subscription id | `<subscription-id>` | `az account show --query id -o tsv` |
| Tenant id | `<tenant-id>` | `az account show --query tenantId -o tsv` |
| Gateway resource group | `<rg>` | `az apim list --query "[?name=='<apim>'].resourceGroup" -o tsv` |
| API Management name | `<apim>` | `az apim list -g <rg> --query "[].name" -o tsv` |
| Projection name prefix | `<prefix>` | `az apim nv show -g <rg> --service-name <apim> --named-value-id entitlement-projection-prefix --query value -o tsv` after deployment |
| Location | `<location>` | `az cosmosdb show -g <rg> -n cosmos-<prefix> --query location -o tsv` when the account exists |
| SKU | `<sku>` | `az apim show -g <rg> -n <apim> --query sku.name -o tsv` |
| Resolver access | `<public-or-private>` | No single read before deployment; the deployer derives it from SKU when omitted. |
| Standard group | `<standard-group>` | `az ad group show --group <standard-group> --query id -o tsv` |
| Premium group | `<premium-group>` | `az ad group show --group <premium-group> --query id -o tsv` when not `none` |

Sources: [Azure CLI discovery](AZ-COMMANDS.md#1-variables-prerequisites-and-discovery), `scripts/Deploy-ClaudeProjection.ps1`, `scripts/ClaudeProjectionSwitch.ps1`.

## Step 1. Preflight

What it does: Preflight checks the PowerShell host, local tools, selected subscription, gateway identity, Graph probes, tier groups, resolver registration, providers, roles and derived names. `-PreflightOnly` exits before Azure writes.

Who: Operator; Entra and network administrators handle rows where the report names them.

```powershell
pwsh -NoProfile -File .\scripts\Deploy-ClaudeProjection.ps1 `
  -SubscriptionId <subscription-id> `
  -ResourceGroup <rg> -ApimName <apim> -NamePrefix <prefix> `
  -Location <location> -Sku <sku> -ResolverInboundAccess <public-or-private> `
  -StandardGroup <standard-group> -PremiumGroup <premium-group> `
  -PreflightOnly
```

Expected result: The report contains check, result, evidence, remedy and who acts. Failed resource or Graph checks remain `FAIL`; unproven app-creation rights are `WARN`.

Sources: [one-command deployment](SECURE-PROJECTION.md#one-command-deployment), `scripts/Deploy-ClaudeProjection.ps1`.

## Step 2. Deploy, populate and compare

What it does: The deployer creates private Cosmos, projection networking and the resolver, sets resolver named values and `entitlement-projection-prefix`, exports named-value decisions, applies a full snapshot through the runner and compares the projection. `entitlement-source` remains unchanged.

Who: Operator; Entra administrator supplies the resolver app registration when the operator cannot create it.

```powershell
pwsh -NoProfile -File .\scripts\Deploy-ClaudeProjection.ps1 `
  -SubscriptionId <subscription-id> `
  -ResourceGroup <rg> -ApimName <apim> -NamePrefix <prefix> `
  -Location <location> -Sku <sku> -ResolverInboundAccess <public-or-private> `
  -StandardGroup <standard-group> -PremiumGroup <premium-group>
```

Expected result:

- The deployer prints `entitlement-resolver-url is <resolverUrl>; entitlement-projection-prefix is <prefix>; entitlement-source is unchanged`.
- The apply summary JSON has `ok:true`, `written`, `deleted`, `unchanged` and zero failed writes.
- The deployer prints `Clean comparison complete; named values remain authoritative. To switch now, rerun with -FlipAfterCleanCompare.`

Sources: [one-command deployment](SECURE-PROJECTION.md#one-command-deployment), [populate from inside the network](SECURE-PROJECTION.md#8-populate-the-projection-from-inside-the-network), `scripts/Deploy-ClaudeProjection.ps1`, `sync/src/apply-projection.mjs`.

## Step 3. Switch check

What it does: The switch check runs resolver checks, drift check, read-only runner compare and switch evidence without backup or write.

Who: Operator with switch read permissions.

```powershell
pwsh -NoProfile -File .\scripts\Deploy-ClaudeProjection.ps1 `
  -ResourceGroup <rg> -ApimName <apim> -NamePrefix <prefix> `
  -StandardGroup <standard-group> -PremiumGroup <premium-group> `
  -FlipAfterCleanCompare -WhatIf
```

Expected result:

- The switch prints `==> Resolver: the gateway's resolver reads the projection Cosmos account`.
- It prints either `==> Drift check: the gateway's lists against Entra` or `==> New gateway: no named-value members; compare projection with a fresh Entra snapshot`.
- It prints `==> Compare: the projection through the in-VNet runner (read-only)` and `==> Evidence: newest full sync and invalid projection records`.
- It prints `WhatIf: resolver checks, compare and evidence passed; no backup and no write.`

Sources: [switch](SECURE-PROJECTION.md#switch-to-the-projection-p95), `scripts/ClaudeProjectionSwitch.ps1`.

## Step 4. Switch

What it does: The switch performs the same evidence checks, writes a projection-switch backup and makes the single APIM named-value write: `entitlement-source=projection`.

Who: Operator with APIM named-value write permission.

```powershell
pwsh -NoProfile -File .\scripts\Deploy-ClaudeProjection.ps1 `
  -ResourceGroup <rg> -ApimName <apim> -NamePrefix <prefix> `
  -StandardGroup <standard-group> -PremiumGroup <premium-group> `
  -FlipAfterCleanCompare
```

Expected result:

- The switch prints `==> Backup and switch`.
- It prints `entitlement-source is projection after switch evidence` with the newest full sync timestamp and executor when those fields are present.
- It prints rollback text generated by `Get-ClaudeProjectionRollbackText`; the text names the named-value refresh, the compare with `-FailOnDrift`, the reset to `named-value` and the backup path.

Sources: [switch](SECURE-PROJECTION.md#switch-to-the-projection-p95), `scripts/ClaudeProjectionSwitch.ps1`.

## Step 5. Verify requests

What it does: Verification sends requests through the gateway after cutover. The request commands are in [AZ-COMMANDS section 11](AZ-COMMANDS.md#11-verification).

Who: Operator with an entitled test caller and a non-entitled test caller.

Expected result:

- An entitled caller gets HTTP `200` and a model response.
- A non-entitled caller gets HTTP `403` with `permission_error` and `Not entitled to Claude Code. Ask your platform team to add you to the 'claude-code-standard' or 'claude-code-premium' Entra group.`
- After adding a user and running the targeted sync, an earlier no-record answer can stay cached for up to 60 seconds.
- Resolver failure returns HTTP `503`, `Retry-After: 5` and a message that starts `The entitlement projection has no usable answer, or the entitlement service did not answer.`

Sources: [AZ-COMMANDS verification](AZ-COMMANDS.md#11-verification), [secure projection verify](SECURE-PROJECTION.md#verify), `infra/policy.xml`.

## Day-2 operation. Add a developer

What it does: The Entra group change remains the source of truth; the targeted projection sync writes one person's record.

Who: Operator with delegated Graph reads.

```powershell
.\scripts\Sync-ClaudeAccess.ps1 -ResourceGroup <rg> -ApimName <apim> -User <upn-or-object-id>
```

Expected result: The script prints `Projection sync complete: written=1 deleted=0 unchanged=0` when a new record is added. A previous no-record cache can remain for up to 60 seconds.

Sources: [ADR-0051 decision 5](adr/0051-persistent-sync-based-cosmos-entitlement.md#decision), `scripts/Sync-ClaudeAccess.ps1`, `infra/policy.xml`.

## Day-2 operation. Remove a developer

What it does: The Entra group removal takes effect when sync deletes the developer's record.

Who: Operator with delegated Graph reads.

```powershell
.\scripts\Sync-ClaudeAccess.ps1 -ResourceGroup <rg> -ApimName <apim> -User <upn-or-object-id>
```

Expected result: The script prints `Projection sync complete: written=0 deleted=1 unchanged=0` when the record is removed. Existing access ends after sync plus at most `entitlement-cache-seconds`; a disabled Entra account obtains no new tokens, and default access tokens last 60 to 90 minutes.

Sources: [ADR-0051 consequences](adr/0051-persistent-sync-based-cosmos-entitlement.md#consequences), `scripts/Sync-ClaudeAccess.ps1`.

## Day-2 operation. Move between tiers or business units

What it does: The group or business-unit change writes the changed record for one person.

Who: Operator with delegated Graph reads.

```powershell
.\scripts\Sync-ClaudeAccess.ps1 -ResourceGroup <rg> -ApimName <apim> -User <upn-or-object-id>
```

Expected result: The apply summary has `written=1` for a changed record. The old entitlement answer can remain until the gateway entitlement cache expires.

Sources: [ADR-0051 decisions](adr/0051-persistent-sync-based-cosmos-entitlement.md#decision), `sync/src/apply-projection.mjs`, `infra/policy.xml`.

## Day-2 operation. Full sync

What it does: Full sync reconciles all entitled people, writes changes, deletes orphans and writes full-mode status evidence.

Who: Operator with delegated Graph reads.

```powershell
.\scripts\Sync-ClaudeAccess.ps1 -ResourceGroup <rg> -ApimName <apim>
```

Expected result: The script prints `Projection sync complete: written=<n> deleted=<n> unchanged=<n>`. `-AllowEmpty` appears only when the groups are truly empty; otherwise the writer refuses to remove all existing records.

Sources: [ADR-0051 decisions](adr/0051-persistent-sync-based-cosmos-entitlement.md#decision), `scripts/Sync-ClaudeAccess.ps1`, `sync/src/plan.mjs`.

## Day-2 operation. Empty full sync

What it does: Empty full sync is the deliberate version of a full sync whose authoritative groups are empty.

Who: Operator with delegated Graph reads.

```powershell
.\scripts\Sync-ClaudeAccess.ps1 -ResourceGroup <rg> -ApimName <apim> -AllowEmpty
```

Expected result: The writer can delete records when the resolved groups are empty and `-AllowEmpty` is supplied. Without it, the refusal is `groups resolved to nobody while the projection holds <n> record(s); refusing to remove them all`.

Sources: `scripts/Sync-ClaudeAccess.ps1`, `sync/src/plan.mjs`.

## Day-2 operation. Optional sync job for very large directories

What it does: The optional job reads Graph inside the network and runs a full sync with the same write rules. Its trigger is Manual unless `-CronExpression` is supplied.

Who: Operator deploys the job; Privileged Role Administrator or Global Administrator grants Graph permission.

```powershell
.\scripts\Deploy-ClaudeProjectionRenewal.ps1 -ResourceGroup <rg> -ApimName <apim> -NamePrefix <prefix> -AlertEmail <address>
.\scripts\Grant-ClaudeProjectionRenewalGraphAccess.ps1 -PrincipalId <job-principal-id>
az containerapp job start -g <rg> -n <job-name>
```

Scheduled form:

```powershell
.\scripts\Deploy-ClaudeProjectionRenewal.ps1 -ResourceGroup <rg> -ApimName <apim> -NamePrefix <prefix> -AlertEmail <address> -CronExpression '<five fields>'
```

Expected result: Deployment prints the job and action group, the Graph grant command and the `az containerapp job start` command. Manual trigger is the default; a schedule adds the stale-success alert. The renewal deployer refuses before any write while the gateway has no `entitlement-projection-prefix` for this prefix: the job writes records without `expiresAt`, which a resolver published before [ADR-0051](adr/0051-persistent-sync-based-cosmos-entitlement.md) refuses, and Step 2 publishes the current resolver before it records the prefix.

Sources: [optional sync job](SECURE-PROJECTION.md#optional-sync-job-and-switch-evidence-p97), `scripts/Deploy-ClaudeProjectionRenewal.ps1`.

## Day-2 operation. Re-check switch evidence

What it does: The switch evidence check can be rerun without writing.

Who: Operator.

```powershell
pwsh -NoProfile -File .\scripts\Deploy-ClaudeProjection.ps1 `
  -ResourceGroup <rg> -ApimName <apim> -NamePrefix <prefix> `
  -StandardGroup <standard-group> -PremiumGroup <premium-group> `
  -FlipAfterCleanCompare -WhatIf
```

Expected result: Evidence passes when the newest full sync for this Cosmos account, database, container and tenant finished within 24 hours and no live entitlement record would be refused by the resolver.

Sources: [switch evidence](SECURE-PROJECTION.md#switch-evidence), `scripts/ClaudeProjectionSwitch.ps1`.

## Checks and outputs

| Output | Meaning |
|---|---|
| `written` | Cosmos upserts that succeeded in the apply. |
| `deleted` | Cosmos deletes that succeeded in the apply. |
| `unchanged` | Resolved records that matched existing projection records and were not rewritten. |
| `excludedByNewerTargetedSync` | Users skipped by a full apply because a targeted sync finished after the full snapshot scan, with a 300-second margin. |
| `ok` | Boolean success flag for compare, apply and runner summary parsing. |
| Status records | Successful mutating applies write `projection-reconciliation-status` records with tenant, account, container, mode, executor, counts and timestamps. |
| Apply lock | Mutating applies take `projection-apply-lock`; the 300-second lease records holder, mode and `leaseExpiresAt`, and expires by itself. |
| Resolver answers | `200` serves entitlement; `404` means no usable entitlement record; `403` means another tenant; `409` means unknown tier; `503` means bad generation or verification. |
| Gateway cache | `200` is cached for `entitlement-cache-seconds`; `404` is cached for at most 60 seconds; resolver failure returns `503` with `Retry-After: 5`. |

Sources: `sync/src/apply-projection.mjs`, `sync/src/apply-lock.mjs`, `resolver/src/entitlement.mjs`, `infra/policy.xml`.

## Rollback to named values

Rollback is bounded by named-value capacity. A tier list holds about 110 identities, and business-unit membership holds about 93 developers; a larger population cannot roll back to named values without exceeding the named-value limit.

Refresh named values from Entra.

```powershell
.\scripts\Sync-ClaudeAccess.ps1 -ResourceGroup <rg> -ApimName <apim> -Store named-value
```

Compare the lists.

```powershell
.\scripts\Compare-ClaudeEntitlement.ps1 -ResourceGroup <rg> -ApimName <apim> -FailOnDrift
```

Set `entitlement-source` to `named-value`.

```powershell
. .\scripts\ApimNamedValue.ps1
Set-ApimNamedValue -ResourceGroup <rg> -ApimName <apim> `
  -SubscriptionId <subscription-id> -Id entitlement-source -Value named-value
```

Expected result: Named values serve again after they have been refreshed and compared. `Compare-ClaudeEntitlement.ps1` prints `In sync. <n> identities resolve to the same tier on both sides.` when no drift exists.

Sources: [Scale named-value limits](SCALE.md#what-runs-out-first), [rollback conditions](SCALE.md#the-move-itself-step-by-step), [secure projection optional sync job and switch evidence](SECURE-PROJECTION.md#optional-sync-job-and-switch-evidence-p97), `scripts/ClaudeProjectionSwitch.ps1`, `scripts/Compare-ClaudeEntitlement.ps1`.

## Troubleshooting

| Message | Cause | Remedy |
|---|---|---|
| `<step> refused at stage <stage>. <remedy>` | The writer in the runner refused; the stage names where it stopped. | The remedy printed after the stage. |
| `a newer full sync finished after this snapshot was taken; export a fresh snapshot.` | A full sync finished after the snapshot scan. | A new full sync, or a new sync job run; a switch that was in progress then runs again. |
| `a newer sync already finished for this user after this snapshot was taken.` | A full or targeted sync for the same user finished after the targeted snapshot scan. | A new targeted sync for that user. |
| `snapshot expired; resolve the directory again.` | The snapshot's apply-by time passed while the apply waited for the lock or read the projection. | A new full or targeted sync, which reads the directory again. |
| `<n> user(s) changed by a targeted sync while this full sync ran were left out of it` | A targeted sync changed those people after the full sync's directory scan. | A full sync five minutes later, or a targeted sync for each of them. |
| `projection apply lock is held by <holder> in <mode> mode until <leaseExpiresAt>` | Another apply holds the 300-second lease. | A new sync or job run after the lease time; a lock left by a stopped run expires by itself. |
| `lost the projection apply lock before the next write; no further writes were made.` | The writer lost the lock before a later read or write. | A new sync (`-User` for one person) or job run after the current holder finishes or its lease passes. |
| `--account-resource-id is required for mutating applies.` | A mutating apply did not name the destination Cosmos account resource id. | `Sync-ClaudeAccess.ps1` passes it; a hand run needs matching `--cosmos` and `--account-resource-id`. |
| `--account-resource-id differs from PROJECTION_ACCOUNT_RESOURCE_ID.` | The flag and the job environment name different account ids. | One account resource id in both. |
| `--account-resource-id names Cosmos account '<x>', but --cosmos is for '<y>'.` | The ARM id and the endpoint name different Cosmos accounts. | An endpoint and an account resource id for the same account. |
| `partial tier override refused for --graph.` | A hand `--graph` run supplied only one of `--standard` or `--premium`. | Both tier overrides, or neither so the deployed job settings apply. |
| `job settings refused: <problems>` | The optional job environment is incomplete or invalid. | The named settings corrected, then a new job or sync run. |
| `snapshot refused: <problems>.` | A targeted snapshot without `--user`, invalid freshness, or an expired snapshot. | A new full or targeted sync; for compare-snapshot, a new switch or deployer run. |
| `Directory scan outlived the snapshot apply-by limit. Nothing exported; resolve again.` | The export took longer than the snapshot apply-by window. | A new export; a scan longer than that window belongs to the optional job. |
| `groups resolved to nobody while the projection holds <n> record(s); refusing to remove them all` | A failed directory read and a real empty directory look the same. | `-AllowEmpty` only for groups known to be empty; otherwise corrected group names and Graph read permission. |
| `API Management <apim> has no entitlement-projection-prefix named value.` | The renewal deployer ran before the projection deployer recorded this projection on the gateway. | Step 2 for this projection, then the renewal deployer again. |
| `AADSTS500011` | Entra has no service principal for the resolver application. | The deployer creates it when it runs again; the switch refuses without it. |
| `InvalidResourceLocation` and `cosmos-<prefix> already exists in location X` | The resource group already holds the projection Cosmos account in another region. | `-Location X`, or another prefix. |
| `Authorization_RequestDenied` or Graph 403 | The caller or job identity lacks directory read permission. | The Entra administrator grants directory read permission; for the optional job, a Privileged Role Administrator or Global Administrator grants `GroupMember.Read.All`. |
| `Could not start runner '<name>' (az exit <code>).` | The runner container group could not be started. | A redeploy with `scripts/Deploy-ClaudeProjection.ps1`, then a new sync. |
| `Runner '<name>' did not reach Running within <seconds> seconds` | The runner did not reach Running after the start. | `az container show -g <rg> -n <name>` shows its state; a redeploy with `scripts/Deploy-ClaudeProjection.ps1` recreates it. |

Sources: `sync/src/apply-projection.mjs`, `sync/src/apply-lock.mjs`, `sync/src/plan.mjs`, `scripts/ClaudeRunner.ps1`, `scripts/Sync-ClaudeAccess.ps1`, `scripts/Sync-ClaudeProjection.ps1`, `scripts/Deploy-ClaudeProjectionRenewal.ps1`, [secure projection troubleshooting](SECURE-PROJECTION.md#troubleshooting).
## Commands without the scripts

Azure CLI-only equivalents for the projection live in [AZ-COMMANDS section 10](AZ-COMMANDS.md#10-optional-cosmos-projection), and request verification lives in [AZ-COMMANDS section 11](AZ-COMMANDS.md#11-verification). Runner-side manual population commands, including `Send-RunnerFile` and `Invoke-RunnerCommand`, live in [SECURE-PROJECTION section 8](SECURE-PROJECTION.md#8-populate-the-projection-from-inside-the-network).

Sources: [AZ-COMMANDS section 10](AZ-COMMANDS.md#10-optional-cosmos-projection), [AZ-COMMANDS section 11](AZ-COMMANDS.md#11-verification), [SECURE-PROJECTION section 8](SECURE-PROJECTION.md#8-populate-the-projection-from-inside-the-network).
