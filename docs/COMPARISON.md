# Claude via Microsoft Foundry vs. Anthropic direct

Why route Claude Code through your own Foundry deployment instead of
`api.anthropic.com`, and what you give up by doing it.

This is written to be used in an architecture review, so it includes the
arguments *against* as well as for.

---

## The three options

| | **A. Anthropic direct** | **B. Foundry direct** | **C. Foundry + gateway** |
|---|---|---|---|
| Endpoint | `api.anthropic.com` | `<res>.services.ai.azure.com/anthropic` | `<apim>.azure-api.net/claude` |
| Credential on the dev machine | API key | none — Entra token | none — Entra token |
| Who can call the model | anyone with the key | anyone with `Cognitive Services User` | only entitled group members |
| Per-developer budget | no | no | **yes** |
| Per-developer cost attribution | no | no | **yes** |
| Billing lands on | Anthropic invoice | Azure invoice | Azure invoice |
| Setup effort | minutes | ~1 hour | ~1 hour |

**B is not a destination.** It removes the API key but leaves you with a shared,
unmetered resource that any role holder can drain. It is a useful stepping stone
and a good debugging isolation point — nothing more. This accelerator builds C.

---

## What actually changes

### 1. There is no API key to leak

This is the single biggest operational difference.

With an Anthropic API key you own a long-lived bearer secret that has to be
distributed, stored, rotated, and revoked. It lands in `.env` files, CI variable
groups, and shell history. It carries no identity: a leaked key is
indistinguishable from legitimate use, and revoking it breaks everyone at once.

With Foundry the developer runs `az login` and Claude Code acquires a short-lived
Entra token bound to *them*. Verified on the wire with the inspector proxy: the
request carries the developer's own token including the `oid` and `upn` claims.

| | API key | Entra token |
|---|---|---|
| Lifetime | until revoked | ~1 hour |
| Identity | none | the actual person |
| Revocation | rotate, break everyone | disable the account, instant |
| Leaving the company | manual key rotation | access dies with the account |
| Conditional Access, MFA, device compliance | not applicable | **enforced** |

That last row is easy to skim past. Routing through Entra means your existing
Conditional Access policies apply to AI usage automatically — no separate control
plane to build.

### 2. Spend moves onto the Azure invoice

Claude in Foundry is billed in **Claude Consumption Units (CCU)** through Azure
Marketplace, so it appears on your Azure bill rather than a separate Anthropic
one, and Microsoft documents it as eligible to draw down an Azure consumption
commitment (MACC).

For an organisation with an existing Azure commitment this is often the decisive
argument, because it converts new net spend into commitment drawdown. It is a
commercial matter — **confirm the current terms with your account team rather
than taking a table in a repository as authority.**

