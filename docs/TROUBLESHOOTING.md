# Troubleshooting

Every entry here is a failure that was actually hit while building and verifying this
accelerator, not a hypothetical.

Use this page when you know the symptom. If you cannot identify the failing
layer, run [Diagnostics](DIAGNOSE.md) first, then follow
[Debugging](DEBUGGING.md); for roles/resource names, use
[Operations](OPERATIONS.md#1-select-the-gateway-and-workspace).
After a fix, repeat the original request and inspect its body and headers.

## Deployment

| Symptom | Cause → Fix |
|---|---|
| `az apim create: 'BasicV2' is not a valid value for '--sku-name'` | The Azure CLI has no v2 SKU support. Deploy with the Bicep/ARM template in `infra/` — that is why this accelerator does not use `az apim create`. |
| `ServiceAlreadyExists: Api service already exists` | API Management names are **globally** unique DNS labels. Pick a different `-NamePrefix`. Also check `az apim deletedservice list` — a soft-deleted instance still holds its name until purged. |
| `RoleAssignmentExists: The role assignment already exists` | The gateway identity already holds `Cognitive Services User` on the Foundry account, under a name created by the CLI or the portal rather than by this template. Azure refuses a second assignment for the same principal, role and scope **even under a different name**, so the deployment fails rather than skipping the grant. Hits the reuse path, since a reused gateway was granted the role when it was first built. Fixed in the installer, which checks first and passes `grantFoundryRole=false`. Deploying the template by hand? Pass it yourself. Note `what-if` does **not** predict this: the grant is a nested deployment at another scope and comes back as `Unsupported`, so the plan looks clean. |
| `Update-ClaudeGateway.ps1` refuses to apply because the fingerprint differs | The record, live gateway, policy file or prices changed after the plan was reviewed. Re-run the update, review the new impact and approve the new fingerprint; do not reuse an old approval. |
| `Update-ClaudeGateway.ps1` says a policy named value has no safe default | The current `infra/policy.xml` references a `{{named-value}}` that is not created by `infra/main.bicep`. Add the named value to the template or create it deliberately before applying; the updater refuses to invent values that could change authorization. |
| `validate-azure-ad-token` says `The audience field is required` while updating policy | `external-idp-extra-audience` exists but is blank or whitespace. Normalize it to the disabled sentinel `urn:disabled:claude-extra-audience`, then retry the policy update. `Update-ClaudeGateway.ps1` now does this before writing the policy. |
| API Management tier change to `StandardV2` fails with `OperationSupportedInSkuForApiVersions` | The Azure CLI used an older API version for the update. Use the guided Tier change or ARM `2024-05-01` or later; v2 tier capabilities require those API versions. |
| Deployment succeeds but `llm-token-limit` never throttles | You are on a classic tier. Anthropic token parsing requires **Basic v2 / Standard v2 / Premium v2**. |
| `Authorization_RequestDenied` granting Graph permissions | Granting the gateway identity `GroupMember.Read.All` needs tenant admin consent. Use the default sync approach instead. |
| Cannot create the Entra groups | Many tenants restrict group creation. Create them by hand and re-run with `-SkipGroups`. |
| Deleting a resource group rolls back with `ResourceGroupDeletionBlocked`, naming a Flex Consumption plan (`Microsoft.Web/serverFarms`, FC1) whose delete fails `NotFound` | The Functions resolver's plan outlived its app: ARM still lists it, the Web provider no longer knows it, and every group delete rolls back on it. Measured on 2026-09-25: five deletes over more than 90 minutes each rolled back. Re-create the plan under the same name (`az rest --method PUT` on its resource ID with `sku` FC1 / FlexConsumption, `kind` functionapp, the original location), delete it, then delete the group; the group was gone 24 seconds later. Capacity 0 carries no cost while it exists. |

## Environment

| Symptom | Cause → Fix |
|---|---|
| `az : ].name was unexpected at this time` | On Windows `az` is a `.cmd` shim, and PowerShell only quotes native arguments that contain a space. A `--query` with parentheses and no space reaches `cmd.exe` bare and is re-parsed. Affects Windows PowerShell 5.1 **and** PowerShell 7 equally — it is a property of the shim, not the host. Keep `( ) \| & < > ^` out of `--query` and filter in PowerShell instead. |
| A `--query` that worked breaks after an edit | Same cause. Deleting the last space from the query is enough to trigger it. |
| A `--query` returns obviously wrong results | Same cause, and quieter. The error text is a non-empty string, so `if ($result)` reads as success and the caller accepts garbage. This shipped once: every Cognitive Services account was reported as having a Claude deployment. Check raw output before trusting a filter. |

The preflight in both setup scripts reports whether the platform is affected.

## Policy

| Symptom | Cause → Fix |
|---|---|
| `An XML comment cannot contain '--', and '-' cannot be the last character` | A `--` inside an XML comment in your policy. Use single dashes. The error does not mention comments. |
| `az rest` fails with `'charmap' codec can't encode character '\ufeff'` | An Azure CLI bug decoding APIM's policy response on Windows. **The PUT usually succeeded** — verify with a GET before retrying. `Set-GatewayPolicy.ps1` avoids `az rest` for this reason. |
| Policy references `{{name}}` and returns 500 | The named value does not exist. Create it, or redeploy the template. |
| A lifecycle entitlement flip is refused after projection deployment | The comparison was not clean. Re-run `Deploy-ClaudeProjection.ps1` without `-FlipAfterCleanCompare`, fix the reported missing/stale identities, then run it with `-FlipAfterCleanCompare`; the guided step deliberately refuses to flip on drift. |

## Runtime

| Symptom | Cause → Fix |
|---|---|
| **401** "A Microsoft Entra ID token is required" | Not signed in, or signed into the wrong tenant. Guests must use `az login --tenant <tenant-id>`. |
| **403** "Not entitled to Claude Code" | Object id is in neither allowlist. Add the person to a group and run `Sync-ClaudeAccess.ps1`. |
| **403** `rate_limit_error` | Read `budget` and the message: personal, organisation or business-unit/team budget. A quota increase can admit new requests after propagation; it does not reset consumption. |
| **403** `model_not_allowed` / unassigned-unit message | Model or unit policy, not necessarily missing tier membership. Check [Budgets](BUDGETS.md) and the published unit map. |
| **429** | Token/request rate, resolver miss admission or Foundry capacity. Inspect the body and honour `Retry-After`; not every 429 is the personal TPM limit. |
| **503** naming an expired projection | Reconciliation did not renew the lease. Complete a fresh scan/apply; never serve stale records or roll back to unreviewed old lists. |
| **503** naming the entitlement service | Resolver/network/authentication failure after cache expiry. Check [Private projection](SECURE-PROJECTION.md#troubleshooting). |
| **404** `api_not_supported` from Foundry | An OpenAI-shaped path. Claude deployments expose only `/anthropic/*`. |
| **404** `DeploymentNotFound` | A model alias points at a deployment you do not have. Foundry mode does no start-up model check, so this surfaces mid-task. |
| Backend returns 401 through the gateway | The gateway identity lacks `Cognitive Services User` on the Foundry account, or the assignment has not propagated (allow 2–5 minutes). |

## Claude Code client

| Symptom | Cause → Fix |
|---|---|
| `baseURL and resource are mutually exclusive` | Both `ANTHROPIC_FOUNDRY_BASE_URL` and `ANTHROPIC_FOUNDRY_RESOURCE` are set. Keep only the base URL when using the gateway. |
| `API Error: 400 ... "thinking.type.enabled" is not supported for this model` | Claude Code does not recognise a Foundry deployment name, and a release older than the model sends the older thinking request. The workstation setup writes `ANTHROPIC_DEFAULT_<ALIAS>_MODEL_SUPPORTED_CAPABILITIES` for each pinned model and runs `claude update`. Measured 2026-09-27: Claude Code 2.1.101 returned this 400 for `claude-opus-5` and `claude-sonnet-5` without the declaration and answered with it. A hand-written declaration that lists `thinking` without `adaptive_thinking` sends the same request on every release measured, 2.1.101 and 2.1.272 ([ADR-0031](adr/0031-client-keys-every-release-reads.md)). |
| The setup or diagnostics report `could not start ...\npm\claude` | npm writes `claude.ps1`, `claude.cmd` and an extensionless POSIX script into one folder, and Windows cannot start the extensionless one. The scripts choose the `.exe`, `.cmd` or `.ps1` in each folder; update the scripts from this repository. |
| The setup stops: `ClaudeClientSupport.ps1 and ClaudeDesktopSignIn.ps1 must be in the same folder as this script` | Only `Setup-ClaudeWorkstation.ps1` was copied. Fetch the whole scripts folder, or use the onboarding email's command, which fetches every file the setup reads. |
| Windows PowerShell: `gateway call failed  HTTP` with no status, or `Object reference not set to an instance of an object` | The setup and diagnostics before 2026-09-27 called `Invoke-WebRequest` without `-UseBasicParsing`, which Windows PowerShell 5.1 needs on a machine without Internet Explorer; no request was sent. Update the scripts from this repository, or run them in PowerShell 7 (`pwsh`). |
| The setup, given `-ConfigPath https://...`, reports `No gateway configuration` on Windows PowerShell | The record was written by the installer on Windows PowerShell 5.1, which starts the file with a UTF-8 byte-order mark, and setups before 2026-09-27 could not read that over HTTP on 5.1. Update the scripts, or pass a downloaded copy of the file. |
| `CLAUDE_CODE_USE_AZURE` appears to do nothing | It does not exist. The variable is `CLAUDE_CODE_USE_FOUNDRY=1`. |
| `/status` says it is not available | `/status` works in the terminal UI, not the VS Code panel. Use `claude auth status`. |
| Extension prompts for Anthropic sign-in | It has not picked up the settings. Run **Developer: Reload Window**; if it persists, add the same variables under `claudeCode.environmentVariables` in VS Code user settings. Shell exports do not reach the extension. |
| The panel fails but the CLI works | The extension host is running an older build than the one installed on disk — it does not pick up auto-updates until the window reloads. A long-lived window can be several versions behind. **Developer: Reload Window**, and quit VS Code entirely if that is not enough. `Debug-ClaudeCode.ps1` reports this. |
| Windows: a credential script returns *"Windows Subsystem for Linux has no installed distributions"* | Inside Git Bash a bare `az` resolves to the WSL shim. Use `az.cmd`. Note `command -v az.cmd` also fails because bash ignores `PATHEXT`, so probe by running the candidate and checking the result starts with `eyJ`. |

## Claude Desktop

| Symptom | Cause → Fix |
|---|---|
| Nothing happens when you open it, and no error is shown | Its app container cannot be created. See below. |
| Connection dropped (ECONNRESET) while every host is reachable | Not an allowlist problem — see [NETWORK.md §6](NETWORK.md#6-econnreset-is-not-an-allowlist-problem). |
| **Connection needs Credential kind**, and the Credential kind field is empty | The profile uses sign-in keys the Desktop release that reads it does not know. `external-idp`, `inferenceIdpOidc` and `inferenceIdpAuthFlow` need Desktop 2.7032.0; `interactive` with `inferenceGatewayOidc` is read from 1.6889.0 and by later releases as `external-idp`. Re-run the workstation setup, which writes the spelling the installed and running build reads ([ADR-0031](adr/0031-client-keys-every-release-reads.md)). |
| The Entra **Sign in** button does nothing after Desktop updated | An older build is still running. The per-user installer adds an `app-<version>` folder for each update, and a shortcut pinned to one folder keeps starting that build: on the owner's workstation on 2026-09-27, 2.9939.2 was installed while `app-1.44121.2\claude.exe` ran. Quit Desktop including the tray icon and start it from the Start menu. `Debug-ClaudeWorkstation.ps1` reports the running build and any versioned shortcut. |
| `getaddrinfo ENOTFOUND <host>` in `%LOCALAPPDATA%\Claude-3p\logs\main.log` | The gateway host in the profile does not resolve from this machine. Compare `inferenceGatewayBaseUrl` with the gateway URL in `claude-gateway.json`; a company address chosen at install needs its DNS record before developers use it. `Debug-ClaudeWorkstation.ps1` shows recent Desktop log errors. The cause on the owner's workstation is open as U29 in [UNKNOWNS](UNKNOWNS.md). |

### Desktop does not open at all

Nothing appears, no window, no error, and no `claude` process. The deployment
log — **Event Viewer → Applications and Services → Microsoft → Windows →
AppXDeploymentServer/Operational** — shows:

```text
Error while deleting file ...\Packages\Claude_pzs8sxrjxfjjc\SystemAppData\Helium\UserClasses.dat
Error Code : 0x20.
```

`0x20` is `ERROR_SHARING_VIOLATION`. The package's own registry hives —
`User.dat` and `UserClasses.dat` — are held open, so the app container cannot
be built and the launch fails as `0x80070020`.

**There is nothing to close.** Restart Manager attributes those handles to
`System` (pid 4) and `Registry` (pid 276): the kernel has the hive loaded. It
is in the AppX app-hive namespace rather than under `HKEY_USERS`, so
`reg unload` cannot reach it either.

Measured as ineffective against this state: `Reset-AppxPackage`, removing and
re-registering the package, stopping the Cowork service, and Developer Mode —
which was already on. **Reinstalling does not help, because the lock outlives
the package.**

**Sign out and back in, or restart.** That is the only thing that drops the
hive.

To confirm it is this and not something else:

```powershell
# names the holder, using the Restart Manager API - no Sysinternals needed
./scripts/Get-FileLockOwner.ps1 -Path "$env:LOCALAPPDATA\Packages\Claude_pzs8sxrjxfjjc\SystemAppData\Helium\UserClasses.dat"
```

`Test-FoundryDirect.ps1` checks for this without launching anything: a lock on
those files while no Claude process is running is the signature.

## Monitoring

| Symptom | Cause → Fix |
|---|---|
| No custom metrics at all | The APIM diagnostic needs `metrics: true`. Without it `llm-emit-token-metric` emits nothing and the namespace never appears. |
| Metrics exist but there is no per-user breakdown | Application Insights needs `CustomMetricsOptedInType: WithDimensions`. Dimensions are dropped silently otherwise. |
| `az monitor metrics list` says the metric does not exist | The CLI drops `--namespace` for custom namespaces. Query the REST API; `Show-Governance.ps1` shows the call. |
| Metrics lag | Custom metric ingestion takes a few minutes. Generate traffic, then wait before querying. |
| Many users work but some never appear in metrics | Custom metric cardinality caps discard new series. Use the request ledger; [FinOps](FINOPS.md) also explains cache-read reporting limits. |
| A service principal is missing from the group sync | Delegated tokens cannot list service principal members without `Application.Read.All`. Pass CI identities explicitly with `-AdditionalPremiumOids` / `-AdditionalStandardOids`. |
| `ApiManagementGatewayLlmLog` is empty — even over all time — while the gateway is plainly serving | You are reading a different workspace. A resource group often holds several, and the first one listed need not be the gateway's; on the reference deployment three share the group and the first is not it. Ask the gateway where it writes rather than guessing: `az monitor diagnostic-settings list --resource <apim-resource-id> --query "[].workspaceId" -o tsv`. The scripts here ask the gateway, match the workspace named after it, or refuse to guess — none takes the first one listed. |

## Still stuck?

Collect UTC time, client/version, gateway host, status/error body and the
relevant operation/request ID for the platform team. Redact personal/deployment
values and never attach a token. [Debugging](DEBUGGING.md) has the next tests.

Do not use the historical inspector proxy unchanged: its upstream is fixed and
its listener is not explicitly loopback-only. See
[the inspection warning](DEBUGGING.md#see-exactly-what-is-on-the-wire).

## Turnstile and offboarding

| Symptom | Next action |
|---|---|
| Need admin approval at Microsoft sign-in | Use [Turnstile's CLI sign-in](TURNSTILE.md#viewers-and-managers), or have the tenant administrator grant approved web consent |
| Removed person still works | Check nested memberships, active-store publication, `Nothing to change`/empty-list warnings and cache/lease timing; [Onboarding](ONBOARDING.md#5-revoke-access) |
| Turnstile save is not yet applied | Check the apply job/last result and governance authority; UI save is not proof of gateway propagation |
