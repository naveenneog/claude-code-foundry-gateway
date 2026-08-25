# Debug guide — isolating a failure

[TROUBLESHOOTING.md](TROUBLESHOOTING.md) is a symptom → fix lookup table. Use it
when you already know what broke.

This guide is for when you do **not** — a request fails and you need to find out
where. It bisects the path layer by layer, so each step eliminates everything
below it.

---

## Step 0 — Run the health check

Before reading any of this, run the whole bisection in one command:

```powershell
./scripts/Debug-ClaudeCode.ps1 `
    -GatewayBaseUrl https://<apim>.azure-api.net/claude `
    -AppInsightsId <app-insights-app-id>
```

It checks sign-in and token expiry, the gateway per model, CLI and VS Code
configuration, a real end-to-end call, and whether the VS Code extension host is
stale — then names the layer at fault.

`-AppInsightsId` is the Application Insights **AppId**, not the resource id:

```bash
az resource show -g <rg> -n appi-claude-gateway \
  --resource-type Microsoft.Insights/components --query properties.AppId -o tsv
```

Supplying it enables the check that matters most: whether the call **arrived**.
A successful `claude -p` that produces no gateway traffic means Claude Code is
answering from somewhere other than your gateway, which no other check catches.

> Telemetry ingestion lags by a couple of minutes, so the script waits 90
> seconds before querying. Do not shorten that — a query run immediately after
> the call returns nothing and looks exactly like a bypass. That misdiagnosis is
> why the wait is there.

---

## The request path

Every failure lives at exactly one of these hops.

```
  developer machine
        │  0. VS Code extension host is current?
        │  1. az login → Entra token (oid, upn)
        ▼
  APIM gateway
        │  2. validate-azure-ad-token      → 401
        │  3. tier lookup, allowlist       → 403
        │  4. llm-token-limit per minute   → 429
        │  5. llm-token-limit daily quota  → 403
        │  6. swap in gateway managed identity
        ▼
  Microsoft Foundry
        │  7. RBAC on the account          → 401
        │  8. deployment exists            → 404
        ▼
  claude-sonnet-5 / claude-opus-5
```

---

## Everything checks out but the panel is still broken

Worth its own section because it is common, it looks nothing like a
configuration fault, and every other check passes.

**The VS Code extension host holds the build that was current when the window
opened.** The extension auto-updates on disk; the running host does not pick
that up. A window left open for days can be several versions behind, and the
symptom is a Claude Code panel that fails while the CLI works perfectly.

Observed case: a window running for **171 hours** across **7 extension
updates**, with a healthy tenant, a healthy gateway, valid tokens, correct
settings on both the CLI and VS Code side, and a `claude -p` that returned
normally and reached the gateway.

```powershell
# is the running VS Code older than the installed extension?
./scripts/Debug-ClaudeCode.ps1 -GatewayBaseUrl <url>   # section 5
```

**Fix:** `Ctrl+Shift+P` → **Developer: Reload Window**. If it persists, quit VS
Code entirely — a stale helper process can survive a reload.

> Suspect this first whenever the **CLI works and the panel does not**. That
> asymmetry almost always means the two are running different builds, or reading
> different configuration — shell exports never reach the extension host, so
> VS Code needs `claudeCode.environmentVariables` or `.claude/settings.json`.

---

## Step 1 — Read the response headers first

This is the fastest single diagnostic and most people skip it. The gateway
annotates every response.

```powershell
$tok = az account get-access-token --resource https://cognitiveservices.azure.com --query accessToken -o tsv
$r = Invoke-WebRequest -Method Post -Uri "https://<apim>.azure-api.net/claude/v1/messages" `
  -Headers @{
    Authorization      = "Bearer $tok"
    'anthropic-version'= '2023-06-01'
    'Content-Type'     = 'application/json'
  } `
  -Body '{"model":"claude-sonnet-5","max_tokens":16,"messages":[{"role":"user","content":"say OK"}]}' `
  -SkipHttpErrorCheck
$r.StatusCode
$r.Headers | Format-Table -AutoSize
```

> Windows PowerShell 5.1 has no `-SkipHttpErrorCheck`. Use PowerShell 7, or wrap
> the call in `try/catch` and read `$_.Exception.Response`.

What the headers tell you:

| Header | Present when | Means |
|--------|--------------|-------|
| `x-governed-by` | request reached the policy | the gateway is in the path at all |
| `x-claude-tier` | tier resolved | `standard` / `premium` — confirms which allowlist matched |
| `x-ratelimit-remaining-tokens` | per-minute limit applied | your remaining minute budget |
| `x-quota-remaining-today` | daily quota applied | remaining daily budget |
| `x-tokens-consumed` | backend responded | what this call cost |
| `Retry-After` | `429` | seconds until the minute budget resets |
| `x-gateway-error` | policy raised the error | **the gateway rejected you, not Foundry** |

