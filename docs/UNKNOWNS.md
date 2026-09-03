# Unknowns register

Unknowns are written down before implementation, then closed by research with a citation and a
date, or by an explicitly labelled assumption with its blast radius.

The table is the machine-readable part: `.ironclad/gate.mjs` counts rows marked `OPEN`, and
fails the release stage while any remain. Detail for each one follows below.

| ID | State | Question | Blocks |
|---|---|---|---|
| U1 | CLOSED | Does a constant counter-key share one counter across callers? Yes — measured 2026-09-02 | P11 unblocked |
| U2 | OPEN | Do emitted token counts reconcile with the Azure invoice? Blocked: this subscription exposes no cost data — measured 2026-09-03 | P12 cost figures |
| U3 | OPEN | Does Claude in Chrome apply under a third-party provider at all? | parity matrix |
| U4 | CLOSED | Can a self-hosted Claude apps gateway serve a Foundry deployment, and is it worth operating? Yes and no — researched 2026-09-03 | P13 unblocked |
| U6 | CLOSED | What signs a plugin, and who verifies it? Nothing, for Claude Code — researched 2026-09-03 | P14 rescoped |
| U7 | CLOSED | Can Log Analytics honour selective deletion within its purge limits? Yes, within 30 days and Analytics-plan tables only — researched 2026-09-03 | P15 unblocked |
| U8 | OPEN | Which OTEL attributes split lines-of-code and tool decisions into their parts? | P10 productivity columns |

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
the invoice is worse than reporting tokens alone, which is why `Get-ClaudeBudget.ps1` reports
tokens and sets `cost_reported: false`.

**Attempted 2026-09-03, and blocked by the environment, not by the method.** August is closed, so
the reconciliation should have been possible. It is not, on this subscription:

| Check | Result |
|---|---|
| `az consumption usage list` for August | 1,002 records returned |
| Records carrying `pretaxCost` | **0 of 1,002** |
| Records carrying `usageQuantity` | **0 of 1,002** |
| `az billing account list` | empty |
| Cost Management query API | blocked before reaching Azure |

The subscription is an internal MCAPS allocation, which returns usage records with the cost and
quantity fields empty. No amount of querying fixes that from inside the subscription.

**How to close.** Run the reconciliation where the cost data is visible:

1. On a subscription whose principal holds **Cost Management Reader**, or an EA/MCA
   **Billing Reader** on the enrolment.
2. Take one closed month of Foundry cost for the account, grouped by meter.
3. Take the same month's tokens from the gateway's Application Insights — note that a redeploy
   may have split them across two workspaces, as happened here on 2026-08-31, so check both with
   `scripts/Get-ClaudeTelemetry.ps1`.
4. Divide to get an effective price per million input and output tokens, and record the margin
   against Foundry list price.

Until that runs, `estimated_cost` keeps `is_estimate: true` and `Get-ClaudeBudget.ps1` keeps
reporting tokens rather than money. Both are correct as they stand; what is missing is the
evidence that would let them report money.

### U3 — Claude in Chrome under a third-party provider

**Question.** Claude Enterprise exposes Chrome controls in org settings. Whether the Chrome
extension works against a third-party provider at all, and whether any managed key governs it,
is unconfirmed.

**How to close.** Check the Claude Desktop 3P configuration reference and the Chrome extension
documentation. If it does not apply, record it as N/A rather than a gap.

### U4 — Server-managed settings without MDM — CLOSED 2026-09-03

**Answer: it can serve Foundry, and it is not the right component for this accelerator.**

The Claude apps gateway is real, documented, and Microsoft Foundry is a first-class upstream. The
page is titled "Claude apps gateway for Amazon Bedrock, Claude Platform on AWS, Google Cloud, and
Microsoft Foundry" ([reference](https://code.claude.com/docs/en/claude-apps-gateway), retrieved
2026-09-03). It ships inside the `claude` binary and runs with `claude gateway --config
gateway.yaml`, so there is no separate product to buy, and there is "no separate license or
per-seat fee".

It does what this repository would want from it. Managed settings are selected by IdP group —
"your IdP groups map to model allowlists and managed settings policies" — and it "delivers
managed settings to signed-in clients itself, taking the place of server-managed settings from
the claude.ai admin console". Model access is enforced server-side.

**Why it is still not adopted here.** It is an inference proxy, not a policy service: "a
self-hosted service that sits between your developers' Claude Code clients and your model
provider". No policy-only mode is documented. It holds the upstream credential itself, and issues
its own short-lived bearer tokens to developers.

That is the one thing this accelerator will not give up. The gateway's value here is that every
request carries the developer's own Entra token, is metered against their `oid`, and is only then
swapped for the managed identity. Under the Claude apps gateway the provider sees one shared
gateway credential, so per-developer attribution at the provider is gone — and with it P10, P11
and P12.

