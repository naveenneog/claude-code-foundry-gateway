# Claude Code — developer setup

You have been granted access to Claude (Sonnet 5 and Opus 5) running in our own
Microsoft Foundry resource, reached through a gateway.

**There is no API key.** You authenticate as yourself with Microsoft Entra ID,
and your usage is metered against your own budget. You need no Azure role on
anything — the gateway holds that. Being in the entitlement group is all it
takes, and you already are.

Nothing on this page needs administrator rights. If you are the person *setting
the gateway up*, you want [docs/SETUP.md](docs/SETUP.md) instead.

**In this article**

1. [One command](#one-command)
2. [Using it](#using-it)
3. [If something is wrong](#if-something-is-wrong)
4. [FAQ](#faq)
5. [Appendix — configuring it by hand](#appendix--configuring-it-by-hand)

## Prerequisites

| | |
|---|---|
| **`claude-gateway.json`** | from your platform team. It carries the gateway URL, tenant and tier limits |
| **Azure CLI** | the setup installs it if it is missing |
| **Entitlement** | membership of the group your platform team put you in. Nothing else — no Azure role, no API key |
| **PowerShell 5.1 or 7** | on Windows. macOS and Linux use the shell script |

---

## One command

Your platform team sent you `claude-gateway.json`. It holds the gateway URL,
tenant and tier limits, so you do not have to type any of them. Ask for the
complete `scripts` folder, including the credential helpers, or download this
repository. Open a terminal in the folder that contains `scripts`, and put
`claude-gateway.json` there. All commands on this page use that directory:

```powershell
# Windows
.\scripts\Setup-ClaudeWorkstation.ps1 -ConfigPath .\claude-gateway.json
```

```bash
# macOS and Linux
./scripts/setup-claude-workstation.sh --config ./claude-gateway.json
```

It checks what you already have, installs anything missing, configures **all
three clients** — Claude Code CLI, the VS Code extension, and Claude Desktop
including Cowork — then makes a real call through the gateway to prove it works.

![The setup script running: prerequisites checked, all three clients configured, and a verified call returning HTTP 200 with the tier and remaining budget](docs/images/run-workstation-setup.png)

> **No `claude-gateway.json`?** It is not in this repository — your platform team
> generates it when they deploy the gateway. Ask them, or pass the two values
> directly:
>
> ```powershell
> .\scripts\Setup-ClaudeWorkstation.ps1 -GatewayUrl https://<apim>.azure-api.net/claude -TenantId <tenant-id>
> ```
>
> Neither is a secret. Your access comes from group membership, not from these.

Then restart the clients — all three read their configuration at startup:

| Client | Restart |
|---|---|
| Claude Code CLI | nothing to do |
| VS Code | reload the window |
| Claude Desktop | quit completely, **including the tray icon** |

Re-run the script any time; it reconciles rather than duplicating.

| Windows | macOS / Linux | Effect |
|---|---|---|
| `-SkipInstall` | `--skip-install` | configure only, install nothing |
| `-SkipDesktop` / `-SkipVSCode` | `--skip-desktop` / `--skip-vscode` | leave that client alone |
| `-NoCowork` | `--no-cowork` | configure Desktop without the Cowork tab |

> **macOS and Linux** need `jq`; the script installs it via Homebrew, apt, dnf,
> pacman or zypper. If `npm install -g` fails on Linux it is almost always a
> non-writable global prefix rather than anything to do with Claude:
> `npm config set prefix ~/.npm-global && export PATH=~/.npm-global/bin:$PATH`

### Check first, if you would rather not find out afterwards

The setup above configures and then proves it works. If you would rather know
*before* anything is written — or if the setup failed and you want the reason
rather than the symptom — run the checks on their own:

```powershell
.\scripts\Onboard-ClaudeDeveloper.ps1 -ConfigPath .\claude-gateway.json -PreflightOnly
```

![The preflight running four checks — tooling, identity, network and access — and reporting that nothing was written](docs/guide/onboard-preflight.png)

Four checks, and it writes nothing either way:

| # | Check | What it catches |
|---|---|---|
| 1 | tooling | no Azure CLI |
| 2 | identity | not signed in, or signed in to a different tenant than the file names |
| 3 | network | a blocked host, and separately a proxy that cuts the response once it starts streaming |
| 4 | access | a token the model refuses, or a model name that is not deployed |

Drop `-PreflightOnly` and it checks, configures and verifies in one go — and
stops before writing anything if a check fails.

> [!TIP]
> Check 3 is the one worth knowing about. Claude streams its answers, and many
> corporate proxies cannot forward a stream — so every host is reachable, the
> setup looks correct, and every prompt dies with `ECONNRESET`. If that is what
> you are seeing, the fix is a proxy exclusion rather than a firewall rule, and
> [docs/NETWORK.md](docs/NETWORK.md) has the exact wording to send your network
> team.

---

## Using it

**In VS Code** — open a folder, then **Ctrl+Shift+P → `Claude Code: Open in Side
Bar`**. There is no sign-in step; your Entra credential is already resolved.

![Claude Code panel in VS Code answering a question about a file, having called its Glob and Read tools, with no sign-in prompt](docs/guide/b3-vscode-answer.png)

**In the terminal** — run `claude`. Confirm the backend with `/status`:

![claude /status showing API provider: Microsoft Foundry](docs/guide/b5-cli-status.png)

**In Claude Desktop** — this one has a sign-in step, and the option you need is
not the obvious one.

1. **Quit Desktop completely**, including the tray or menu-bar icon. It reads
   its configuration at startup, so a running instance will not pick this up.
2. Reopen it. You get the **Sign In** screen.
3. Choose **"Or sign in with Gateway"** at the bottom.

![Claude Desktop sign-in, with Continue with Google and Continue with email above a small Or sign in with Gateway link at the bottom](docs/guide/b6-desktop-gateway-signin.png)

**Do not use "Continue with Google" or "Continue with email".** Those sign you
into Anthropic's own service with a personal or work Anthropic account. It will
appear to work — you get a working Claude — but your organisation's access rules
and usage tracking do not apply, and Anthropic bills that usage separately from
your organisation's Azure agreement.

Check **Settings → Connection**: it should name your gateway URL. If it shows an
Anthropic account instead, sign out and start again at step 1.

If there is no **Connection** entry under Settings at all, the setup script has
not run on this machine — it writes the developer setting that reveals it.

**Your budget is on every response:**

```
x-ratelimit-remaining-tokens: 19980
x-quota-remaining-today: 499980
```

Exceeding the per-minute limit returns `429` with `Retry-After`, and Claude Code
backs off on its own — you may only notice a pause. Exhausting the daily quota
returns `403` until the period rolls over; ask the platform team if you need the
premium tier.

Your usage is recorded against your name so your organisation can allocate its
cost. Nothing is anonymous — but nothing is inspected either. Only token counts
are recorded, never your prompts.

---

## If something is wrong

| Symptom | Cause → Fix |
|---|---|
| `401` / "Entra ID token required" | Signed into the wrong tenant. Re-run the setup script — it pins the right one |
| `403` "Not entitled to Claude Code" | Not in the group, or membership not synced yet. Ping the platform team |
| `429` | Per-minute budget hit. Resets within a minute; Claude Code retries automatically |
| `DeploymentNotFound` | A model alias points at something we do not host. Use only `claude-sonnet-5` / `claude-opus-5` |
| Extension prompts for Anthropic sign-in | Settings not picked up — reload the VS Code window |
| Desktop asks for an Anthropic password | You picked Google or email. Sign out, quit completely, reopen, choose **Or sign in with Gateway** |
| Desktop works but your usage never appears in your team's report | Same cause — you are signed into Anthropic, not the gateway. Check **Settings → Connection** names your gateway URL |
| No **Settings → Connection** in Desktop | Developer settings missing. Re-run the setup script; it writes `allowDevTools: true` |
| `401 Principal does not have access to API/Operation` | On the **direct** path only, and it names a *principal* — which is often not you. Usually a stray `AZURE_CLIENT_ID` in a `.env`, or the resource is in another tenant. See [Diagnostics](docs/FOUNDRY-DIRECT.md#4-diagnostics) |
| `Foundry Entra device init failed: HTTP 400` | Desktop's own device-code flow. This happens **before any token exists**, so no role assignment can fix it — it is the client id or tenant in the Connection screen. See [Diagnostics](docs/FOUNDRY-DIRECT.md#4-diagnostics) |
| Panel fails but the CLI works | The extension host is running an older build. **Developer: Reload Window** in each open window |

Anything else → [docs/DEBUGGING.md](docs/DEBUGGING.md), or your platform team.

---

## FAQ

**I fixed my settings and Claude Code still uses the old model. Why?**
Something higher in the precedence order is overriding the file you edited.
Claude Code reads four places, lowest to highest:

| | File |
|---|---|
| 1 | `~/.claude/settings.json` — what the setup script writes |
| 2 | `.claude/settings.json` in the project folder |
| 3 | `.claude/settings.local.json` in the project folder |
| 4 | command-line arguments |

A **correct** user file is simply ignored while a project one sets the same
values, and nothing tells you that is happening — the error names a model you
cannot find anywhere in the configuration you are reading. It is the local file
that catches people out, because it is per-machine and usually untracked, so it
is not in the repository anyone is looking at.

Find them all:

```powershell
Get-ChildItem -Path . -Recurse -Force -Include settings.json,settings.local.json -Filter * -ErrorAction SilentlyContinue |
  Where-Object FullName -match '\\\.claude\\'
Get-Item "$env:USERPROFILE\.claude\settings*.json"
```

`./scripts/Test-FoundryDirect.ps1` reports this as **"Nothing overrides the
settings just checked"**. Rename or empty the offending file and start a new
session — a running one keeps what it loaded.

**Do I need an Anthropic account?**
No. You never create one and you never sign in to one. Your Entra ID is the
credential. If a screen is asking for an Anthropic password, you are on the
wrong path — see the Desktop sign-in step above.

**I signed in with Google by mistake. What now?**
Sign out in Desktop, quit it completely including the tray icon, open it again
and choose **Or sign in with Gateway**. Nothing is broken. That session was
served by Anthropic rather than your gateway, so its cost was not recorded
against your organisation and your prompts went to Anthropic's service.

**Why is there a developer-mode step at all?**
Desktop only shows **Settings → Connection** when a developer setting is turned
on, and the gateway configuration has nowhere to live without it. The setup
script writes it for you; there is nothing to switch on by hand.

**Do I have to re-run the setup when my token expires?**
No. The credential helper refreshes it silently. You only re-run setup if the
gateway URL changes or you move to a different machine.

**What does my platform team see?**
Token counts, the model, which client you used, and your name. Not your prompts
and not the replies. Usage is recorded against your name, and its cost is
allocated to the department or team your platform team has assigned you to.

**I get 403 and I am definitely in the group.**
Group membership is not available to the gateway the instant it changes — a sync
has to run. If your platform team has confirmed your membership and you still
get `403`, ask them to check the sync completed.

**Can I use a personal Anthropic subscription alongside this?**
On a different machine or profile, yes — but not through this configuration. If
you sign the same Desktop into an Anthropic account, it stops using the gateway
until you sign back in with Gateway.

---

## Appendix — configuring it by hand

Only needed if you cannot run the script, or you are checking what it did.

**1. Sign in, naming the tenant.** Guests land in their home directory
otherwise, and the gateway rejects the token:

```powershell
az login --tenant <your-tenant-id>
az account show --query "{tenant:tenantId, user:user.name}" -o table
```

**2. Install** the CLI and extension. Needs Node.js 18+, VS Code 1.94+, and the
Azure CLI:

```powershell
npm install -g @anthropic-ai/claude-code
code --install-extension anthropic.claude-code
```

**3. Write Claude Code's settings file.** It lives in your home directory, so
the path is the same on every platform:

| | Path |
|---|---|
| Windows | `%USERPROFILE%\.claude\settings.json` |
| macOS | `~/.claude/settings.json` |
| Linux | `~/.claude/settings.json` |

Take the gateway URL from your `claude-gateway.json`:

```json
{
  "env": {
    "CLAUDE_CODE_USE_FOUNDRY": "1",
    "ANTHROPIC_FOUNDRY_BASE_URL": "https://<your-gateway>.azure-api.net/claude",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "claude-opus-5",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "claude-sonnet-5",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "claude-sonnet-5"
  },
  "availableModels": ["claude-sonnet-5", "claude-opus-5"],
  "enforceAvailableModels": true
}
```

Two traps the script handles for you:

- Do **not** also set `ANTHROPIC_FOUNDRY_RESOURCE`. It is mutually exclusive
  with the base URL, and the session dies with
  `baseURL and resource are mutually exclusive`
- Point the **haiku** alias at Sonnet. Most tenants have no Haiku deployment,
  and the failure otherwise surfaces mid-task as `DeploymentNotFound`

**4. VS Code usually needs nothing more.** The extension reads the same
`~/.claude/settings.json`, and its own setting description says to prefer it
over VS Code settings.

Two cases where you do open VS Code's own settings. It is a **different file in
a different place** — the shared name is all they have in common:

| | Path |
|---|---|
| Windows | `%APPDATA%\Code\User\settings.json` |
| macOS | `~/Library/Application Support/Code/User/settings.json` |
| Linux | `${XDG_CONFIG_HOME:-~/.config}/Code/User/settings.json` |

Or reach it without the path: **Ctrl+Shift+P → Preferences: Open User Settings
(JSON)**. Use the JSON editor rather than the Settings UI — the setting below is
an array of objects and the UI will not edit it properly.

If you need a VS Code-only override, `claudeCode.environmentVariables` is an
**array of name/value objects**, not a map — verified against extension 2.1.263,
whose schema requires both properties:

```json
"claudeCode.environmentVariables": [
  { "name": "CLAUDE_CODE_USE_FOUNDRY",     "value": "1" },
  { "name": "ANTHROPIC_FOUNDRY_BASE_URL",  "value": "https://<your-gateway>.azure-api.net/claude" }
]
```

If the extension keeps asking you to sign in to Anthropic, tell it not to —
authentication is happening outside it, through Entra:

```json
"claudeCode.disableLoginPrompt": true
```

Either way, **Developer: Reload Window** afterwards. The extension host reads
configuration at startup and will not pick up a change in a running window.

**5. Check it:**

```powershell
claude auth status     # expect apiProvider: foundry
claude -p "Reply with exactly: OK"
```

**6. Claude Desktop, if you use it.** Desktop cannot read
`~/.claude/settings.json`. It takes a base URL and a credential helper — a small
script that prints an Entra token — and keeps both in its own profile library.

Quit it completely first, including the tray icon. It rewrites its
configuration on exit, so anything written underneath a running instance is
discarded:

```powershell
Get-Process -Name 'Claude' -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.Id -Force }
Start-Sleep 2
@(Get-Process -Name 'Claude' -ErrorAction SilentlyContinue).Count    # must be 0
```

To start from nothing, delete the library and let these steps recreate it:

```powershell
Remove-Item "$env:LOCALAPPDATA\Claude-3p\configLibrary" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$env:APPDATA\Claude\developer_settings.json" -Force -ErrorAction SilentlyContinue
```

Developer settings, or there is no **Settings → Connection** to look at:

```powershell
New-Item -ItemType Directory -Force -Path "$env:APPDATA\Claude" | Out-Null
'{ "allowDevTools": true }' | Set-Content "$env:APPDATA\Claude\developer_settings.json" -Encoding UTF8
```

**Where the helper comes from.** `get-foundry-token.ps1` and
`get-foundry-token.cmd` ship in the repo's `scripts` folder and are **copied,
not generated** — they must be sitting next to `Setup-ClaudeWorkstation.ps1`
when you run it. Fetch the folder, not the one file: on its own the setup warns
and carries on, leaving the CLI and VS Code working and Desktop with no
credential at all.

They also have to **stay** installed. Desktop re-runs the helper every
`inferenceCredentialHelperTtlSec` seconds — 1800 by default — to refresh the
token, so deleting them breaks Desktop at the next refresh rather than
immediately, which reads as an intermittent fault. Point the profile at the
**`.cmd`**; it is a shim that runs the `.ps1` beside it.

Prove the helper works before Desktop depends on it. `CLAUDE_FOUNDRY_TENANT_ID`matters for guests and anyone in more than one directory — without it a bare
`az login` lands in the home tenant and the token is refused downstream:

```powershell
[Environment]::SetEnvironmentVariable('CLAUDE_FOUNDRY_TENANT_ID','<tenant-guid>','User')
$env:CLAUDE_FOUNDRY_TENANT_ID = '<tenant-guid>'
$t = & "$env:LOCALAPPDATA\ClaudeFoundry\get-foundry-token.cmd"
if ($t -match '^eyJ') { "OK - JWT, $($t.Length) chars" } else { 'FAILED - run az login --tenant <tenant-guid>' }
```

Then the profile. Desktop keys the file by a GUID it records in `_meta.json`, so
the two must agree — a mismatch leaves it silently on the default profile:

```powershell
$lib = "$env:LOCALAPPDATA\Claude-3p\configLibrary"
New-Item -ItemType Directory -Force -Path $lib | Out-Null
$id = [guid]::NewGuid().ToString()

@{ appliedId = $id; entries = @(@{ id = $id; name = 'Default' }) } |
  ConvertTo-Json -Depth 5 | Set-Content "$lib\_meta.json" -Encoding UTF8

@{
  inferenceProvider                             = 'gateway'
  inferenceGatewayBaseUrl                       = 'https://<your-gateway>.azure-api.net/claude'
  inferenceGatewayAuthScheme                    = 'bearer'
  inferenceCredentialKind                       = 'helper-script'
  inferenceCredentialHelper                     = "$env:LOCALAPPDATA\ClaudeFoundry\get-foundry-token.cmd"
  inferenceCredentialHelperTimeoutSec           = 60
  inferenceCredentialHelperTtlSec               = 1800
  inferenceCredentialHelperSilentRefreshEnabled = $true
  inferenceModels                               = @(@{ name = 'claude-sonnet-5' }, @{ name = 'claude-opus-5' })
  chatTabEnabled                                = $true
  isClaudeCodeForDesktopEnabled                 = $true
  inferenceModelPricingEnabled                  = $true
  coworkTabEnabled                              = $true
} | ConvertTo-Json -Depth 6 | Set-Content "$lib\$id.json" -Encoding UTF8
```

Reopen Desktop. **Settings → Connection** should name your gateway. Two things
that bite:

- Use the **`.cmd`**, not the `.ps1`. Desktop runs the file directly, and the
  `.cmd` shim invokes `powershell.exe` with the right arguments.
- If Desktop asks for an Anthropic password you have taken the wrong sign-in.
  Quit completely, reopen, and choose **Or sign in with Gateway**.

### Letting Desktop do the sign-in itself

Everything above hands the sign-in to the Azure CLI. Desktop can instead run
its own browser sign-in, under **Settings → Connection → Configure third-party
inference**. It needs an app registration, which the helper route does not, so
take this one only if you would rather Desktop owned the credential.

| Field | Value |
|---|---|
| Client ID | your app registration |
| Issuer URL | `https://login.microsoftonline.com/<tenant-guid>/v2.0` |
| Authorization URL | leave blank — discovered from the issuer |
| Token URL | leave blank — discovered from the issuer |
| Bearer token | **Access token** |
| Scopes | `https://cognitiveservices.azure.com/.default offline_access` |
| Redirect port | (ephemeral) |
| Redirect host | `127.0.0.1` |

Two fields decide whether this works at all:

- **Clear the default Scopes.** `openid profile email offline_access` yields a
  Microsoft Graph audience, and the gateway's `validate-azure-ad-token` accepts
  only `https://cognitiveservices.azure.com` or `https://ai.azure.com`. The
  sign-in succeeds and every call then returns 401.
- **Access token**, not ID token. An ID token's audience is your client id, so
  the gateway refuses it for the same reason.

The authorization code flow needs a redirect URI, so unlike the helper route
this does need a registration:

```powershell
az ad app create --display-name "Claude Desktop - Gateway" `
  --is-fallback-public-client true `
  --public-client-redirect-uris "http://localhost"

# 7d312290-... Microsoft Cognitive Services, 5f1e8914-... user_impersonation
az ad app permission add --id <app-id> `
  --api 7d312290-28c8-473c-a0ed-8e53749b6d6d `
  --api-permissions 5f1e8914-a52b-429f-9324-91b92b81adaf=Scope
az ad app permission admin-consent --id <app-id>
```

### Signing in without a browser

`az login` opens a browser, which a jump box, VDI session or SSH connection
does not have. Both the setup script and the credential helper can print a code
to use on another machine instead:

```powershell
.\scripts\Setup-ClaudeWorkstation.ps1 -ConfigPath .\claude-gateway.json -Auth device

# and for the helper, which signs in again when its cached token expires
[Environment]::SetEnvironmentVariable('CLAUDE_FOUNDRY_AUTH','device','User')
```
