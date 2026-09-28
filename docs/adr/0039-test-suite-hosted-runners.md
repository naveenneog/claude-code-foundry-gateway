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
establish a hosted speedup. The approval evidence consists of queue-to-merge wall time, setup
time, every shard's duration and complete exact-source coverage.

## Contract

The marked registration block remains the authority. Its AST is read without running checks or
probing Azure (`tests/TestAll-Sharding.ps1:2`). An opt-in shard selects whole registered checks using longest-processing-time bin packing:
descending committed weight, registration index to break equal weights, then the least-loaded bin
with shard index to break equal loads. A new check receives a documented positive default weight.
No clock, CPU count, locale, hash-map enumeration or installed-tool state affects ownership
(`tests/TestAll-Sharding.ps1:80`).

Execution still uses ADR-0025's isolated `pwsh` processes, private scratch, explicit prerequisite
SKIPs, deadlines and exclusive machine lane. Without shard parameters, the local scheduler and
legacy timing array remain. New receipts include schema version, exact
commit and tree, shard coordinates, complete ownership and results, completion state and timings.

The merger uses the independently parsed registration and committed assignment. It requires every shard,
one result for every owned check, no duplicates or extras, PASS with exit zero or SKIP with a
registered reason, and identical commit/tree (`tests/TestAll-Sharding.ps1:162`). Local-only checks have
explicit names and reasons, with separate successful evidence for that same source. An empty local-only list means
all default checks run in CI; the opt-in live Azure registrations remain outside the default suite.

The workflow uses `windows-latest`, 12 shards and one always-evaluated merge job; pinned actions,
`contents: read`, ref-scoped cancellation, no secrets, no Azure login and no `pull_request_target`.
Setup installs both checkout-local Python environments, Node dependencies and Bicep. Receipts
and console logs are retained even on failure. Job timeout/cancellation contains the hosted process tree
(`.github/workflows/test-all.yml:14`, `:26`, `:63`, `:96`).

The wizard and both-host preflight no longer read an operator's Azure session or issue live
HTTP probes. The shared fixture retains a native `az.cmd` boundary, per-run Azure configuration,
recorded commands and explicit unexpected-command failures. The wizard's missing named value
still writes native stderr and exits 3; this preserves the PS 5.1 optional-error regression
that the business-unit mutation harness checks (`tests/TestAzureFixture.ps1:2`,
`tests/Test-On-PS51.ps1:3`, `tests/Test-BusinessUnitsNegative.ps1:630`).

The remote helper accepts only a clean HEAD already on origin, finds or dispatches an exact-SHA
run, waits with progress and an estimate, downloads that run's artifacts, and re-runs coverage
validation. A successful workflow badge alone is not evidence. Failed/cancelled/incomplete runs,
wrong commits/trees, expired artifacts and changed source fail explicitly.

## Dependency and action evidence

On 2026-09-28, `accel`'s two test interpreters reported Python 3.12.10. Their
`pip freeze --exclude-editable` outputs became `tests/requirements-finops.lock` and
`tests/requirements-aum-service.lock`. These are version snapshots, not artifact-hash locks.
The service requirements and FinOps project/test extras are still installed alongside them.
The installed standalone Bicep compiler reported 0.46.1; the workflow reproduces that version.
Node 22 compatibility remains part of the hosted run, rather than a claim based on the local
Node 26.1.0 runtime.
The first hosted attempt (`aee8fda`, run 36454004081) reached the browser checks but failed
because npm dependencies do not include the Chromium executable. Setup now runs the checkout's
Playwright installer explicitly; no browser check is removed or skipped.

The GitHub API's current release tags and commit endpoints returned these pins on 2026-09-28
(`.github/workflows/test-all.yml:39`, `:49`, `:58`, `:89`, `:107`):

| Action | Release | Full commit |
|---|---|---|
| actions/checkout | v7.0.1 | `3d3c42e5aac5ba805825da76410c181273ba90b1` |
| actions/setup-python | v7.0.0 | `5fda3b95a4ea91299a34e894583c3862153e4b97` |
| actions/setup-node | v7.0.0 | `820762786026740c76f36085b0efc47a31fe5020` |
| actions/upload-artifact | v7.0.1 | `043fb46d1a93c77aae656e7c1c64a875d1fc6a0a` |
| actions/download-artifact | v8.0.1 | `3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c` |

Sources, accessed 2026-09-28:
[checkout](https://api.github.com/repos/actions/checkout/commits/v7.0.1),
[setup-python](https://api.github.com/repos/actions/setup-python/commits/v7.0.0),
[setup-node](https://api.github.com/repos/actions/setup-node/commits/v7.0.0),
[upload-artifact](https://api.github.com/repos/actions/upload-artifact/commits/v7.0.1),
[download-artifact](https://api.github.com/repos/actions/download-artifact/commits/v8.0.1).

## Proposed charter and ROADMAP change (not enacted)

The proposal for owner approval is:

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
- Negative experiments remove a result, duplicate a check and substitute another SHA/tree.
  An isolated, committed stub exits 9; its shard fails and its actual receipt is rejected by the
  merger for the failed check. No published-history rewrite is part of the experiment.
- Required tool/environment setup fails rather than silently shrinking the suite.

The workflow also runs three negative-proof groups on its existing VMs, rather than waiting
for a shared workstation lock. The groups cover the pure contracts, the isolated runner
scenarios and the native wizard/preflight boundary. The pre-sharding runner is frozen at
`0345e85020b25d2f3595832b9453a174f253be64`, so later main changes do not erase that RED
baseline. Only valid-syntax mutations with the full baseline count and at least one failed
assertion count; restored suites must pass. Reports are retained as `negative-*.txt`, separate
from the receipt JSON (`.github/scripts/Test-InfrastructureProof.ps1:1`).

Baseline-only diagnostics are not negative-proof evidence. They exposed the draft's
`-LocalOnly` reassignment of the range-validated public `ShardIndex` parameter: one of 20
runner assertions failed for that reason, then all 20 passed with a separate internal index.
The public shard-coordinate bounds remain unchanged.

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
