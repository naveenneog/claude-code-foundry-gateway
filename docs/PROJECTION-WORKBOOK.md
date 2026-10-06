# Cosmos entitlement projection operator workbook

## 1. Purpose and scope

This workbook is the manual procedure to deploy, populate, switch to and operate the Cosmos DB entitlement projection. The projection implements [ADR-0051](adr/0051-persistent-sync-based-cosmos-entitlement.md): a Cosmos entitlement record grants access until a sync deletes or changes it, and the resolver treats legacy expired records as no record. Sources: `docs/adr/0051-persistent-sync-based-cosmos-entitlement.md:47-58`, `docs/status/P97.md:16-35`.

The scope is the operator path for the sync-based entitlement store: deploy the projection, populate it from Entra, compare it with the current gateway decisions, switch `entitlement-source` after evidence passes, and run day-2 syncs. The design reasons stay in ADR-0051. Sources: `docs/SECURE-PROJECTION.md:135-140`, `docs/SECURE-PROJECTION.md:146-174`.

The automated alternative planned from P98 onward is the installer path: `Install-ClaudeGateway.ps1` deploys and switches the projection by default. This branch records the manual projection switch as the supported evidence-gated path. Source: `docs/SECURE-PROJECTION.md:146-174`.

## 2. Roles

| Role | Steps | Rights boundary | Source |
|---|---|---|---|
| Operator | Preflight, deployment, population, compare, switch evidence, targeted and full syncs, rollback. | Azure deployment rights on the resources, API Management named-value read/write for switching, delegated Graph group reads for sync, and runner read/start/exec on `aci-projtest-<prefix>`. | `docs/SECURE-PROJECTION.md:67-73`, `docs/SECURE-PROJECTION.md:261-274` |
| Entra administrator | App registration and group creation when the operator cannot create or assign them. | Application registration/assignment rights in Entra ID are separate from Azure subscription Owner. | `docs/SECURE-PROJECTION.md:67-68`, `docs/SECURE-PROJECTION.md:250-255` |
| Privileged Role Administrator or Global Administrator | Optional sync job Graph application permission. | The optional job identity needs Microsoft Graph application permission `GroupMember.Read.All`; the deployment script never grants it. | `docs/SECURE-PROJECTION.md:106-119`, `scripts/Grant-ClaudeProjectionRenewalGraphAccess.ps1:3-8` |
| Network team | Private resolver and VNet handoff. | The network team supplies subnets and DNS where enterprise network policy owns them. | `docs/SECURE-PROJECTION.md:67-72`, `docs/SECURE-PROJECTION.md:404-424` |

## 3. Prerequisites

| Requirement | Exact prerequisite | Source |
|---|---|---|
| PowerShell | PowerShell 7 or later for `Deploy-ClaudeProjection.ps1` and `Sync-ClaudeProjection.ps1`. | `docs/SECURE-PROJECTION.md:72`, `scripts/Sync-ClaudeProjection.ps1:63` |
| Azure CLI and Bicep | Azure CLI with Bicep; the Azure CLI guide was checked against Azure CLI 2.86.0 help and the Bicep templates, and `build-params` with `using none` evaluates the existing storage name locally. | `docs/AZ-COMMANDS.md:3`, `docs/SECURE-PROJECTION.md:72` |
| Node.js and npm | Local Node/npm for packaging and runner-side `npm --prefix /work/sync ci --omit=dev --ignore-scripts --no-audit --fund=false`. | `docs/SECURE-PROJECTION.md:72`, `scripts/Deploy-ClaudeProjection.ps1:224` |
| ZIP-capable tar | A `tar` executable that can create ZIP/tar archives for resolver and sync packages. | `docs/SECURE-PROJECTION.md:72`, `scripts/Deploy-ClaudeProjection.ps1:180-187` |
| Azure roles | Owner, or Contributor plus User Access Administrator, on deployment resources; network join/write rights on supplied VNet/subnets/DNS. | `docs/SECURE-PROJECTION.md:67-68` |
| Resource providers | `Microsoft.App`, `Microsoft.DocumentDB`, `Microsoft.Web`, `Microsoft.ContainerInstance`, `Microsoft.Network`, `Microsoft.Storage`, `Microsoft.OperationalInsights`, `Microsoft.Insights` and `Microsoft.Authorization`. | `docs/SECURE-PROJECTION.md:69` |
| Graph delegated reads | Full sync needs delegated `GroupMember.Read.All`; targeted `-User` also needs `User.ReadBasic.All`. | `docs/SECURE-PROJECTION.md:274`, `docs/adr/0051-persistent-sync-based-cosmos-entitlement.md:63-73` |
| Switch permissions | API Management named-value read/write, ARM reads of resolver deployment and site, `Microsoft.Web/sites/config/list/action`, Graph read for drift check, and Cosmos data read through the runner. | `docs/SECURE-PROJECTION.md:273` |
| Runner permissions | On `aci-projtest-<prefix>`: container group read, `Microsoft.ContainerInstance/containerGroups/start/action`, and `Microsoft.ContainerInstance/containerGroups/containers/exec/action`. | `docs/SECURE-PROJECTION.md:274` |
| Cosmos region | `-Location` equals the region of an existing `cosmos-<prefix>` account when one already exists. | `docs/adr/0051-persistent-sync-based-cosmos-entitlement.md:82-91`, `docs/SECURE-PROJECTION.md:782-789` |

