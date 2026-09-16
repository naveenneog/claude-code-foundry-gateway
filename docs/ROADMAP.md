# Roadmap — Claude Enterprise parity on Azure

Milestones are ordered by what a customer is blocked on, not by difficulty.

- **M0** shipped — the governed gateway, three clients, migration and MDM. Done.
- **M1** closes the two gaps a customer notices first: spend ceilings and analytics.
- **M2** closes governance depth: role-scoped capability, connectors, plugins.
- **M3** covers compliance retrieval, which is the largest single piece and depends on a
  decision recorded in an ADR before any code.

---

## Parity matrix

Legend: **Have** — shipped in M0 · **Design** — achievable with the components already in
play · **Gap** — needs a decision or new component · **N/A** — no Azure analogue, or the
premise does not carry over.

### People and roles

| Claude Enterprise control | Azure equivalent | State |
|---|---|---|
| Built-in roles: Primary Owner, Owner, Admin, User | Azure RBAC roles on the subscription and resource group; Entra directory roles | Design — no single-holder "Primary Owner"; nearest is a PIM-eligible Owner assignment |
| Add, invite, deactivate members | Entra user lifecycle | Have — and richer than the first-party equivalent |
| Billing access restricted to Owners | `Billing Reader` / Cost Management roles, separate from resource RBAC | Have |
| Custom roles | Entra custom roles and Azure custom RBAC role definitions | Have |
| Capability scoping per role — Chat, Cowork, Claude Code, web search, individual connectors | Models: `models-standard` / `models-premium`, enforced at the gateway. Tabs and connectors: `New-ClaudeCodePolicy.ps1 -Tier`, delivered per tier by MDM | Have — P13. Models are a control; the rest are management controls, ADR-0004 |
| Scoped admin permissions — Identity & Access, Billing, Analytics, Privacy, User Management, Libraries, Directory | Azure RBAC and Entra admin roles, each independently assignable | Have |
| Additive permission model | Azure RBAC is additive, with explicit deny assignments available | Have |
| Provisioning: SSO, domain capture, SCIM, JIT | Entra ID native | Have |

### Spend

| Claude Enterprise control | Azure equivalent | State |
|---|---|---|
| Org-wide monthly ceiling | `llm-token-limit` on a constant counter-key, `quota-org`, monthly. Verified shared across callers | Have — P11. Soft cap |
| Group-level limits cascading under the org cap | Tier named values (`tpm-standard`, `quota-premium`, …) checked after the org ceiling | Have — P11 |
| Per-member limits | `llm-token-limit` keyed on `oid`, with `quota-overrides` per developer | Have — P12 |
| Nothing bypasses the ceiling | `scripts/Get-ClaudeBypass.ps1` finds principals with data-plane access directly on the Foundry account, which skip every control here | Have — P16 |
| Programmatic cost control — read effective limits and MTD spend, set and clear per-user overrides | `scripts/Get-ClaudeBudget.ps1` and `scripts/Set-ClaudeBudget.ps1` over APIM named values and Application Insights | Have — P12 |

### Models and features

| Claude Enterprise control | Azure equivalent | State |
|---|---|---|
| Enable or disable models org-wide | Foundry deployments, the gateway allowlist, and `availableModels` + `enforceAvailableModels` in managed settings | Have |
| Claude in Chrome controls | No third-party analogue confirmed | **U3** |

### Connectors and MCP

| Claude Enterprise control | Azure equivalent | State |
|---|---|---|
| Allow or block connectors | `managedMcpServers` with per-tool `toolPolicy` of allow / ask / blocked | Have |
| Managed authorization, identity inherited from groups | Connector OAuth against Entra, or `headersHelper` for short-lived tokens | Have |
| MCP allowlist | `managedMcpServers` plus `isLocalDevMcpEnabled: false` | Have |
| Phased rollout by role | Per-tier MDM profile from `New-ClaudeCodePolicy.ps1 -Tier` | Have — P13 |
| Plugin marketplace | A `marketplace.json` in git or over HTTPS. Plugins pin to a commit sha or archive `sha256`; the catalog itself pins only to a branch or tag. No publisher signing for Claude Code plugins; `.mcpb` desktop bundles are the exception | Design — P14, rescoped by U6 |

### Claude Code

| Claude Enterprise control | Azure equivalent | State |
|---|---|---|
| Managed policy settings across all clients | `managed-settings.json`, `HKLM\SOFTWARE\Policies\ClaudeCode`, macOS managed preferences | Have |
| Server-managed settings without MDM | A self-hosted Claude apps gateway delivers policy per IdP group and supports a Foundry upstream, but it replaces the request path and its shared credential removes per-developer attribution. Anthropic's own hosted server-managed settings are org-wide only — "per-group configurations are not yet supported" — and are skipped for third-party providers | N/A by decision — ADR-0004, U4 closed |

