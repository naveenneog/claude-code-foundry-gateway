# Unknowns register

Unknowns are written down before implementation, then closed by research with a citation and a
date, or by an explicitly labelled assumption with its blast radius.

The table is the machine-readable part: `.ironclad/gate.mjs` counts rows marked `OPEN`, and
fails the release stage while any remain. Detail for each one follows below.

| ID | State | Question | Blocks |
|---|---|---|---|
| U1 | CLOSED | Does a constant counter-key share one counter across callers? Yes — measured 2026-09-02 | P11 unblocked |
| U2 | OPEN | Do emitted token counts reconcile with the Azure invoice, and within what margin? | P12 |
| U3 | OPEN | Does Claude in Chrome apply under a third-party provider at all? | parity matrix |
| U4 | OPEN | Can a self-hosted Claude apps gateway serve a Foundry deployment, and is it worth operating? | P13 |
| U6 | OPEN | What signs a plugin, and who verifies it? | P14 |
| U7 | OPEN | Can Log Analytics honour selective deletion within its purge limits? | P15 |

---

## Detail

### U1 — Does APIM support a shared counter across all principals? — CLOSED 2026-09-02

**Answer: yes.** A constant `counter-key` is a single counter shared by every caller. P11 can
enforce the org ceiling in the request path; the scheduled-job fallback is not needed.

**Measured, not inferred.** A throwaway API (`u1-counter-test`) was added to the live gateway
alongside the untouched `claude-foundry` API, carrying two `llm-token-limit` policies: one keyed
on an `x-test-user` header with a 100,000-token quota, one keyed on the constant
`u1-org-constant` with a 400-token quota. Both hourly. Entra validation was kept so the route
was never unauthenticated. The API was deleted immediately afterwards and the live API verified
still serving 200 with entitlement intact.

Using a header for caller identity removed the blocker that had held this open — proving a
*shared* counter needs two callers, and one operator presents one Entra token. The counter-key
mechanism is the same whichever way identity is established.

```
alice  200  org-remaining=319   user-remaining=99919
alice  200  org-remaining=238   user-remaining=99838
alice  200  org-remaining=157   user-remaining=99757
alice  200  org-remaining=76    user-remaining=99676
alice  200  org-remaining=0     user-remaining=99595
alice  403
bob    403   <- had spent none of its own quota
carol  403   <- had spent none of its own quota
```

Two counters moved independently in the same response: `x-org-remaining` fell to zero while
alice's own `x-user-remaining` still showed 99,595. Then two callers who had spent nothing were
refused. That is a shared counter.

**Design consequences for P11**, from the
[`llm-token-limit` reference](https://learn.microsoft.com/en-us/azure/api-management/llm-token-limit-policy)
(retrieved 2026-09-02) and confirmed above:

| Point | Consequence |
|---|---|
| `Monthly` is a valid `token-quota-period` — `Hourly`, `Daily`, `Weekly`, `Monthly`, `Yearly` | The org ceiling can be monthly as the customer asked. Windows start at the UTC timestamp truncated to the unit |
| "For each key value, a single counter is used for all scopes" | Confirmed by measurement |
| "This policy can be used multiple times per policy definition" | The org counter sits alongside the two existing per-user policies |
| "High-concurrency requests can temporarily exceed the configured token limit" | The ceiling is a **soft cap**. It must not be described as a hard spend guarantee |
| Remaining quota "may be larger than expected based on actual token usage" | Any month-to-date figure surfaced in P12 is an estimate |
| Reusing one `counter-key` across scopes needs matching `tokens-per-minute` | The org counter takes its own key at a single scope |

The refusal is `403`, matching the existing daily-quota behaviour, so the developer-facing
message needs to distinguish "your budget" from "the organisation's budget" or the 403 will be
misread as an entitlement problem.

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
