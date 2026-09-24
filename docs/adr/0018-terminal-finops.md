# ADR-0018: Two terminal faces over one FinOps backend

- **Status:** Accepted
- **Date:** 2026-09-24
- **Packet:** CLI FinOps first release (owner-authorized parallel packet)
- **Deciders:** Platform owner

## Context

The owner explicitly commissioned this packet on the `claude-finops` worktree while P45
remains the lead worktree's active packet. The owner reserved STATUS, ROADMAP, CHANGELOG
and UNKNOWNS for the lead; this packet proposes those ledger changes in its delivery
report instead of modifying them. This reconciles the repository's single-packet and
same-packet ledger rules with the parallel assignment; no detector is relaxed.

The revision 4 design includes future approvals, boosts, bulk allocation and an assistant.
This release is bounded by the owner's enumerated Turnstile endpoints. Features without
that API contract are not represented as working controls.

## Decision

Use Textual and Typer over one backend interface: Turnstile HTTP, direct gateway through
the existing PowerShell scripts and analytics queries, and deterministic example data.
Keep token acquisition in memory through Azure CLI; configuration holds addresses only.
Members remain read-only even when a future server returns manager scopes. The server
always makes the authorization decision.

Changes default to a preview; an explicit apply is required. Show allocation headroom
separately from remaining usage. Follow apply jobs without treating a saved record as
proof of gateway enforcement. Never automatically retry a write.

## Evidence and unknowns before implementation

- DOCUMENTED: Repository ADR-0016 defines Owner and Member behavior; manager writes
  belong to a later packet.
- DOCUMENTED: `ClaudeTurnstileGovernance.ps1` maps units to organizations and teams
  to departments, and defines the quote-free integration named value.
- DOCUMENTED: The fork's `claude-gateway` models and HTTP routers are the API contract;
  compatibility tests pin the covered routes and response fields.
- INFERRED pending tests: A scoped manager response may grow fields. Preserve additional
  identity fields, fail closed for edits, and never perform client-side scope widening.
- INFERRED pending live reads: Server apply status demonstrates job completion, not
  exact budget counters; budgets remain delayed brakes, not invoice guarantees.

## Consequences

One set of validation and preview rules serves automation and the terminal. Direct mode
requires the repository scripts and Azure roles and cannot offer scoped manager access.
Future Turnstile pages require explicit parity review; the manifest distinguishes current
coverage from intentionally deferred endpoints.

## P46 scope compatibility follow-up, 2026-09-24

DOCUMENTED: The deployed Turnstile contract at `c0c345a` adds `manager_scope` to
`Profile` in `backend/http/authentication.py`. `manager_scope.py` defines its
organizations, departments and writable-department ids. Null is unrestricted;
an object, including empty lists, is scoped. `session.py::MANAGER_READ_ROUTES`
permits every first-release FinOps read endpoint; other protected views are denied.

The CLI therefore keeps all nine views for assigned managers, without inventing a
parent-unit filter. It hides data views for empty assignments and leaves Settings
and readable configuration. Context parent catalog rows are not authorized unit
lookup targets; scoped chargeback enumerates managed departments. Identity and
scope are refreshed before rendering, and changed scope discards cached tables.
HTTP 403 is a scope/permission denial, not zero usage or a sign-in expiry.
Members remain read-only even when writable ids are advertised. Owner manager-group
edits use the deployed `manager_group_id` attribute and an Entra object id.

## P52 amendment: AUM, dashboard and live publication, 2026-09-24

The owner commissioned P52 in the separate `aum` worktree while the lead owns the
main ledger and README. The product is now **AUM - Azure Usage Management**.
`aum` is the primary command; `claude-finops` remains a deprecated alias for one
release. Internal `cli/finops`, `claude_finops`, `.venv-finops` and the PowerShell
bridge stay compatible: renaming those adds migration risk without a user benefit.

The Overview changes from a metric table to a responsive, keyboard-focusable
dashboard. Its token gauges, trend, rankings, risks and anomalies all come from
existing APIs. Missing cost/forecast is unknown, never fabricated. The canonical
budget counter remains separate from estimated cost and parent allocation.
Catalog enforcement attributes display as strict/allowance/notify badges; an
absent attribute displays the gateway default, strict.

Display-time redaction replaces identities and deployment identifiers only in
rendered output, never in requests, authorization checks or write targets. Published
screenshots must come from live read-only backends with redaction on, with a
manifest and privacy guard. Fake data remains test evidence, not live evidence.
Existing Azure CLI/Owner rights are sufficient; no new consent or grant is sought.

Research sources (2026-09-24): `rothgar/awesome-tuis`, btop, bottom, k9s, lazygit,
WTF, Dolphie and Posting. Patterns and exact source links are recorded in the
delivery report. Their code/assets are not copied. Tests must preserve the P51
role, scope, preview, confirmation, headroom and apply-status guarantees.
