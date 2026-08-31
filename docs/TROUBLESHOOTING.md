# Troubleshooting

Every entry here is a failure that was actually hit while building and verifying this
accelerator, not a hypothetical.

## Deployment

| Symptom | Cause → Fix |
|---|---|
| `az apim create: 'BasicV2' is not a valid value for '--sku-name'` | The Azure CLI has no v2 SKU support. Deploy with the Bicep/ARM template in `infra/` — that is why this accelerator does not use `az apim create`. |
| `ServiceAlreadyExists: Api service already exists` | API Management names are **globally** unique DNS labels. Pick a different `-NamePrefix`. Also check `az apim deletedservice list` — a soft-deleted instance still holds its name until purged. |
| Deployment succeeds but `llm-token-limit` never throttles | You are on a classic tier. Anthropic token parsing requires **Basic v2 / Standard v2 / Premium v2**. |
| `Authorization_RequestDenied` granting Graph permissions | Granting the gateway identity `GroupMember.Read.All` needs tenant admin consent. Use the default sync approach instead. |
| Cannot create the Entra groups | Many tenants restrict group creation. Create them by hand and re-run with `-SkipGroups`. |

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

## Runtime

| Symptom | Cause → Fix |
|---|---|
| **401** "A Microsoft Entra ID token is required" | Not signed in, or signed into the wrong tenant. Guests must use `az login --tenant <tenant-id>`. |
| **403** "Not entitled to Claude Code" | Object id is in neither allowlist. Add the person to a group and run `Sync-ClaudeAccess.ps1`. |
| **403** with no message | Daily token quota exhausted. It resets on the period boundary. |
| **429** | Per-minute token budget hit. `Retry-After` says how long; Claude Code backs off on its own. |
| **404** `api_not_supported` from Foundry | An OpenAI-shaped path. Claude deployments expose only `/anthropic/*`. |
| **404** `DeploymentNotFound` | A model alias points at a deployment you do not have. Foundry mode does no start-up model check, so this surfaces mid-task. |
| Backend returns 401 through the gateway | The gateway identity lacks `Cognitive Services User` on the Foundry account, or the assignment has not propagated (allow 2–5 minutes). |

## Claude Code client

| Symptom | Cause → Fix |
|---|---|
| `baseURL and resource are mutually exclusive` | Both `ANTHROPIC_FOUNDRY_BASE_URL` and `ANTHROPIC_FOUNDRY_RESOURCE` are set. Keep only the base URL when using the gateway. |
| `CLAUDE_CODE_USE_AZURE` appears to do nothing | It does not exist. The variable is `CLAUDE_CODE_USE_FOUNDRY=1`. |
| `/status` says it is not available | `/status` works in the terminal UI, not the VS Code panel. Use `claude auth status`. |
| Extension prompts for Anthropic sign-in | It has not picked up the settings. Run **Developer: Reload Window**; if it persists, add the same variables under `claudeCode.environmentVariables` in VS Code user settings. Shell exports do not reach the extension. |
| The panel fails but the CLI works | The extension host is running an older build than the one installed on disk — it does not pick up auto-updates until the window reloads. A long-lived window can be several versions behind. **Developer: Reload Window**, and quit VS Code entirely if that is not enough. `Debug-ClaudeCode.ps1` reports this. |
| Windows: a credential script returns *"Windows Subsystem for Linux has no installed distributions"* | Inside Git Bash a bare `az` resolves to the WSL shim. Use `az.cmd`. Note `command -v az.cmd` also fails because bash ignores `PATHEXT`, so probe by running the candidate and checking the result starts with `eyJ`. |

## Monitoring

| Symptom | Cause → Fix |
|---|---|
| No custom metrics at all | The APIM diagnostic needs `metrics: true`. Without it `llm-emit-token-metric` emits nothing and the namespace never appears. |
| Metrics exist but there is no per-user breakdown | Application Insights needs `CustomMetricsOptedInType: WithDimensions`. Dimensions are dropped silently otherwise. |
| `az monitor metrics list` says the metric does not exist | The CLI drops `--namespace` for custom namespaces. Query the REST API; `Show-Governance.ps1` shows the call. |
| Metrics lag | Custom metric ingestion takes a few minutes. Generate traffic, then wait before querying. |
| A service principal is missing from the group sync | Delegated tokens cannot list service principal members without `Application.Read.All`. Pass CI identities explicitly with `-AdditionalPremiumOids` / `-AdditionalStandardOids`. |

## Still stuck?

Run the inspector proxy to see exactly what Claude Code is sending, including the decoded token
claims (the token itself is never printed):

```powershell
node scripts/inspect-proxy.mjs
$env:ANTHROPIC_FOUNDRY_BASE_URL = "http://localhost:8787"
claude -p "hello"
```