### Data and compliance

| Claude Enterprise control | Azure equivalent | State |
|---|---|---|
| Custom data retention | `cleanupPeriodDays`, `desktopSessionCleanupPeriodDays`, and Log Analytics retention | Have |
| Audit logs — admin actions, seat changes, connector approvals | Azure Activity Log and Entra audit logs | Have |
| Compliance API — activity, chat history and file content by user and time, with selective deletion | `scripts/Find-ClaudeUserData.ps1` finds records by subject and window; `scripts/Remove-ClaudeUserData.ps1` purges them per table with Azure Monitor's GDPR Purge operation | Have — P15, within a 30-day SLA and Analytics-plan tables only |
| Analytics API | Anthropic's API does not cover Foundry at all. Replaced by `analytics/claude-code-daily.kql` and `scripts/Get-ClaudeAnalytics.ps1`, which emit the same field set from gateway telemetry | Have — P10 |
| Customer-managed encryption keys | CMEK on Foundry, Log Analytics and Storage | Design |
| US-only inference, ~10% surcharge | Region selection at deployment, no surcharge | Have — and cheaper |
| HIPAA-ready with BAA | Covered by the Azure BAA | Have |
| Model training off by default | Foundry does not train on customer inference data | Have |

---

## Packets

M0 is shipped. The table below is the queue; the checklist under it is what the gate tracks.

| Packet | Milestone | Deliverable | Depends on |
|---|---|---|---|
| P10 | M1 | Analytics equivalent: Claude Code OTEL into Log Analytics, a documented schema, and a query surface matching the Claude Code Analytics API fields | ADR-0002 |
| P11 | M1 | Org-wide monthly spend ceiling enforced at the gateway, with tier limits cascading under it | U1 closed |
| P12 | M1 | Admin surface to read effective limits and month-to-date spend, and to set or clear a per-user override | P11 |
| P13 | M2 | Per-group capability scoping: one policy profile per tier, covering Chat, Cowork, Code and connectors | — |
| P14 | M2 | Plugin marketplace: a template repository, a signing and review path, and the managed configuration to pin it | U6 |
| P15 | M3 | Compliance retrieval: content capture to the customer's collector, retrieval by user and time, and selective deletion | ADR pending, U7 |

### M0 — shipped

- [x] P1 governed gateway: APIM v2, tiered `llm-token-limit` keyed on Entra `oid`
- [x] P2 entitlement: Entra groups synced to APIM named values
- [x] P3 three clients: Claude Code CLI, VS Code extension, Claude Desktop with Cowork
- [x] P4 interactive installer, reusing an existing v2 instance rather than creating a second
- [x] P5 fleet policy: managed settings for Claude Code and Desktop, with Intune, GPO and Jamf payloads
- [x] P6 migration: import from claude.ai, bulk entitlement from CSV or an Entra group
- [x] P7 documentation: setup, onboarding, monitoring, debug, migration, comparison
- [x] P-0 Ironclad adopted — charter, gate, ledger, ADR-0001

### M1 — spend and analytics

- [x] P10 analytics equivalent — `analytics/claude-code-daily.kql` returns the Claude Code
      Analytics API field set for a given day, and `scripts/Get-ClaudeAnalytics.ps1` emits it in
      that API's response shape. Verified live: 19 rows regrouped into 13 records, 167,713 input
      tokens, 22 sessions, 2 callers. `estimated_cost` carries `is_estimate` until U2 closes; the
      four OTEL-only productivity fields are null until U8 closes
- [x] P11 org-wide monthly ceiling — a constant-keyed `llm-token-limit` reading `quota-org`,
      checked before the per-tier budgets, with tier limits still applying beneath it. Verified
      live: exhausting the org budget refuses with `"budget": "organisation"`, exhausting a
      personal budget refuses with `"budget": "personal"`, and raising either restores service
      immediately. Soft cap — high-concurrency requests can temporarily exceed it
- [x] P12 programmatic cost control — `scripts/Get-ClaudeBudget.ps1` reports effective limits and
      month-to-date spend per developer, `scripts/Set-ClaudeBudget.ps1` sets and clears a per-user
      daily override without editing named values by hand. Verified live: an override changes what
      the gateway applies on the next request, clearing it restores the tier default, and another
      developer's override survives both

### M2 — governance depth

