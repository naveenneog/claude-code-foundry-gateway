# Unknowns register

Unknowns are written down before implementation, then closed by research with a citation and a
date, or by an explicitly labelled assumption with its blast radius.

The table is the machine-readable part: `.ironclad/gate.mjs` counts rows marked `OPEN`, and
fails the release stage while any remain. Detail for each one follows below.

| ID | State | Question | Blocks |
|---|---|---|---|
| U1 | OPEN | Does a constant counter-key share one counter across different principals? Narrowed — the rest closed from the policy reference | P11 |
| U2 | OPEN | Do emitted token counts reconcile with the Azure invoice, and within what margin? | P12 |
| U3 | OPEN | Does Claude in Chrome apply under a third-party provider at all? | parity matrix |
| U4 | OPEN | Can a self-hosted Claude apps gateway serve a Foundry deployment, and is it worth operating? | P13 |
| U6 | OPEN | What signs a plugin, and who verifies it? | P14 |
| U7 | OPEN | Can Log Analytics honour selective deletion within its purge limits? | P15 |

---

## Detail

### U1 — Does APIM support a shared counter across all principals?

**Narrowed 2026-09-02.** Most of this closed against the
[`llm-token-limit` reference](https://learn.microsoft.com/en-us/azure/api-management/llm-token-limit-policy)
(retrieved 2026-09-02). What the documentation settles:

| Sub-question | Answer |
|---|---|
| Is `Monthly` a valid `token-quota-period`? | Yes — `Hourly`, `Daily`, `Weekly`, `Monthly`, `Yearly`. The window starts at the UTC timestamp truncated to the unit |
| Does a constant `counter-key` give one shared counter? | Documented yes: "For each key value, a single counter is used for all scopes at which the policy is configured" |
| Can a third `llm-token-limit` sit alongside the two already in the policy? | Yes — "This policy can be used multiple times per policy definition" |
| Is the cap exact? | No. "High-concurrency requests can temporarily exceed the configured token limit", and the remaining-quota figure "may be larger than expected based on actual token usage" |

Two consequences for P11's design, both from the same page. The org ceiling is a **soft cap**
that can overshoot under concurrency, so it cannot be sold as a hard spend guarantee. And if
the same `counter-key` is ever used at more than one scope, `tokens-per-minute` must match
across them or behaviour is undefined — so the org counter uses its own key at a single scope.

**Still open, and it needs measuring rather than reading.** Whether a constant key genuinely
shares one counter across *different authenticated principals*. The documentation implies it,
but this repository has shipped documented-but-wrong behaviour before — `what-if` reporting a
clean plan for a role assignment that then failed, and a v2 SKU whose policies attach happily
while counting zero tokens.

**The experiment.** Add a third `llm-token-limit` with `counter-key="org"` and a deliberately
small `token-quota`. Have identity A exhaust it. Then call as identity B, which has spent none
of its own budget, and confirm B is throttled. If B is served, the counter is per-principal
regardless of the key and P11 has to move out of the request path into a scheduled job that
reads Application Insights and flips a named value.

**What that needs:** a second authenticated identity — the blocker, since one operator can
only present one Entra token — plus a window in which a non-production gateway carries a test
quota. `apim-hackgwfl4s7jvpxekno` in `rg-hackathon-gateway` is a non-production instance and is
the right place to run it.

### U2 — Cost attribution accuracy against the Azure invoice

**Question.** The gateway meters tokens via `llm-emit-token-metric`. Claude's analytics API
reports an `estimated_cost` in cents. Whether token counts multiplied by Foundry list price
reconcile with the actual Azure invoice, and within what margin, is unmeasured.

**Why it matters.** P12 exposes month-to-date spend. Reporting a figure that does not match
the invoice is worse than reporting tokens alone.

**How to close.** Compare a full month of emitted metrics against the Foundry line on the
Azure invoice.

### U3 — Claude in Chrome under a third-party provider

**Question.** Claude Enterprise exposes Chrome controls in org settings. Whether the Chrome
extension works against a third-party provider at all, and whether any managed key governs it,
is unconfirmed.

**How to close.** Check the Claude Desktop 3P configuration reference and the Chrome extension
documentation. If it does not apply, record it as N/A rather than a gap.

### U4 — Server-managed settings without MDM

**Question.** Claude Code documents a self-hosted "Claude apps gateway" that delivers managed
settings per IdP group. Whether it can be run against a Foundry deployment, what it costs to
operate, and whether it is worth it next to one Intune profile per tier, is unknown.

**Why it matters.** It decides P13: one profile per tier is simple and static; a gateway is
dynamic but is a second always-on component, which the charter treats as needing justification.

**How to close.** Read the Claude apps gateway documentation, then price the hosting.

### U6 — Plugin signing and trust

**Question.** A plugin marketplace can be hosted in git or over HTTPS.
`isDesktopExtensionSignatureRequired` exists for `.mcpb` extensions. What signs a plugin, who
verifies it, and whether the same trust applies to marketplace-delivered plugins, is not
established.

**Why it matters.** P14 distributes executable extensions to every desktop. Getting the trust
model wrong here is a supply-chain problem, not a documentation problem.

### U7 — Selective deletion of captured content

**Question.** The Compliance API supports deleting specific records. If content capture lands
prompts and responses in Log Analytics, deleting one user's records on request is bounded by
what Log Analytics supports for purge, and by its latency and quota.

**Why it matters.** A retention promise that cannot be honoured on a subject-access request is
a compliance liability rather than a feature.

---

## Closed

_(none yet)_
