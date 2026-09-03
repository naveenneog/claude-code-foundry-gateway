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