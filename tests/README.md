# Test execution and hosted evidence

`Test-All.ps1` is the offline suite entry point on PowerShell 7. Its default invocation retains
the isolated processes, exclusive lane, ordered summary, prerequisite SKIPs and per-check
deadlines described in [ADR-0025](../docs/adr/0025-parallel-test-suite.md).
The optional Azure registrations remain outside the default suite (`tests/Test-All.ps1:189`).

```powershell
pwsh -NoProfile -File .\tests\Test-All.ps1
pwsh -NoProfile -File .\tests\Test-All.ps1 -Serial
pwsh -NoProfile -File .\tests\Test-All.ps1 -ThrottleLimit 2
```

## Deterministic shards

The marked registration block is the authority. `Get-TestAllRegistration` parses its AST without
running the registrations or their prerequisite probes (`tests/TestAll-Sharding.ps1:2`).
The committed [timing table](test-all-durations.json) supplies positive weights and a shard count.
Longest-processing-time assignment sorts by descending weight, then registration index; equal
bin loads choose the lower shard index. An unmeasured check receives the positive default weight
(`tests/TestAll-Sharding.ps1:80`). Assignment does not depend on installed tools, culture or load.

```powershell
. .\tests\TestAll-Sharding.ps1
$configuration = Get-TestAllConfiguration
$configuration.Plan | Format-Table Id, Name, ShardIndex, EstimatedSeconds
pwsh -NoProfile -File .\tests\Test-All.ps1 -ShardIndex 0 -ShardCount 12
```

Shard coordinates are zero-based and supplied together. A shard requires a clean committed
checkout, preserves complete registered checks rather than partitioning their internals, and
retains the existing process scheduler and deadlines (`tests/Test-All.ps1:5`, `:316`).
The machine-exclusive lane remains exclusive within each runner; each hosted shard has a
separate Windows VM. It is not a distributed lock against an operator's local test run.

The [local-only manifest](test-all-local-only.json) is empty. Every default registration therefore
belongs to CI. A future entry requires a registered name, a reason and a successful matching
local receipt; an exclusion is not permission to omit evidence. `-LocalOnly` selects that lane
when it is nonempty. `-IncludeAzure` cannot be combined with sharding or local-only receipts.

## AUM test shards

The AUM pytest suite runs as four registered checks, `AUM - commands, dashboard and pilot [0/4]`
to `[3/4]` (`tests/Test-All.ps1:293`). On 2026-09-29 its 871 tests took 860 s serially, beyond
the 600 s per-check timeout (`tests/Test-All.ps1:9`). `Test-FinOps.ps1 -Shard i/n` passes one
share of the top-level `cli/finops/tests` files to pytest; without `-Shard` it runs the whole
directory as before (`tests/Test-FinOps.ps1:4`).

Files are assigned longest first to the least-loaded shard, by whole-second weights in
[finops-test-durations.json](finops-test-durations.json). Equal weights keep ordinal file order,
equal loads choose the lower shard, and a file without a weight takes `DefaultSeconds`
(`tests/Select-FinOpsShard.ps1:49`). A weight only moves a file between shards; no file is run
twice or left out.

`Test-FinOpsShards.ps1` compares the registrations, the listings, the files on disk and pytest's
own collection, and runs a synthetic suite in which each shard's passed count identifies the files
it ran. One synthetic shard runs with pytest's colour on and one with it off (`PY_COLORS`), because
the packet gate runs Test-All with `FORCE_COLOR=0` (`.ironclad/gate.mjs:340`) and pytest colours its
output for any non-empty `FORCE_COLOR` (`tests/Test-FinOpsShards.ps1:185`). It fails when a planned
shard exceeds half the per-check timeout or a weight names a missing file.

```powershell
pwsh -NoProfile -File .\tests\Test-FinOps.ps1 -Shard 1/4 -ListFiles
pwsh -NoProfile -File .\tests\Test-FinOpsShards.ps1
.\.venv-finops\Scripts\python.exe -m pytest cli\finops\tests -q -p no:cacheprovider --junitxml $env:TEMP\aum.xml
pwsh -NoProfile -File .\tests\Update-FinOpsDurations.ps1 -JUnitXml $env:TEMP\aum.xml
```

The last two lines refresh the weights from one complete serial run.

## Receipts and coverage

A shard writes a versioned receipt with its exact Git commit and tree, coordinates, ordered
ownership, results, completion state, workflow run/attempt and timings. A source change during
execution invalidates completion. The legacy timing array remains available
(`tests/Test-All.ps1:390`).

`Merge-TestAllReceipts.ps1` reads the registration and assignment from a clean matching checkout.
It rejects missing or duplicate shards/results, unknown checks, foreign commits/trees, mixed
workflow attempts, wrong ownership, invalid field types and failed checks. PASS requires exit
zero. SKIP requires the check's exact registered prerequisite reason and no process exit.
The successful union contains every default check exactly once, in registration order
(`tests/TestAll-Sharding.ps1:162`, `tests/Merge-TestAllReceipts.ps1:5`).

```powershell
pwsh -NoProfile -File .\tests\Merge-TestAllReceipts.ps1 -ReceiptDirectory C:\test-evidence\receipts
```

