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
- [ ] P14 plugin marketplace — the configuration half shipped as P36; what remains is the
      verification, which needs a real marketplace repository and a client machine: (a) an approved
      Claude Code plugin pinned to a commit sha or archive hash installs, a modified one is refused
      on hash mismatch, and a marketplace outside `strictKnownMarketplaces` is rejected; (b) with
      `isDesktopExtensionSignatureRequired` set, a signed `.mcpb` installs and an unsigned one does
      not. The original wording — signed plugin accepted, unsigned refused — is not implementable:
      Claude Code has no plugin signing scheme
- [x] P36 adding a model, and plugin governance — `Add-ClaudeModel.ps1` lists, deploys, allows,
      prices and retires a Claude model in one command, with the price book moved out of the code
      into `config/price-book.json` so a new model is not a code change. `New-ClaudeCodePolicy.ps1`
      now emits marketplace and extension controls for both clients — `strictKnownMarketplaces` for
      Claude Code, `allowedPluginMarketplaces`, `userPluginMarketplacesEnabled`,
      `userPluginUploadsEnabled` and `isDesktopExtensionSignatureRequired` for Claude Desktop — and
      writes the Desktop profile, which the script built and discarded before. Documented in
      [MODELS.md](MODELS.md) and [PLUGINS.md](PLUGINS.md), both stating that the plugin keys are
      feature-availability controls rather than data boundaries

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
      identities. **U10, ADR-0005**. 2026-09-24: continuation paging, absolute two-hour leases, miss
      admission and coalescing, and a private-only enterprise default are built and measured, and
      500,000 records were loaded and read ([ADR-0017](adr/0017-projection-freshness-and-admission.md)).
      Still open: `cos-default`, `cos-upgrade`, a scheduled Graph scan (**U17**), coalescing across
      instances, and sizing per deployment. 2026-09-26, P61: the installer offers the projection
      by SKU and developer count, and `Deploy-ClaudeProjection.ps1` is the one-command
      deploy-beside, populate, compare and flip for an existing operator (`cos-upgrade`); the
      default for new deployments stays named values below the ceiling (`cos-default` as a choice,
      not a flip)
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
- [x] P21 dollar budgets per business unit — acceptance: spend computed from categorised usage, not
      a single token total. Output is five times input and a cache read is a tenth of it, so one
      counter cannot represent money.
      **Delivered by P59 (merged 2026-09-26).** Dollar definitions with a pinned price book; a
      Decimal reconciler that prices input, output, cache-read and both cache-write categories and
      refuses unpriced models; scoped gateway stops in the strict, allowance and notify modes, a
      distinct 403 and a 503 on stale state; measured live on an isolated Basic v2 gateway.
      [ADR-0026](adr/0026-usd-budget-reconciliation.md), `docs/BUDGETS.md`. Enforcement trails usage
      by log ingestion and the reconcile interval; it is not a hard invoice cap. Open: streaming
      cache-creation detail without buffering the stream (**U13**), invoice parity (**U2**), dollar
      budgets in the AUM terminal (P62)
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
- [x] P25 delayed kill switch — the overshoot bound is measured rather than asserted.
      `scripts/Measure-ClaudeOvershoot.ps1` reports it from the live deployment: telemetry lag
      worst 193s and median 87s over 102 requests, read from `ingestion_time()` rather than polled;
      named-value propagation 17s, observed through a gateway response header rather than by
      reading the value back from ARM; plus whatever job interval you choose. On the reference
      deployment with a 300s job that is a **511s window**, and in-flight requests on top. It is
      not called a hard cap, because a hard cap needs admission-time reservation that the quota
      policies do not offer
- [x] P39 Turnstile as the FinOps console — units, teams and budgets synced from the gateway, every
      request and hour of cache reads exported and accepted exactly by Turnstile's own ingest code,
      budgets optionally edited in Turnstile and enforced by the gateway, admin-only through
      Microsoft Entra. [TURNSTILE.md](TURNSTILE.md)
- [x] P40 scheduled export and sync — an hourly Container Apps job running as a managed identity
      with no secret. Run live: a pass sent usage, a changed budget reached Turnstile attributed to
      the job's identity, and removing its Event Hubs grant made the next run fail with 401
