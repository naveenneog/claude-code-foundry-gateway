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
| Capability scoping per role — Chat, Cowork, Claude Code, web search, individual connectors | Desktop managed config (`chatTabEnabled`, `coworkTabEnabled`, `managedMcpServers`) plus the gateway model allowlist | Design — the keys exist; per-group delivery needs one MDM profile per tier, or a bootstrap server |
| Scoped admin permissions — Identity & Access, Billing, Analytics, Privacy, User Management, Libraries, Directory | Azure RBAC and Entra admin roles, each independently assignable | Have |
| Additive permission model | Azure RBAC is additive, with explicit deny assignments available | Have |
| Provisioning: SSO, domain capture, SCIM, JIT | Entra ID native | Have |

### Spend

| Claude Enterprise control | Azure equivalent | State |
|---|---|---|
| Org-wide monthly ceiling | No direct analogue. APIM quotas are per-principal per period; Cost Management budgets alert but do not block inference | **Gap — P11** |
| Group-level limits cascading under the org cap | Tier named values (`tpm-standard`, `quota-premium`, …) | Design — tiers exist, cascade under an org cap does not |
| Per-member limits | `llm-token-limit` keyed on `oid` | Have |
| Programmatic cost control — read effective limits and MTD spend, set and clear per-user overrides | APIM named values plus Application Insights, behind an admin surface | **Gap — P12** |

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
| Phased rollout by role | Per-group MDM profile, or a bootstrap server returning per-user configuration | Design — P13 |
| Plugin marketplace | A `marketplace.json` in git or over HTTPS, pinned to a revision | Design — P14 |

### Claude Code

| Claude Enterprise control | Azure equivalent | State |
|---|---|---|
| Managed policy settings across all clients | `managed-settings.json`, `HKLM\SOFTWARE\Policies\ClaudeCode`, macOS managed preferences | Have |
| Server-managed settings without MDM | The claude.ai console does not apply to a gateway deployment. A self-hosted Claude apps gateway delivers policy per IdP group | **U4** |

### Data and compliance

| Claude Enterprise control | Azure equivalent | State |
|---|---|---|
| Custom data retention | `cleanupPeriodDays`, `desktopSessionCleanupPeriodDays`, and Log Analytics retention | Have |
| Audit logs — admin actions, seat changes, connector approvals | Azure Activity Log and Entra audit logs | Have |
| Compliance API — activity, chat history and file content by user and time, with selective deletion | Conversations are on local disk in third-party mode. Retrieval requires OTLP content capture into the customer's own collector | **Gap — P15** |
| Analytics API | Gateway telemetry plus Claude Code OpenTelemetry | **Gap — P10** |
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

- [ ] P10 analytics equivalent — acceptance: a KQL function returns the Claude Code Analytics
      API field set for a given day, sourced from gateway telemetry and Claude Code OTEL, with
      `estimated_cost` labelled an estimate until U2 closes
- [ ] P11 org-wide monthly ceiling — acceptance: aggregate spend across all principals stops at
      the cap, verified live; tier limits still apply beneath it. U1 closed — a constant`n      counter-key is shared, so this sits in the request path
- [ ] P12 programmatic cost control — acceptance: read effective limits and month-to-date spend
      per user, and set or clear a per-user override, without editing named values by hand

### M2 — governance depth

- [ ] P13 per-group capability scoping — acceptance: two tiers receive different Chat, Cowork,
      Code and connector capability sets from policy alone. **Depends on U4**
- [ ] P14 plugin marketplace — acceptance: a pinned marketplace delivers a signed plugin to a
      managed desktop, and an unsigned one is refused. **Blocked on U6**

### M3 — compliance retrieval

- [ ] P15 compliance retrieval — acceptance: prompts and responses for a named user over a date
      range can be retrieved and selectively deleted, within Log Analytics purge limits.
      **Blocked on U7**

Explicitly out of scope for now: replicating the claude.ai admin console UI, and any attempt
to close the preview-feature gap. Both are recorded in `docs/CHARTER.md` as non-goals.