## 4. Worksheet

| Value | Placeholder | How the operator records it | Command that reads it | Source |
|---|---|---|---|---|
| Subscription id | `<subscription-id>` | Azure subscription that holds the gateway resource group. | `az account show --query id -o tsv` | `docs/AZ-COMMANDS.md:70-80` |
| Tenant id | `<tenant-id>` | Tenant that owns the gateway managed identity. | `az account show --query tenantId -o tsv` | `docs/AZ-COMMANDS.md:70-80` |
| Gateway resource group | `<rg>` | Resource group that contains API Management and the projection resources. | `az apim show -g <rg> -n <apim> --query resourceGroup -o tsv` | `docs/SECURE-PROJECTION.md:203-232` |
| API Management name | `<apim>` | Existing gateway APIM instance. | `az apim show -g <rg> -n <apim> --query name -o tsv` | `scripts/ClaudeProjectionSwitch.ps1:76-80` |
| Projection name prefix | `<prefix>` | 1-37 lowercase letters/digits with separated hyphens and alphanumeric ends. | `az apim nv show -g <rg> --service-name <apim> --named-value-id entitlement-projection-prefix --query value -o tsv` after deployment | `docs/SECURE-PROJECTION.md:211-219`, `scripts/Deploy-ClaudeProjection.ps1:197-200` |
| Location | `<location>` | Azure region for the projection; for an existing `cosmos-<prefix>`, the existing Cosmos region. | `az cosmosdb show -g <rg> -n cosmos-<prefix> --query location -o tsv` when the account exists | `docs/SECURE-PROJECTION.md:782-789` |
| SKU | `<sku>` | `BasicV2`, `StandardV2` or `PremiumV2`. | `az apim show -g <rg> -n <apim> --query sku.name -o tsv` | `scripts/Deploy-ClaudeProjection.ps1:27-31` |
| Resolver access | `<public-or-private>` | `public` for Basic v2 default; `private` for Standard v2/Premium v2 default. | No single read before deployment; the deployer derives it from SKU when omitted. | `scripts/Deploy-ClaudeProjection.ps1:73-80` |
| Standard group | `<standard-group>` | Display name or object id for standard entitlement. | `az ad group show --group <standard-group> --query id -o tsv` | `scripts/Deploy-ClaudeProjection.ps1:31-34`, `scripts/ClaudeProjectionSwitch.ps1:108-116` |
| Premium group | `<premium-group>` | Display name, object id, or `none` when no premium tier exists. | `az ad group show --group <premium-group> --query id -o tsv` when not `none` | `scripts/Deploy-ClaudeProjection.ps1:31-34`, `scripts/ClaudeProjectionSwitch.ps1:108-116` |

## 5. Steps

### Step 1. Preflight

| Field | Value |
|---|---|
| What it does | Step 1 checks the PowerShell host, local tools, subscription, gateway identity, Graph probes, tier groups, resolver registration, providers, roles and derived names. `-PreflightOnly` exits before Azure writes. Sources: `docs/SECURE-PROJECTION.md:190-219`, `scripts/Deploy-ClaudeProjection.ps1:80-94`. |
| Who | Operator; Entra administrator or network team handles rows where the report names them. Source: `docs/SECURE-PROJECTION.md:211-219`. |
| Command | ```powershell
pwsh -NoProfile -File .\scripts\Deploy-ClaudeProjection.ps1 `
  -SubscriptionId <subscription-id> `
  -ResourceGroup <rg> -ApimName <apim> -NamePrefix <prefix> `
  -Location <location> -Sku <sku> -ResolverInboundAccess <public-or-private> `
  -StandardGroup <standard-group> -PremiumGroup <premium-group> `
  -PreflightOnly