- [x] P41 upstream the fork — the four branches of naveenneog/turnstile offered to
      xuleihive/turnstile as draft pull requests #25 to #28, each with its tests, mutations and
      live evidence
- [ ] P42 the AI Gateway tier — acceptance: Claude Code, the VS Code extension and Claude Desktop
      through an AI Gateway tier instance, its cost limit refusing a request with
      `LlmCostQuotaExceeded`, and the hybrid behind this gateway measured. Blocked by U16: the
      instance deployed but served no model route. [AI-GATEWAY-TIER.md](AI-GATEWAY-TIER.md)
- [x] P43 nothing about one deployment in the code — every `-ResourceGroup` default comes from the
      environment or from what the installer recorded; a guard test fails when a literal is put back
- [x] P44 governance authored in Turnstile — business units, teams, their Entra groups, budgets and
      tier limits edited on Turnstile's pages, each save starting the gateway's apply job. Run live:
      a tier limit saved on the page reached the gateway in 112 s, and a budget saved in Turnstile
      refused the next request 123 s after the save. New groups and membership refresh wait on
      U17. [ADR-0015](adr/0015-governance-authored-in-turnstile.md)
- [x] P45 delegated management, phase 1 — viewer and manager app roles, created as the app's
      owner; admins sign in as Owner, viewers and managers read-only, developers never; a browser
      sign-in through the Azure CLI that needs no consent. Run live: the link opened a session in
      13.4 s, and the same link again returned 401. [ADR-0016](adr/0016-delegated-management.md)
- [x] P46 delegated management, phase 2 — a manager sees and manages only the units and teams
      whose manager group is in their token (fork `c0c345a`), proven live with a manager-only
      token on 2026-09-25 (P53); allocation within their own headroom; per unit or team, the
      admin's enforcement mode, strict, allowance or notify, enforced by the gateway, live-tested
      and restored ([ADR-0019](adr/0019-budget-enforcement-modes.md)), with a guard that rechecks
      Turnstile's revisions before an apply writes
- [ ] P47 delegated management, phase 3 — acceptance: budget requests that go to the manager one
      level up, boosts with an expiry, escalation, notifications at the warning threshold.
      Delivered **for the AUM service** (P55): requests, approve, reject, escalate, and boosts
      whose expiry a timer reverts, proven live. Open: the same endpoints in Turnstile, and
      delivering the warning notifications by email
- [ ] P48 delegated management at 500,000 — acceptance: overrides and unit and team budgets in the
      projection, one queue-driven writer instead of a job run per save, usage sent hourly per
      person and model, access packages for joining a team
- [ ] P49 network profiles — acceptance: one parameter chooses private (private endpoints for
      every component) or public (Entra-only access, no private endpoints or DNS zones), for the
      gateway, the projection and Turnstile, each priced by the bill-of-materials scripts.
      Delivered **for the gateway's ingress** by P54. Open: the projection, Turnstile, PostgreSQL
      and the scheduled jobs
- [x] P50 chargeback reports — one command writes each business unit's monthly report (people,
      requests, every token kind, estimated cost, budget against use), reconciled to the month's
      total through an explicit unassigned line; recipients per unit and for the admin team are
      set by script, limited to allowed domains; a private scheduled job archives each run and
      emails each unit its own report. Live on 2026-09-24: both months' reports reached the
      owner's inbox. [ADR-0020](adr/0020-chargeback-reports.md), `docs/CHARGEBACK-REPORTS.md`.
      Follow-ups: a verified custom sender domain for broad delivery (an Azure-managed domain
      sends 10 an hour), team-level recipients, `aum report`, recipients from the Turnstile catalog
- [x] P53 Turnstile, tested and captured live — every Turnstile picture recaptured live with a
      provenance record; the consent-free sign-in, a tier change and a budget mode made in the UI
      and read on the gateway, then restored; and the live manager-only journey (2026-09-25),
      scoped to one unit, with admin routes refused and everything restored. Open: viewer-only
      evidence
