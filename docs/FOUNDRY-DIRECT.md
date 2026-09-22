# Foundry direct — Claude Code without the gateway

Points Claude Code straight at a Microsoft Foundry resource. No API Management
in front of it, no entitlement check, no budget, no chargeback.

This repository exists to put a gateway in that path, so shipping the opposite
needs saying plainly: **this is for evaluating Foundry, not for running a team
on it.** The distinction is not a preference, and section 4 is the part to read
before using it on anything that matters.

---

## 1. When this is the right tool

| | |
|---|---|
| Proving Claude works on your Foundry resource before building anything | ✅ |
| A spike, a demo, or debugging whether a problem is the gateway or Foundry | ✅ |
| One person evaluating models against their own subscription | ✅ |
| A team | ❌ use the gateway |
| Anything where you need to know what it cost, or who spent it | ❌ use the gateway |
| Anything where access must end when somebody leaves | ❌ use the gateway |

It is also the fastest way to answer *"is the gateway broken, or is Foundry?"* —
configure one machine directly and see which layer the failure follows.

## 2. Running it

```powershell
# Device code. No browser needed on this machine - enter the code anywhere.
./scripts/Setup-ClaudeFoundryDirect.ps1 -Resource ai-contoso -TenantId <tenant-guid>

# Browser sign-in on this machine
./scripts/Setup-ClaudeFoundryDirect.ps1 -Resource ai-contoso -TenantId <guid> -Auth interactive

# Use the Azure CLI session that is already signed in
./scripts/Setup-ClaudeFoundryDirect.ps1 -Resource ai-contoso -TenantId <guid> -Auth current

# Sign in through your own app registration rather than the Azure CLI's
./scripts/Setup-ClaudeFoundryDirect.ps1 -Resource ai-contoso -TenantId <guid> -ClientId <app-guid>
```

`-Resource` is the Foundry account **name**, not a URL and not a resource id.

**Give it `-TenantId`.** It is optional and almost always wanted: an account that
exists in more than one directory, or is a guest, signs in to the wrong one by
default, and the Foundry resource is then invisible with an error that does not
mention tenants.

### Or hand over a config file

Four values typed by hand is four chances to mistype one. Set one machine up,
write the file, and give that to everybody else — the same shape and the same
idea as the gateway's `claude-gateway.json`:

```powershell
# On the machine that works
./scripts/Setup-ClaudeFoundryDirect.ps1 -Resource ai-contoso -TenantId <guid> `
    -WriteConfig .\claude-foundry-direct.json