| | Claude apps gateway | This accelerator |
|---|---|---|
| Foundry upstream | Documented | Yes |
| Developer identity reaching the provider boundary | One shared gateway credential | The developer's own Entra token, per request |
| Per-group managed settings | Server-delivered | Per-tier MDM profile |
| Per-group model allowlist | Server-side | Server-side, at the gateway policy |
| Spend limits | Per user and group | Per user, per tier, and org-wide |
| Always-on components | Gateway plus PostgreSQL plus load balancer | API Management only |
| Network exposure | Private addresses only — "Claude Code only connects to a gateway whose address is private" | Public endpoint, Entra-authenticated |

Chaining the two was considered and is **not documented**: the apps gateway's Foundry upstream
takes a `resource` and its own credential, and nothing in the reference describes forwarding a
caller's original Entra token to an intermediate API Management instance. That is left as an
inference nobody should make.

**The finding that decides P13.** Anthropic's own hosted server-managed settings state: "Settings
apply uniformly to all users in the organization. Per-group configurations are not yet supported"
([reference](https://code.claude.com/docs/en/server-managed-settings), retrieved 2026-09-03). So
per-tier MDM profiles are not a downgrade from the hosted option — for per-group scoping they are
ahead of it. P13 is one profile per tier, plus a server-side model allowlist at the gateway,
where it cannot be bypassed by editing a client.

**When the apps gateway is the right answer.** An organisation that has no API Management
instance and no wish to run one, that needs data residency through its own cloud provider, and
that does not need per-developer attribution at the provider boundary. That is a different
customer from this repository's.

### U6 — Plugin signing and trust — CLOSED 2026-09-03

**Question.** A plugin marketplace can be hosted in git or over HTTPS.
`isDesktopExtensionSignatureRequired` exists for `.mcpb` extensions. What signs a plugin, who
verifies it, and whether the same trust applies to marketplace-delivered plugins?

**Answer: nothing signs a Claude Code plugin. This changes P14's acceptance criterion.**

P14 was written to accept "a pinned marketplace delivers a signed plugin to a managed desktop,
and an unsigned one is refused". That test cannot be written, because for Claude Code there is no
signature to check.

| Artefact | Publisher signature | Integrity pinning |
|---|---|---|
| Claude Code plugin | **None documented** | Git source: full 40-character commit `sha`. HTTPS archive: `sha256`, and "Claude Code verifies every download against it and refuses the install on a mismatch" |
| Claude Code marketplace catalog | **None documented** | Branch or tag `ref` only — **not** a commit sha |
| Claude Desktop `.mcpb` | **Yes.** Detached PKCS#7/CMS over SHA-256, chain validated against the OS trust store | Signature covers bundle content |

For Claude Code the documentation has no signature field, no publisher trust root, no signed-commit
verification, no attestation check and no "require signed plugins" setting. Anthropic says so
directly: "Anthropic doesn't control what MCP servers, files, or other software are included in
plugins and can't verify that they work as intended"
([reference](https://code.claude.com/docs/en/discover-plugins), retrieved 2026-09-03).

Pinning a commit sha or an archive hash proves the content is the content that was reviewed. It
does not prove who wrote it, and the expected hash is itself only as trustworthy as the catalog
it is read from — and the catalog cannot be pinned to a commit, only to a branch or tag.

**Claude Desktop is the exception.** `isDesktopExtensionSignatureRequired` "reject[s] desktop
extensions that are not signed by a trusted publisher. Defaults to `false`"
([reference](https://claude.com/docs/third-party/claude-desktop/configuration), retrieved
2026-09-03). Bundles are signed with `mcpb sign` using an X.509 code-signing certificate, and
verification validates the chain against the operating system's trust store — `security
verify-cert -p codeSign` on macOS, `X509Chain` with OID 1.3.6.1.5.5.7.3.3 on Windows. There is no
Anthropic CA. Whether an existing Authenticode or Apple Developer ID certificate is accepted is
not documented.

**Blast radius, which is why this matters.** A plugin contributes hooks, commands, agents and MCP
servers, and runs as native code with the user's privileges. The only documented sandbox is the
Bash tool sandbox: unavailable on native Windows without WSL2, and not documented as covering
hook, MCP or LSP processes. There is no plugin-wide sandbox, and no Anthropic-operated vetted
registry or approval workflow.

**Admin controls that do exist**, all managed-settings keys:

| Key | Effect |
|---|---|
| `strictKnownMarketplaces` | Only listed marketplaces may be used |
| `extraKnownMarketplaces` | Provisions marketplaces; does not restrict others on its own |
| `blockedMarketplaces` | Explicit blocklist |
| `enabledPlugins` | `plugin@marketplace` to boolean. Managed `false` blocks installation and hides it |
| `disableSideloadFlags` | Rejects `--plugin-dir`, `--plugin-url`, `--agents`, `--mcp-config` |
| `disableCommandPluginSources` | Blocks command-source plugins |
| `disableSkillShellExecution` | Blocks inline shell in skills and custom commands |
| `allowedMcpServers`, `allowManagedMcpServersOnly` | Restricts MCP servers, including plugin-provided ones |

**P14's acceptance criterion is therefore restated** as two claims that can each be tested:

1. Claude Code — an approved plugin pinned to a commit sha or archive hash installs, and a
   modified one is refused on hash mismatch. Marketplaces outside the allowlist are rejected.
2. Claude Desktop — with `isDesktopExtensionSignatureRequired` set, a bundle signed by a trusted
   publisher installs and an unsigned one does not.

What must not be claimed is universal signed-plugin enforcement. It does not exist for Claude
Code, and a marketplace does not add verification — it is a distribution convenience, and the
same trust model applies to marketplace-delivered and locally installed plugins alike.

### U7 — Selective deletion of captured content — CLOSED 2026-09-03

**Question.** The Compliance API supports deleting specific records. If content capture lands
prompts and responses in Log Analytics, deleting one user's records on request is bounded by
what Log Analytics supports for purge, and by its latency and quota.

**Answer: yes, within limits that have to be written down rather than glossed.**

Azure Monitor's Purge operation is Microsoft's documented GDPR erasure mechanism, and it is a
real delete, not a hide: "Delete and purge operations are destructive and non-reversible"
([Manage personal data in Azure Monitor Logs](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/personal-data-mgmt),
retrieved 2026-09-03). It takes a per-column predicate, so one identified subject over a time
range is expressible.

The constraints are the part that matters, because they decide what may be promised.

| Constraint | Documented value |
|---|---|
| Purge requests | **50 per hour**. The scope of that limit — workspace, subscription or tenant — is not documented |
| Formal completion SLA | **30 days.** "There's no way to expedite the operation" |
| Tables per request | **One.** Content spread across five tables needs five requests |
| Table plans | Analytics only. "You can't purge data from tables that have the Basic and Auxiliary table plans" |
| Predicate operators | `==`, `=~`, `in`, `in~`, `>`, `>=`, `<`, `<=`, `between`. Not arbitrary KQL — no joins, regex or `contains` |
| Custom dimensions | Addressable through the filter's `key` property |
| Permission | `Microsoft.OperationalInsights/workspaces/purge/action`, from the **Data Purger** role (`150f5e0c-0603-4f03-8c7f-cf70034c4e90`) or Log Analytics Contributor |
| Sentinel data-lake mirrors | Cannot be selectively purged: "Specific records can't be purged from the Sentinel data lake" |
| Resource locks | A `CanNotDelete` lock does **not** prevent purge |
| Billing | Unaffected. "Deleting or purging data doesn't affect billing" |
| Eligible use | GDPR only. Microsoft "reserves the right to reject" other purge requests |

**What this rules out.** Any promise of deletion in hours or days. The Delete Data API is faster,
typically minutes, but it only marks rows deleted "without physically removing them from
storage", is limited to 10 requests per hour, and Microsoft points GDPR cases away from it: "If
you need to comply with GDPR requirements, use the Purge API."

**What it means for P15.** Microsoft's own first recommendation is not to capture the data:
filtering or pseudonymising at ingestion is "*by far* the best option". That is already this
repository's posture — content capture is opt-in behind `-CaptureContent` — and P15 should keep
it that way rather than making capture the default and deletion the remedy.

The design that follows:

1. Content capture stays opt-in, and off by default.
2. Capture into **one dedicated Analytics-plan table**, not scattered across Application Insights
   tables, so a deletion is one purge request rather than five.
3. Key rows on the Entra object id, which the gateway already emits, rather than on a UPN or
   email — Microsoft's advice is to log an internal identifier and keep the identity lookup
   somewhere separately deletable.
4. Document the 30-day SLA and the Basic/Auxiliary exclusion as constraints of the offering, not
   as footnotes.

**The wording P15 may use, and no stronger:** records in the designated Analytics-plan table can
be identified by subject id, purged with Microsoft's GDPR Purge operation per affected table, and
tracked to completion — subject to 50 purge requests per hour and a 30-day completion SLA with no
expedite. It does not cover Basic or Auxiliary tables, Sentinel data-lake mirrors, or exported
copies.

### U8 — OTEL attribute names behind the split productivity metrics

**Question.** Claude Code's OpenTelemetry export publishes
`claude_code.lines_of_code.count` and `claude_code.code_edit_tool.decision`
([monitoring reference](https://code.claude.com/docs/en/monitoring-usage), retrieved
2026-09-02). The Analytics API reports those split four ways — lines added, lines removed,
tools accepted, tools rejected. The attribute that carries the split, and its exact values, has
not been read from a live export because no OpenTelemetry collector is deployed in this
environment.

**Why it matters.** `analytics/claude-code-daily.kql` returns those four columns as null rather
than guessing an attribute name. A wrong guess would return zero, which reads as "nobody
rejected anything" instead of "not measured".

**How to close.** Deploy an OpenTelemetry collector against one Claude Code install, run one
session containing an accepted and a rejected edit, and read the attribute keys off the
exported metric. Then replace the four `real(null)` literals with `sumif` over the real
attribute.

---

## Closed

_(none yet)_
