# ADR-0060: USD reconciliation attributes stamped units and uses normalized model prices

- **Status:** Proposed
- **Date:** 2026-10-08
- **Packet:** P108
- **Amends:** ADR-0026

## Context

The 2026-10-08 live reconciliation on a projection gateway returned `usd_budget_unpriced` for a strict
`finance` unit after one developer used the gateway while unassigned and later while assigned to `finance`.
The query grouped by day, user and deployment, then collapsed the unit only when the day had one unit. That
turned a real stamped-unit split into an unattributed row. The same run used deployment
`claude-haiku-4-5` and model `claude-haiku-4-5-20251001`, while the dated book held `claude-haiku-4.5`.

This refines these ADR-0026 sentences:

- "Current membership attribution matches the existing financial reports; team usage also charges its parent."
- "Rates for all nonzero categories must exist."
- "Unpriced models or malformed counts produce an explicit unavailable-price decision, never zero spend."
- "State has a compact internal row encoding: shared period bounds and tariff date, with eight positional fields per scope."

## Decision

`usage_query` groups by day, user id, deployment and the business unit stamped on the request. The 1,001-row
capacity guard is unchanged, but it now counts those finer rows; an overflow still returns 503
`usd_usage_capacity` and applies no partial spend.

For a projection gateway, a row's leaf is the stamped unit, with an empty stamp treated as `unassigned`.
For a named-value gateway, today's membership still wins and falls back to the stamp. A user can therefore
produce one row per unit in a day, and each row is charged only through that row's leaf and its parent.

A row without a user id is not the spend of any unit member or person. It counts toward no scope, adds no
unpriced problem to any scope, and the reconciliation result reports the count and token totals. Rows with a
user and a unit outside a scope are simply outside that scope's spend.

Model price matching uses one rule in Python and the PowerShell model price reader: normalize by lowercasing
and keeping only letters and digits. A name matches a price-book key when the normalized strings are equal,
or when the normalized name is the normalized key followed by exactly eight digits. A shorter family never
matches: `claude-opus-5-5` is not `claude-opus-5`. The chargeback KQL uses the same exact-or-eight-digit
rule rather than a broad prefix match.

An unpriced row is never $0 and marks only scopes that own that row. The compact policy-facing state keeps
the same `compact-v1` item shape and `policy_revision`; the userless-row report is emitted only when such
rows are present.

## Consequences

Projection-backed budgets no longer fail every strict/allowance unit because one user moved units during the
month or because a refused request has no user. The row cap can be reached sooner because the query groups by
stamped unit as well as day, user and deployment.

`claude-haiku-4-5` and `claude-haiku-4-5-20251001` price from the Foundry-style
`claude-haiku-4-5` entry when a new book includes it, while older budget documents
that still contain only `claude-haiku-4.5` can still price the same normalized family.
Distinct families need their own tariffs: `claude-opus-5-5`, `claude-sonnet-5-5`
and `claude-fable-5-1` never inherit their shorter-family keys. The shipped example
book adds every 2026-10-08 eastus2 Foundry Claude catalog model whose Anthropic list
price is a single tariff. `claude-haiku-5-5` stays unpriced until U178 splits usage
by prompt-size tier.

The standalone scheduled reconciler is also per gateway, not per commit. Its
Container Apps job, identity and default environment suffix excludes `repositoryRef`,
so a registration at a newer commit changes `REPO_REF` on the same job. The
register script removes older jobs for the same gateway only after the replacement
deployment succeeds, and only prints manual cleanup commands for the old identity
and an unused old environment because those resources may be shared. Job deletion
uses core ARM resource deletion; the optional `-RunNow` path still uses the
Container Apps CLI extension.
