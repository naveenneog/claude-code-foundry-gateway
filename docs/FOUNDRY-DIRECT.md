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
  "tenantId": "00000000-0000-0000-0000-000000000000",
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
- **Haiku points at a real deployment.** Claude Code uses a small model for
  background work; left unset it asks for one that does not exist and the
  session fails with `DeploymentNotFound` partway through, which reads as a
  bug rather than a setting. A genuine Haiku deployment is used if the resource
  has one, and Sonnet otherwise.

### Deployment names are not model names

The aliases are resolved from each deployment's `properties.model.name`, not
from what the deployment is called. Deployment names are chosen by whoever
created them, so a resource can perfectly well carry:

| Deployment name | Model |
|---|---|
| `claude-primary` | `claude-opus-5` |
| `claude-fast` | `claude-sonnet-5` |

Matching on the name would set no alias at all here, Claude Code would fall back
to its own built-in model names, and none of those exist on a Foundry resource.
The reference resource happens to name its deployments after their models, which
is a convention and not a rule.

If discovery cannot run — no reader rights on the resource, or it is in a
subscription this account cannot see — the script **stops** rather than guessing
a name. A guessed name writes a settings file that looks fine and fails minutes
later. Supply the names instead:

```powershell
.\Setup-ClaudeFoundryDirect.ps1 -Resource <resource> -Models claude-sonnet-5,claude-opus-5
```

Passing `-Models` skips discovery, so aliases fall back to matching the name.
That is the less reliable route; prefer discovery where you can.

### availableModels holds deployment names, not model names

`availableModels` is the list of **deployments on your resource**, not the list
of Claude models Anthropic publishes. Pasting a catalogue in looks harmless and
is not, because `enforceAvailableModels` then permits names that were never
deployed and each one fails as `DeploymentNotFound` when selected.

Seen in the wild, on a resource whose deployments were never checked:

```json
"availableModels": ["claude-opus-5", "claude-sonnet-5", "claude-opus-4-8",
                    "claude-opus-4-6", "claude-sonnet-4-5", "claude-haiku-4-5"]
```

Discovery writes what is really there. If you are editing by hand, this is the
list to copy:

```powershell
az cognitiveservices account deployment list --name <resource> --resource-group <rg> `
  --query "[?properties.model.format=='Anthropic' && properties.provisioningState=='Succeeded'].{deployment:name, model:properties.model.name}" -o table
```

### The setting that ends a session

`ANTHROPIC_FOUNDRY_RESOURCE` and `ANTHROPIC_FOUNDRY_BASE_URL` are **mutually
exclusive**. Both present and Claude Code stops with *"baseURL and resource are
mutually exclusive"*.

The base URL is the gateway path; the resource is this one. The script removes
a base URL left behind by a gateway setup, which is what makes it safe to run on
a machine that was previously on the gateway.

## 4. Diagnostics

Everything in this section is measured against a live resource. Run the one
command first - it names the layer that is broken, which is the part the
error messages do not.

### One command that checks the whole chain

Two scripts, and they answer different questions. Run the admin one first:
there is no point debugging a developer's machine against a resource that was
never ready.

```powershell
# Admin: is this resource set up so developers can use it? Changes nothing.
./scripts/Test-FoundryDirectAdmin.ps1 -Resource <resource>