**`x-gateway-error` is the key signal.** If it is present, stop looking at
Foundry — the request never got there.

---

## Step 2 — Narrow by status code

| Code | Layer | Go to |
|------|-------|-------|
| `401` with `x-gateway-error` | identity | [Step 3](#step-3--identity) |
| `403` with `x-gateway-error` | entitlement or quota | [Step 4](#step-4--entitlement-and-budget) |
| `429` | per-minute budget | [Step 4](#step-4--entitlement-and-budget) |
| `401` **without** `x-gateway-error` | gateway → Foundry RBAC | [Step 5](#step-5--gateway--foundry) |
| `404` | wrong path or missing deployment | [Step 6](#step-6--foundry-itself) |
| `500` | usually a missing named value | [Step 7](#step-7--policy-and-configuration) |
| timeout / no response | network or a very long agent turn | [Step 8](#step-8--client-configuration) |

---

## Step 3 — Identity

```powershell
az account show --query "{tenant:tenantId, user:user.name, type:user.type}" -o table
```

Then decode what you are actually sending. The `oid` is what the gateway
compares against the allowlists:

```powershell
$t = az account get-access-token --resource https://cognitiveservices.azure.com --query accessToken -o tsv
$p = $t.Split('.')[1].Replace('-','+').Replace('_','/')
while ($p.Length % 4) { $p += '=' }
[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p)) | ConvertFrom-Json |
  Select-Object oid, upn, unique_name, tid, aud, appid
```

Check, in order:

| Claim | Must be | If wrong |
|-------|---------|----------|
| `tid` | the tenant hosting the gateway | `az login --tenant <tenant-id>` — **the usual cause for guests** |
| `aud` | `https://cognitiveservices.azure.com` | you requested the wrong resource scope |
| `oid` | present | service principals differ from users; use the SP object id, not the app id |
| `exp` | in the future | token expired — re-run `az login` |

> A guest account's `upn` often looks like
> `user_home.com#EXT#@hosting-tenant.onmicrosoft.com`. That is normal. The
> allowlists key on `oid`, so the odd-looking UPN is not the problem.

---

## Step 4 — Entitlement and budget

### Is the object id entitled?

```bash
az apim nv show -g <rg> --service-name <apim> --named-value-id allow-standard --query value -o tsv
az apim nv show -g <rg> --service-name <apim> --named-value-id allow-premium  --query value -o tsv
```

Not there → they are in the Entra group but the sync has not run:

```powershell
./scripts/Sync-ClaudeAccess.ps1 -ApimName <apim> -ResourceGroup <rg>
```

### Is it a budget rejection instead?

`429` and quota-`403` are working-as-intended, not faults.

| Code | Meaning | Resolution |
|------|---------|-----------|
| `429` + `Retry-After` | per-minute budget | wait; Claude Code retries on its own |
| `403`, no entitlement message | daily quota spent | wait for the period, or move them to premium |

> Raising `quota-standard` does **not** unblock someone already over it — the
> counter runs against the period that has already started. Move them to the
> premium tier instead.

Distinguish the two `403`s by the message body: an entitlement failure says so
explicitly, a quota failure has no message.

---

## Step 5 — Gateway → Foundry

A `401` with **no** `x-gateway-error` means the policy accepted you and Foundry
rejected the gateway.

```bash
# 1. does the gateway have an identity at all?
az apim show -g <rg> -n <apim> --query "identity.principalId" -o tsv

# 2. does that identity hold the data-plane role?
az role assignment list \
  --assignee <principal-id> \
  --scope $(az cognitiveservices account show -g <rg> -n <foundry> --query id -o tsv) \
  --query "[].roleDefinitionName" -o tsv
```

Expect `Cognitive Services User`.

| Finding | Fix |
|---------|-----|
| No principal id | System-assigned identity is off. Turn it on, then re-create the role assignment |
| Role is `Owner` or `Contributor` only | Those are control-plane roles and grant **no** data-plane access. Add `Cognitive Services User` |
| Role is correct, still `401` | Propagation. Wait 2–5 minutes |
| Assignment vanished | It is scoped to the Foundry account; recreating that resource drops it |

---

## Step 6 — Foundry itself

Take the gateway out of the picture entirely:

```powershell
./scripts/Test-FoundryDirect.ps1 -Resource <foundry-account>
```

Seven checks: CLI sign-in, token acquisition, deployment discovery, the Messages
API, the Claude Code install, provider resolution, and an end-to-end call.

- **All pass** → Foundry is healthy; the fault is in the gateway or the policy.
  Go back to Step 5, then Step 7.
- **Any fail** → fix Foundry first. The gateway cannot be healthier than its
  backend.

> This needs you to hold `Cognitive Services User` directly, which by design you
> normally should not. Grant it temporarily and remove it afterwards — see
> [Setup §4.1](SETUP.md#41-close-the-bypass--do-not-skip-this).

Two `404`s that look alike and are not:

| Body | Cause |
|------|-------|
| `api_not_supported` | an OpenAI-shaped path. Claude deployments expose only `/anthropic/*` |
| `DeploymentNotFound` | a model alias pointing at something you do not host. Foundry mode does no start-up model check, so this surfaces mid-task |

---

## Step 7 — Policy and configuration

```bash
# is the policy actually attached?
az apim api policy show -g <rg> --service-name <apim> --api-id claude-foundry --query value -o tsv

# do all referenced named values exist?
az apim nv list -g <rg> --service-name <apim> --query "[].name" -o tsv
```

A `{{name}}` in the policy with no matching named value returns `500`.

| Symptom | Cause |
|---------|-------|
| `500` on every request | missing named value |
| Policy edit appears not to apply | `az rest` on Windows throws `charmap codec can't encode '\ufeff'` **after a successful PUT**. Verify with a GET before retrying |
| `An XML comment cannot contain '--'` | a `--` inside an XML comment. The error does not mention comments |
| Limits never trigger | classic APIM tier — Anthropic token parsing needs **v2**. Check `az apim show --query "sku.name"` |

---

## Step 8 — Client configuration

If the request never reaches the gateway at all, `x-governed-by` is absent and
Application Insights **Live metrics** shows nothing.

```powershell
claude auth status
```

```json
{ "loggedIn": true, "authMethod": "third_party", "apiProvider": "foundry" }
```

| Symptom | Cause |
|---------|-------|
| `apiProvider` is not `foundry` | `CLAUDE_CODE_USE_FOUNDRY=1` not set |
| `baseURL and resource are mutually exclusive` | both `ANTHROPIC_FOUNDRY_BASE_URL` and `ANTHROPIC_FOUNDRY_RESOURCE` set — keep only the base URL for gateway mode |
| `CLAUDE_CODE_USE_AZURE` has no effect | it does not exist; the variable is `CLAUDE_CODE_USE_FOUNDRY` |
| Extension prompts for Anthropic sign-in | settings not picked up. **Developer: Reload Window**; shell exports do **not** reach the extension host — use `.claude/settings.json` or `claudeCode.environmentVariables` |
| Panel fails while the CLI works | the extension host is running an older build than the one on disk. Reload the window — see [above](#everything-checks-out-but-the-panel-is-still-broken) |
| `/status` unavailable | terminal-only; use `claude auth status` in the panel |

### See exactly what is on the wire

When nothing else explains it, put the inspector between the client and the
gateway. It decodes the token claims and prints headers; the token itself is
never logged.

```powershell
node scripts/inspect-proxy.mjs
$env:ANTHROPIC_FOUNDRY_BASE_URL = "http://localhost:8787"
claude -p "hello"
```

This is how the identity model was established rather than assumed — it is what
proved Claude Code forwards the developer's own Entra token, complete with `oid`,
`upn`, and `x-claude-code-session-id`.

---

## Step 9 — Is it just this person?

```powershell
./scripts/Show-Governance.ps1 -ApimName <apim> -ResourceGroup <rg>
```

If all four controls pass for the test identities, the gateway is healthy and the
problem is specific to the affected user — go back to Step 3.

If they fail, it is platform-wide. Start at Step 5.

---

## Quick reference

| Signal | Layer | Section |
|--------|-------|---------|
| Everything passes but the panel fails | stale extension host | [above](#everything-checks-out-but-the-panel-is-still-broken) |
| CLI works, VS Code does not | different build or different config | [above](#everything-checks-out-but-the-panel-is-still-broken) |
| `x-gateway-error` present | gateway rejected it | Steps 3–4 |
| `x-gateway-error` absent, `401` | Foundry rejected the gateway | Step 5 |
| No `x-governed-by`, no Live metrics traffic | never left the client | Step 8 |
| `429` + `Retry-After` | working as designed | Step 4 |
| Metrics all zero | classic APIM tier | [Monitoring §8](MONITORING.md#8-when-the-charts-are-empty) |
| Metrics exist, no per-user split | `CustomMetricsOptedInType` | [Monitoring §8](MONITORING.md#8-when-the-charts-are-empty) |