``` |
| Expected result | The report contains `check`, `result`, `evidence`, `remedy` and `who acts`; failed resource/Graph checks remain `FAIL`; unproven app-creation rights are `WARN`. Source: `docs/SECURE-PROJECTION.md:211-219`. |

### Step 2. Deploy, populate and compare

| Field | Value |
|---|---|
| What it does | Step 2 deploys private Cosmos, projection networking and resolver, sets resolver named values and `entitlement-projection-prefix`, exports named-value decisions, populates Cosmos from Entra through the runner, compares the projection, and leaves `entitlement-source` unchanged. Sources: `docs/SECURE-PROJECTION.md:225-238`, `scripts/Deploy-ClaudeProjection.ps1:197-235`. |
| Who | Operator; Entra administrator supplies resolver app registration if the operator cannot create it. Sources: `docs/SECURE-PROJECTION.md:250-255`, `docs/SECURE-PROJECTION.md:261-274`. |
| Command | ```powershell
pwsh -NoProfile -File .\scripts\Deploy-ClaudeProjection.ps1 `
  -SubscriptionId <subscription-id> `
  -ResourceGroup <rg> -ApimName <apim> -NamePrefix <prefix> `
  -Location <location> -Sku <sku> -ResolverInboundAccess <public-or-private> `
  -StandardGroup <standard-group> -PremiumGroup <premium-group>
``` |
| Expected result | The deployer prints `[OK] entitlement-resolver-url is <resolver-url>; entitlement-projection-prefix is <prefix>; entitlement-source is unchanged`, then `Clean comparison complete; named values remain authoritative. To switch now, rerun with -FlipAfterCleanCompare.` Sources: `scripts/Deploy-ClaudeProjection.ps1:197-200`, `scripts/Deploy-ClaudeProjection.ps1:228-235`. The apply summary is JSON with `ok:true`, `written`, `deleted`, `unchanged` and zero failed writes. Source: `sync/src/apply-projection.mjs:328-345`. |

### Step 3. Check before switching

| Field | Value |
|---|---|
| What it does | Step 3 runs the switch path without the backup or named-value write. It checks resolver configuration, drift, read-only runner compare and switch evidence. Sources: `docs/SECURE-PROJECTION.md:146-174`, `scripts/ClaudeProjectionSwitch.ps1:80-159`. |
| Who | Operator. Source: `docs/SECURE-PROJECTION.md:273`. |
| Command | ```powershell
pwsh -NoProfile -File .\scripts\Deploy-ClaudeProjection.ps1 `
  -ResourceGroup <rg> -ApimName <apim> -NamePrefix <prefix> `
  -StandardGroup <standard-group> -PremiumGroup <premium-group> `
  -FlipAfterCleanCompare -WhatIf
``` |
| Expected result | The switch prints `==> Resolver: the gateway's resolver reads the projection Cosmos account`, `==> Drift check: the gateway's lists against Entra` or `==> New gateway: no named-value members; compare projection with a fresh Entra snapshot`, `==> Compare: the projection through the in-VNet runner (read-only)`, `==> Evidence: newest full sync and invalid projection records`, then `WhatIf: resolver checks, compare and evidence passed; no backup and no write.` Sources: `scripts/ClaudeProjectionSwitch.ps1:80-159`. |

### Step 4. Switch

| Field | Value |
|---|---|
| What it does | Step 4 performs the same evidence checks, writes a projection-switch backup, and makes the single API Management named-value write: `entitlement-source=projection`. Sources: `docs/SECURE-PROJECTION.md:146-174`, `scripts/ClaudeProjectionSwitch.ps1:163-172`. |
| Who | Operator with API Management named-value write permission. Source: `docs/SECURE-PROJECTION.md:273`. |
| Command | ```powershell
pwsh -NoProfile -File .\scripts\Deploy-ClaudeProjection.ps1 `
  -ResourceGroup <rg> -ApimName <apim> -NamePrefix <prefix> `
  -StandardGroup <standard-group> -PremiumGroup <premium-group> `
  -FlipAfterCleanCompare
