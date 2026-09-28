# ADR-0039: The test suite runs on hosted runners

- **Status:** Draft for @naveenneog; no charter change is made by P78
- **Date:** 2026-09-28
- **Packet:** P78
- **Related:** [ADR-0024](0024-test-suite-time-budget.md),
  [ADR-0025](0025-parallel-test-suite.md), [ADR-0036](0036-gate-budget-until-sharded.md)

## Context and measurements

The owner's 16-logical-CPU workstation is shared with build agents and endpoint protection.
ADR-0036 records passing local Test-All runs of 1,368.1, 1,371.1, 1,683.9 and 1,688.3 seconds,
three 1,800-second timeouts, and throttle eight making common parallel checks about 2.2 times
slower. P69 subsequently passed in 2,015.2 seconds under the temporary 3,600-second budget.

On 2026-09-28 P79's gate on `d0226dd` recorded **2,631.6 seconds wall and 6,212.1 seconds in
checks**. Business-unit shard 3/4 reached its 600-second deadline and RunnerIntegrity failed.
Shard 0/4 took 819.2 seconds. These are failures, not usable gate evidence. The full command
takes 30-45 minutes under this load; increasing contention on that same machine is not a fix.

GitHub documents standard hosted runners as free for public repositories, with fresh Windows
VMs providing four CPUs and 16 GB RAM. This repository is public (verified through `gh`).
Sources, read 2026-09-28:
[hosted runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners),
[Actions limits](https://docs.github.com/en/actions/reference/limits).

**Hosted measurements:** pending the P78 workflow. Local durations seed the table; they do not
establish a hosted speedup. Record queue-to-merge wall time, setup time and every shard's run
duration before proposing approval.

## Contract

Keep the marked registration block as the authority. Read it without running checks or probing
Azure. An opt-in shard selects whole registered checks using longest-processing-time bin packing:
descending committed weight, registration index to break equal weights, then the least-loaded bin
with shard index to break equal loads. A new check receives a documented positive default weight.
No clock, CPU count, locale, hash-map enumeration or installed-tool state affects ownership.

Execution still uses ADR-0025's isolated `pwsh` processes, private scratch, explicit prerequisite
SKIPs, deadlines and exclusive machine lane. Without shard parameters, preserve the local runner.
Keep the old timing array for existing consumers. New receipts include schema version, exact
commit and tree, shard coordinates, complete ownership and results, completion state and timings.

Merge against the independently parsed registration and committed assignment. Require every shard,
one result for every owned check, no duplicates or extras, PASS with exit zero or SKIP with a
registered reason, and identical commit/tree. Local-only checks must be explicitly named with a
reason and have separate successful evidence for that same source. An empty local-only list means
all default checks run in CI; the opt-in live Azure registrations remain outside the default suite.

The workflow uses `windows-latest`, a matrix and one always-evaluated merge job; pinned actions,
`contents: read`, ref-scoped cancellation, no secrets, no Azure login and no `pull_request_target`.
Install the two checkout-local Python environments, Node dependencies and Bicep. Retain receipts
and console logs even on failure. Job timeout/cancellation contains the hosted process tree.

The remote helper accepts only a clean HEAD already on origin, finds or dispatches an exact-SHA
run, waits with progress and an estimate, downloads that run's artifacts, and re-runs coverage
validation. A successful workflow badge alone is not evidence. Failed/cancelled/incomplete runs,
wrong commits/trees, expired artifacts and changed source fail explicitly.

## Proposed charter and ROADMAP change (not enacted)

After owner approval, propose:

```json
{
  "commands": {
    "test": "pwsh -NoProfile -File ./tests/Invoke-RemoteTestAll.ps1"
  },
  "commandTimeoutMs": 1800000
}
```

The build command and all other charter values stay as they are. The lead still runs the council
and gate. A 30-minute remote-wait budget needs measured queue/setup headroom; this draft does not
claim three sub-20-minute local runs or fix `gate.mjs`'s existing shell-only local termination.
STATUS proposes replacement ROADMAP acceptance reflecting hosted exact-source evidence.
ROADMAP and `.ironclad/charter.json` remain untouched.

## Detectors

- Fast tests cover deterministic assignment, new-check weights, invalid coordinates/table data,
  independent registration parsing, every coverage rejection and exact-source remote selection.
- RunnerIntegrity retains the full-registration summary/completion invariants, process isolation,
  native argument handling, deadlines and descendant termination, and gains shard scenarios.
- Hosted coverage compares its union to the local read-only registration parse.
- Negative experiments remove a result, duplicate a check and substitute another SHA. A temporary
  committed failing check must fail its shard and merge; revert it without rewriting history.
- Required tool/environment setup fails rather than silently shrinking the suite.

## Rejected alternatives and consequences

**Higher local throttle:** already slower in ADR-0036 and causes per-check deadline failures.
**Azure VMs:** add cost, provisioning, credentials and lifecycle management for a public repo
whose standard GitHub Windows capacity is free. **Self-hosted runners:** preserve the workstation
bottleneck and add maintenance and untrusted-PR isolation responsibilities. **Dropping tests,
reducing mutations or relaxing deadlines:** changes what a green gate proves, not its throughput.

Hosted execution adds queue and dependency-setup time and depends on GitHub availability.
The timing table is an estimate and needs review as coverage grows. A single long check sets a
lower bound; this packet does not silently repartition its internal mutation inventory.
No product script, policy, deployed component, identity or Azure resource changes.
