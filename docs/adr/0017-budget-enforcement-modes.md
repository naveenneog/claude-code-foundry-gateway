# ADR-0017: Budget modes are separate from the registry and notices are advisory

- **Status:** Accepted
- **Date:** 2026-09-24
- **Packet:** P46 (gateway side)
- **Deciders:** platform owner

## Context

ADR-0016 authorizes strict, allowance and notify enforcement per unit or team.
The owner assigned this P46 worktree while the shared status ledger still names
P45. This packet implements that decision; the lead updates the shared ledger
when merging. It does not change allocation or manager authorization.

Research before implementation, 2026-09-24: the
[`llm-token-limit` reference](https://learn.microsoft.com/en-us/azure/api-management/llm-token-limit-policy)
documents remaining quota as an estimate that can exceed the true remainder.
It requires a rate or quota; it has no non-blocking monthly counter. Counts cover
prompt and completion, not cache, and streaming always estimates tokens.

## Decision

Keep `bu-registry` unchanged. A separate `bu-modes` map holds only exceptions:
`,sales=allowance:10,sales-emea=notify,`. Absent entries mean strict.
Strict retains the same counter key, quota and error. Allowance adds the floored
percentage of the base quota, using decimal arithmetic before converting to long.
Notify skips that scope's limiter, not the parent, organization or tier controls.
There is no artificial "unlimited" quota that can eventually refuse a request.

Allowance notices compare APIM's estimated remaining quota with the allowance.
Notify has no monthly remaining counter, so every successful response with a
nonzero notify budget carries an advisory notice, including before 100%.
It never asserts that the request crossed the budget. A trace carries both
scopes' base budgets and modes with RequestId; the ledger can join usage and
calculate over-budget usage. Neither notice claims invoice-accurate accounting,
an exact crossing request, or reliable display by a Claude client.

Invalid Turnstile mode metadata refuses the complete apply before any write,
rather than silently removing a unit or turning off its budget. Gateway edits
preserve modes unless explicitly changed; seeding preserves them too.

## Consequences

- Existing installations remain strict; the installer preserves stored modes.
- Mode changes reuse the existing counters. Notify skips counting at that scope,
  so changing back mid-month does not reconstruct usage incurred while notify.
  Ledger totals remain the reporting source.
- Notify advisories are intentionally broader than over-budget alerts. An exact
  crossing notice needs a non-blocking durable monthly usage reader, which APIM
  does not provide here; adding one would put a new dependency in the request path.
- Live tests and mutations must distinguish estimated notices from exact limits.

## How we would know this was wrong

A strict default changing behavior, malformed metadata loosening a budget, a
redeploy resetting modes, or an advisory being presented as proof of a precise
budget crossing is a regression, not a supported interpretation.
