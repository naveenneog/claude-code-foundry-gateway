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

## P52 amendment: full revision-4 acceptance, 2026-09-25

The owner's subsequent instruction explicitly supersedes this ADR's bounded-release
scope and read-only-manager decision above. Implement every supported revision-4
row in both faces. The deployed P46 `writable_department_ids` contract now permits
manager team/person budget forms only for authorized objects; units, modes, tiers,
catalog and explicit gateway apply remain Owner-only.

Use the existing assistant API and optional model-gateway reads rather than a
second assistant or model registry. Server-authored charts are displayed and pinned
without client-invented data. Ask can incur model cost and persist conversations,
so preview and redacted capture modes never submit a question.

Approvals, expiring boosts, notifications, lossless request cursors, conditional
collection writes, anomaly dispositions and global search need named server
contracts. The packaged `contracts.json` pins those contracts. Their tested clients
remain hidden until a schema-versioned, role-aware advertisement enables the action;
unknown versions and malformed advertisements fail closed. Server authorization is
still authoritative. No automatic write retry or client-side scope widening is added.

Saved views and the first-run tour are private to a hashed identity/profile pair.
Changing profile verifies the prospective sign-in before replacing the working
backend. Changing identity, month or filters discards bound cursors and stale context.
Ledger links use discovered workspace/tenant values and never deployment defaults.

P50 report generation delegates to the repository generator when installed; AUM
does not duplicate report accounting or storage logic. The parity manifest records
implementation tests and named server dependencies separately from live acceptance.
Live portal evidence is not complete while the capture profile requires sign-in:
that fact remains a failing publication check, not an exception or silent skip.

## P52 amendment: independent AUM and optional service authority, 2026-09-25

The owner explicitly requires AUM to operate without Turnstile. Direct is the
default when no HTTP profile is configured; a saved Turnstile profile remains an
explicit supported choice. Direct uses Azure RBAC and never claims unit-level
authorization. Scoped managers/viewers require either the separate optional AUM
service or Turnstile; one capability model normalizes their different contracts.

Direct people are observed ledger identities, not a downloaded directory. Search,
grouping and paging occur in KQL. Hourly request/token trends come from the request
ledger; daily cost is not distributed into fabricated hourly prices. Direct anomaly
findings are statistical candidates computed by Azure Monitor KQL, with method,
pricing exclusions and ingestion limits displayed.

Gateway person overrides are daily, while unit/team budgets are monthly. Keep
these periods explicit; never compare or sum daily limits as monthly allocations.
Reuse `Set-ClaudeBudget.ps1` and a shared strict override serializer, rejecting
malformed maps instead of silently dropping another person's entry.

Multi-value Direct writes use optimistic preflight, the existing writers, complete
read-back and reverse compensation. Restore exact prior values (or prior absence)
after later failure, but never overwrite a third-party value that differs from both
the observed before and expected after. Failed/unverifiable compensation requires
manual recovery; this is not represented as an atomic distributed transaction.

DOCUMENTED: Microsoft Learn `series_decompose_anomalies()` supports Azure Monitor,
numeric make-series input, a configurable residual threshold, integer seasonal
period and `linefit` trend. The Direct implementation uses threshold 3, weekly
seasonality and at least 14 active priced days; unknown prices are not zeroed.
Source verified 2026-09-25:
https://learn.microsoft.com/kusto/query/series-decompose-anomalies-function

DOCUMENTED: P55's published AUM service OpenAPI 1.0.3 uses `/api/v1/me`,
boolean role-aware capabilities, current gateway budgets with one revision,
`If-Match` plus an audit reason for mutations, and daily person limits. Normalize
those semantics explicitly rather than sending Turnstile paths or monthly person
allocations to that service. Missing routes must remain visibly unavailable, not
empty successful datasets or calls to a hidden Turnstile dependency.

## Culminating owner-approved live acceptance, 2026-09-25

The owner now authorizes temporary test-only security groups, membership of the
signed-in test person, test unit/team budgets and mode changes, real tiny model
requests, and exact cleanup in `finally`. This supersedes the earlier read-only
live boundary for this explicit acceptance journey only. No consent, app-role,
directory-role or Standard-tier limit change is authorized by the client.

AUM adds delegated group discovery and verified owner creation. Graph's
eventual consistency means a successful create can precede an owners read and
a successful delete can remain briefly readable: retry verification reads,
never repeat the write automatically. Persist each returned created-group id
immediately so `finally` can remove it even if later verification fails.

Selected-scope membership refresh preserves unrelated assignments and tier
entitlement, uses the repository's Graph reader and sentinel serializer, and
requires explicit reassignment approval. Request-time usage is separate from
published current-membership cost, because the latter may intentionally
reattribute a historical request after a membership change.

An exclusive live window is requested from the other mutation agents before
governance changes. The retired P53 agent cannot receive new messages; active
P55/modes agents are notified and running apply jobs are checked. Temporary
Direct authority selection is recorded and restored exactly; other production
governance defaults are never silently changed. No test is complete if cleanup
or runtime enforcement cannot be proved.
