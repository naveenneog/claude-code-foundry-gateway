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
For a named-value gateway, today's membership still wins and falls back to the stamp, matching the chargeback
workbook's `coalesce(unit_now, stamp)` attribution. Consequence: on named-value gateways, moving a person can
shift earlier period spend into the new unit and stop that unit immediately; changing named-value attribution to
the stamped unit needs a follow-up ADR and workbook change.

A row without a user id is not the spend of any unit member or person. It counts toward no scope, adds no
unpriced problem to any scope, and the reconciliation result reports the count and token totals. A cache-metric
row with a user but no ledger row in the query window counts for that person only; it is reported as
`unit_unknown_usage` and never silently assigned to `unassigned`. These cases can under-count enforced unit
scopes when identity or unit tracing is broken, so operators must monitor the reported rows.

Model price matching has three implementations held together by parity tests: Python, PowerShell and KQL.
Each normalizes by lowercasing and keeping only letters and digits. A name matches a price-book key when the
normalized strings are equal, or when the normalized name is the normalized key followed by exactly eight
digits. A shorter family never matches: `claude-opus-5-5` is not `claude-opus-5`. Price books loaded for
budgets, model lifecycle and query publication reject duplicate normalized keys. The chargeback KQL reduces
the published price table to one row per normalized key before joining, so a malformed query cannot duplicate
spend rows.

The cache-read metric has no business-unit dimension. The reconciler therefore groups ledger rows and metrics
by day, user and normalized model family. When all requests in that group have body cache-read counts, the
metric is ignored. Otherwise the group cache total is `max(sum(body_reads), metric_reads)`, and only the
remainder beyond row body counts is assigned to the latest stamped ledger row in the group. A metric-only group
uses the user's latest stamped unit in the query window; without one it is person-only and `unit_unknown`.

An unpriced row is never $0 and marks only scopes that own that row. The compact policy-facing state keeps
the same `compact-v1` item shape and `policy_revision`; the userless-row report is emitted only when such
rows are present.

The gateway's `usd_budget_unpriced` response names the unpriced model list from
the state and the state's `price_book_date` when both fields have the expected
shape. If those fields are absent or malformed, the response stays a 403 with
the previous generic wording rather than becoming a stale-state 503.

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

The price book is pinned while budget items exist. The script path now follows
the AUM service rule: clear active budgets before replacing the stored book.

The standalone scheduled reconciler is also per gateway, not per commit. Its
Container Apps job, identity and default environment suffix excludes `repositoryRef`,
so a registration at a newer commit changes `REPO_REF` on the same job. Because a
new managed identity's RBAC can take up to 10 minutes to propagate, the register
script proves the replacement job has a post-deployment successful execution before
deleting older jobs for the same gateway. If no such run succeeds, the older jobs
are kept so state stays fresh and the operator gets the log query and rerun command.
Job deletion uses core ARM resource deletion. The immediate `-RunNow` path uses the
same ARM start/poll flow, not the Container Apps CLI extension.

After deleting old jobs, the register script starts the replacement job once more
and waits for a post-deletion success. Live run 2 for P108 showed that an old
job can begin a scheduled run before deletion finishes and can overwrite the
new state for one interval (`docs/status/P108.md`, live run 2, 2026-10-08).

On `main`, each scheduled-reconciler registration created a commit-specific
Container Apps job, optional environment and user-assigned identity. From this
release, one job and one identity per gateway are updated in place. Older
identities keep their role assignments until those assignments are removed and
the identity is deleted. The role assignment names are keyed by the runtime
principal id through the shared gateway and Log Analytics access modules
(`infra/aum-gateway-access.bicep`, `infra/aum-logs-access.bicep`). This naming
changed before release. A gateway that deployed an earlier build of this branch
could have hit Azure `RoleAssignmentExists` because the same assignment name
cannot change principals, but no released build used that shape.