``` |
| Expected result | The switch prints `==> Backup and switch`, `[OK]   entitlement-source is projection after switch evidence from full sync finished <timestamp> by <executor>`, and the rollback text generated by `Get-ClaudeProjectionRollbackText`. That text names the named-value refresh, the compare with `-FailOnDrift`, the `entitlement-source` reset to `named-value`, and the backup path. Sources: `scripts/ClaudeProjectionSwitch.ps1:18-21`, `scripts/ClaudeProjectionSwitch.ps1:163-172`. |

### Step 5. Verify requests

| Field | Value |
|---|---|
| What it does | Step 5 sends a real request through the gateway and verifies entitlement behavior after cutover. Source: `docs/AZ-COMMANDS.md:1700-1750`. |
| Who | Operator with a test entitled caller and a test non-entitled caller. Source: `docs/SECURE-PROJECTION.md:759-789`. |
| Command | ```bash
p89_gateway_url
export FOUNDRY_TOKEN="$(az account get-access-token --resource https://ai.azure.com --query accessToken -o tsv)"
curl -sS -o response.json -w "%{http_code}\n" -H "Authorization: ******" -H "Content-Type: application/json" -d "{\"model\":\"${SONNET_DEPLOYMENT}\",\"max_tokens\":32,\"messages\":[{\"role\":\"user\",\"content\":\"Return the word ok.\"}]}" "${GATEWAY_URL}/v1/messages"
jq -r '.content[0].text // .error.message' response.json
``` |
| Expected result | An entitled caller receives HTTP `200` and a model response. A non-entitled caller receives the refusal documented in the verification section. Sources: `docs/AZ-COMMANDS.md:1700-1750`, `docs/SECURE-PROJECTION.md:771-789`. |

## 6. Day-2 operations

| Operation | What it does | Who | Command | Expected result and timing | Source |
|---|---|---|---|---|---|
| Add a developer | The Entra group change remains the source of truth; the targeted projection sync writes only that person's record. | Operator with delegated Graph reads. | ```powershell
.\scripts\Sync-ClaudeAccess.ps1 -ResourceGroup <rg> -ApimName <apim> -User <upn-or-object-id>
``` | The script prints `Projection sync complete: written=1 deleted=0 unchanged=0` when a new record is added. A previous 404/no-record cache is stored for at most 60 seconds, so access starts after the sync and that short cache window. | `docs/adr/0051-persistent-sync-based-cosmos-entitlement.md:63-73`, `scripts/Sync-ClaudeAccess.ps1:60-116`, `infra/policy.xml:142-162` |
| Remove a developer | The Entra group removal takes effect when sync deletes that person's record. | Operator. | ```powershell
.\scripts\Sync-ClaudeAccess.ps1 -ResourceGroup <rg> -ApimName <apim> -User <upn-or-object-id>
``` | The script prints `Projection sync complete: written=0 deleted=1 unchanged=0` when the record is removed. Existing access ends after the sync plus at most `entitlement-cache-seconds`; a disabled Entra account obtains no new tokens, and default access tokens last 60-90 minutes. | `docs/adr/0051-persistent-sync-based-cosmos-entitlement.md:115-120`, `scripts/Sync-ClaudeAccess.ps1:110-116` |
| Move between tiers or business units | A tier or unit move writes the changed record for that person. | Operator. | ```powershell
.\scripts\Sync-ClaudeAccess.ps1 -ResourceGroup <rg> -ApimName <apim> -User <upn-or-object-id>
``` | The summary shows `written=1` for a changed record, and the old answer can remain served until the entitlement cache expires. | `docs/adr/0051-persistent-sync-based-cosmos-entitlement.md:49-58`, `sync/src/apply-projection.mjs:328-345`, `infra/policy.xml:136-142` |
| Full sync | The full sync reconciles all entitled people, writes changes, deletes orphans and writes full-mode status evidence. | Operator. | ```powershell
.\scripts\Sync-ClaudeAccess.ps1 -ResourceGroup <rg> -ApimName <apim>
``` | The script prints `Projection sync complete: written=<n> deleted=<n> unchanged=<n>`. `-AllowEmpty` is present only when the groups are truly empty; otherwise the writer refuses to remove all existing records. | `scripts/Sync-ClaudeAccess.ps1:31-43`, `scripts/Sync-ClaudeAccess.ps1:110-116`, `sync/src/plan.mjs:73-84` |
| Full sync with known empty groups | The full sync allows an empty authoritative directory only when it is deliberate. | Operator. | ```powershell
.\scripts\Sync-ClaudeAccess.ps1 -ResourceGroup <rg> -ApimName <apim> -AllowEmpty
``` | The writer can delete records when the resolved groups are empty and `-AllowEmpty` is supplied. Without it, the refusal is `groups resolved to nobody while the projection holds <n> record(s); refusing to remove them all`. | `scripts/Sync-ClaudeAccess.ps1:38-43`, `sync/src/plan.mjs:73-84` |
| Optional sync job for very large directories | The job reads Graph inside the network and runs a full sync with the same write rules. Its trigger is Manual unless `-CronExpression` is supplied. | Operator deploys; Privileged Role Administrator or Global Administrator grants Graph permission. | ```powershell
.\scripts\Deploy-ClaudeProjectionRenewal.ps1 -ResourceGroup <rg> -ApimName <apim> -NamePrefix <prefix> -AlertEmail <address>
.\scripts\Grant-ClaudeProjectionRenewalGraphAccess.ps1 -PrincipalId <job-principal-id>
az containerapp job start -g <rg> -n <job-name>
```
Scheduled form:
```powershell
.\scripts\Deploy-ClaudeProjectionRenewal.ps1 -ResourceGroup <rg> -ApimName <apim> -NamePrefix <prefix> -AlertEmail <address> -CronExpression '<five fields>'
``` | Deployment prints the job and action group; it also prints the Graph grant command and `az containerapp job start`. Manual trigger is the default; a schedule adds the stale-success alert. | `docs/SECURE-PROJECTION.md:106-125`, `scripts/Deploy-ClaudeProjectionRenewal.ps1:218-221`, `scripts/Deploy-ClaudeProjectionRenewal.ps1:297-303` |
| Re-check switch evidence | The switch evidence check can be rerun without writing. | Operator. | ```powershell
pwsh -NoProfile -File .\scripts\Deploy-ClaudeProjection.ps1 `
  -ResourceGroup <rg> -ApimName <apim> -NamePrefix <prefix> `
  -StandardGroup <standard-group> -PremiumGroup <premium-group> `
  -FlipAfterCleanCompare -WhatIf
``` | Evidence passes when the newest full sync for this Cosmos account, database, container and tenant finished within 24 hours and no live entitlement record would be refused by the resolver. | `docs/SECURE-PROJECTION.md:140-144`, `scripts/ClaudeProjectionSwitch.ps1:156-159` |

