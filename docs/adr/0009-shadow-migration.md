# ADR-0009: Entitlement migrates in shadow mode, and a rollback never returns spent allowance

- **Status:** Accepted
- **Date:** 2026-09-16
- **Packet:** P19b
- **Deciders:** claude-code-foundry-gateway maintainers
- **Depends on:** [ADR-0005](0005-identity-projection.md), which decides *what* entitlement becomes

## Context

[ADR-0005](0005-identity-projection.md) replaces the named-value entitlement list with a durable
projection, because a named value holds 4,096 characters and therefore 110 object ids. Measured
2026-09-16 on BasicV2: 110 object ids is 4,071 characters and is accepted, 111 is 4,108 and is
rejected. [SCALE.md](../SCALE.md) has the rest.

That decision says nothing about how a running deployment gets there. Entitlement is live: it is
the thing that returns 403. A cutover that is wrong denies every developer at once, and a cutover
that is wrong in the other direction grants people access they no longer have.

There is a second hazard that is easy to miss. Budgets are **consumed state**, not configuration.
A developer who has spent 80% of a monthly allowance is carrying a number that exists only in the
gateway's counters. Any migration that moves, resets or re-keys those counters hands that allowance
back, and the symptom - a budget that stops binding - looks like the budget working.

## Decision

Five phases. Authorization does not change until phase 4, and each phase is reversible.

| Phase | What runs | What decides |
|---|---|---|
| 1. Schema and diagnostics | Projection deployed, populated, and reported on. Nothing reads it | The named-value path |
| 2. Backfill and compare | Both paths resolve every identity. Disagreements are reported | The named-value path |
| 3. Shadow spend | The projection additionally accumulates spend, compared against the ledger | The named-value path |
| 4. Canary | A named cohort is authorized by the projection. Everyone else is not | Mixed, explicitly |
| 5. Expand | The cohort grows while phase 2's comparison stays clean | The projection |

Phase 2 is the one that cannot be skipped. `Compare-ClaudeEntitlement.ps1` is that comparison, and
it exists now: it resolves every identity twice, once from what the gateway is enforcing and once
from the directory, and exits non-zero when the two disagree.

It resolves the tier with the **same precedence as the policy** - premium is tested before
standard, so an identity in both groups is premium. A comparison that ordered it the other way
would report drift the gateway does not have, and the first thing anyone does with a noisy
comparison is stop reading it.

### Counters are preserved, not migrated

Quota keys and period boundaries stay exactly as they are. The projection changes *who is
authorized and at what tier*; it does not become the counter.

This is the constraint that shapes the rest:

| Rule | Why |
|---|---|
| A rollback restores authorization, never consumption | Rolling back at 80% spent must not resume at zero |
| Counter keys do not change during migration | Re-keying is indistinguishable from a reset, from the counter's point of view |
| Period boundaries are not realigned | A monthly quota must roll over once, not once per migration step |

### Opening balance for a mid-period start

A business unit that starts mid-month has no consumption history for that month. Two answers are
defensible and they are not the same:

- **Full allowance from day one.** Simple, and the unit may overspend the month relative to a
  pro-rata peer.
- **Pro-rata for the remaining days.** Fair against peers, and it makes the first month's report
  inconsistent with every later one.

This is a finance question rather than an engineering one, so it is **deferred to P20b**, which
settles the financial semantics. Until P20b lands, a mid-period start takes the full allowance,
because that is what the current implementation does and stating it is better than a surprise.

## Consequences

+ Every phase before 4 is observation. The blast radius of being wrong is a report, not a 403.
+ The comparison is useful immediately, before any of this is built: it answers "is the sync
  current?", which is a live support question today. Entitlement is not live, and the gap between a
  directory change and the sync is exactly what the comparison measures.
+ Rollback is bounded and stated rather than hoped for.
− Both paths run at once through phases 2 and 3, so there is a period with two sources of a similar
  answer. The comparison is what makes that safe rather than confusing.
− The opening-balance question is deferred, not answered.

## How we would know this was wrong

If phase 2 never reports anything, the comparison is not measuring - membership is read from the
same place by both sides, so a perpetually clean result means the two sides are not actually
independent. It was negative-tested on the reference deployment: removing an identity from its
Entra group without running the sync produced `stale (1)` and exit 1, and re-adding it returned the
comparison to clean.

If phase 4's canary produces support load out of proportion to its size, the staleness window in
ADR-0005 is wrong and that is the thing to revisit, not this sequence.
