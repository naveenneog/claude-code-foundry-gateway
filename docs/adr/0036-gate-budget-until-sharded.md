# ADR-0036: The gate's command budget is 60 minutes until the exclusive checks are sharded

- **Status:** Accepted
- **Date:** 2026-09-28
- **Packet:** P77; P78 restores the 30-minute budget
- **Supersedes:** the 1,800,000 ms `commandTimeoutMs` of [ADR-0025](0025-parallel-test-suite.md); ADR-0025's runner, throttle and shards are unchanged
- **Deciders:** claude-code-foundry-gateway maintainers (the platform owner was not reachable on 2026-09-28 and reviews this decision)

## Context

[ADR-0025](0025-parallel-test-suite.md) returned `commandTimeoutMs` to 1,800,000 when
`tests/Test-All.ps1` ran 39 checks in 790 to 927 seconds. It now runs 89 to 91. Each packet gate on
2026-09-28 ran on this repository's gate machine (16 logical CPUs) at the default throttle of four,
under the shared gate lock:

| Tree | Start (IST) | Test-All | Result |
|---|---|---:|---|
| P76 on `f98f885` | 11:48 | 1,368.1 s | pass |
| P75 on `f98f885` | 12:11 | 1,371.1 s | pass |
| P69 `d361d5d` (the agent's gate) | 12:35 | 1,683.9 s | pass |
| P75 on `e39c3e4` (reviews ran during it) | 13:07 | 1,688.3 s | pass |
| P69 `1cd1567` (CPU averaged 68.4%) | after 13:35 | 1,800 s | timeout |
| P69 `b4e970b` on `040ca87`, throttle 8 | 15:10 | 1,800 s | timeout |
| P69 `b4e970b` on `040ca87` | 15:54 | 1,800 s | timeout |

In P76's gate the checks that run alone (the exclusive lane) took 663.0 s and the parallel checks
2,502.0 s. P69 adds three exclusive checks, which took 341.0 s in the run that timed out at 15:10;
its company-address mutations alone took 321.0 s. The main worktree also has the AUM Python
environments, so two checks that every packet worktree skipped run there: the FinOps suite took
206 to 228 s in P71's gates.

Load: at 15:45 the processor queue was 121 with processor time at 100%; Microsoft Defender's
real-time scanner (`MsMpEng`) used about 2.4 cores and Defender for Endpoint (`MsSense`) about
half a core, scanning the files the checks write. The 13 exclusive checks that P76's gate also ran
took 1,105.9 s in the 15:10 run against 663.0 s there, and the 69 common parallel checks 5,565.2 s
against 2,502.0 s.

Throttle 8, which ADR-0025's `TEST_ALL_THROTTLE` allows, was tried in the 15:10 run: it did not
shorten the parallel phase (each common parallel check ran about 2.2 times slower), the four
business-unit mutation shards reached their per-check timeouts, and "Test-All counts every check"
failed.

`gate.mjs` stops a command that reaches `commandTimeoutMs` by ending its shell (`spawnSync` with
`shell: true`); `Test-All` and its checks keep running. After the 15:10 timeout, `Test-All` ran for
ten more minutes. A budget with no headroom therefore leaves processes running in a worktree.

## Options considered

1. **Keep 1,800 s and gate only on a quiet machine.** Tried at 15:54 with no other gate or review
   running (one agent ran unit tests): timed out. Not chosen.
2. **Raise the throttle.** Measured above: slower, with per-check timeouts. Not chosen.
3. **Remove checks or mutations, or move timing-sensitive checks into the parallel lane without
   isolation.** Loosens what the gate proves, or makes it flaky. Not chosen.
4. **Raise `commandTimeoutMs` to 3,600,000 while the long exclusive checks are sharded (chosen).**
   The precedent is [ADR-0024](0024-test-suite-time-budget.md), which ADR-0025 reversed once the
   suite was parallel.

## Decision

`commandTimeoutMs` in `.ironclad/charter.json` is 3,600,000. `tests/Test-All.ps1`, its default
throttle of four, its per-check timeouts and its shards are unchanged, and every check must still
pass. P78 shards or isolates the exclusive lane's long checks; when `Test-All` on main, with the AUM
environments, is under 20 minutes on a busy machine in three runs, a new ADR returns the budget to
1,800,000.

## Consequences

- A hung gate command is stopped after an hour, not half an hour.
- The completion guard, failure recording and SKIP counting in `Test-All.ps1` are unchanged: a run
  that stops early still fails.
- Gate receipts keep stating Test-All's duration, so growth stays visible.
- A gate that times out still leaves its `Test-All` running; whoever runs the gate stops that
  process tree by process id before the next gate starts. P78 includes making the timeout stop it.
