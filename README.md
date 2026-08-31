# Claude Code on Microsoft Foundry — Governed Gateway Accelerator

Give your engineering team **Claude Code** running on **your own Claude deployment in Microsoft
Foundry**, with per-developer budgets, tiering, and chargeback — and **no model credential on any
developer machine**.

One interactive command deploys the whole thing.

```powershell
./Install-ClaudeGateway.ps1          # macOS/Linux: ./install-claude-gateway.sh
```

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fnaveenneog%2Fclaude-code-foundry-gateway%2Fmain%2Finfra%2Fazuredeploy.json)

![Architecture: the developer's Entra ID token reaches Azure API Management, which validates identity, applies tiered token budgets and emits chargeback metrics, then swaps in the gateway managed identity to call Microsoft Foundry](docs/images/architecture.png)

---

## Why

Claude Code is excellent, and the usual objection to rolling it out is not the tool — it is the
sentence *"and then every developer pastes a vendor API key into a file on their laptop."*

Foundry already fixes the key problem: Claude Code's Foundry mode authenticates with **Microsoft
Entra ID**, so `az login` is the whole credential story. But going direct to Foundry means every
developer needs `Cognitive Services User` on the resource, and you get:

- no per-developer rate limit
- no per-developer budget
- no tiering
- usage data only at the resource level, with no idea who spent it
- anyone with the role can point any tool at the endpoint

This accelerator puts an **Azure API Management AI gateway** in front. Developers hold no Foundry
role at all — the gateway's managed identity is the only principal with data-plane access, so the
gateway is not the recommended path, it is the **only** path.

### What makes per-developer metering trustworthy

Claude Code sends the **developer's own Entra ID token**, obtained through
`DefaultAzureCredential`. Every request carries a real `oid` that cannot be forged, shared, or
copied to a colleague's laptop. The gateway meters against that claim.

You do not need an app registration, a custom audience, or any client-side auth code.

---

## What you get

| Control | Mechanism | Result |
|---|---|---|
| Who may use Claude Code | Entra ID group membership | **403** with an actionable message |
| Tiered budgets | `llm-token-limit` per tier | standard vs premium limits |
| Per-developer rate limit | tokens/minute keyed on `oid` | **429** + `Retry-After` |
| Per-developer daily budget | `token-quota` + period | **403** until reset |
| Runaway-agent protection | `rate-limit-by-key` on requests | request ceiling |
| Chargeback | `llm-emit-token-metric` → App Insights | tokens per named person |
| No credential sprawl | gateway managed identity | nothing to leak or rotate |

![Governance controls verified](docs/images/governance-checks.png)

Works with both the CLI and the VS Code extension, streaming included:

![Claude Code in VS Code through the gateway](docs/images/vscode-through-gateway.png)

---

## Prerequisites

| Requirement | Notes |
|---|---|
| Microsoft Foundry account (`AIServices` kind) | with at least one Claude deployment |
| Azure CLI, signed in | `az login` |
| PowerShell 5.1+ or PowerShell 7+ | both supported |
| Permission to create Entra ID groups | or create them yourself and pass `-SkipGroups` |
| An APIM **v2** SKU is deployed | see the SKU note below |

> ### ⚠️ The SKU matters more than anything else here
> APIM's `llm-*` policies parse the **Anthropic Messages API** shape **only on v2 tiers**
> (Basic v2, Standard v2, Premium v2). On classic Developer/Basic/Standard/Premium the policies
> apply happily but token counts come back empty — so budgets silently never trigger and you
> believe you are governed when you are not. This accelerator defaults to **Basic v2**.

---

## Quickstart

```powershell
git clone https://github.com/naveenneog/claude-code-foundry-gateway
cd claude-code-foundry-gateway

az login

# Interactive. Discovers your Foundry account, asks for each budget with a
# sensible default already filled in, and shows a summary before it creates
# anything. Enter throughout gives a working, governed deployment.
./Install-ClaudeGateway.ps1
```

**macOS and Linux** — same wizard, same Bicep, same result:

```bash
./install-claude-gateway.sh
```

Needs `az` and `jq`. The entitlement sync step also wants PowerShell 7
(`pwsh`); without it the script tells you the one command to run afterwards.

Preview without changing anything:

```powershell
./Install-ClaudeGateway.ps1 -WhatIf     # or: ./install-claude-gateway.sh --what-if
```

Unattended, taking every default:

```powershell
./Install-ClaudeGateway.ps1 -FoundryAccount ai-contoso -Yes
./install-claude-gateway.sh --foundry-account ai-contoso --yes
```

`deploy.ps1` is still there for anyone scripting against it; the wizard wraps
the same Bicep and produces the same result.

### What it does

1. Signs you in, picks the subscription, and finds Foundry accounts that
   actually have a Claude deployment
2. Collects every budget — tokens per minute and per day, per tier, plus a
   request ceiling — each with a default in place
3. Shows a summary and waits. **Nothing is created before you confirm**
4. Deploys APIM (v2, system-assigned identity), Log Analytics and Application
   Insights with custom metric dimensions enabled
5. Creates the Claude API, its operations, and the governance policy
6. Grants the gateway identity `Cognitive Services User` on your Foundry account
7. Creates the two Entra tier groups and syncs membership
8. Verifies the controls, and writes `onboarding/claude-gateway.json` — the file
   your developers' setup script reads. **It is generated, not shipped**; see
   [onboarding/README.md](onboarding/README.md).

Re-runnable, so it is also how you change budgets later.

---

## Onboarding a developer

**1. Entitle them** — portal or CLI. The
[portal walkthrough](docs/ONBOARDING.md#2-ui-walkthrough--adding-a-member-in-the-portal)
includes a deep link, and how to delegate this to a team lead without giving
them any Azure rights.

```powershell
az ad group member add --group claude-code-standard `
    --member-id (az ad user show --id alice@contoso.com --query id -o tsv)

./scripts/Sync-ClaudeAccess.ps1 -ApimName <apim-name> -ResourceGroup <rg>
```

**2. Send them the setup**

```powershell
./scripts/New-OnboardingEmail.ps1 `
    -ConfigPath ./onboarding/claude-gateway.json `
    -To alice@contoso.com -DisplayName Alice
```

Produces a formatted email — HTML, plain text, and an `.eml` to send from
Outlook. `-Send` tries Microsoft Graph and falls back cleanly.

**3. They run one command**

```powershell
# Windows
.\Setup-ClaudeWorkstation.ps1 -ConfigPath .\claude-gateway.json
```

```bash
# macOS and Linux
./setup-claude-workstation.sh --config ./claude-gateway.json
```

`claude-gateway.json` is the file step 2 sent them — generated by the wizard,
not shipped in this repo. Without it they can pass `-GatewayUrl` and `-TenantId`
directly instead.

No admin rights. Checks prerequisites, installs what is missing, and configures
**all three clients** — Claude Code CLI, the VS Code extension, and Claude
Desktop including Cowork — then makes a real call through the gateway to prove
it works.

No key, no Foundry role, and they appear in chargeback from their first request.

Revoking is `az ad group member remove` + sync. Promotion to premium is a group
change.

> **Guest accounts:** if the developer is a B2B guest in your tenant (a `#EXT#` UPN), they must
> sign in with `az login --tenant <tenant-id>`. A plain `az login` lands them in their home
> tenant and the gateway returns 401. The setup script pins the tenant for them.

---

## Verifying the controls

```powershell
./scripts/Show-Governance.ps1 -ApimName <apim-name> -ResourceGroup rg-claude-gateway
```

Checks that an entitled developer is served, a second identity gets its own tier, an exhausted
budget is throttled with a `Retry-After`, and consumption is attributed per person. This produces
the screenshot above.

---

## Close the bypass

Until you do this, developers with a direct role can skip the gateway entirely:

```powershell
$scope = az cognitiveservices account show -n <foundry-account> -g <rg> --query id -o tsv
az role assignment delete --assignee <developer-oid> --role "Cognitive Services User" --scope $scope
```

Leave the role assigned only to the gateway's managed identity.

---

## Tuning budgets

Limits live in APIM named values, so changing one is a config edit, not a redeployment:

| Named value | Default | Meaning |
|---|---|---|
| `tpm-standard` | 20,000 | standard tier tokens/minute |
| `quota-standard` | 500,000 | standard tier tokens/day |
| `tpm-premium` | 80,000 | premium tier tokens/minute |
| `quota-premium` | 5,000,000 | premium tier tokens/day |
| `calls-per-minute` | 120 | request ceiling per developer |

```powershell
az apim nv update -g rg-claude-gateway --service-name <apim-name> `
    --named-value-id tpm-standard --value 40000
```

---

## Chargeback

Token usage is emitted to Application Insights as custom metrics in the `claudecode` namespace,
dimensioned by `User`, `UserId`, `Tier`, `Model` and `SessionId`.

```
naveen.g@contoso.com      831 tokens
alice@contoso.com         728 tokens
```

> The Azure CLI's `az monitor metrics list` drops `--namespace` for custom namespaces and reports
> "metric not found". Use the REST API — `Show-Governance.ps1` does.

---

## What it costs

| Item | Approx |
|---|---|
| APIM Basic v2, 1 unit | ~$250/month |
| Log Analytics + Application Insights | ingestion-based, small at this volume |
| Claude tokens | Foundry CCU billing, unchanged by the gateway |

Tear it down:

```powershell
az group delete -n rg-claude-gateway --yes --no-wait
az apim deletedservice purge --service-name <apim-name> --location <region>
az ad group delete --group claude-code-standard
az ad group delete --group claude-code-premium
```

`purge` matters — a soft-deleted APIM keeps its globally unique name.

---

## Repository layout

```
deploy.ps1                     one-command deployment
infra/
  main.bicep                   gateway, observability, API, policy, RBAC
  foundry-role.bicep           Cognitive Services User for the gateway identity
  policy.xml                   the governance policy
  azuredeploy.json             compiled ARM, for the Deploy to Azure button
Install-ClaudeGateway.ps1        interactive admin setup - start here (Windows)
install-claude-gateway.sh        the same, for macOS and Linux
scripts/
  Setup-ClaudeWorkstation.ps1  one-command developer setup (Windows)
  setup-claude-workstation.sh  the same, for macOS and Linux
  get-foundry-token.*          credential helper for Claude Desktop
  New-OnboardingEmail.ps1      generate the developer's onboarding email
  Debug-ClaudeCode.ps1         end-to-end health check, run this first
  Sync-ClaudeAccess.ps1        Entra groups -> APIM named values
  Show-Governance.ps1          verify all four controls
  Get-FoundryValues.ps1        discover your Foundry values (-Mask to share)
  Set-GatewayPolicy.ps1        apply a policy file on its own
  Test-FoundryDirect.ps1       verify Foundry with the gateway bypassed
  inspect-proxy.mjs            see exactly what Claude Code sends
docs/
  SETUP.md                     prerequisites, roles, deployment
  ONBOARDING.md                add/change/revoke access; developer setup
  MONITORING.md                metrics, chargeback, KQL, alerts
  DEBUGGING.md                 isolate a failure layer by layer
  COMPARISON.md                Foundry vs Anthropic direct
  ARCHITECTURE.md              how it works, and why each piece is there
  GOVERNANCE-CHECKS.md         command reference for verifying controls
  TROUBLESHOOTING.md           symptom -> fix lookup
guide/
  capture.mjs                  Playwright capture of the portal flow
  compose.mjs                  banner treatment for existing stills
  auth.mjs                     one-time portal sign-in
```

`inspect-proxy.mjs` is how the identity model was established rather than assumed: it decodes the
JWT Claude Code sends and prints the claims, without ever logging the token.

---

## Documentation

**Find your path:**

| You are… | Read, in order |
|----------|----------------|
| **Standing this up for the first time** | [Setup](docs/SETUP.md) → [Onboarding Part A](docs/ONBOARDING.md#part-a--platform-team) → [Monitoring](docs/MONITORING.md) |
| **A developer who was just given access** | [Onboarding Part B](docs/ONBOARDING.md#part-b--developer) — nothing else |
| **Deciding whether to do this at all** | [Comparison](docs/COMPARISON.md) → [Architecture](docs/ARCHITECTURE.md) |
| **Fixing something that broke** | [Debug](docs/DEBUGGING.md) — it names the layer, then sends you on |
| **Being asked "who spent what?"** | [Monitoring](docs/MONITORING.md) |

**The four guides:**

| Guide | For | Covers |
|-------|-----|--------|
| [Setup](docs/SETUP.md) | platform team | prerequisites, **roles and permissions**, deployment, closing the bypass |
| [Onboarding](docs/ONBOARDING.md) | platform team + developers | add a developer, change tiers, revoke; the developer's own setup |
| [Monitoring](docs/MONITORING.md) | whoever owns the spend | metrics, filters, chargeback, KQL, alerts |
| [Debug](docs/DEBUGGING.md) | anyone | isolate a failure layer by layer |

**Reference, when you need it:**

- [Foundry vs Anthropic direct](docs/COMPARISON.md) — what changes, and what you give up
- [Architecture](docs/ARCHITECTURE.md) — request path, identity model, design decisions
- [Governance checks](docs/GOVERNANCE-CHECKS.md) — command reference for verifying controls
- [Troubleshooting](docs/TROUBLESHOOTING.md) — symptom → fix lookup, when you already know what broke
- [Screenshot tooling](guide/README.md) — regenerate the screenshots against your own deployment

---

## Companion accelerator

**[claude-desktop-foundry](https://github.com/naveenneog/claude-desktop-foundry)** —
the same treatment for **Claude Desktop**, the GUI client.

It reuses *this* gateway, so if you already run it there is no new Azure
infrastructure: generate a managed-policy payload, deploy it with Intune or your
MDM, and Desktop traffic lands under the same budgets, tiering and chargeback.

Entitle a person once in the Entra group and they get both clients.

---

## Contributing

Issues and pull requests welcome. This accelerator was built and verified end to end against a
live Foundry deployment; if something does not work in your tenant, please open an issue with the
failing command and its output.

### Running the checks

```powershell
./scripts/Test-All.ps1                 # offline: encoding, shell scripts, both PowerShell hosts
./scripts/Test-All.ps1 -IncludeAzure   # adds the checks that call Azure
```

Two things these guard that are easy to get wrong, and that a syntax check will not catch:

**PowerShell scripts containing non-ASCII characters must be saved as UTF-8 *with* a BOM.**
Windows PowerShell 5.1 reads `.ps1` files as ANSI unless a BOM says otherwise, so the banner's
block characters are mangled at parse time — before anything is printed, and regardless of the
console code page. PowerShell 7 reads UTF-8 either way, so this is invisible until someone runs
it on 5.1. `./scripts/Repair-ScriptEncoding.ps1` fixes it; `-Check` just reports.

**Keep `( )`, `|`, `&`, `<`, `>` and `^` out of `az --query`.** On Windows `az` is a `.cmd`
shim, and PowerShell only quotes a native argument if it contains a space. A query such as
`"[?contains(name,'x')].name"` has none, so it reaches `cmd.exe` bare and is re-parsed:
`].name was unexpected at this time`. This affects PowerShell 5.1 and 7 equally. Worse, the
error text is a non-empty string, so a plain `if ($result)` reads it as success. Filter in
PowerShell instead. Brackets and braces are safe; bash is unaffected.

## License

MIT — see [LICENSE](LICENSE).
