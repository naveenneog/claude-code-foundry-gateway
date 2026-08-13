# Claude Code access — developer onboarding

You have been granted access to Claude (Sonnet 5 and Opus 5) running in our own Azure AI
Foundry resource, reached through the Contoso AI gateway.

**There is no API key.** You authenticate as yourself with Microsoft Entra ID, and your usage is
metered against your own budget.

---

## Your access

| | |
|---|---|
| Tier | **Standard** — 20,000 tokens/minute, 500,000 tokens/day |
| Models | `claude-sonnet-5`, `claude-opus-5` |
| Gateway | `https://<your-gateway>.azure-api.net/claude` |
| Tenant | `<your-tenant-id>` |
| Entitlement | Entra group `claude-code-standard` |

You do **not** need any Azure role on the Foundry resource. The gateway holds that; you only
need to be in the group, which you already are.

---

## Step 1 — Install the tools

```powershell
# Claude Code CLI
npm install -g @anthropic-ai/claude-code

# VS Code extension
code --install-extension anthropic.claude-code
```

Requires Node.js 18+, VS Code 1.94+, and the Azure CLI.

---

## Step 2 — Sign in to the right tenant

This matters. Your `@microsoft.com` account is a **guest** in the tenant that hosts the gateway,
so a plain `az login` signs you into the wrong directory and the gateway will reject the token.

```powershell
az login --tenant <your-tenant-id>
```

Confirm you landed in the right place:

```powershell
az account show --query "{tenant:tenantId, user:user.name}" -o table
```

`tenant` must read `<your-tenant-id>`.

---

## Step 3 — Configure Claude Code

Create `%USERPROFILE%\.claude\settings.json` (macOS/Linux: `~/.claude/settings.json`):

```json
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
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

> Do **not** also set `ANTHROPIC_FOUNDRY_RESOURCE`. It is mutually exclusive with
> `ANTHROPIC_FOUNDRY_BASE_URL` and the session will fail with
> `baseURL and resource are mutually exclusive`.

That one file covers both the CLI and the VS Code extension.

---

## Step 4 — Check it works

```powershell
claude auth status
```

```json
{ "loggedIn": true, "authMethod": "third_party", "apiProvider": "foundry" }
```

Then a real call:

```powershell
claude -p "Reply with exactly: OK"
```

Start an interactive session and run `/status` — it should report **API provider: Microsoft
Foundry**.

---

## Step 5 — Use it in VS Code

Open a folder, then **Ctrl+Shift+P → `Claude Code: Open in Side Bar`**.

The panel opens straight into a usable prompt. **There is no sign-in step** — your Entra
credential is already resolved.

![Claude Code panel in VS Code answering a question about a file, having called its Glob and Read tools, with no sign-in prompt](images/vscode-through-gateway.png)

If the extension asks you to sign in to Anthropic, it has not picked up the settings file. Run
**Developer: Reload Window**, and if it persists add the same variables under
`claudeCode.environmentVariables` in **Preferences: Open User Settings (JSON)**.

---

## What to expect

**Your token budget.** Every response carries your remaining budget:

```
x-ratelimit-remaining-tokens: 19980
x-quota-remaining-today: 499980
```

**If you exceed the per-minute limit** you get `HTTP 429` with a `Retry-After` header. Claude
Code backs off and retries on its own — you may just notice a pause.

**If you exhaust the daily quota** you get `HTTP 403` until the next day. Ask the platform team
if you need the premium tier (80,000 tokens/minute, 5,000,000/day).

**Your usage is attributed to you** by name in the platform team's chargeback reporting. Nothing
is anonymous — but nothing is inspected either; only token counts are recorded, not prompts.

---

## Troubleshooting

| Symptom | Cause → Fix |
|---|---|
| `401` / "Entra ID token required" | Signed into the wrong tenant. Re-run `az login --tenant <your-tenant-id>`. |
| `403` "Not entitled to Claude Code" | Not in the group, or membership not synced yet. Ping the platform team. |
| `429` | Per-minute budget hit. It resets within a minute; Claude Code retries automatically. |
| `baseURL and resource are mutually exclusive` | Remove `ANTHROPIC_FOUNDRY_RESOURCE` from your settings. |
| `DeploymentNotFound` | A model alias points at something we do not host. Use only `claude-sonnet-5` / `claude-opus-5`. |
| Extension prompts for Anthropic sign-in | Settings not picked up — reload the window. |
| Windows: a script returns a WSL error instead of a token | Inside Git Bash use `az.cmd`, not `az`. |

Questions → the platform team.