- [x] P54 the enterprise network — a regional Application Gateway WAF_v2 as the gateway's only
      ingress (internal, internet or hybrid listeners) with private origins; every choice
      discovered, priced from the retail price list and stated with its implications, then one
      frozen review, including the identities that may lose access, confirmed before any write.
      Streaming, timeouts, body size, WAF on code and client-address trust measured live; the
      evaluation removed. [ADR-0022](adr/0022-enterprise-network-edge.md),
      `docs/NETWORK-ENTERPRISE.md`. Its 24 portal pictures were captured live on 2026-09-25 from
      a short-lived isolated copy of the evaluation estate, then removed. Open: Front Door, hub
      routing and corporate egress as tested automation; callers' existing private routes (**U22**)
- [x] P55 the AUM service — an optional authority independent of Turnstile: its own Entra app
      roles with consent-free tokens, scoped managers, audited conditional named-value writes,
      and P47's requests and boosts; discovery-first deployment with cost and implications, and a
      FinOps tooling selector. [ADR-0023](adr/0023-aum-service.md), `docs/AUM-SERVICE.md`.
      Real Claude enforcement in all three modes and a Manager-only proof ran live through the
      service on an isolated gateway (2026-09-25), then everything was restored and retired.
      Open: the AUM client (P52) driving the service end to end, the Users and groups picture (the
      next Entra step-up) and the Function and storage pictures (a deployed service); the four
      registration pictures were captured live on 2026-09-25
- [x] P57 documentation review — eight reader journeys walked with the guides alone; 70
      findings fixed, five task guides added (Operations, Budgets, FinOps, Reference, Data
      governance), README from 710 to 278 lines, live names replaced by discovery commands, and
      `tests/Test-DocReferences.ps1` guarding links, anchors, scripts and parameters. Its portal
      walkthrough pictures were captured live on 2026-09-25 by the lead's batch
- [x] P58 architecture after every feature — ten diagrams from text sources under
      `docs/architecture/`, rendered by one command with a hash manifest; `docs/ARCHITECTURE.md`
      rewritten around them; an `AGENTS.md` rule that every feature packet updates its diagram;
      and `tests/Test-Architecture.ps1` failing on drift, stale labels, or an Azure resource type
      in no diagram. Open: the AUM diagram from its packet; the enterprise network's three
      topologies arrived with P54
- [x] P51 terminal FinOps, first release — `claude-finops`, nine terminal views and scriptable
      commands over one engine, backed by Turnstile, the gateway directly, or example data. Budget
      changes are previewed, rechecked against the server and never retried. Managers see only
      their scope and read only; a 403 says "Not in your scope". The owner's command and terminal
      journeys agreed live on identity, budgets, catalog, tiers, month totals and 200 request ids,
      with no live writes. [ADR-0018](adr/0018-terminal-finops.md), `docs/CLI-FINOPS.md`.
      Follow-ups: saved views, comparison charts and in-terminal profiles; a request cursor (the
      API stops at 200); conditional catalog and tier writes; P47's requests and boosts; a live
      scoped-manager journey (**U20**)
- [x] P52 AUM (Azure Usage Management) — `claude-finops` renamed `aum` (the old command still
      works): one engine behind a dashboard and scriptable commands, backed by Turnstile, the
      gateway directly, the AUM service or example data, so it does not need Turnstile. Owned
      Entra groups, budgets and all three modes enforced on real requests, then a byte-exact
      restore, measured live through Direct and Turnstile on 2026-09-25. `docs/AUM.md`,
      [ADR-0018](adr/0018-terminal-finops.md). Open: a mutation journey through a deployed AUM
      service; the server endpoints for approvals, boosts, notifications, conditional writes,
      anomaly dispositions, request paging and global search (clients built and hidden until
      advertised); full-directory scale (**U20**)
- [x] P56 a parallel test suite — `tests/Test-All.ps1` runs checks in separate `pwsh` processes,
      at most four at a time, with an exclusive lane for checks that share Azure CLI state or scan
      the whole tree, logs printed in registration order, one result slot per registration, a
      per-check deadline (600 s by default) and the same completion guard and SKIP counting. The
      business-unit and Turnstile mutation harnesses run as four and two shards, and a new check
      proves the shards cover exactly the 476 and 108 mutations, in order. Three busy full runs:
      927.2, 830.6 and 790.0 s, against 1,829 s serially; the gate's command budget is back to
      1,800 s. [ADR-0025](adr/0025-parallel-test-suite.md)
