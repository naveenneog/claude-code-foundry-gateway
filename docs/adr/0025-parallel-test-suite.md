# ADR-0025: Parallel checks and shards restore the 30-minute gate budget

- **Status:** Accepted
- **Date:** 2026-09-25
- **Packet:** P56
- **Supersedes:** ADR-0024's temporary command budget
- **Deciders:** claude-code-foundry-gateway maintainers

## Context

ADR-0024 raised `commandTimeoutMs` to 3,600,000 until Test-All was reliably below
20 minutes on a busy machine. The supplied serial receipt on `49c53bf` was
1,829 seconds for 34 offline checks. Most time was in two negative harnesses.

Separate processes alone were insufficient: a busy run on `269464d` took
1,302.772 seconds, including 1,113.9 seconds in the business-unit harness.
Removing checks, reducing mutations or ignoring a failure is not an option.

That experiment and a frozen serial run also exposed a reporting error. Under
headless PowerShell's code page 437, Node's default Unicode summary no longer
matched the resolver wrapper's one-character-prefix regex. An independent probe
confirmed native exit 0 and 14 passes, but no counter match. The wrapper now
requests ASCII TAP and still requires a nonzero test count and zero failures.
Those earlier receipts are recorded as failed, not green gates.

## Options considered

1. Keep the serial runner and 60-minute budget. Retains the bottleneck.
2. Share runspaces or use thread jobs. Does not isolate process-wide environment,
   loaded types, native tools and test mocks as strongly.
3. Separate processes only. Measured above the 20-minute target.
4. Bounded processes plus coverage-proven mutation shards (chosen).

## Decision

`tests/Test-All.ps1` registers checks with one line each, then runs separate
`pwsh -NoProfile -NonInteractive -File` processes. The default concurrency is
`max(1, min(4, logical CPU count))`; a parameter or environment variable can
override it. `-Serial` runs one check at a time in registration order.

The business-unit harness has four zero-based modulo shards of 119 mutations;
Turnstile has two of 54. The original 476 and 108 mutations are unchanged.
Turnstile's count includes ten generated cases. Every shard still verifies the
unmutated sandbox before applying mutations. `Test-MutationShards.ps1` compares
independent manifest construction, unsharded listing, every shard and their union,
including ordinals, duplicates, order and registration.

Each process receives private scratch. Recursive source scans and Azure CLI
consumers run exclusively; Turnstile's Bicep checks are exclusive if they need
the CLI fallback instead of the installed compiler. Live checks remain last and
exclusive because they share deployment state. This is not a distributed lock
against another worktree or operator.

Output is captured and printed in registration order. Exit codes, exceptions,
crashes, missing scripts and timeouts produce FAIL; prerequisite SKIPs have
explicit result slots. The completion guard checks every registered slot and
its identity. Durations, five slowest checks and the timings JSON remain.
RunnerIntegrity exercises concurrent failures, timeout/descendant cleanup,
argument handling, output, serial lanes and four deliberate runner mutations.

**`commandTimeoutMs` returns to 1,800,000.** The default per-check timeout is
600 seconds, independently overridable. The initial benchmark default was
1,200 seconds; review found that a late-starting hung check could then outlive
the restored gate command budget. No measured check exceeded 445.9 seconds.
Both the global timeout and an individual override are tested with a hung
check and a child process.

## Evidence

Windows, 16 logical CPUs, default throttle four, FinOps installed and executed.
All times are wall seconds; CPU is cumulative user plus kernel seconds for the
entire Windows Job Object process tree, including exited descendants. Each run
used the same clean committed source, `e039f24`.

| Run, UTC on 2026-09-24 | Wall seconds | CPU seconds | Result | Other packet gates observed |
|---|---:|---:|---|---|
| 19:20:26-19:35:54 | 927.247 | 2,514.016 | 39 PASS, 0 FAIL, 0 SKIP | two at start, one at end |
| 19:38:43-19:52:33 | 830.563 | 2,453.984 | 39 PASS, 0 FAIL, 0 SKIP | one at both boundaries |
| 19:52:37-20:05:47 | 789.974 | 2,446.750 | 39 PASS, 0 FAIL, 0 SKIP | one at both boundaries |

Every summary and timings row was checked against registration. The actual
captured CAUGHT names also matched every shard's inventory: 476 plus 108,
without omissions or duplication. Every run left the same clean source commit
and no surviving process in its measurement job.

The slowest full run was 15 minutes 27 seconds, 49.3% below the supplied serial
reference and over four minutes inside the 20-minute target. The mean was
849.261 seconds. All samples were busy; there is no controlled quiet-machine
claim. [Per-check measurements](../measurements/p56-test-suite.json) retain the
numbers and the earlier failed experiments.

## Consequences

- More CPU is spent on process startup and stronger runner tests. This improves
  elapsed time, not CPU efficiency: measured full-tree CPU was approximately
  2,447-2,514 seconds versus 1,841 in the frozen original serial run.
- Ordered buffering can delay a later check's output behind an earlier check.
- `-Serial`, low throttles, slower machines and added coverage may exceed the
  packet command budget; they are not the configuration used to size it.
- Timeout termination cannot run a live check's restoration `finally` block.
  Live checks require operator coordination and inspection after interruption.
- Future budget changes still require an ADR and measurements, not removed tests
  or silent retries. See [running and extending the suite](../TESTING.md).