- [x] P13 per-group capability scoping — models are restricted per tier at the gateway, verified
      live: a model outside the tier's list is refused before Foundry is called, one inside it
      still works, and a longer name sharing a prefix does not slip through. Chat, Cowork, Code
      and connectors ship as per-tier managed settings from `New-ClaudeCodePolicy.ps1 -Tier`, and
      are documented as management controls rather than security boundaries. U4 closed, ADR-0004
- [ ] P14 plugin marketplace — acceptance, restated after U6 closed: (a) an approved Claude Code
      plugin pinned to a commit sha or archive hash installs, a modified one is refused on hash
      mismatch, and a marketplace outside `strictKnownMarketplaces` is rejected; (b) with
      `isDesktopExtensionSignatureRequired` set, a signed `.mcpb` installs and an unsigned one does
      not. The original wording — signed plugin accepted, unsigned refused — is not implementable:
      Claude Code has no plugin signing scheme

### M4 — business-unit chargeback

Three measurements reframed this milestone. Custom metric dimensions cap at 100 unique values and
the namespace at 1,000 time series, after which data is "silently discarded". Named values cap at
4,096 characters, so an allow list holds about 110 object ids. And the sync swallowed the resulting
error. Together they made the accelerator a roughly 100-developer system, which is below the scale
at which chargeback is a question worth asking.

Azure-native allocation was considered and ruled out on evidence: Claude bills as a single
aggregated Claude Consumption Unit meter with no per-user or per-model split, Cost Allocation rules
redistribute by fixed percentages rather than actual usage, and Azure Budgets cannot block —
"resources aren't affected, and your consumption isn't stopped". Microsoft's own Architecture Centre
guidance is to capture a business-unit identifier at a gateway, which is what this does.

- [x] P17 named value writes fail loudly — a shared helper refuses an oversized value before the
      call and throws on a failed one, so a tier that outgrows a named value stops the sync instead
      of silently freezing entitlement. Covers the governance demo's restore path too
- [x] P18 scale the chargeback ledger — `analytics/chargeback-ledger.kql` over the built-in
      `ApiManagementGatewayLlmLog`, joined to identity by a trace the gateway emits. A log rather
      than a metric, so no cardinality cap, and correct for streamed requests where the quota scalar
      reports 11 tokens for a 41-token completion. Cache is recorded as null with
      `cache_tokens_known = false`, and a test fails if it ever becomes zero. **U12 closed**, and
      the acceptance wording changed: pricing from the response body was rejected because reading it
      in outbound buffers the response and ends streaming. ADR-0006
- [x] P18b load envelope — `docs/SCALE.md` states the measured ceilings and the five numbers a
      capacity figure needs, and `scripts/Measure-ClaudeCeiling.ps1` reports a live gateway's
      headroom against them, exiting non-zero past a threshold. Measured on BasicV2: a named value
      holds 4,096 characters (4,097 is rejected) and 110 object ids (111 is rejected). The traffic
      half is deliberately not filled in — the reference deployment holds 111 requests across 2
      days, which is not a traffic model. **U9 still open**
- [ ] P19 scale identity resolution — acceptance: a durable entitlement projection synced from Graph
      off the request path, with a written failure contract for stale, unknown and revoked
      identities. **U10, ADR-0005**
- [x] P19b shadow migration — the sequence is settled in
      [ADR-0009](adr/0009-shadow-migration.md): five phases, authorization unchanged until the
      canary at phase 4, counter keys and period boundaries preserved throughout, and a rollback
      that restores authorization without restoring consumption. Phase 2's comparison ships as
      `Compare-ClaudeEntitlement.ps1`, which resolves every identity from the gateway and from the
      directory using the policy's own premium-before-standard precedence and exits non-zero on
      disagreement. Negative-tested against the reference deployment: removing an identity from its
      group without syncing produced `stale (1)` and exit 1, and re-adding it returned it to clean.
      The mid-period opening balance is deferred to P20b rather than decided here
- [x] P20 business-unit identity model — a stable identifier separate from display name, settled in
      [ADR-0007](adr/0007-business-unit-model.md). A business unit is an Entra group plus a budget;
      transfer is group membership, deletion returns members to `unassigned`, and a developer in two
      business-unit groups takes the first in registry order
- [x] P20b financial semantics — settled in [ADR-0010](adr/0010-financial-semantics.md): an
      internal tariff at list price rather than actual Azure cost, because the CCU meter carries no
      per-user or per-model split and private-offer discounts apply before conversion; all five
      token categories billable at their measured multipliers and never summed before pricing;
      pricing joined on the deployment rather than the client's model alias; decimal arithmetic
      rounded once at presentation; a price book versioned by effective interval so a price change
      cannot rewrite history; UTC periods; an append-only ledger where corrections are new rows; and
      "soft cap" stated to mean approximate blocking rather than warn-only. The implementation was
      moved from `[double]` to `[decimal]` to match. **U2** still blocks actual-cost chargeback