# Developer: is this machine configured, and does it work?
./scripts/Test-FoundryDirect.ps1 -Resource <resource> -ResourceGroup <rg>
```

The admin check reports what an admin can fix without touching anyone's laptop:

| Check | Catches |
|---|---|
| Resource is visible in this tenant | a resource nobody signed in here can reach |
| Anthropic deployments exist | nothing usable, or only `Disabled` ones |
| missing model families | a resource with no Sonnet, where clients must not assume one |
| a role reaches the Claude data plane | roles scoped to `accounts/OpenAI/*`, which serve no Claude |
| groups against people | entitlement granted person by person, which does not scale |
| reachable from developer machines | `publicNetworkAccess` off, or a deny-by-default firewall |
| Desktop app registration | not a public client, so device code returns `AADSTS7000218` |

Run against a real resource it found three things its owner did not know:
`Azure AI Developer` assigned to someone who therefore had no access at all,
twelve entitlements with not one group among them, and no Haiku deployment.

It configures nothing, so it is safe on someone else's machine. What it
separates:

| Check | Catches |
|---|---|
| Token belongs to a signed-in user | a service principal from `.env` ahead of your CLI sign-in |
| Resource is in the signed-in tenant | a valid token for a tenant that does not own the resource |
| A role reaches the Claude data plane | a role scoped to `accounts/OpenAI/*`, which serves no Claude |
| Messages API responds | the endpoint itself |
| CLI / VS Code / Desktop point at this resource | one client left on an old target |
| Entra device-code init | an app registration problem, not RBAC |

The last one matters because it is the only failure here that no role
assignment can fix.

### 401 Principal does not have access to API/Operation

The most common failure on this path, and the message is precise: the token was
accepted, and the **principal it belongs to** has no access to that resource. It
is not saying your credentials are wrong.

There are three ways to end up here, in the order they actually occur.

**1. No `AZURE_TENANT_ID`, and the resource is in another tenant.** This is the
usual one. Without it the Azure Identity chain mints a token for whichever
tenant your `az` session defaults to, presents it to a resource in a different
tenant, and that tenant has never heard of the principal. Observed on a resource
that returned zero rows from the signing-in account's tenant:

```powershell
# Does your account see it at all?
az cognitiveservices account list --query "[?name=='<resource>'].name" -o tsv
```

Nothing back means you are in the wrong tenant, not that you lack a role. Sign
in to the owning tenant and record it in the settings file, where it applies to
every session rather than only this shell:

```powershell
az login --tenant <owning-tenant-guid>
```

```json
"env": { "AZURE_TENANT_ID": "<owning-tenant-guid>" }
```

The setup script always writes this, which is why generating the file beats
copying one from a colleague — a hand-made file usually omits it.

**2. A stray `AZURE_CLIENT_ID`, or a managed identity on the machine.** Claude
Code does not use the `az` session directly; it walks the Azure Identity chain,
and **several credentials sit ahead of the Azure CLI in it**. A leftover
variable, or an Azure VM's own identity, silently authenticates as something
else:

```powershell
Get-ChildItem Env: | Where-Object Name -match 'AZURE_CLIENT_ID|AZURE_CLIENT_SECRET|AZURE_USERNAME|IDENTITY_ENDPOINT|MSI_ENDPOINT'
```

This is the failure where the health check passes and Claude Code still gets
401: the check reads the `az` token, and Claude Code never asked for it.

Rather than deleting an identity the machine may need for other work, pin the
chain to your sign-in:

```powershell
[Environment]::SetEnvironmentVariable('AZURE_TOKEN_CREDENTIALS','dev','User')
```

**Use `dev`. A credential name is rejected**, even though the Azure Identity
documentation lists individual names as valid from `@azure/identity` 4.11.0.
That is true of the library, but Claude Code validates the value itself before
the library sees it, against a shorter list. Measured on CLI 2.1.272:

| Value | Result |
|---|---|
| `AzureCliCredential` | `API Error: Invalid value for AZURE_TOKEN_CREDENTIALS = AzureCliCredential. Valid values are 'prod' or 'dev'.` |
| `dev` | works — excludes managed identity, selects the CLI sign-in |
| `prod` | fails — `prod` excludes the developer credentials, which is the sign-in you are trying to select |

`dev` is the value in every case. There is no version of Claude Code where a
credential name is the better answer, because the check is the client's own and
not the library's.

Then open a new terminal and restart VS Code or Desktop — a running process
keeps the environment it started with. Source:
[Credential chains in the Azure Identity library for JavaScript](https://learn.microsoft.com/azure/developer/javascript/sdk/authentication/credential-chains#defaultazurecredential-overview).

> **On a Cloud PC, a Dev Box or any Azure VM this is the default, not an edge
> case.** Those machines run on Azure, so the instance metadata service answers
> and a managed identity is found ahead of your `az login` every time. Measured
> on a Windows 365 Cloud PC: `169.254.169.254` returns instance metadata in
> 10 ms. `Test-ClaudeNetwork.ps1` reports which of the three behaviours -
> answers, refused, dropped - applies to a given machine.

Granting that principal the role is the other route, and is right only where
the machine identity is genuinely meant to have Claude access.

**Do not set `ANTHROPIC_FOUNDRY_AUTH_TOKEN` to get past this.** It works,
because it pins a token the client then uses verbatim — and that token expires
in about an hour, after which the failure comes back looking unrelated to
anything you changed.

**3. Right tenant, no role.** Only now is a role assignment the answer:

```powershell
az role assignment create --assignee <client-id-or-your-object-id> `
  --role "Cognitive Services User" `
  --scope $(az cognitiveservices account show -n <resource> -g <rg> --query id -o tsv)
```

Whichever applies, restart the terminal **and** reload the VS Code window
afterwards — the extension host reads the environment once, at startup.

Isolate auth from everything else before launching Claude:

```powershell
$t = az account get-access-token --resource https://cognitiveservices.azure.com --query accessToken -o tsv
curl -s -o NUL -w "%{http_code}\n" -X POST `
  "https://<resource>.services.ai.azure.com/anthropic/v1/messages" `
  -H "Authorization: Bearer $t" -H "anthropic-version: 2023-06-01" `
  -H "content-type: application/json" `
  -d '{\"model\":\"<a-deployment-name>\",\"max_tokens\":16,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}'
```

On the gateway path none of this applies: API Management holds the role through
its managed identity, so developers need no role on the Foundry resource at all.

### Foundry Entra device init failed: HTTP 400

Claude Desktop only. **No role assignment can fix this**, and a correct set of
roles is entirely consistent with seeing it.

Desktop's native Foundry Entra mode runs its own device-code flow. Read from
`app.asar` in Desktop 2.110.1.0, it posts:

```
POST https://login.microsoftonline.com/{tenantId}/oauth2/v2.0/devicecode
     client_id=<clientId>&scope=https://cognitiveservices.azure.com/.default offline_access
```

That happens **before any token exists**, so Azure RBAC has not been consulted
and cannot be the cause. The failure is the client id and tenant typed into
Desktop's Connection screen.

Three causes, measured against Entra:

| Cause | Code |
|---|---|
| App registration has *Allow public client flows* = No | `AADSTS7000218` |
| Client id does not exist in that tenant | `AADSTS700016` |
| Tenant GUID is wrong or unknown | `AADSTS90002` |

Get the actual code rather than guessing between them:

```powershell
./scripts/Test-FoundryDirect.ps1 -Resource <resource> -ResourceGroup <rg> `
  -ClientId <client-id> -TenantId <tenant-guid>
```

Fixes, in order of effort:

- **Use the Azure CLI's client id**, `04b07795-8ddb-461a-bbee-02f9e1bf7b46`. It
  is already a public client and pre-consented in essentially every tenant, so
  there is nothing to register. Verified to return 200 for the exact scope
  Desktop requests. Some tenants block it with Conditional Access.
- **Fix the existing app**, if the toggle is the problem:
  ```powershell
  az ad app show   --id <client-id> --query isFallbackPublicClient   # expect true
  az ad app update --id <client-id> --set isFallbackPublicClient=true
  ```
- **Register one**, where the organisation wants its own:
  ```powershell
  az ad app create --display-name "Claude Desktop - Foundry" --is-fallback-public-client true
  # 7d312290-... Microsoft Cognitive Services, 5f1e8914-... user_impersonation
  az ad app permission add --id <app-id> `
    --api 7d312290-28c8-473c-a0ed-8e53749b6d6d `
    --api-permissions 5f1e8914-a52b-429f-9324-91b92b81adaf=Scope
  az ad app permission admin-consent --id <app-id>
  ```

**Or avoid the flow entirely.** `Setup-ClaudeFoundryDirect.ps1` configures
Desktop with `inferenceCredentialKind: helper-script`, which takes its token
from the Azure CLI. It never calls `/devicecode`, so none of the above applies.

### Which role, and which scope
Entitlement on this path is an Azure role assignment. Give it to an Entra
**group** and manage people by membership — there is no Entra app registration,
no API permission and no admin consent involved, because sign-in reuses the
Azure CLI's own pre-consented client.

```powershell
az role assignment create `
  --assignee-object-id  $(az ad group show --group "claude-direct-users" --query id -o tsv) `
  --assignee-principal-type Group `
  --role "Cognitive Services User" `
  --scope $(az cognitiveservices account show -n <resource> -g <rg> --query id -o tsv)
```

`--assignee-principal-type Group` is not optional in practice: without it the
CLI attempts a Graph lookup that frequently fails for groups.

Measured across the built-in roles, five carry the unrestricted
`Microsoft.CognitiveServices/*` data action that the `/anthropic` endpoint
needs. **Cognitive Services User** is the least-privilege one; Foundry User,
Foundry Project Manager, Foundry Owner and Cognitive Services Data Contributor
(Preview) also work.

These two look right and are not:

| Role | Data actions | Serves Claude |
|---|---|---|
| Azure AI Developer | `accounts/OpenAI/*`, `SpeechServices/*`, `ContentSafety/*`, `MaaS/*` | No |
| Cognitive Services OpenAI User | `accounts/OpenAI/*` | No |

Claude on Foundry is not served under `accounts/OpenAI/`, so neither grants
anything here — and the refusal is the same unhelpful *"Principal does not have
access to API/Operation"*. Cognitive Services Data Reader fails too: it holds
`Microsoft.CognitiveServices/*/read`, and inference is a POST.

**Scope it at the account.** A role on a *project inside* the account does not
cover the account-level endpoint these clients call. If someone holds a role
that should work and still gets 401, check where it is actually assigned:

```powershell
az role assignment list --assignee <object-id> --all `
  --query "[?contains(roleDefinitionName,'Foundry') || contains(roleDefinitionName,'Cognitive')].{role:roleDefinitionName, scope:scope}" -o table
```

