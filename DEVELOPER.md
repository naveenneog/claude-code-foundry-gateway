# Claude Code — developer setup

You have been granted access to Claude (Sonnet 5 and Opus 5) running in our own
Microsoft Foundry resource, reached through a gateway.

**There is no API key.** You authenticate as yourself with Microsoft Entra ID,
and your usage is metered against your own budget. You need no Azure role on
anything — the gateway holds that. Being in the entitlement group is all it
takes, and you already are.

Nothing on this page needs administrator rights. If you are the person *setting
the gateway up*, you want [docs/SETUP.md](docs/SETUP.md) instead.

---

## One command

Your platform team sent you `claude-gateway.json`. It holds the gateway URL,
tenant and tier limits, so you do not have to type any of them. Put it next to
the script:

```powershell
# Windows
.\Setup-ClaudeWorkstation.ps1 -ConfigPath .\claude-gateway.json
```

```bash
# macOS and Linux
./setup-claude-workstation.sh --config ./claude-gateway.json
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
> .\Setup-ClaudeWorkstation.ps1 -GatewayUrl https://<apim>.azure-api.net/claude -TenantId <tenant-id>
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

---

## Using it

**In VS Code** — open a folder, then **Ctrl+Shift+P → `Claude Code: Open in Side
Bar`**. There is no sign-in step; your Entra credential is already resolved.

![Claude Code panel in VS Code answering a question about a file, having called its Glob and Read tools, with no sign-in prompt](docs/guide/b3-vscode-answer.png)

**In the terminal** — run `claude`. Confirm the backend with `/status`:

![claude /status showing API provider: Microsoft Foundry](docs/guide/b5-cli-status.png)

**Your budget is on every response:**

```
x-ratelimit-remaining-tokens: 19980
x-quota-remaining-today: 499980
```

Exceeding the per-minute limit returns `429` with `Retry-After`, and Claude Code
backs off on its own — you may only notice a pause. Exhausting the daily quota
returns `403` until the period rolls over; ask the platform team if you need the
premium tier.

Your usage is attributed to you by name in chargeback. Nothing is anonymous —
but nothing is inspected either. Only token counts are recorded, never your
prompts.

---

## If something is wrong

| Symptom | Cause → Fix |
|---|---|
| `401` / "Entra ID token required" | Signed into the wrong tenant. Re-run the setup script — it pins the right one |
| `403` "Not entitled to Claude Code" | Not in the group, or membership not synced yet. Ping the platform team |
| `429` | Per-minute budget hit. Resets within a minute; Claude Code retries automatically |
| `DeploymentNotFound` | A model alias points at something we do not host. Use only `claude-sonnet-5` / `claude-opus-5` |
| Extension prompts for Anthropic sign-in | Settings not picked up — reload the VS Code window |
| Panel fails but the CLI works | The extension host is running an older build. **Developer: Reload Window** in each open window |

Anything else → [docs/DEBUGGING.md](docs/DEBUGGING.md), or your platform team.

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

**3. Write** `~/.claude/settings.json` (`%USERPROFILE%\.claude\settings.json` on
Windows), taking the gateway URL from your `claude-gateway.json`:

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

**4. VS Code needs the same values again.** The extension host does not inherit
shell environment, so add `claudeCode.environmentVariables` in **Preferences:
Open User Settings (JSON)** with the same names and values.

**5. Check it:**

```powershell
claude auth status     # expect apiProvider: foundry
claude -p "Reply with exactly: OK"
```