Receipts produced outside GitHub have no hosted run identity. They can prove a local partition,
but are not a substitute for the hosted jobs and run-scoped artifacts the remote helper checks.

## GitHub-hosted execution

[The workflow](../.github/workflows/test-all.yml) runs on pushes to main and the approved P78
branches, pull requests and manual dispatch. Its token has only `contents: read`; it uses no
secrets, Azure sign-in or privileged pull-request trigger. Actions are pinned by full commit SHA
(`.github/workflows/test-all.yml:14`, `:39`). Failed shards do not cancel sibling coverage.
The merge and artifact-upload paths also evaluate failures (`.github/workflows/test-all.yml:100`).

Setup installs Python 3.12.10, both checkout-local Python environments, Node dependencies and
Bicep 0.46.1, with the actual Playwright Chromium executable and full Git release history.
The Python dependency snapshots came from `accel`'s two isolated environments on
2026-09-28; the application manifests remain authoritative alongside those snapshots.
Pip/npm cache keys include the dependency files (`.github/workflows/test-all.yml:50`).

The wizard and both-host preflight use a native `az.cmd` fixture, an isolated Azure configuration
directory and recorded HTTP fixtures. The wizard still exercises discovery queries and the
missing named-value error under Windows PowerShell 5.1. These are offline behavior checks, not
evidence about an operator's real sign-in or network (`tests/TestAzureFixture.ps1:2`,
`tests/Test-On-PS51.ps1:3`, `tests/Test-PreflightBothHosts.ps1:4`).

## Remote verification

`Invoke-RemoteTestAll.ps1` uses the existing GitHub CLI authentication. It requires a clean HEAD
on a named branch, already reachable from that branch on origin. It finds the newest exact-SHA
push/dispatch run, or dispatches the current remote tip with an exact-SHA guard. A dirty or
unpushed source, unavailable workflow, failed/cancelled/incomplete run, expired artifacts or
source change fails explicitly (`tests/Invoke-RemoteTestAll.ps1:15`, `:23`, `:29`).

```powershell
pwsh -NoProfile -File .\tests\Invoke-RemoteTestAll.ps1
pwsh -NoProfile -File .\tests\Invoke-RemoteTestAll.ps1 -RunId 123456789 -ArtifactDirectory C:\test-evidence\new-run
```

The helper reports progress and an estimate, checks every expected job in the same run attempt,
downloads that attempt's artifacts into a new/empty directory, and reruns receipt validation.
A successful workflow badge alone is insufficient. `workflow-times.json` records the run URL,
source identity, queue-to-merge wall time and individual job times. Artifact retention is 14 days.

## Infrastructure checks and approval boundary

```powershell
pwsh -NoProfile -File .\tests\Test-TestAllSharding.ps1
pwsh -NoProfile -File .\tests\Test-RemoteTestAll.ps1
pwsh -NoProfile -File .\tests\Test-RunnerIntegrity.ps1
```

The fast suites use synthetic invalid receipts and workflow records. RunnerIntegrity uses
isolated stub processes, including failing and source-changing shards; its receipt assertions
compare the actual fixture commit/tree and original registration IDs, not just hash shapes
(`tests/Test-RunnerIntegrity.ps1:207`).

The workflow runs Core, Runner and Wizard negative-proof groups on three of the existing shard
VMs before their owned checks. `Test-InfrastructureProof.ps1` changes isolated copies only.
A mutation counts only with valid PowerShell syntax, the full baseline assertion count,
nonzero exit and at least one failed assertion. The original source is restored and checked
again. Its JSON-formatted `negative-*.txt` reports and console logs share the shard artifact;
the receipt merger reads only the receipt JSON, not these proof reports
(`.github/scripts/Test-InfrastructureProof.ps1:1`).

```powershell
pwsh -NoProfile -File .\.github\scripts\Test-InfrastructureProof.ps1 -Mode Runner -BaselineOnly
```

`-BaselineOnly` runs short diagnostics without mutations and is forbidden in the CI workflow.
Full local proof runs acquire the sibling `.gate-lock`, retry every 60 seconds and remove only
their own lock in `finally`. Isolated GitHub-hosted VMs do not use the workstation lock.

The first complete P79-integrated hosted proof was
[run 36457223984](https://github.com/naveenneog/claude-code-foundry-gateway/actions/runs/36457223984),
accessed 2026-09-28: exact commit `f829812`, 95/95 registered checks, 0 FAIL and 0 SKIP,
including both Python environments. Queue-to-merge took 638 s (10 min 38 s); individual jobs
took 153-608 s, including setup, artifact handling and the three proof groups. Those groups
caught 74/74, 12/12 and 9/9 mutations with full baseline counts and restored green suites.
The approximately 44-minute loaded-workstation reference is not a controlled comparison.
The committed timing table uses that run's 95 passing check durations, not job/setup durations.

[STATUS](../docs/STATUS.md) records measured runs and negative-proof counts.
[ADR-0039](../docs/adr/0039-test-suite-hosted-runners.md) remains a draft proposal.
P78 does not change the charter test command or timeout, claim a packet gate, or fix the existing
local gate shell's process-tree timeout limitation. Council, gate and adoption belong to the lead
and owner.