- [CCU billing](https://learn.microsoft.com/en-us/azure/foundry/foundry-models/concepts/claude-models-billing)
- [Hosting comparison](https://learn.microsoft.com/en-us/azure/foundry/foundry-models/concepts/claude-models-hosting-comparison)

### 3. Governance you cannot express with an API key

Everything in this accelerator — tiering, per-minute and daily budgets,
chargeback — depends on requests carrying an identity. An API key has none, so
the best you can do is one shared bucket.

| Control | API key | This gateway |
|---|---|---|
| Per-developer rate limit | ✗ | ✓ `llm-token-limit` keyed on `oid` |
| Per-developer daily quota | ✗ | ✓ |
| Tiers | ✗ | ✓ Entra group membership |
| Cost attribution by person | ✗ | ✓ App Insights dimension |
| Revoke one person | ✗ | ✓ remove from group, sync |
| Model allowlist | ✗ | ✓ policy |

### 4. Data handling — the nuance most people get wrong

> **Anthropic remains the data processor, and Anthropic provides the SLA, even
> for the Azure-hosted option.** "On Azure" does not mean "Microsoft is now the
> processor". Use is subject to Anthropic's commercial terms.

There are two hosting options, and they differ materially:

| | Hosted on Azure | Hosted on Anthropic |
|---|---|---|
| Inference infrastructure | Azure | Anthropic |
| Prompts and completions | stay within Azure, except usage metadata and safety-flagged content | may be processed outside Azure, including outside your region |
| Deployment types | Global Standard, **US Data Zone Standard** | Global Standard only |
| Suits strict residency | yes | no |

Check what you actually have:

```bash
az cognitiveservices account deployment list -g <rg> -n <foundry> \
  --query "[].{name:name, model:properties.model.name, sku:sku.name}" -o table
```

```bash
# what the region offers - DataZoneStandard indicates the Azure-hosted option
az cognitiveservices model list -l <region> \
  --query "[?contains(model.name,'claude')].{name:model.name, skus:join(',',model.skus[].name)}" -o table
```

On the deployment this accelerator was built against, both models run
`GlobalStandard` and the model `format` is `Anthropic`.

> If you are adopting Foundry **specifically** for data residency, verify the
> hosting option and deployment type before committing. Do not assume the Azure
> endpoint implies Azure-only processing.

### 5. Network and platform integration

| | Anthropic direct | Foundry |
|---|---|---|
| Network path | public internet | Azure backbone; Private Link available |
| Egress control | allowlist a third-party FQDN | stays inside your network boundary |
| Diagnostics | Anthropic console | Azure Monitor, Log Analytics, App Insights |
| Policy and posture | separate | Azure Policy, Defender for Cloud |
| Identity | Anthropic org | Entra ID, Conditional Access, PIM |

If your organisation already runs on Azure, option C adds no new control plane.
That is worth more than any single feature in these tables.

---

## What you give up

An honest architecture review has to cover this side too.

| Trade-off | Detail | Mitigation |
|---|---|---|
| **New model lag** | Anthropic ships to its own API first; Foundry follows | Keep a small direct-API path for evaluation |
| **Beta feature lag** | Newer beta headers and endpoints may not be exposed | Test before depending on one |
| **Not every model** | Your region and Marketplace entitlement decide what you can deploy. Marketplace purchases disabled in the tenant blocks deployment entirely | Check `az cognitiveservices model list` early |
| **Gateway cost** | APIM Basic v2 is ~$250/month before any tokens | Only worth it at team scale; a 5-person team is likely below the line |
| **Gateway latency** | one extra hop | co-locate APIM and Foundry in the same region |
| **New single point of failure** | gateway down = everyone down | Standard v2 / Premium v2 for SLA and multi-region |
| **Membership is not live** | entitlement changes apply when the sync runs | schedule the sync |
| **Operational ownership** | someone now owns policy, budgets, and upgrades | this is real headcount, not zero |

---

## How to choose

```
Do you need per-developer budgets or chargeback?
├── yes ────────────────────────────────▶ C. Foundry + gateway
└── no
    └── Do you need to remove API keys, or put spend on the Azure invoice?
        ├── yes ────────────────────────▶ B. Foundry direct
        └── no
            └── Are you evaluating, or fewer than ~5 developers?
                ├── yes ────────────────▶ A. Anthropic direct
                └── no ─────────────────▶ C. Foundry + gateway
```

### Rules of thumb

- **Under ~5 developers**, the $250/month gateway probably exceeds the spend it
  governs. Use A or B and revisit.
- **Regulated industry, or residency requirements** — go to Foundry, and verify
  the hosting option per section 4.
- **You have an Azure commitment** — the MACC drawdown usually settles it.
- **You cannot answer "who spent this?"** and someone is starting to ask — that
  is the specific problem C solves.
- **You want the newest model on release day** — keep a direct path alongside.

These are not exclusive. A common pattern is C for daily engineering work and a
small, tightly-held direct account for evaluating new releases.

---

## Verified technical differences

Established empirically against a live deployment while building this, not read
from documentation:

| Finding | Consequence |
|---|---|
| Foundry exposes the **native Anthropic Messages API** at `/anthropic/v1/messages` | Claude Code works unmodified — no translation layer, no proxy |
| OpenAI-shaped paths return `404 api_not_supported` | Do not reuse Azure OpenAI client code |
| Auth is `Authorization: Bearer <entra-token>` + `anthropic-version: 2023-06-01` | Standard Entra tooling applies |
| **Cognitive Services User** is required; Owner is not sufficient | Owner is control-plane only and gets `401` |
| `CLAUDE_CODE_USE_FOUNDRY=1` is the switch; `CLAUDE_CODE_USE_AZURE` does not exist | — |
| `ANTHROPIC_FOUNDRY_RESOURCE` and `ANTHROPIC_FOUNDRY_BASE_URL` are mutually exclusive | Use the base URL in gateway mode |
| Claude Code forwards the developer's own Entra token, with `oid`/`upn` and an `x-claude-code-session-id` header | Per-user metering is unforgeable — this is what makes the whole design work |
| Streaming, tool use, and `count_tokens` all work through the gateway | No feature loss on the governed path |
| APIM `llm-*` policies parse Anthropic token usage **only on v2 SKUs** | Classic tiers silently meter zero |

---

## Next

| Task | Guide |
|------|-------|
| Stand it up | [Setup guide](SETUP.md) |
| Give people access | [Onboarding guide](ONBOARDING.md) |
| Watch the spend | [Monitoring guide](MONITORING.md) |
| Fix something | [Debug guide](DEBUGGING.md) |
