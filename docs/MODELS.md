# Adding a model

A new Claude model appearing in Foundry is routine. Making it usable takes one
command.

## Prerequisites

- Select the gateway and Foundry resources with
  [Operations](OPERATIONS.md#1-select-the-gateway-and-workspace).
- Read access for discovery; Foundry deployment write access if using `-Deploy`;
  API Management Service Contributor for tier allowlists.
- An approved USD price/source date and the actual deployment name.
  Examples below match this repository's example price book, not a current quote.
- A change window, a configuration backup, and the owner of any managed client
  policy. Run from the repository root in PowerShell with Azure CLI signed in.
- If Turnstile owns tiers, coordinate its next apply rather than leaving a
  gateway-only model edit that will be overwritten.

## 1. Inspect, deploy and allow

```powershell
./scripts/Add-ClaudeModel.ps1 -Model claude-opus-5 -Tier premium `
    -InputPerMillion 5 -OutputPerMillion 25 `
    -ResourceGroup <rg> -ApimName <apim>
```

That checks the model is deployed, adds it to the tier's allow list, writes its
price so usage is charged, and prints what developers have to change.

To see where things stand first:

```powershell
./scripts/Add-ClaudeModel.ps1 -List -ResourceGroup <rg> -ApimName <apim>
```

```
  Model                      Deployed   Priced             In/M        Out/M
  claude-haiku-4.5           no         yes                  $1           $5
  claude-opus-5              yes        yes                  $5          $25
                             tiers: premium
  claude-sonnet-5            yes        yes                  $2          $10
                             tiers: standard, premium
```

Only Claude deployments are listed. The reference account also carries GPT,
Sora and embedding deployments; this gateway does not front them, so showing
them as unpriced would be true and useless.

**Portal/manual:**

1. Foundry > Models + endpoints > select/deploy the approved Claude model.
   Confirm hosting/version, quota and `Succeeded`; provide the organisation
   details in [Setup](SETUP.md#azure-resources-you-must-already-have).
2. APIM > APIs > Named values > `models-standard` / `models-premium` > Edit.
   Write the approved deployment names with sentinel commas.
3. Edit the private price book locally and republish `ClaudeCost`; there is no
   Azure portal rate-setting blade for this accelerator's internal tariff.
4. Update the permitted/default model names in the managed client profile.

**Verify:** rerun `-List`, call the permitted deployment as the target tier,
and check the priced ledger's `priced_ok` after ingestion and query publication.
A model working in Foundry's playground proves the operator's access, not the
developer's gateway tier.

---

## The four things that have to agree

| | Where it lives | What happens if it is missed |
|---|---|---|
| **Deployed** | The Foundry account | The gateway forwards and Foundry refuses |
| **Allowed** | `models-standard` / `models-premium` named values | The gateway refuses with 403 before Foundry sees it |
| **Priced** | `config/price-book.json` | Served, and reported at **$0** |
| **Selectable** | `availableModels` in managed settings, if you pin it | The client hides a model the gateway would serve |

The third is the one that fails quietly. A model with no price still works, and
its usage lands in reports as nothing, which reads as nobody using it rather
than as a configuration gap. `-List` marks it in red, and the command refuses to
add an unpriced model unless you pass `-SkipPrice`.

A model that is not deployed is refused outright, and the error names what *is*
deployed:

```
'claude-opus-9' is not deployed on Foundry account 'ai-contoso'.
Deployed: claude-opus-5, claude-sonnet-5. Pass -Deploy to create it now, or
-SkipDeploymentCheck if you are staging configuration ahead of the deployment.
```

`-Deploy` creates the Foundry deployment as part of the same command. A quota
refusal is reported as quota rather than as a generic failure, because the
answer to one is a quota request and not a retry.

---

## The price book

To use your own rates, copy the example and edit it:

```powershell
Copy-Item config/price-book.example.json config/price-book.json
```

With no such file, built-in list rates apply, so a fresh clone works. Prices are
**US dollars per million tokens**:

```json
{
  "date": "2026-09-16",
  "source": "list price, https://platform.claude.com/docs/en/about-claude/pricing",
  "models": {
    "claude-sonnet-5": { "inputPerM": 2.0, "outputPerM": 10.0 }
  }
}
```

Only base input and output are stored. For Anthropic prompt caching, reusing
cached input costs 0.1x the base input rate, writing to a five-minute cache
costs 1.25x, and writing to a one-hour cache costs 2x — so the three cache rates
are derived rather than stored.

`config/price-book.json` is **not** in the repository, because it may hold your
negotiated rates rather than list price, and a negotiated schedule is
commercially sensitive. `config/price-book.example.json` ships instead.

A malformed price book raises an error; the script does not quietly fall back to
built-in rates. See [ADR-0010](adr/0010-financial-semantics.md) for how a dollar
figure here is calculated and what it does and does not mean.
After changing prices, republish with `scripts/Publish-ClaudeQueries.ps1` using
the explicit gateway/workspace. `ClaudeCost` embeds the current book at
publication; it does not implement an effective-dated price series. Preserve the
book and exported rows used for each closed month ([FinOps](FINOPS.md)).

---

## What developers change

The model name, and nothing else:

```bash
claude --model claude-opus-5
```

Their gateway URL, token and settings are unchanged. If your managed settings
pin `availableModels`, regenerate that profile too — otherwise the client hides
a model the gateway is willing to serve, which presents as the model missing:

```powershell
./scripts/New-ClaudeCodePolicy.ps1 -GatewayUrl <url> -Tier premium `
    -AvailableModels claude-opus-5, claude-sonnet-5
```

---

## Retiring one

**Important:** an empty gateway model allowlist means **allow all**, not deny
all. Removing the last entry with this command writes `,,` and therefore
reopens all deployed models for that tier. Do not use last-entry removal as a
revocation operation. First set the complete remaining approved list; if none
should be callable, disable the relevant entitlement or retire the Foundry
deployment through an approved change.

```powershell
./scripts/Add-ClaudeModel.ps1 -Model claude-opus-4.8 -Remove -Tier both `
    -ResourceGroup <rg> -ApimName <apim>
```

That takes it out of both tier allow lists and reports what is left. The list
keeps its sentinel commas, so `,claude-opus-5,claude-opus-4.8,` becomes
`,claude-opus-5,` and an emptied list becomes `,,`.

Its price-book entry stays, and that is deliberate: reports over past months
still need to recognize the retired model. [ADR-0010](adr/0010-financial-semantics.md)
requires effective-dated pricing; the current query publisher embeds one book,
so keeping an entry does not by itself preserve past rates. Keep monthly
exports and price snapshots until that record requirement is implemented.

If your managed settings pin `availableModels`, regenerate and redistribute that
profile too, or the client will keep offering a model the gateway now refuses.

**Portal:** APIM > Named values > model list, then Foundry > Models + endpoints
if the deployment itself must be removed. The command removes allowlist entries,
not the Foundry deployment. Verify the old model is refused through each
intended tier and another allowed model still works.

## Troubleshoot and next steps

| Symptom | Check |
|---|---|
| `DeploymentNotFound` | Deployment name versus catalogue model name, account and provisioning state |
| `model_not_allowed` | Effective tier and full sentinel allowlist |
| Usage appears free | Price mapping and published book; unknown prices are not zero-cost models |
| Retired model still works | Empty-list allow-all behavior, other tier membership, stale config or a direct bypass |

[Budgets](BUDGETS.md) covers limits; [Plugins](PLUGINS.md) covers non-model client
capabilities. Neither a client picker nor plugin policy replaces gateway controls.