- [ ] P21 dollar budgets per business unit — acceptance: spend computed from categorised usage, not
      a single token total. Output is five times input and a cache read is a tenth of it, so one
      counter cannot represent money.
      **Partly shipped, and the gap is the acceptance criterion.** The admin surface takes dollars
      and `Get-ClaudeBusinessUnit` reports categorised spend from the ledger, but enforcement
      converts dollars to one blended token figure at write time and runs a single
      `llm-token-limit`. Measured on thirty days of live usage, that counter is blind to 38.7% of
      real cost weight because it counts prompt and completion only. Closing this needs categorised
      enforcement, which APIM cannot express today — see **U13**
- [x] P22 business-unit soft cap — a unit that exhausts its budget is refused with a fourth, distinct
      `403` naming the unit, others are unaffected, and an unpriced unit is skipped rather than
      walled off
- [x] P20c teams and tiers — a team is a unit with a parent, charged to itself and to the unit above
      it; tier is a separate axis attached by nesting the team group inside the tier group. Depth is
      capped at two and cycles refused at write time. [ADR-0008](adr/0008-teams-and-tiers.md)
- [x] P26 model discovery at install — `Install-ClaudeGateway.ps1` lists Claude deployments with
      SKU and capacity, lets the operator pick which models each tier may call, and offers to create
      a deployment when the account has none. Quota failures are named separately from other errors
- [x] P24 dashboard — an Azure Workbook, published by `Publish-ClaudeWorkbook.ps1` over saved KQL
      functions. Neither stores nor runs anything, so no always-on component was added. Grafana
      remains optional and unbuilt
- [x] P27 per-surface telemetry — the gateway captures the caller's `User-Agent` and the ledger
      parses the surface from it, so Claude Code, the VS Code extension, Desktop and the SDKs are
      separable. Measured rather than assumed: Claude Code 2.1.241 sends `(external, sdk-cli)`
- [x] P28 bill of materials and flow diagram — acceptance: one picture of the six-hop request and
      telemetry path naming the Azure resources actually used
- [ ] P23 showback reporting — acceptance: as-of joins against effective-dated mapping history, so a
      mid-month transfer does not move last week's spend
- [ ] P25 delayed kill switch — acceptance: the overshoot bound is stated and measured. Not a hard
      cap, and not described as one
### M3 — compliance retrieval
- [x] P15 compliance retrieval — `scripts/Find-ClaudeUserData.ps1` reports what the gateway's
      telemetry holds about one person, per table, reading each table's plan from the workspace so
      it states what is actually deletable rather than assuming. `scripts/Remove-ClaudeUserData.ps1`
      purges it, one request per table, and does nothing without `-Execute`. Bounded by what U7
      measured: 50 purge requests an hour, a 30-day completion SLA with no expedite, and
      Analytics-plan tables only

Explicitly out of scope for now: replicating the claude.ai admin console UI, and any attempt
to close the preview-feature gap. Both are recorded in `docs/CHARTER.md` as non-goals.


- [x] P16 close the bypass — `scripts/Get-ClaudeBypass.ps1` lists every principal that can reach
      Foundry without passing through the gateway, deriving the roles from their `dataActions`
      rather than a name and including inherited assignments. Measured on the reference deployment:
      the documented one-role hand check reported clean while 11 assignments could call Foundry
      directly, three of them through `Foundry User`
- [x] P29 backup and restore — gateway configuration, Claude Code history and Claude Desktop
      conversations, with a developer-side tool that wraps all three. Secrets absent by
      construction; restores are dry runs; a running Desktop is refused
- [x] P30 SKU sizing at install — the installer asks how many developers and sizes on published
      included request volume, naming VNet and availability zones as the real decider
- [x] P31 the Entra group must exist — a business unit pointing at a missing group syncs to nobody
      and reads as unused rather than broken, so the write is refused with near matches offered
- [x] P32 tier limits — `Set-ClaudeTier.ps1` reads and sets tokens per minute, the daily quota and
      the model allow list, checking models against what the account serves. A third tier remains a
      policy change, stated rather than implied
- [x] P33 add or remove one developer — acceptance: a single command with confirmation and an audit
      line, rather than only the bulk sync and CSV import
- [x] P34 optional Grafana — only if a customer requires Grafana by name; it is the one
      observability option with a standing bill
- [x] P35 workload identities in a tier group — acceptance: the request form is measured rather
      than assumed, and the fix is proven by a membership count changing on the live gateway.
      A build agent or scheduled job authenticates as a service principal and needs entitlement
      the same way a developer does