## 7. Checks and what the outputs mean

| Output | Meaning | Source |
|---|---|---|
| `written` | Number of Cosmos upserts that succeeded in the apply. | `sync/src/apply-projection.mjs:336-345` |
| `deleted` | Number of Cosmos deletes that succeeded in the apply. | `sync/src/apply-projection.mjs:336-345` |
| `unchanged` | Number of resolved records that matched the existing projection and were not rewritten. | `sync/src/apply-projection.mjs:321-330` |
| `excludedByNewerTargetedSync` | Number of users skipped by a full apply because a targeted sync finished after the full snapshot's scan, with a 300-second margin. | `docs/adr/0051-persistent-sync-based-cosmos-entitlement.md:98-111`, `sync/src/apply-projection.mjs:299-330` |
| `ok` | Boolean success flag for compare, apply and runner summary parsing. Failed writes make `ok:false` and exit code 3. | `sync/src/apply-projection.mjs:328-345`, `sync/src/apply-projection.mjs:373-385`, `scripts/ClaudeRunner.ps1:160-164` |
| Status records | Successful mutating applies write a `projection-reconciliation-status` record with tenant, account resource id, database, container, mode (`full` or `user`), executor, write counts and timestamps. The partition key starts with `projection-status::<tenantId>` and the TTL is seven days. | `sync/src/apply-projection.mjs:345-376`, `docs/SECURE-PROJECTION.md:130-132` |
| Apply lock | Mutating applies take the `projection-apply-lock` document. The lock records holder, mode, acquisition time and `leaseExpiresAt`; the lease is 300 seconds and expires by itself. | `docs/adr/0051-persistent-sync-based-cosmos-entitlement.md:98-111`, `sync/src/apply-lock.mjs:1-47`, `sync/src/apply-lock.mjs:94-126` |
| Resolver answers | `200` serves an entitlement record; `404` means no record, control record, legacy expired record or not-yet-effective record; `403` means another tenant; `409` means unknown tier; `503` means bad generation or verification. | `resolver/src/entitlement.mjs:28-80` |
| Gateway cache | A `200` resolver answer is cached for `entitlement-cache-seconds`; a `404` is cached for at most 60 seconds; resolver failure returns `503` with `Retry-After: 5`. | `infra/policy.xml:126-162`, `infra/policy.xml:190-209` |

