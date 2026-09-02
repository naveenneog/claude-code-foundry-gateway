# Unknowns register

Unknowns are written down before implementation, then closed by research with a citation and a
date, or by an explicitly labelled assumption with its blast radius.

The table is the machine-readable part: `.ironclad/gate.mjs` counts rows marked `OPEN`, and
fails the release stage while any remain. Detail for each one follows below.

| ID | State | Question | Blocks |
|---|---|---|---|
| U1 | OPEN | Does APIM support a usable shared counter across all principals? | P11 |
| U2 | OPEN | Do emitted token counts reconcile with the Azure invoice, and within what margin? | P12 |
| U3 | OPEN | Does Claude in Chrome apply under a third-party provider at all? | parity matrix |
| U4 | OPEN | Can a self-hosted Claude apps gateway serve a Foundry deployment, and is it worth operating? | P13 |
| U6 | OPEN | What signs a plugin, and who verifies it? | P14 |
| U7 | OPEN | Can Log Analytics honour selective deletion within its purge limits? | P15 |

---

## Detail

### U1 — Does APIM support a shared counter across all principals?

**Question.** P11 needs an org-wide monthly ceiling that every developer's spend counts
against. `llm-token-limit` takes a `counter-key`; whether a constant key gives a usable shared
counter at Basic v2, and how it interacts with the per-principal counters already in the
policy, is unverified.

**Why it matters.** If a shared counter is not usable, the org cap has to be enforced outside
the request path — a scheduled job reading Application Insights and flipping a named value —
which is a different design with a lag measured in minutes.

**How to close.** Deploy both shapes to the live gateway and measure. Do not infer from the
policy reference.

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