# On every other machine
./scripts/Setup-ClaudeFoundryDirect.ps1 -ConfigPath .\claude-foundry-direct.json
```

`-ConfigPath` also takes a URL, so the file can live on an internal share or a
wiki page rather than being emailed around.

Explicit arguments still win over the file. Passing both a config and a
`-Resource` means the override, not a conflict.

#### The file

```json
{
  "mode": "foundry-direct",
  "generated": "2026-09-21 17:28",
  "foundryResource": "ai-contosohub530569751908",
  "tenantId": "16b3c013-d300-468d-ac64-7eda0820b6d3",
  "clientId": "",
  "auth": "device",
  "models": ["claude-opus-5", "claude-sonnet-5"],
  "defaults": {
    "opus": "claude-opus-5",
    "sonnet": "claude-sonnet-5",
    "haiku": "claude-sonnet-5"
  }
}
```

| Field | |
|---|---|
| `mode` | Always `foundry-direct`. It is what stops a gateway config being applied here |
| `foundryResource` | The account name |
| `tenantId` | The directory to sign in to |
| `clientId` | An app registration, or empty for the Azure CLI's |
| `auth` | `device`, `interactive` or `current` |
| `models` | Becomes `availableModels`, and is enforced |
| `defaults` | Which deployment each size maps to |

**`mode` earns its place.** The gateway file has the same extension and a
different meaning, and applying one as the other produces a machine pointed at
something that is not a Foundry resource, failing with an error that never
mentions which file was wrong. The script refuses a config carrying `gatewayUrl`
and names the script that does want it.

**Nothing in the file is a credential.** It is a resource name, a directory id
and some deployment names. Handing it to somebody grants them nothing — they
still have to hold a role on the resource and sign in as themselves. That is
what makes it safe to put on a wiki.

### What it does, in order

1. Checks the Azure CLI is present
2. Signs in, the way you asked
3. **Refuses if the signed-in tenant is not the one you named** — otherwise
   everything below fails later and less clearly
4. Gets a data-plane token, before writing anything. A config file that looks
   right but cannot authenticate is harder to diagnose than a refusal now
5. Lists the Claude deployments on the resource
6. Writes `~/.claude/settings.json`, backing up any existing one
7. Makes a real call and prints what came back

Nothing is written until steps 1–5 pass, so a failed run leaves the machine as
it was.

## 3. The model list

Discovered from the resource rather than assumed, and written as four settings
Claude Code needs:

```json
"env": {
  "ANTHROPIC_DEFAULT_OPUS_MODEL":   "claude-opus-5",
  "ANTHROPIC_DEFAULT_SONNET_MODEL": "claude-sonnet-5",
  "ANTHROPIC_DEFAULT_HAIKU_MODEL":  "claude-sonnet-5"
},
"availableModels": ["claude-opus-5", "claude-sonnet-5"],
"enforceAvailableModels": true
```

Two details that are easy to get wrong:

- **Only `Succeeded` deployments are offered.** A disabled deployment lists
  normally and then refuses every call. Measured on the reference resource,
  two of its deployments are in that state.
- **Haiku points at the Sonnet deployment.** Claude Code uses a small model for
  background work; left unset it asks for one that does not exist and the
  session fails with `DeploymentNotFound` partway through, which reads as a
  bug rather than a setting.

Override with `-Models claude-sonnet-5, claude-opus-5` when you do not have
reader rights on the resource and discovery cannot run.

### The setting that ends a session

`ANTHROPIC_FOUNDRY_RESOURCE` and `ANTHROPIC_FOUNDRY_BASE_URL` are **mutually
exclusive**. Both present and Claude Code stops with *"baseURL and resource are
mutually exclusive"*.

The base URL is the gateway path; the resource is this one. The script removes
a base URL left behind by a gateway setup, which is what makes it safe to run on
a machine that was previously on the gateway.

## 4. What you give up, and what you inherit

Every control in this repository governs traffic **through the gateway**.
Configuring a client directly does not weaken those controls — it steps around
them entirely.

| | Through the gateway | Direct |
|---|---|---|
| Who may call | Entra group membership, checked per request | anyone with a data-plane role on the resource |
| Per-developer limit | tokens per minute and per day | none |
| Organisation ceiling | enforced | none |
| Model allowlist | enforced at the gateway | the client's own list, which the user can edit |
| Cost attribution | per developer and per team | the resource total, and nothing else |
| Revoking access | remove from the group, sync | **remove the role assignment** — group membership is irrelevant |

That last row is the one that surprises people. On the direct path, taking
somebody out of `claude-code-standard` does nothing. Their access comes from a
role on the Foundry account, and it persists until that assignment is removed.

### This is the thing the bypass audit looks for

`./scripts/Get-ClaudeBypass.ps1` exists to find principals that can reach
Foundry without the gateway, and `./scripts/Test-ClaudeHealth.ps1` **fails the
run** when it finds any.

Using this script will therefore make your own health check fail, and that is
correct rather than a false positive. The check is not wrong; the machine really
can bypass the gateway. Two ways to keep both true:

- do the evaluation in a **separate subscription or Foundry resource** from the
  one the gateway uses, so the audit of the governed resource stays clean; or
- accept the finding while the spike runs, and remove the role assignment when
  it ends — at which point the audit goes quiet on its own.

What does not work is suppressing the finding. The control and the exception
then disagree, and the disagreement outlives whoever understood it.

## 5. Reading the configuration off a machine

There is no hidden config file for this path. The machine state is
`~/.claude/settings.json`, and the portable form is the
`claude-foundry-direct.json` described in section 2. The script prints both:

```powershell
./scripts/Setup-ClaudeFoundryDirect.ps1 -ShowConfig
```

It reports which path the machine is on — direct, gateway, or neither — and for
a direct machine prints a ready-to-save config file as well as the equivalent
command.

Nothing it prints is a secret. They are resource names and directory ids; the
credential is the Entra sign-in and is never written to the file. Copying
`settings.json` to another machine therefore grants nobody anything on its own —
they still have to hold the role and be signed in.

### "There is no settings.json on that machine"

Expected, and not a fault. Claude Code creates `~/.claude/` the first time it
runs — `sessions`, `projects`, `telemetry` all appear from ordinary use — but
`settings.json` is only written when something configures it.

A machine showing only those folders has never been pointed at Foundry or a
gateway. There is nothing on it to export, so configure it rather than trying to
copy from it.

## 6. Configuring it by hand

Only needed if you cannot run the script, or you are checking what it did. Read
from the installed extension and the live resource on 2026-09-22, not from
memory.

### Step 1 — sign in, naming the tenant

```powershell
# Device code: no browser on this machine
az login --use-device-code --tenant <tenant-guid>

# Or a browser on this machine
az login --tenant <tenant-guid>

az account show --query "{tenant:tenantId, user:user.name}" -o table
```

Name the tenant. An account in more than one directory, or a guest, signs in to
the wrong one by default, and the Foundry resource is then invisible behind an
error that never mentions tenants.

### Step 2 — make sure you can actually reach the resource

Unlike the gateway path, entitlement here is an Azure **role**, not group
membership. Without it every call returns 403 no matter what is configured:

```powershell
az role assignment create `
  --assignee <your-object-id> `
  --role "Cognitive Services User" `
  --scope /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.CognitiveServices/accounts/<resource>
```