## 8. Rollback to named values

Rollback is bounded by named-value capacity. A tier list holds about 110 identities, and business-unit membership holds about 93 developers; a larger population cannot roll back to named values without exceeding the named-value limit. Sources: `docs/SCALE.md:30-42`, `docs/SCALE.md:539-555`.

| Step | Command | Expected result | Source |
|---|---|---|---|
| Refresh named values from Entra | ```powershell
.\scripts\Sync-ClaudeAccess.ps1 -ResourceGroup <rg> -ApimName <apim> -Store named-value
``` | Named-value lists are rebuilt from Entra before they serve again. | `docs/SECURE-PROJECTION.md:91-94`, `scripts/Sync-ClaudeAccess.ps1:127-134` |
| Compare the lists | ```powershell
.\scripts\Compare-ClaudeEntitlement.ps1 -ResourceGroup <rg> -ApimName <apim> -FailOnDrift
``` | The script prints `In sync. <n> identities resolve to the same tier on both sides.` and exits 0 when no drift exists. | `scripts/Compare-ClaudeEntitlement.ps1:43-57`, `scripts/Compare-ClaudeEntitlement.ps1:175-197` |
| Set `entitlement-source` to `named-value` | ```powershell
. .\scripts\ApimNamedValue.ps1
Set-ApimNamedValue -ResourceGroup <rg> -ApimName <apim> `
  -SubscriptionId <subscription-id> -Id entitlement-source -Value named-value