A scope ending in `/projects/<name>` is the explanation.

### Network access

An allowlist written from documentation is a guess. **[NETWORK.md](NETWORK.md)**
carries the measured list as a single table, marked with which of the three
clients — CLI, VS Code extension, Claude Desktop — needs each host, and
separating what is needed to *run* from what is needed to *install*.

```powershell
./scripts/Test-ClaudeNetwork.ps1                  # required destinations
./scripts/Test-ClaudeNetwork.ps1 -IncludeOptional # plus install and telemetry
```

Only three hosts are needed to run any of the clients:
`<resource>.services.ai.azure.com` on the direct path or
`<apim-name>.azure-api.net` on the gateway path, plus
`login.microsoftonline.com` for sign-in.

Two entries commonly on an allowlist that do not do what they appear to:

- **`cognitiveservices.azure.com` is the token audience, not an endpoint.** It
  is the string in the OAuth scope. No client connects to it. The host they
  dial is `<resource>.services.ai.azure.com`.
- **`*.azure-api.net` is not matched by any `*.azure.com` rule.** Different
  suffix. On the gateway path it is the entry that matters most.

If you see `Connection dropped (ECONNRESET)` while every host is reachable, the
allowlist is not the problem — see
[NETWORK.md §6](NETWORK.md#6-econnreset-is-not-an-allowlist-problem).


## 5. What you give up, and what you inherit

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

## 6. Reading the configuration off a machine

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

## 7. Configuring it by hand

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

Claude Code's own settings file. Same location on every platform, because it
sits in your home directory rather than the operating system's configuration
directory:

| | Path |
|---|---|
| Windows | `%USERPROFILE%\.claude\settings.json` |
| macOS | `~/.claude/settings.json` |
| Linux | `~/.claude/settings.json` |

Create the folder if it is not there. Claude Code makes it on first run, but
only writes `settings.json` once something configures it — a machine that has
never been pointed at Foundry or a gateway will have the folder and no file.

Two neighbours you will see and should leave alone:

- `~/.claude/settings.local.json` — a per-machine override that wins over the
  file above. If a setting seems to be ignored, look here first.
- `~/.claude.json` — a *file*, not the folder. Session and project state, tens
  of kilobytes of it. Not configuration; do not hand-edit it.

Contents:

```json
{
  "env": {
    "CLAUDE_CODE_USE_FOUNDRY": "1",
    "ANTHROPIC_FOUNDRY_RESOURCE": "ai-contosohub530569751908",
    "AZURE_TENANT_ID": "00000000-0000-0000-0000-000000000000",
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

Two cases where you do touch VS Code settings. This is a **different file** in a
**different place** — the shared name is the only thing they have in common:

| | Path |
|---|---|
| Windows | `%APPDATA%\Code\User\settings.json` |
| macOS | `~/Library/Application Support/Code/User/settings.json` |
| Linux | `${XDG_CONFIG_HOME:-~/.config}/Code/User/settings.json` |

Or open it without typing a path: **Ctrl+Shift+P → Preferences: Open User
Settings (JSON)**. Use the JSON editor, not the Settings UI — the setting below
is an array of objects, which the UI will not let you edit properly.

**If you need a VS Code-only override**, `claudeCode.environmentVariables` is an
**array of name/value objects**, not a map. Verified against extension
2.1.263, whose schema requires both properties:

```json
"claudeCode.environmentVariables": [
  { "name": "CLAUDE_CODE_USE_FOUNDRY",    "value": "1" },
  { "name": "ANTHROPIC_FOUNDRY_RESOURCE", "value": "ai-contosohub530569751908" },
  { "name": "AZURE_TENANT_ID",            "value": "00000000-0000-0000-0000-000000000000" }
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

## 8. Undoing it

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