Then prove the token works before configuring anything:

```powershell
az account get-access-token --resource https://cognitiveservices.azure.com --query accessToken -o tsv
```

If that fails, nothing below will work, and the failure is easier to read here.

### Step 3 — find the deployment names

```powershell
az cognitiveservices account deployment list `
  --name <resource> --resource-group <rg> `
  --query "[?properties.model.format=='Anthropic' && properties.provisioningState=='Succeeded'].name" -o tsv
```

Use what this prints. A name that does not exist, or one that exists but is
disabled, fails as `DeploymentNotFound` partway through a session rather than at
startup.

### Step 4 — install the clients

Needs Node.js 18+, VS Code 1.94+ and the Azure CLI.

```powershell
npm install -g @anthropic-ai/claude-code
code --install-extension anthropic.claude-code
```

### Step 5 — write the settings

`%USERPROFILE%\.claude\settings.json` on Windows, `~/.claude/settings.json`
elsewhere:

```json
{
  "env": {
    "CLAUDE_CODE_USE_FOUNDRY": "1",
    "ANTHROPIC_FOUNDRY_RESOURCE": "ai-contosohub530569751908",
    "AZURE_TENANT_ID": "16b3c013-d300-468d-ac64-7eda0820b6d3",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "claude-opus-5",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "claude-sonnet-5",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "claude-sonnet-5"
  },
  "availableModels": ["claude-opus-5", "claude-sonnet-5"],
  "enforceAvailableModels": true
}
```

Three things that are easy to get wrong:

- `ANTHROPIC_FOUNDRY_RESOURCE` is the account **name**. Not a URL, not a
  resource id.
- Do **not** also set `ANTHROPIC_FOUNDRY_BASE_URL`. They are mutually exclusive
  and the session ends with `baseURL and resource are mutually exclusive`. If
  this machine was ever on a gateway, delete that line.
- Point **haiku** at the Sonnet deployment. Claude Code asks for a small model
  for background work, and most resources have no Haiku deployment.

### Step 6 — VS Code

**Usually nothing to do.** The extension reads the same
`~/.claude/settings.json`, and its own setting description says to prefer it.

Two cases where you do touch VS Code settings — **Preferences: Open User
Settings (JSON)**:

**If you need a VS Code-only override**, `claudeCode.environmentVariables` is an
**array of name/value objects**, not a map. Verified against extension
2.1.263, whose schema requires both properties:

```json
"claudeCode.environmentVariables": [
  { "name": "CLAUDE_CODE_USE_FOUNDRY",    "value": "1" },
  { "name": "ANTHROPIC_FOUNDRY_RESOURCE", "value": "ai-contosohub530569751908" },
  { "name": "AZURE_TENANT_ID",            "value": "16b3c013-d300-468d-ac64-7eda0820b6d3" }
]
```

**If the extension keeps prompting you to sign in to Anthropic**, tell it not
to. Authentication is happening outside it, through Entra:

```json
"claudeCode.disableLoginPrompt": true
```

Reload the window afterwards — **Developer: Reload Window**. The extension host
reads configuration at startup, so a changed setting is not picked up by an
already-running window.

### Step 7 — check it

```powershell
claude auth status                    # expect apiProvider: foundry
claude -p "Reply with exactly: OK"
```

In VS Code: **Ctrl+Shift+P → Claude Code: Open in Side Bar**. There should be
no sign-in prompt — your Entra credential is already resolved.

If you want to test the endpoint without involving Claude Code at all:

```powershell
./scripts/Test-FoundryDirect.ps1 -Resource <resource> -ResourceGroup <rg>
```

## 7. Undoing it

```powershell
# The script backs up whatever was there before overwriting
copy $env:USERPROFILE\.claude\settings.json.bak $env:USERPROFILE\.claude\settings.json
```

To put the machine on the gateway instead, run
[`Setup-ClaudeWorkstation.ps1`](../scripts/Setup-ClaudeWorkstation.ps1) with the
`claude-gateway.json` the installer wrote. It removes
`ANTHROPIC_FOUNDRY_RESOURCE` for the same mutual-exclusion reason.

And on the Azure side, remove the role assignment. Until that is gone the
machine can be reconfigured back at any time by anybody who can edit a JSON
file.

## See also

- [Setup](SETUP.md) — standing up the gateway
- [Debugging](DEBUGGING.md) — isolating a failure layer by layer
- [Comparison](COMPARISON.md) — Foundry through the gateway against Anthropic direct
- `./scripts/Test-FoundryDirect.ps1` — verifies the direct path without configuring anything
