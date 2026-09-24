# ADR-0024: The test suite's time budget is 60 minutes until it runs in parallel

- **Status:** Accepted
- **Date:** 2026-09-24
- **Packet:** follows P46; P56 plans the parallel suite that lets this be tightened again
- **Deciders:** claude-code-foundry-gateway maintainers, platform owner

## Context

`.ironclad/charter.json` gives every gate command 1,800 seconds (`commandTimeoutMs`). The
packet gate's slowest command is `tests/Test-All.ps1`, which runs its checks one after another.
Its measured duration on main grew as coverage was added, and the machine that runs the gate
now also runs several agents' gates at once:

| Commit | What it added | Test-All |
|---|---|---|
| `d1f1756` | P19 projection mutations, the runner integrity check | 1,477.4 s |
| `c7f0a29` | terminal FinOps, 93 Python tests | 1,721.8 s |
| `690015d` | budget modes: 119 assertions, 61 mutations | 1,797.2 s |

The last run passed 2.8 seconds inside the limit. A budget-modes gate on its own branch had
already failed once by reaching the limit, with no failing check. Every packet waiting to merge
adds checks, so the next merge would fail on time alone.

## Options considered

1. **Keep 1,800 s and stop merging until the suite is faster.** Blocks seven packets on work that
   has not started. Not chosen.
2. **Remove checks or mutations to fit.** Loosens what the suite proves. Not chosen.
3. **Raise the budget to 3,600 s, record each check's duration, and make the suite parallel
   (chosen).** A hung suite is still stopped, now after an hour. `Test-All` prints each check's
   seconds in its summary and writes them to a timings file, so the parallel work starts from
   measurements.

## Decision

`commandTimeoutMs` is 3,600,000. `tests/Test-All.ps1` records every check's duration, prints the
five slowest, and writes all of them to `test-all-timings-<utc>-<pid>.json` in the temp folder.
P56 runs independent checks in parallel; when `Test-All` is reliably under 20 minutes on a busy
machine, the budget returns to 1,800 seconds in a new ADR.

## Consequences

- A suite that hangs takes up to an hour, not half an hour, to be stopped.
- The completion guard, per-check failure recording and explicit SKIP counting in `Test-All.ps1`
  are unchanged: a run that stops early still fails, whatever the budget.
- Gate receipts must keep stating Test-All's duration, so growth stays visible.