``` | API Management reads the named-value lists again. | `scripts/ClaudeProjectionSwitch.ps1:18-21`, `docs/SCALE.md:762-776` |

## 9. Troubleshooting

| Message | Cause | Remedy | Source |
|---|---|---|---|
| `a newer full sync finished after this snapshot was taken; export a fresh snapshot.` | A full sync finished after the snapshot scan. | The remedy text is `Remedy: rerun scripts/Sync-ClaudeAccess.ps1 -ResourceGroup <rg> -ApimName <apim> (or start the sync job again), then rerun the switch if one was in progress.` | `sync/src/apply-projection.mjs:61-63`, `sync/src/apply-projection.mjs:299-303` |
| `a newer sync already finished for this user after this snapshot was taken.` | A full or targeted sync for the same user finished after the targeted snapshot scan. | The remedy text is `Remedy: rerun scripts/Sync-ClaudeAccess.ps1 -ResourceGroup <rg> -ApimName <apim> -User <upn-or-oid>.` | `sync/src/apply-projection.mjs:61-63`, `sync/src/apply-projection.mjs:313-321` |
| `projection apply lock is held by <holder> in <mode> mode until <leaseExpiresAt>` | Another apply holds the 300-second lease. | The remedy text says to rerun `Sync-ClaudeAccess.ps1` or start the sync job after the lease expiry; a lock left by a stopped run expires by itself. | `sync/src/apply-lock.mjs:1-47`, `sync/src/apply-lock.mjs:125-131` |
| `lost the projection apply lock before the next write; no further writes were made.` | The writer lost the lock before a later read or write. | The remedy text says to rerun `Sync-ClaudeAccess.ps1` with optional `-User`, or start the sync job again after the current lock holder finishes or its lease passes. | `sync/src/apply-lock.mjs:61-76` |
| `--account-resource-id is required for mutating applies.` | A mutating apply did not name the destination Cosmos account resource id. | The remedy text says to rerun `Sync-ClaudeAccess.ps1`, or rerun with matching `--cosmos` and `--account-resource-id $(az cosmosdb show -n <account> -g <rg> --query id -o tsv)`. | `sync/src/apply-projection.mjs:61-63`, `sync/src/apply-projection.mjs:393-414` |
| `--account-resource-id differs from PROJECTION_ACCOUNT_RESOURCE_ID.` | The flag and job environment name different account ids. | The same account-resource-id remedy applies. | `sync/src/apply-projection.mjs:393-397` |
| `--account-resource-id names Cosmos account '<x>', but --cosmos is for '<y>'.` | The ARM id and endpoint do not point to the same Cosmos account. | The same account-resource-id remedy applies. | `sync/src/apply-projection.mjs:401-414` |
| `partial tier override refused for --graph.` | A hand `--graph` run supplied only one of `--standard` or `--premium`. | The remedy text says to rerun with both tier overrides or omit both so deployed job settings are used. | `sync/src/apply-projection.mjs:94-105` |
| `job settings refused: <problems>` | The optional job environment is incomplete or invalid. | The job settings named in the message are corrected, then the job or sync is run again. | `sync/src/apply-projection.mjs:99-106` |
| `snapshot refused: <problems>.` | A snapshot is targeted without `--user`, has invalid freshness or has expired. | For apply, the remedy is the full or targeted `Sync-ClaudeAccess.ps1` rerun; for compare-snapshot, the remedy is to rerun the switch or deployer. | `sync/src/apply-projection.mjs:136-148`, `sync/src/apply-projection.mjs:270-278`, `sync/src/plan.mjs:428-438` |
| `Directory scan outlived the snapshot apply-by limit. Nothing exported; resolve again.` | The export itself exceeded the snapshot apply-by window. | The remedy text says to rerun the command; a scan longer than `-MaxAgeSeconds` is synced by the optional job. | `scripts/Sync-ClaudeProjection.ps1:249-255` |
| `groups resolved to nobody while the projection holds <n> record(s); refusing to remove them all` | A directory read that returns nobody is indistinguishable from a real empty directory. | `-AllowEmpty` is used only when the groups are truly empty; otherwise Graph group names and read permissions are corrected. | `sync/src/plan.mjs:73-84`, `scripts/Sync-ClaudeAccess.ps1:198-210` |
| `AADSTS500011` | Entra has no service principal for the resolver application. | The deployer creates the service principal when missing; the switch refuses without it. | `docs/SECURE-PROJECTION.md:157-158`, `docs/SECURE-PROJECTION.md:301-307` |
| `InvalidResourceLocation` and `cosmos-<prefix> already exists in location X` | The resource group already contains the projection Cosmos account in another region. | The fix is to rerun with `-Location X`, or choose another prefix. | `docs/SECURE-PROJECTION.md:782-789` |
| `Authorization_RequestDenied` or Graph 403 | The caller or job identity lacks directory read permission. | The customer Entra administrator verifies directory read permission; for the optional job, a Privileged Role Administrator or Global Administrator grants `GroupMember.Read.All` to the job identity. | `scripts/ClaudeGraphMembership.ps1:15-20`, `docs/SECURE-PROJECTION.md:694-701` |
| `Could not start runner '<name>' (az exit <code>).` | The runner container group could not be started. | The remedy text says to redeploy with `scripts/Deploy-ClaudeProjection.ps1`, then rerun the sync. A stopped runner is started automatically before projection sync. | `scripts/ClaudeRunner.ps1:37-80`, `scripts/Sync-ClaudeAccess.ps1:100-116` |
| `Runner '<name>' did not reach Running within <seconds> seconds` | The runner did not become Running after start. | The remedy text says to inspect `az container show -g <rg> -n <name>`, or redeploy with `scripts/Deploy-ClaudeProjection.ps1`. | `scripts/ClaudeRunner.ps1:70-80` |

## 10. Commands without the scripts

Azure CLI-only equivalents for the projection live in [AZ-COMMANDS section 10](AZ-COMMANDS.md#10-optional-cosmos-projection), and request verification lives in [AZ-COMMANDS section 11](AZ-COMMANDS.md#11-verification). Runner-side manual population commands, including `Send-RunnerFile` and `Invoke-RunnerCommand`, live in [SECURE-PROJECTION section 8](SECURE-PROJECTION.md#8-populate-the-projection-from-inside-the-network). This workbook does not duplicate those low-level blocks. Sources: `docs/AZ-COMMANDS.md:1508-1700`, `docs/SECURE-PROJECTION.md:636-711`.