- [x] P60 Claude Desktop sign-in, chosen by the admin — acceptance: the installer offers Desktop's
      credential kinds that work with this gateway (the Azure CLI credential helper, today's only
      option; Desktop's own sign-in through an Entra app registration, in the system browser or
      the Entra broker), each with what it needs (app registration, consent, Conditional Access,
      the audience the gateway must accept) and implies; the choice is recorded in
      `claude-gateway.json` and the developer scripts and MDM payloads write exactly the matching
      Desktop keys; a helper-script install is unchanged; the token path is proven live on an
      isolated gateway. **Merged 2026-09-26**: `desktopSignIn`, one validator/renderer for the
      scripts and MDM, the gateway audience only through `external-idp-extra-audience`, and
      `New-ClaudeDesktopEntraApp.ps1`; live: helper token 200, wrong audience 401.
      [ADR-0027](adr/0027-claude-desktop-sign-in-choice.md). Open: Desktop's own sign-in end to
      end, which needs tenant consent (**U23**); the app-registration portal pictures
- [x] P61 the Cosmos entitlement store as an installer choice, including Basic v2 — acceptance:
      for 100-500 developers, which named values cannot hold (about 93), the installer offers the
      projection by SKU: private on Standard v2 and Premium v2; on Basic v2 through a resolver with
      a public, Entra-authenticated endpoint in front of a private Cosmos account, with the risk and
      the cost at 100 and 500 developers stated; one command deploys, populates from Entra,
      compares against the lists and flips only after a clean comparison; proven live on an
      isolated Basic v2 gateway and removed. **Merged 2026-09-26**: `Deploy-ClaudeProjection.ps1`;
      live: unauthenticated resolver call 401, count-tokens 200 after the flip, 500 synthetic
      records. [ADR-0028](adr/0028-basic-v2-projection-resolver.md). Open: **U25**, **U18**
- [ ] P62 dollar budgets in AUM — acceptance: AUM lists, sets, raises and clears dollar budgets
      and shows reconciled spend with its completeness flags, through the AUM service's contract
      (`docs/aum-usd-budgets-client-contract.md`) and the Direct backend's shared USD writer,
      refused while Turnstile owns budgets; proven live through AUM on an isolated gateway (a stop,
      then a raise that lifts it)
- [ ] P63 split the five files over the size budget — the gate's `quality.filesize` warning:
      `tests/Test-BusinessUnitsNegative.ps1` (3,208 lines, budget 800),
      `tests/Test-AdminSurface.ps1` (1,348), `Install-ClaudeGateway.ps1` (1,254, budget 700),
      `scripts/Test-FoundryDirect.ps1` (942) and `scripts/Setup-ClaudeFoundryDirect.ps1` (866);
      split by responsibility, with every assertion and mutation kept
- [x] P64 add and remove developers from AUM by email — acceptance: AUM searches the whole Entra
      directory while an administrator types an email, UPN or name (guests included), adds a
      person to a discovered tier group and optionally a unit or team group, removes them from
      every tier and unit group, publishes to the gateway, and uses only the administrator's own
      rights; `Set-ClaudeDeveloper.ps1` discovers the tier groups instead of fixed names; proven
      live on an isolated gateway (200 after adding, refused after removal). Turnstile does not
      change Entra membership: that needs a Microsoft Graph permission only a tenant
      administrator can grant (**U17**, **U19**). **Merged 2026-09-26**: live 200 after add, 403
      after remove. [ADR-0029](adr/0029-aum-developer-membership.md). Open: full-email `$search`
      behaviour (**U24**), publication on a projection-backed gateway (**U25**)
- [x] P65 fleet deployment with Intune, Jamf or Group Policy — acceptance: step-by-step device
      delivery of Claude Code, the VS Code extension and Claude Desktop (software, managed
      settings including the Desktop sign-in choice, optional CA/proxy), per-tier profiles from
      `New-ClaudeCodePolicy.ps1`, Intune on Windows and macOS with the portal path for each step,
      Jamf Pro and Group Policy alternatives, device verification and troubleshooting.
      **Merged 2026-09-26**: `docs/MDM.md`; the generated profile drove a real request through
      the gateway; the Intune detection script runs under Windows PowerShell 5.1. Open: Intune
      admin center pictures, which need an Intune administrator role this tenant does not grant
      the owner
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
