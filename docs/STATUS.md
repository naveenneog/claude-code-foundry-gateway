# Status

**Active packets (2026-09-30, run in parallel worktrees):** P80 AUM shows every action it has ([ROADMAP](ROADMAP.md)), P85 AUM's terminal UI manages people, units, teams and budgets, and P81 USD budgets are the primary enforcer, each on its own branch. The owner approved merging P80 and P85 on 2026-09-29; each merges after its council passes and its packet gate passes on the merged tree, P85 after P80. P81 merges only with the owner's explicit approval. Each has its own section on its branch; the section lands here when the packet merges. P71 AUM answers fast and says why it cannot is merged with the owner's approval (`01bb6c7`, [below](#p71-aum-answers-fast-and-says-why-it-cannot-2026-09-28)). P84 projection deployment checks everything before it writes and never switches into an outage is merged with the owner's approval (`3e4430b`, [below](#p84-projection-deployment-checks-everything-before-it-writes-and-never-switches-into-an-outage-2026-09-29)); switching entitlement to the projection waits for P86. P78 the test suite runs in parallel on GitHub-hosted runners is merged with the owner's approval (`2737232`, [below](#p78-the-test-suite-runs-in-parallel-on-github-hosted-runners-2026-09-28)); ADR-0039's proposed charter change is not enacted. P79 fixes from the owner's test on 2026-09-28 is merged (`6468235`, [below](#p79-fixes-from-the-owners-test-on-2026-09-28)), and its follow-up, the installer permutation check reads only its own record (`05dea1b`, [below](#p79-follow-up-the-installer-permutation-check-reads-only-its-own-record-2026-09-28)). P69 the company address in the flow is merged (`69db07a`, [below](#p69-the-company-address-in-the-flow-2026-09-28)); its proof of a request through a company address needs an owned, publicly delegated domain and is P74. P77 a 60-minute gate budget while the exclusive checks are sharded is merged (`e393487`, [below](#p77-a-60-minute-gate-budget-while-the-exclusive-checks-are-sharded-2026-09-28)). P75 the macOS/Linux installer prices its choices is merged (`5d1cd03`, [below](#p75-the-macoslinux-installer-prices-its-choices-2026-09-28)). P76 one plan, one order on both shells is merged (`d731023`, [below](#p76-one-plan-one-order-on-both-shells-2026-09-28)). P70 newly deployed models reach the tiers and the workstations is merged (`bb75aab`, [below](#p70-newly-deployed-models-reach-the-tiers-and-the-workstations-2026-09-28)). P72 permutation tests of the guided flow and the installer is merged (`cac1260`, [below](#p72-permutation-tests-of-the-guided-flow-and-the-installer-2026-09-28)). P68 the guided flow starts at once and gives the foundation to the installer is merged (`fc9c86c`, [below](#p68-the-guided-flow-starts-at-once-and-gives-the-foundation-to-the-installer-2026-09-27)). P67 developer workstation fixes from the owner's test are merged ([below](#p67-developer-workstation-fixes-from-the-owners-test-2026-09-27)). P66 guided flow is merged ([below](#p66-guided-flow-2026-09-27)); the owner's test on 2026-09-27 reopened its user experience as P68. Every packet started for the owner on 2026-09-25 and 2026-09-26 before P66 is merged ([ROADMAP](ROADMAP.md) lists what stays open). Merged on 2026-09-26: P62 dollar budgets in AUM ([below](#p62-dollar-budgets-in-aum-merged-2026-09-26)), P61 the Cosmos entitlement store on every v2 tier ([below](#p61-the-cosmos-entitlement-store-on-every-v2-tier-merged-2026-09-26)), P64 adding and removing developers from AUM by email ([below](#p64-add-and-remove-developers-from-aum-by-email-merged-2026-09-26)), P60 Claude Desktop sign-in chosen by the admin ([below](#p60-claude-desktop-sign-in-chosen-by-the-admin-merged-2026-09-26)), P65 fleet deployment with Intune, Jamf or Group Policy ([below](#p65-fleet-deployment-with-intune-jamf-or-group-policy-merged-2026-09-26)), P59 dollar budgets at the gateway ([below](#p59-dollar-budgets-at-the-gateway-merged-2026-09-26)) and P52 AUM ([below](#p52-aum-azure-usage-management-merged-2026-09-26)). P54, the enterprise network edge, merged on 2026-09-25 ([below](#p54-the-enterprise-network-2026-09-25)). P46 is complete: managers scoped to their units and teams (fork `c0c345a`), budget modes in the gateway (`3ee0bd3`), and the live manager-only sign-in (P53, 2026-09-25) ([TURNSTILE.md](TURNSTILE.md#managers), [BUSINESS-UNITS.md](BUSINESS-UNITS.md), [ADR-0016](adr/0016-delegated-management.md), [ADR-0019](adr/0019-budget-enforcement-modes.md)).

## P84 Projection deployment checks everything before it writes and never switches into an outage, 2026-09-29

**Merged as `3e4430b` on 2026-09-29 with the owner's approval. Council round 3 passed on all five seats and the packet gate passed at `5612c94`.** All five seats blocked the earlier submission. The owner requested P84 after a partial customer deployment on
2026-09-29. The branch is `p84-projection-preflight`, based on `30cdfd0`. The lead owns COUNCIL
and GATE; the owner owns merge approval. This packet performs no live Azure writes.

### Council round 3 and the packet gate

- [x] Council round 3, over `624ebd4..f39524d`: all five seats PASS. QA's independent sweep of
      fifteen summary widths reached truncation inside the fortieth line: 40 lines and 4,093
      characters for the ten-digit case, and at most 40 lines and 4,096 characters overall
- [x] Gate 1, at `f39524d` (19:22-19:48), failed six checks. The architecture manifest still held
      input hashes from before P84 changed `Sync-ClaudeProjection.ps1`, `ClaudeAumDirectWrites.ps1`,
      `Sync-AumMembership.ps1` and `Install-ClaudeGateway.ps1`. `Test-Scale.ps1` expected the manual
      switch as `az apim nv update`, while `docs/SCALE.md` now documents the same single write through
      `Set-ApimNamedValue`, which reads the value back. The four business-unit mutation shards failed
      only because their unmutated `Test-Scale.ps1` copy failed. Fixed in `5612c94`: the manifest is
      regenerated with no image change, and the assertion accepts either spelling of that one write;
      with the switch command removed from SCALE.md it fails (1 of 211)
- [x] Gate 2, at `5612c94` (20:05-20:35), the tree that merges: PASS. Test-All in 1,821 s; 22
      passed, 2 warned (open unknowns), 0 failed

### Council round 2 corrections

Round 2, over `10ff113..624ebd4`: Architect, Coder, UX and Security PASS. The three automated
switch paths refuse unconditionally (`scripts/Deploy-ClaudeProjection.ps1:46`,
`Install-ClaudeGateway.ps1:122-124`, `scripts/flow/Entitlement.ps1:77-79`); the manual named-value
step in `docs/SCALE.md` keeps its warning. QA BLOCK: forty short runner summaries produced 41
diagnostic lines, because the heading was added before forty summaries, and the tests allowed 42
lines and 4,352 characters.

- [x] RED: new assertions on the formatter's own output fail on `624ebd4` with `lines=41` for forty
      short summaries and for eighty long lines
- [x] GREEN: `Write-ClaudeRunnerOutput` keeps the heading and at most 39 summaries, and on
      truncation keeps at most 39 lines before the marker, so the diagnostic is at most 40 lines and
      4,096 characters in total. A sweep of fifteen summary widths reaches the case where truncation
      cuts inside the fortieth line. The apply and compare assertions now allow only the failure
      message beyond that. Council suite 86 of 86 in 65.8 s (all groups, three locales); preflight
      197 of 197 in 16.2 s
- [x] Mutations, each in a private copy, each running the baseline 70 Core assertions: 40 input
      lines (4 fail), no line cap on truncation (1 fails: the sweep), the previous truncation length
      (4 fail); 3 of 3 caught in 30 s (`p84-r2-mutate.ps1`)

### Council round 1 corrections

The lead's 2026-09-29 decision supersedes the earlier ARM-admission contract and its passing
receipts below. A digest-pinned scheduled dry-run can satisfy that contract without renewing
anything (`sync/src/apply-projection.mjs:136`). Those receipts did not prove safe admission.

- [x] PLAN/CONTRACT: P84 refuses every projection switch; proposed P86 admission requires
      destination-bound Cosmos renewal observations, not ARM execution metadata alone.
- [x] Architect: all three entry points refuse unconditionally with the two-hour lease,
      developer-wide 503 and P86/ROADMAP explanation; the job-admission implementation is removed.
- [x] Coder: policy unreadability/delegated rights produce an explicit WARN, not invented denial;
      existing app ids bypass Policy.Read.All reads. en-GB and de-DE regression runs are included.
- [x] QA: confirmed-absent premium passes with a note; Graph errors still fail. Every real
      shared membership caller has absence and error cases on its supported hosts.
- [x] UX: a 100-column console has readable check/result/evidence/remedy/who records; lease,
      outage and reconciler warnings precede switching examples and replace stale setup advice.
- [x] Security: failure output contains counts and hashed samples, no email/unit values, at most
      40 lines and 4,096 characters. A declined prerequisite aborts; check permissions are documented.
- [x] RED/GREEN, relevant existing checks and valid-syntax/count-preserving mutations are recorded.

**Final correction proof, 2026-09-29:** `eca8b55` caught **95/95** current mutations in
**1,356.35 s**, under one owned shared-workstation lock released in that command's `finally`.
Every mutant parsed, retained its selected suite's complete assertion count, failed an assertion
and exited nonzero. Independent receipt verification found zero invalid catches.

| Proof group | Baseline | Restored |
|---|---|---|
| Preflight | 197/197, 14.61 s | 197/197, 16.57 s |
| Council Core | 66/66, 3.00 s | 66/66, 2.34 s |
| Real Graph Callers | 14/14, 15.80 s | 14/14, 16.80 s |

Default council `All` also passes all 83 assertions, including complete preflight runs under
en-US, en-GB and de-DE. It does not omit groups for the default Test-All registration.
Receipt: `$env:TEMP\p84-r1-mutations.json`, with persistent session copy
`files\p84-r1-mutation-receipt.json`; SHA-256
`2c3298ab63bf4398863835360b4cbdf8cffaef135cd507ea876f6c65de2ac3c9`.
`4156090` implements the corrections; `eca8b55` updates proof and runbooks.
Final ledger validation: DocReferences 34/34 (9.75 s), encoding 300/300 (7.53 s).
The main Active packets line is unchanged; tested PowerShell inputs match the proof commit.

No runtime component is added. The proposed P86 reconciler and Cosmos evidence are not implemented
by this correction. The lead owns round 2 and the packet gate.

**RED/GREEN:** the corrected RED loaded 65 council assertions and failed 39 in 51.76 s.
It reproduced locale failures, silent declined prerequisites, leaked comparison samples, missing
character bounds, denied optional premium and false app-permission refusals. Real-caller tests
also exposed a Boolean `-FailOnDrift` being passed without a value and PowerShell 5.1 treating the
AUM named-value JSON array as one element. Both are corrected. An earlier test draft's
PSCmdlet substitution and Boolean fixture arguments were corrected before that RED receipt.

GREEN: preflight **197/197, 11.52 s**; council **65/65, 51.60 s**, including en-US/en-GB/de-DE
complete-suite runs and absence/error execution of all four real Graph callers on supported
hosts. The reduced preflight count reflects retirement of the rejected ARM-admission feature,
not omitted active checks. ProjectionInstaller 34 (0.76 s), FlowLifecycle 33 (2.58 s),
ProjectionRules 34 (0.78 s) and script encoding 300/300 pass. Changed-guard mutations and
runbook completion followed, as recorded above.

**Expanded proof and runbooks:** `4156090` commits the first correction GREEN. The council
suite now has **83 assertions** (Core 66, real Callers 14, Cultures 3), including long structured
diagnostics, private JSON parser paths and string values in count fields. Default `All` passed
in **67.88 s**; group selection is only for bounded proof commands. The mutation matrix contains
95 syntactically valid current guards; retired ARM admission probes are not counted.
Five smoke probes caught character-cap, sample-hash, parser-message, PS5.1 array and declined
comparison breakage with complete selected baselines (173.46 s). That smoke run still grouped
culture cases with callers (17 assertions); the selector is corrected to separate Callers 14
and Cultures 3 without changing default coverage.

Current related results: InstallerPermutations 48/48 (55.96 s), FlowPermutations 43/43
(104.63 s), ProjectionNegative 57/57 (62.34 s), SecureProjection 123/123 (11.90 s),
DocReferences 34/34 (11.23 s) and TestAllSharding 79/79 (3.40 s).
Runbooks now put the outage/refusal warning first, document read permissions and WARN semantics,
and retain the explicitly unprotected manual SCALE operation. The complete current mutation
proof is recorded above.

### Historical builder submission, superseded by council round 1

- [x] PLAN: A-F below define the packet; P85 belongs to another builder and P86 is proposed.
- [x] CONTRACT: [ADR-0040](adr/0040-projection-preflight-and-switch.md) records the switch
      evidence contract, with U54-U57 researched before implementation.
- [x] A: `-PreflightOnly` and normal deployment share a read-only preflight before any Azure
      write. One table contains check, result, evidence, remedy and acting party. Checks cover
      PowerShell 7, Azure sign-in/subscription, two Graph probes 20-30 seconds apart, tier
      groups, resolver registration permission/identifier URI, providers, resource-group RBAC,
      every derived name and global availability, local tools and regional-capacity limits.
- [x] B: Deployment, installer and guided Entitlement refuse a projection switch without a
      verified reconciler. Refusal states the two-hour maximum lease, absolute expiry and
      developer-wide 503 consequence. ARM reads verify schedule and recent success; no bypass
      or scheduled resource is introduced.
- [x] C: Every shared Graph-membership caller fails on CAE, authorization and network errors;
      only a positively empty lookup represents an absent optional group.
- [x] D: Apply/compare parsing and `ok:false` failures show the last 40 runner-output lines.
      App creation failure never updates an empty id or reports a fictitious WhatIf failure.
- [x] E: A fast registered offline suite exercises A-D, with right-reason RED, passing related
      projection/installer/Entitlement checks and count-preserving guard mutations.
- [x] F: STATUS, CHANGELOG, SECURE-PROJECTION, SCALE, UPDATE-AND-CHANGE, SETUP, GUIDED-FLOW,
      ADR-0040, U54-U57 and ROADMAP record the behavior, evidence and remaining decisions.

Architecture conclusion: no deployed component, identity, network path or schedule changes;
only operator-side validation and switch admission change. U56 records the evidence-contract
assumption and pending owner acceptance. The initial audit-only packet gate passed
(20 passed, 2 warned, 0 failed, 4 command checks skipped); this is not the lead's packet gate.

**Final builder receipt, 2026-09-29:** the complete proof at `4083c8b` caught **111/111**
mutations in **1,444.66 s**, under one owned shared-workstation lock released in that command's
`finally`. Every mutant parsed, loaded all **240** baseline assertions, failed at least one
assertion and exited nonzero; independent receipt validation found zero invalid catches.
Baseline: 240/240 in **14.51 s**; restored: 240/240 in **11.91 s**. Each host also executes
nine native Graph/stderr assertions. The receipt is `$env:TEMP\p84-mutations-final.json`;
the reproducible detector is `tests/Test-ProjectionPreflightNegative.ps1:1`.
Receipt SHA-256: `2cf0661c7a958f428039fe33bbc0a3d43f78298b4c42aa39127a7a0899f1ecde`.
The persistent session artifact is `files\p84-final-mutation-receipt.json`.

| Final related check | Result | Seconds |
|---|---|---|
| InstallerPermutations | 48/48 | 62.71 |
| FlowPermutations | 43/43 | 102.46 |
| FlowLifecycle, including Entitlement | 33/33 | 2.87 |
| SecureProjection | 123/123 | 14.25 |
| Existing ProjectionNegative | 57/57 mutations | 59.20 |
| Documentation references | 34/34 | 8.32 |
| Windows CLI argument safety | PASS | 8.86 |
| Script encoding | 299/299 | 6.93 |

The evidence contract remains proposed in ADR-0040: an existing hourly-or-faster scheduled job,
destination/tenant bindings, pinned current image/template, recent succeeded execution and
remaining snapshot lease, with no override. U56 explicitly assumes that the customer-controlled
image performs renewal; ARM exit status cannot prove its semantics or future health. P86 owns
the tested reconciler, tenant-admin Graph grant and alerts. U54, U55 and U57 are closed; no P84
unknown is silently treated as a live Azure proof. No Azure write, resource creation, push or
merge was performed. The full packet gate and five council verdicts belong to the lead.

Commits before the final ledger: `89d9906` PLAN/CONTRACT; `f7280e3` implementation;
`c50c21c` API shapes and subscription pinning; `c633046` canonical names/inherited roles;
`80a639e` mutation harness; `d3225d0` resolved installer target, binding case and runbooks;
`4083c8b` independently observable guard probes.

Commit metadata note: these earlier bodies contain both requested trailer lines, separated by
a blank paragraph. `git interpret-trailers --parse` recognizes only the final Copilot-Session
line. No history was rewritten; the handoff ledger commit uses adjacent trailer lines.

**First RED/GREEN:** PLAN/CONTRACT is `89d9906`. The new offline check loaded 188 assertions,
failed 165 in 12.35 s, and exposed the PS7 CAE diagnostic loss, a successful-looking nonzero
runner exit, absent preflight/switch checks and missing raw output. The same 188 assertions
passed in 7.79 s after implementation. Native `az.cmd` boundaries run on PowerShell 7 and 5.1;
deployment and projection sync refuse 5.1 with `run in pwsh`.

Focused existing checks passed: ProjectionInstaller 34 (0.73 s), FlowLifecycle 33 (2.48 s),
ProjectionRules 34 (0.75 s), Teams 146 (2.25 s), SecureProjection 123 (12.45 s),
AdminSurface 682 (4.42 s), Scale 211 (1.20 s). Encoding passed for 298 scripts.
Installer permutations, projection negatives, additional integration proofs and mutations were
still in progress at that first GREEN. Evidence is offline, not a customer-tenant deployment proof.

**Entry-point and API-shape follow-up:** implementation GREEN is `f7280e3`. Added cases loaded
206 assertions and failed seven in 12.58 s: six exposed optional ARM/Graph fields, an explicit
zero expiry being treated as an estimate, and missing subscription forwarding; one exposed an
overbroad AST fixture selector, corrected without changing its assertion. GREEN is 206/206 in
11.31 s. Actual child processes prove preflight-only success/failure and normal-run failure
exit codes with zero Azure writes. Actual installer guard and Entitlement invocation refuse
missing evidence before their next operation. The switch's three writes pin the subscription
that preflight verified. FlowLifecycle 33 (2.23 s), ProjectionInstaller 34 (0.62 s),
TestAllSharding 79 (2.11 s) and encoding (298 scripts) pass.

Required existing checks also passed: InstallerPermutations 48 (46.06 s),
ProjectionNegative 57/57 mutations (59.88 s), FlowPermutations 43 (90.64 s).
The new registration uses the existing positive default shard weight; the hosted timing table
is unchanged because P84 has no hosted timing receipt.

**Name and inherited-role follow-up:** `c50c21c` commits the API/entry-point fixes. Expanded
negative cases loaded 225 assertions; two failed in 11.47 s. User casing was reaching the
case-sensitive storage hash, and a management-group Owner returned by the scoped inherited-role
query was being rejected. Canonical ARM ids now seed the hash, and that scoped query's
management-group ancestors count. GREEN: 225/225 in 11.28 s; encoding remains 298/298.
The added pagination assertions also verify that foreign HTTP calls never receive the token.

**Mutation preparation:** `c633046` commits canonical naming and inherited-role handling.
The complete offline regression check now passes 236 assertions in 13.54 s, including the
actual switch block (zero writes on refusal; three subscription-pinned writes with source last
on success). Each native host independently passes nine stderr/Graph assertions. The new
mutation harness's five detector self-checks and all 108 mutation anchors/syntax checks pass;
mutation execution was still pending then. A syntax error, missing summary, lost assertion, exit-only
failure or assertion failure with exit zero cannot count as a catch. Encoding passes 299 scripts.

**Installer target and binding follow-up:** the first 108-probe run is isolated at `80a639e`
with its 236-assertion baseline. Independent integration investigation then added three cases:
the installer had checked the job before assigning its gateway name, ARM id casing caused
false refusals, and case-insensitive environment keys could attest the wrong Linux variable.
RED: 239 assertions, three failures, 12.50 s. The guard now follows gateway-name resolution
before writes, resource-id/GUID values compare case-insensitively and environment names compare
ordinally. GREEN: 239/239, 12.10 s; encoding 299/299. The earlier mutation run is not evidence
for these later changes; it was followed by the final-tree proof above.

**First mutation run and detector repair:** under its own shared-workstation lock,
`80a639e` caught 99/108 probes in 1,378.02 s with all 236 assertions loaded and the restored
baseline green. Nine survivors were recorded, not counted as catches: four prerequisite
diagnostics were protected by later parameter binding, the wrong-app and bad-name fixtures
also broke later checks, a missing-id diagnostic overlapped format validation, a foreign-job
fixture failed before exercising subscription binding, and the flow argument assertion matched
its earlier refusal call. Fixtures now isolate those conditions and require the precise
diagnostic/forwarded argument. No assertion was removed or weakened.

The current baseline is 240/240 (12.54 s); all nine former survivors plus three new binding
probes are caught, **12/12**, with all 240 assertions loaded and the restored baseline green
(176.34 s). All 111 final anchors parse. Windows CLI argument safety passes (8.86 s), docs
references 34 (8.81 s), FlowLifecycle 33 (2.37 s), ProjectionInstaller 34 (0.67 s) and encoding
299/299. The complete final-tree 111-probe run followed, as recorded above.

## P78 the test suite runs in parallel on GitHub-hosted runners, 2026-09-28

**Merged as `2737232` on 2026-09-29 with the owner's approval. Council round 1 passed and the local packet gate passed; ADR-0039's proposed charter change is not enacted.**
PLAN and CONTRACT are committed in `55e1b90`.
Work is isolated to `p78-parallel-tests`, from `main` `0345e85`.
The lead runs the council and gate; the owner decides the merge.
[ADR-0039](adr/0039-test-suite-hosted-runners.md) is proposed, not a charter amendment. The owner
approved the merge and the replacement ROADMAP P78 acceptance on 2026-09-29; the charter change
(the gate's test command and budget) needs a separate decision. The records below describe the
state before that approval.

**Local packet gate, 2026-09-29:** `node .ironclad/gate.mjs --stage packet` passed at `fab1298`
(main `17e488c` merged) between 01:18 and 01:46 IST: Test-All in 1,676 s, 22 passed, 2 warned
(open unknowns), 0 failed. It ran under the shared workstation lock, with the lead raising only
the gate's own processes to AboveNormal priority.

**Council round 1, reported 2026-09-29:** Architect, Coder, QA, UX and Security all PASS at
`6880d29`. The council supports owner approval of ADR-0039 as written; approval has not been
given and no proposed command, timeout or ROADMAP change is enacted.

**P79 follow-up integration, 2026-09-29:** main `17e488c` adds the isolated installer-input
copy and saved-record assertions (`tests/Test-InstallerPermutations.ps1:92`). It is merged
into P78 without rebasing. The default registration remains 95 checks across 12 shards;
the complete ownership plan and committed timing-table bytes equal those at `6880d29`.
The timing table retains its recorded hosted measurements rather than guessed replacements.
The merged tree's local sharding suite passed 79 assertions in 3.7 s and the remote contract
suite passed 37 in 2.5 s. Encoding passed for all 295 PowerShell scripts. No long local
test command or gate ran, and this integration did not take the shared lock.

**Follow-up hosted receipt:** [run 36472384417, attempt 1](https://github.com/naveenneog/claude-code-foundry-gateway/actions/runs/36472384417),
accessed 2026-09-29, passed on the clean pushed merge HEAD
`202ccde6787986eb53a06a2d055c5d72a8e295f1`, tree
`f5b6403b74fbc25ed9db9547cf52f1478850f675`. `tests/Invoke-RemoteTestAll.ps1` downloaded
the run's artifacts and independently revalidated exact commit/tree, ownership and ordered
coverage: **95 PASS, 0 FAIL, 0 SKIP**, across all 12 shards and the successful merge job.
Queue-to-merge wall time was **635 s (10 min 35 s)**, from 2026-09-28T19:27:37Z to
19:38:12Z. The updated installer-permutation check passed in 38.8 s; no registration or
ownership adjustment was needed, and the existing recorded timing table remains unchanged.
The subsequent receipt-recording commit changes only this STATUS section. The local packet
gate remains with the lead; ADR-0039 approval is pending and nothing in its proposal is enacted.

Acceptance:

- [x] Opt-in Test-All shards use deterministic longest-processing-time assignment from a
      committed timing table, preserve process isolation, exclusive lanes and deadlines, and
      record their complete ownership, results, commit and tree. The default invocation is unchanged.
- [x] The receipt merger rejects missing, duplicate, failed, foreign-SHA/tree and unregistered
      results; only a registered prerequisite reason permits SKIP. CI plus any explicitly listed
      local-only evidence covers exactly the default registration, in registration order.
- [x] A read-only-permissions, SHA-pinned Windows workflow runs all shards and a coverage merge;
      both Python environments, Node dependencies and Bicep are installed without Azure sign-in.
- [x] A clean, pushed exact HEAD can be verified remotely through `gh`, with progress and an
      estimate; dirty/unpushed heads and incomplete or mismatched runs fail.
- [x] Fast infrastructure tests and RunnerIntegrity pass under the shared workstation lock;
      GitHub produces a green full-suite run and recorded queue-to-merge and per-shard timings.
      Missing, duplicate, foreign-SHA and deliberately failing-check experiments all fail.
- [x] Merge `main` before handoff. STATUS, CHANGELOG, tests README and ADR record evidence and
      limitations. Product scripts, policies, ROADMAP and the charter are unchanged.

**Proposed replacement ROADMAP P78 acceptance (owner approval required):** The default Test-All
registration runs as coverage-proven, deterministic shards on GitHub-hosted Windows runners,
with no check or mutation removed, machine-exclusive checks still exclusive, both AUM environments
installed, and complete exact-SHA/tree evidence. The remote helper fails closed on dirty/unpushed
source, failed/missing shards or invalid coverage. Record hosted wall time, shard times and the
local baseline. Propose the gate's test command and 30-minute budget in ADR-0039; the owner decides
whether to amend the charter. Hosted job cancellation bounds its process tree; the existing local
gate-shell timeout limitation is not represented as fixed.

**Validation history:** the resumed draft initially passed 49 sharding
and 24 remote assertions, despite two absent dependency snapshots and live wizard/preflight
boundaries. Added receipt-type/run-identity cases failed 8 of 65 assertions; corrected workflow
setup failed 3 of 25, and offline-boundary cases failed 2 of 27 before their implementations.
Targeted suites now pass 79 sharding and 37 remote assertions. The real wizard passes its
four offline native-boundary assertions; preflight returns through the same fixtures on both
PowerShell 7 and 5.1. Twenty isolated runner scenarios pass. Their local-only case first failed
because the draft assigned -1 to the range-validated public `ShardIndex` variable; the internal
selection index now leaves public validation intact. The actual exit-9 receipt fails the merger
for its failed check.

`ed62bef` commits the shard/receipt contracts; `1505b2e` commits the offline native boundary;
`f728d86` commits the runner and its scenarios, including P79's process-start identity from
`0e64028`. Main `449489b` (P79 merge `6468235`) is integrated before handoff. The resolution retains
P79's final probe inside `try/finally`, compares the process start time obtained from the operating
system, and includes both new P79 registrations. The default inventory now has 95 checks.
Under P78's own shared lock, the merged sharding suite passed 79 assertions in 2.2 s, remote
contracts 37 in 1.0 s and full RunnerIntegrity 68 in 214.0 s; the lock was removed in `finally`.
With the shared lock previously occupied after its
estimated release, the workflow also runs count-preserving Core, Runner and Wizard negative
proofs on three of its existing VMs. Baseline-only diagnostics do not count as negative proofs.
Hosted measurements follow below.

The first hosted attempt, [36454004081](https://github.com/naveenneog/claude-code-foundry-gateway/actions/runs/36454004081)
on `aee8fda`, found missing Playwright Chromium executables in the screenshot/redaction checks,
and one uncaught core mutation: a removed declaration guard was hidden by an overly broad
expected error pattern matching a later exception. Setup now installs Chromium explicitly and
the declaration assertion matches the intended diagnostic. These failures are not green evidence.
The completed attempt also exposed a shallow checkout with no release tags, and an unmutated
projection Node baseline failure whose harness discarded its diagnostic. The hosted checkout
now retains history/tags; the projection harness preserves failed-baseline output without
changing its mutations or timeout. The same 46-test Node baseline passes locally on Node 26.1.0;
the hosted Node 22 difference remains under investigation. Wizard/preflight proofs caught 9/9
mutations and runner proofs caught 12/12, with their complete 4/2 and 20-assertion baselines.

Run [36455666772](https://github.com/naveenneog/claude-code-foundry-gateway/actions/runs/36455666772)
on `a9ebfd1` passed every product check except release ancestry: the later proof-baseline fetch
with `--depth=1` made the otherwise full checkout shallow again. That redundant fetch is removed;
the frozen baseline already exists in full history. The projection baseline and every mutation
passed on Node 22 in that run, so the earlier failure's cause remains unproven rather than
classified as a Node incompatibility. Its future diagnostic is retained. Core proofs passed
73/73 locally under the shared lock at full 79/37 assertion counts; all restored suites passed.

**Green hosted evidence:** [run 36457223984, attempt 1](https://github.com/naveenneog/claude-code-foundry-gateway/actions/runs/36457223984),
accessed 2026-09-28, verified by the real `Invoke-RemoteTestAll.ps1` on the clean pushed HEAD
`f82981270702f0af5eeceb41a4e8d776524acf28`, tree
`aaac14f39655051693c3c51929f9841faec094af`. The downloaded receipt union passed **95/95
registrations, 0 FAIL, 0 SKIP** in registration order, with no local-only exclusions.
Queue-to-merge wall time was **638 s (10 min 38 s)**, from 17:18:45Z to 17:29:23Z.
The merge job took 23 s. Setup before checks, excluding infrastructure proofs, ranged from
87 to 212 s. Core, Runner and Wizard proof steps took 96, 282 and 60 s respectively.

| Shard | Entire job, seconds | Test-All receipt, seconds |
|---|---:|---:|
| 0 | 459 | 232.4 |
| 1 | 608 | 199.9 |
| 2 | 391 | 226.8 |
| 3 | 443 | 224.5 |
| 4 | 289 | 191.2 |
| 5 | 232 | 139.6 |
| 6 | 390 | 240.1 |
| 7 | 292 | 193.6 |
| 8 | 312 | 211.0 |
| 9 | 153 | 55.5 |
| 10 | 340 | 232.4 |
| 11 | 390 | 287.4 |

The hosted run includes **74/74 Core, 12/12 Runner and 9/9 Wizard mutations caught** with
baseline counts 79/37, 20 and 4/2 respectively; every restored suite passed. The real
exit-9 check fails its shard and the merger. Missing/duplicate results and foreign SHA/tree
receipts are rejected in the synthetic suite. The actual remote entry point also rejected a
dirty worktree and a clean unpushed HEAD, and rejected failed hosted run 36454004081.
The complete hosted suite includes 320 FinOps pytest tests, 127 AUM service unit tests and
five service mutations, 512 business-unit mutations, 108 Turnstile mutations, 105 company-address
mutations and 57 projection mutations; none was removed for CI.

Compared with the approximately 44-minute loaded-workstation baseline (P79's passing gate
records 2,666 s in Test-All below), the hosted end-to-end interval is 10 min 38 s. This is not
a controlled same-machine benchmark: runner hardware, load, setup, Python-environment presence
and infrastructure proof work differ. `tests/test-all-durations.json:1` now records all 95
observed passing durations as future LPT weights; the default for a new check remains 60 s.

**Limits and approval:** artifact retention is 14 days; Python snapshots pin versions rather
than artifact hashes; GitHub queues and hosted images can change. The isolated unmutated
projection failure in the first run has no recovered cause; two later hosted runs passed it,
and the harness now preserves failure output. No local gate-shell process-tree fix or charter
change is claimed. ADR-0039 remains a draft for owner approval, including the proposed remote
test command, 30-minute budget and replacement ROADMAP acceptance. Product scripts, policies,
ROADMAP and charter equal the integrated main; no Azure resource was accessed by P78.

U50-U53 track hosted compatibility, timing, remote-run identity and detector evidence. No product architecture
component changes; this is test execution and evidence transport, not an accelerator deployment.

## P79 follow-up: the installer permutation check reads only its own record, 2026-09-28

The main check after the P79 merge (Test-All in the main worktree at `449489b`, 22:31-23:04,
2,001 s) failed one check of 93, "Installer summary across permutations": 14 of its assertions,
each with "Saved record '...\accel\onboarding\claude-gateway.json' names gateway
'rg-contosohub/apim-claude-gw-fzgql9' ...". P79 moved the installer's saved-record comparison to
the gateway question (`Install-ClaudeGateway.ps1:778-825`), and `tests/Test-InstallerPermutations.ps1`
ran the installer in the checkout itself, so in a checkout whose saved record names another
gateway every case stops there. The record is ignored by Git (`.gitignore:35`), so packet
worktrees, where the P79 gate ran, have none. The installer does what P79 intends; the check was
not isolated from the machine's own record. The same main check sent seven Claude Code 2.1.272
requests through the reference gateway; all seven answered. Work is on
`p79-followup-installer-record`, based on `main` `449489b`.

- [x] RED: with the main worktree's record copied into this worktree, the check fails 14 of its 44
      assertions in 23 s, as on main
- [x] The cases run a copy of the installer's inputs (the root files and `analytics`, `cli`,
      `config`, `guide`, `infra`, `onboarding`, `resolver`, `scripts`, `service` and `sync`) with no
      `claude-gateway*.json` under `onboarding`. Three new assertions: the copy leaves out saved
      records (a synthetic tree with three of them), the installer path is inside the copy, and the
      checkout's own record is neither changed nor created (its hash before and after). GREEN with
      the record present: 47 of 47 in 50 s, 103 cases on each shell (`627fc76`)
- [x] Mutations: 3 of 3 caught (round 1; see council round 1 for five), each in its own detached worktree with a saved record, each running
      the baseline 47 assertions: the installer run from the checkout (15 fail), no record exclusion
      (16 fail), the checkout's record changed (1 fails) (`p79b-mutate.ps1`, 68 s)
- [x] CHANGELOG and GUIDED-FLOW.md. Architecture: no component, data flow, identity, schedule or
      network path changes
- [x] Council round 1, five seats, over `449489b..ae2e76f`: Architect, Coder, UX and Security PASS;
      QA BLOCK. The checkout's record was hashed after the copy, so a copy that deleted the records
      it skips would have removed the operator's record first and passed. The hash is now taken
      before anything is copied, and a new assertion requires the synthetic source records to stay
      in place, unchanged (`3ec2dfb`). Evidence (`p79b-mutate-r2.ps1`, detached worktrees): against
      `ae2e76f` that mutation passes 47 of 47, with and without a saved record; against `3ec2dfb`
      it is caught with and without one, the three earlier mutations are still caught, and both
      baselines pass 48 of 48. Architect's note: a folder the installer starts to read must be added
      to the copy list; otherwise the check fails when that input is required, and runs without it
      when the installer only reads it if present
- [x] Council round 2, over `ae2e76f..31b660d`: Architect, Coder, UX and Security PASS; QA BLOCK.
      The skipped records' content was compared with case-insensitive `-eq`, so a copy that
      rewrote them in upper case passed in a checkout without an operator record. Each synthetic
      file now holds its own relative path, compared with `-ceq` (`35a7d2d`). Against `31b660d`
      that mutation passes 48 of 48; against `35a7d2d` it is caught with and without a saved
      record, the four earlier mutations are still caught (five runs), and both baselines pass 48 of 48
- [x] Council round 3, over `31b660d..a196d13`: all five seats PASS
- [x] The packet gate exits 0, run with the main worktree's saved record (it names the reference
      gateway) copied into this worktree. Gate 1, at `ae2e76f` (23:16-23:47), passed: Test-All in
      1,823 s, 22 passed, 0 failed. Gate 3, at `a196d13` (00:12-00:40), the tree that merges,
      passed: Test-All in 1,714 s, 22 passed, 2 warned (open unknowns), 0 failed. Gate 2, at
      `31b660d`, was stopped when council round 2 changed the test

## P79 fixes from the owner's test on 2026-09-28

The owner ran `main` (`040ca87`, then `0345e85`) from his own clone on 2026-09-28 and sent four
defects, each with a screenshot. Work is on `p79-owner-test-fixes`, based on `0345e85`.

1. The guided flow's FinOps step stopped at "Applying FinOps..." with "Cannot convert value to type
   System.String." (`scripts/flow/FinOps.ps1:157`). `& $path @($Command.arguments)` passes the
   argument list as one array: every script the step runs is an advanced script, which refuses an
   array for a `[string]` parameter, so every choice but None failed on both shells, whatever its
   arguments. In a splatted array a string such as `-Accept` is a positional value to a script,
   not a parameter name, so the AUM service and Turnstile plus AUM choices would have been wrong
   too; and the scripts' output would have reached the step's change set.
2. `.\Update-ClaudeGateway.ps1` from the repository root read
   `C:\Users\nag\onboarding\claude-gateway.json`: the root shim's `-RecordPath` default is the
   relative `onboarding/claude-gateway.json`, and `Read-ClaudeDecisionRecord` reads it with
   `[IO.File]::ReadAllText`, which resolves a relative path against the process's start directory,
   not PowerShell's current folder.
3. The installer, creating a new gateway (`rg-hello-agent-dev/hocon-gateway`) in a checkout whose
   record names another (`rg-contosohub/apim-claude-gw-fzgql9`), refused only at the address
   question, after every other answer, and left moving the record to the administrator.
4. After the developer count (250), the installer warned "This holds about 93 developers" and
   asked "Continue anyway", saying the store that removes the limit "is not built yet". P61 built
   the Cosmos entitlement store on every v2 tier; the tier and the store are chosen after this.

- [x] Each FinOps choice applies its commands with the parameters it plans, on both shells, and the
      step returns only its change set: tested with stubs that carry the real scripts' parameter
      blocks (`tests/Test-FlowFinOpsApply.ps1`, 11 checks; against the previous `FinOps.ps1` 8 fail
      with the owner's error; `872b88b`)
- [x] A record path given relative to PowerShell's current folder is read and written there,
      whatever the process's start directory; the root Update shim reads the repository's record
      (`tests/Test-RelativeRecordPath.ps1`, 8 checks, each child started in one folder and moved to
      another; all 8 fail before the fix with the owner's error; `cd1005b`)
- [x] The installer compares a saved record with the chosen gateway as soon as the gateway is
      chosen; attended, it offers to archive the saved record under its gateway's name and go on;
      unattended, it refuses unless `-ArchiveSavedRecord`; `-WhatIf` moves nothing
      (`tests/Test-CompanyInstaller.ps1`, 5 new checks, 22 on both shells; against the `0345e85`
      installer the 5 fail and the other 17 pass, on both shells; `5885d4e`, `5de7ba2`)
- [x] The developer count asks nothing about the entitlement store; after the store is chosen,
      named values for more developers than they hold is stated with the Cosmos store as the remedy
      (`tests/Test-AdminSurface.ps1`, 682 checks; 4 fail against the previous installer; `f14f92f`)
- [x] SETUP.md, GUIDED-FLOW.md and CHANGELOG. Architecture: no component, data flow, identity,
      schedule or network path changes; the manifest's source hashes are refreshed, no image changes
- [x] Mutations: 16 of 16 caught. Each mutation ran in its own copy of the worktree; it counts as
      caught only when a suite ran its baseline number of checks (FinOpsApply 11, RelativeRecordPath
      8, CompanyInstaller 22, AdminSurface 682) and at least one failed. FinOps: the arguments as one
      array, the output returned into the change set, `Confirm` dropped, `aum`'s arguments as one
      array, no exit-code reset, `NoConfigure` dropped. Records: the read and the write resolved
      against the process directory, the shim passing a relative path through. Installer:
      `-ArchiveSavedRecord` ignored, no console question, the record never moved, the record moved
      under `-WhatIf`, the comparison back at the address question, the store warning back at the
      developer count, the Cosmos store called unbuilt
- [x] Heavier suites once on the branch: FlowOrdinalOrder 35, GuidedFlow 44, FlowStart 114,
      FlowPermutations 43, InstallerPermutations 44; CompanyInstaller 22 and FinOpsApply 11 with
      Windows PowerShell 5.1 as the host. Suites that start child shells through
      `ProcessStartInfo.ArgumentList` (RelativeRecordPath, FlowStart, FlowPermutations, Test-All)
      need PowerShell 7 as the host, which is how Test-All runs them; their children run on both
- [x] Council round 1, five seats, over `0345e85..5de7ba2`: Architect, Coder, QA, UX and Security
      PASS. Its one note, the stale "21 on both shells", is corrected above
- [x] The first packet gate, at `01f9605` on 2026-09-28 (19:20), failed one check: "Test-All counts
      every check" (`tests/Test-RunnerIntegrity.ps1`). Its `Get-Registered` reads a check name between
      single quotes with no quote inside, so the new registration `'Decision record paths are
      PowerShell''s'` was not read: the copied runner had no stub for `Test-RelativeRecordPath.ps1` and
      exited 1. The check is renamed "Relative decision record paths follow the current folder", and
      the integrity test now asserts that every `Invoke-Check` line in the registration is read,
      naming any line that is not (it fails on `01f9605` with that line; 47 checks pass after)
- [x] The second gate, at `d0226dd` (20:13), failed two checks that P79 does not change, under
      96-100% CPU load from other sessions: "Business unit checks detect breakage [3/4]" timed out
      at 600 s, and "Test-All counts every check" failed after 325 s. Run alone, the integrity test
      then failed twice with "every non-skipped check runs in its own process - 90 of 91" while all
      91 stub checks passed: each stub named its record `<process id>.json`, and Windows reuses
      process ids, so a later stub overwrote an earlier one's record. Records are now named by
      process id and that process's start time, and identity checks use that pair. A probe
      assertion runs one stub and checks the name; it failed on the old naming ("files:
      48620.json") and passes after; the integrity test passes 48 checks in 272 s under the same load
- [x] Council round 2, five seats, over `01f9605..d0226dd`: all five seats PASS
- [x] Council round 3, five seats, over `d0226dd..0e64028`: Architect, UX and Security PASS; two
      BLOCKs on the probe, both fixed test-first. Coder: the probe wrote and read its files before
      the `try` whose `finally` removes the scratch folder, so a failed write or unreadable record
      left the folder behind. QA: the probe accepted any number after the process id, so a constant
      such as `Proc = "$PID-0"`, which brings back the overwrite, passed. The probe now runs inside
      that `try`, starts the stub with `Start-Process -PassThru`, and requires exit code 0 and a
      record named `<id>-<start ticks>` from the started process's own id and start time. Evidence,
      run in private copies (`p79-r3-probe.ps1`, 254 s): the fixed probe fails on `Proc = "$PID-0"`,
      on records named by process id and on an empty `Proc`; the old probe passes on
      `Proc = "$PID-0"`; with an unreadable record, the old test leaves its scratch folder behind
      and the fixed test removes it; the fixed integrity test passes 48 checks
- [x] Council round 4, five seats, over `0e64028..96bee6a`: all five seats PASS
- [x] The packet gate exits 0. Gate 3, at `0e64028` (20:47-21:24), passed: Test-All in 2,216 s,
      22 passed, 2 warned (open unknowns), 0 failed. Gate 4, at `96bee6a` (21:44-22:28), the tree
      that merges, passed: Test-All in 2,666 s, 22 passed, 2 warned, 0 failed. Both ran while other
      sessions held the machine at 88-100% CPU; the lead raised only the gate's own processes to
      AboveNormal priority. Gate 4 ran without the shared lock, which the P71 agent held from 21:25
      for its mutation and full-suite runs

## P77 a 60-minute gate budget while the exclusive checks are sharded, 2026-09-28

Merged to `main` as `e393487` (`--no-ff`, 2026-09-28); the merge tree equals the tree of the branch
head `dcb6593`.

`.ironclad/charter.json` gives every gate command 1,800 seconds ([ADR-0025](adr/0025-parallel-test-suite.md)).
On 2026-09-28 the packet gates ran on this repository's gate machine (16 logical CPUs) under the
shared lock at the default throttle of four: P76 1,368.1 s and P75 1,371.1 s and 1,688.3 s passed;
P69's own gate passed at 1,683.9 s and then timed out at 1,800 s (CPU averaged 68.4%). On `b4e970b`,
P69 merged with `main` `040ca87`, the gate timed out at 15:10 at throttle 8 and again at 15:54 at the
default throttle, with no other gate or review running. The measurements, the load (Defender's
scanner used about 2.4 cores at 15:45, with 121 threads queued) and the options are in
[ADR-0036](adr/0036-gate-budget-until-sharded.md). Work is on `p77-gate-budget`, based on `040ca87`.

- [x] `commandTimeoutMs` is 3,600,000; `tests/Test-All.ps1`, its throttle, per-check timeouts and
      shards are unchanged
- [x] ADR-0036, CHANGELOG, and ROADMAP P78, which returns the budget to 1,800,000
- [x] Council, five seats: round 1 BLOCK (ARCHITECTURE.md and REFERENCE.md stated the 30-minute budget
      as current; the ADR's check counts and two agent-reported gates; fixed in `2d0fa09`), round 2 all
      five seats PASS. No test run: the change is one charter number and documents
- [x] The next packet gate on `main` passes within the new budget: P69's, on `d73e3fd` (P69 with `main`
      `9635426`), 16:43:46-17:17:30 IST: 22 passed, 0 failed; Test-All 2,015.2 s, above the former
      1,800 s and within 3,600 s

## P75 the macOS/Linux installer prices its choices, 2026-09-28

Merged to `main` as `5d1cd03` (`--no-ff`, 2026-09-28); the merge tree equals the tree of the branch
head `b52e9d9`, which differs from the gated `e830a6d` only in this file.

`install-claude-gateway.sh` is the macOS and Linux installer. It asks for the region with no
price, asks for the tier with no price, and its summary, which is the approval, says "BasicV2 is
about $150/month at list price" whatever tier and region were chosen, and "Provisioning takes
30-45 minutes". `Install-ClaudeGateway.ps1` stopped printing both before P68 (CHANGELOG: a Premium
v2 install was approved against the fixed figure at $2,800/month, and the whole install took
5 minutes 23 seconds), and prices its region and tier prompts since P68
([ADR-0032](adr/0032-guided-flow-starts-at-once.md)). The bash installer's record also lacks the
tier, the region and the Foundry account, and it does not offer the FinOps tool. Work is isolated
to `p75-bash-installer-prices`, based on `38ad175`.

Measured at 01:30 UTC on 2026-09-28: the Azure Retail Prices API query the PowerShell installer
uses (`serviceName eq 'API Management' and priceType eq 'Consumption'` and the three v2 unit
meters) returned 182 rows on one page in 0.6 s; in eastus2, Basic v2 0.20548, Standard v2 0.9589
and Premium v2 3.83562 an hour, USD 150, 700 and 2,800 a month at 730 hours; Italy North
publishes two of the three meters. `az account list-locations` returned 109 regions in 4.9 s,
including EUAP and staging regions in the US geography group that publish no v2 price.

Found while testing: jq.exe on Windows ends its output lines with CRLF. In Git Bash, the last,
empty field of a tab-separated option line was a carriage return, which is not empty and which
awk reads as 0, so a tier that a region does not publish (in the test fixture, one region without Premium v2) printed
as USD 0.00. Measured in Git Bash: command substitution drops the carriage return of the last
line only, so a single value (a URL, a price) keeps none, and lines that `read` splits keep theirs.
The region lines drop it before they are split, and the stub `az` and `curl` refuse any argument
that carries one. The discovery loop that already existed (`--foundry-account` not given) reads
`jq -r` output the same way and is not changed here.

- [x] Asked in a terminal, the region prompt lists the default region first (the Foundry
      account's region unless `--location` names another) and then the other physical regions in
      its geography group that publish a v2 price, cheapest Basic v2 first, each with the three v2
      tiers' monthly list price for one unit at 730 hours, from one Retail Prices API call; a tier
      a region does not publish reads "not published"; the answer is a number or a region name in
      any case or spacing, and anything else is asked again
- [x] The tier prompt shows each tier's monthly list price in the chosen region
- [x] The summary prices the chosen tier in the chosen region at list price, or says the price
      could not be read and names the pricing page; it no longer names a fixed price, and the
      provisioning note is the PowerShell installer's measured figure
- [x] With the prices unreadable, the region and tier prompts say so with the reason, and the
      install goes on; under `--yes` there is no table and no tier list, and the summary still
      prices the choice
- [x] The record holds `mode`, `sku`, `location`, `foundryAccount`, `foundryResourceGroup` and
      `requestsPerMinute`, as the PowerShell installer's record does
- [x] Run on its own in a terminal, it ends by offering the FinOps tool
      (`scripts/Select-ClaudeFinOpsTooling.ps1 -Region`, through PowerShell 7); `--choose-finops`
      opens it without asking and `--skip-finops-offer` leaves it out; without PowerShell 7, or
      under `--yes`, the command is a numbered next step
- [x] `tests/Test-BashInstaller.ps1` runs the installer in Git Bash from a TEMP copy, with stub
      `az`, `curl` and `pwsh` and a PATH without the real Azure CLI, over a terminal run, a region
      named by name, an unknown region, unreadable prices, `--yes`, a full run to the record, the
      FinOps offer accepted, declined, skipped and forced, and no PowerShell 7; the script uses no
      construct that needs bash 4, since it states that it runs on macOS
- [x] SETUP.md and CHANGELOG

Mutations, each in its own copy of the worktree, counted as caught only when the suite ran all 49
checks and at least one failed: 24 of 24 caught, among them free-tier rows kept, the first tier
instead of the marginal one, other geographies or unpriced regions listed, the summary pricing Basic
v2 whatever is chosen, prices read at every use, one page read, the table under `--yes`, the
record without the tier, the FinOps tool offered under `--yes` or with `CLAUDE_NONINTERACTIVE=1`,
a bash 4 construct, and a carriage return in the region lines or reaching `az`. A 25th, the
carriage return strip removed from the next-page link, survived: in Git Bash a single value keeps
no carriage return, so that strip changed nothing, and it is removed.

Council round 1 (gpt-6-astra, five seats, read-only, over `38ad175..426b132`): BLOCK.

| Seat | Verdict | Finding | Fix |
|---|---|---|---|
| Architect | PASS | Should-fix: the cent was rounded half up. `ConvertTo-MonthlyPrice` rounds a `[decimal]` half to even, so 0.2005 an hour was 146.37 a month in bash and 146.36 in PowerShell | The monthly figure is computed on whole billionths of the price as written and rounded half to even. It equals `[math]::Round([decimal]$p * 730, 2)` over the parity run's 160 prices and, in a one-off run, over 3,207 prices, 200 of them half-cent months |
| Coder | BLOCK | `read` with a tab IFS joins empty fields: with Standard v2 missing, the Premium v2 price printed under Standard v2 | A price that is not published is written `null`, which `money_` prints as not published |
| Coder | BLOCK | An `az account list-locations` entry that is not a region object stopped both jq reads, and any region name was then taken | Entries that are not objects with a string `name` and an object `metadata` are skipped, as `Read-GatewayRegion` skips them |
| QA | BLOCK | Without jq the suite printed SKIP and exited 0 with no check | The suite fails without bash or jq; Test-All skips it with the reason |
| QA | BLOCK | The offer-order check passed when the next step it compares with was absent | Both positions must be found |
| UX | BLOCK | A price list jq could not transform read as prices that are not published, with no reason | The transform's exit status is checked, a price that is not a number fails it, and the prompts give the reason |
| Security | BLOCK | `NextPageLink` reached curl unchecked, a `file://` link included | Only a next page on `https://prices.azure.com`, with or without `:443`, is read, and curl runs with `--proto '=https'`. The URL always starts with `https://`, so no argument reads as an option |
| Security | should-fix | jq's directory and `/usr/bin` can hold a real `pwsh` or `az` | The runs call jq through a stub that names its absolute path; their PATH is the stubs, `/usr/bin` and `/bin`, and the run without PowerShell 7 reports SKIP when `/usr/bin` or `/bin` holds a `pwsh` |

Found while fixing:
- The API writes its next page as `https://prices.azure.com:443/api/retail/prices?...&$skip=1000`
  (read 2026-09-28 from a query of more than 1,000 rows). A check for `https://prices.azure.com/`
  alone would have refused every second page.
- In bash, `"${x:-{}}"` with `x` set expands to `$x` followed by `}`: the parser ends the expansion
  at the first `}`. The default is assigned on its own line.
- In PowerShell, a cast of an empty pipeline, `[string](@() | Select-Object -First 1)`, is `$null`,
  not `''`, so the suite's missing-jq branch would have thrown. It uses `"$(...)"`.

`tests/Test-BashInstaller.ps1` now holds 62 checks over 19 runs, in about 30 s. The new runs: a
missing first and middle price, region entries that are not regions, a price written as a string,
a next page off the host and one over `http://`, and a parity run over 160 prices in 61 regions,
72 of them half-cent months. In the terminal run and the parity run, the region table must equal
the one `Format-ClaudeGatewayRegionTable` prints from the same files through
`Get-ClaudeApimV2Prices`. Against `426b132`'s installer, 8 of the new checks fail. 12 new
mutations, 12 caught at 62 checks: the order check with its anchor renamed, an empty field for an
unpublished price, the type checks removed from either region read, the transform's status
ignored, a price written as a string taken, any next page followed, the API's own next-page form
refused, a half cent rounded up, every price rounded as a double, and the price map defaulted with
the stray brace.

Council round 2 (gpt-6-astra, five seats, read-only, over `426b132..2cb7c7a`): BLOCK. Every
round-1 BLOCK is closed.

| Seat | Verdict | Finding | Fix |
|---|---|---|---|
| Architect | BLOCK | B1: one price written in different ways was rounded differently. jq 1.7 and later keep a number's literal text, so `0.2005000000` and `2.005000000e-1` took the double fallback and gave 146.37 a month where `0.2005` gave 146.36; `10000.0005` gave 7300000.37 where PowerShell gives 7300000.36. 40 of 7,420 inputs differed | `547df27` |
| Coder | PASS | the round-1 findings 3 and 4 closed | none needed |
| QA | PASS | findings 6 and 7 closed; add B1's literals to the parity fixture | `547df27` |
| UX | PASS | finding 9 closed | none needed |
| Security | PASS | finding 10 closed; no `--` before the URL is safe after the URL check | none needed |

`ConvertTo-MonthlyPrice` computes `[math]::Round([decimal]$HourlyPrice * 730, 2)`. On PowerShell 7,
ConvertFrom-Json reads the price as a double, and `[decimal]` of a double is .NET's VarDecFromR8:
the double is scaled by a power of ten chosen from its binary exponent, in double arithmetic, and
rounded half to even to at most 15 significant digits (measured on .NET 10.0.12: 0.0074999999999999945
becomes 0.0075, and 3.9985000000000052 becomes 3.9985). Cutting the double's shortest decimal form to
15 digits, tried first, gave 5.47 and 2918.91 for those two, where PowerShell 7 gives 5.48 and
2918.90: 2,485 differences over 124,993 prices of at most 17 significant digits, 72,000 of them a
hair from a half-cent month. The installer's `monthly` now takes the same steps as VarDecFromR8:
the binary exponent by exact halving and doubling (jq 1.5 has no `frexp`), the same power of ten
and scale, the same rounding, then the 730-hour product on digit strings with cents half to even.
Over the same 124,993 prices, run through the installer's own definitions with jq 1.8.2: 0
differences from PowerShell 7; over 3,000 of them through the whole transform: 0.

Two limits, stated in the installer: Windows PowerShell 5.1 reads a price written without an
exponent as an exact decimal, so above 15 significant digits the two PowerShell hosts can differ by
a cent, and this installer gives PowerShell 7's; jq 1.7.1 and later round a price written with more
than 17 significant digits to 17 before converting it (0.0105000000000000501 becomes
0.01050000000000005, where .NET reads 0.010500000000000051), so such a price can differ by a cent.
Every one of the 43 differences in a set of 132,993 had 18 significant digits, measured with jq 1.8.2.
The Retail Prices API wrote the 182 API Management v2 prices with at most 7 significant digits (read
2026-09-28). jq 1.7.0 differs more: see council round 3 below.

The parity fixture has ten written prices: B1's three, 6.25E-2, 0.2214999999999999, 1.25e-05, and
four 17-digit prices a hair from a half-cent month (PowerShell 7: 5.48, 147.10, 752.27 and 2918.90).
Against `2cb7c7a`'s installer the parity check fails (pr67: bash 5.47, PowerShell 5.48); after the
fix the 62 checks pass, in 50 s.

Mutations, the same rule, at 62 checks: 36 of 36 caught. The two that changed the former rounding
(a half cent rounded up, every price rounded as a double) targeted code that is gone; three take
their place: cents rounded half up on the digit string, the 15-digit conversion rounding half up,
and the 15-digit conversion truncating.

Council round 3 (gpt-6-astra, five seats, read-only, over `2cb7c7a..dcca62c`): BLOCK. B1 is closed:
its three prices and the four near-ties match PowerShell 7, and 11,705 more inputs (zero, exponent
forms, 0.0001 to 100,000) differed on none of jq 1.5, 1.6 and 1.8.2.

| Seat | Verdict | Finding | Fix |
|---|---|---|---|
| Architect | PASS | B1 closed | none needed |
| Coder | BLOCK | B2: jq 1.7.0 converts a number literal through a 16-digit decimal (decimal64), so 0.010500000000000051 gives 7.66 a month where PowerShell 7 gives 7.67; 18 of the 11,705 inputs differed on jq 1.7.0. `scripts/preflight.sh` accepts that release | the preflight warns, below |
| QA | PASS | the literal-preserving fixtures exercise B1 | none needed |
| UX | BLOCK | B2 in the text: "jq 1.7 and later" is wrong for 1.7.0 | the installer's comment and this section name 1.7.0 and 1.7.1 apart |
| Security | PASS | the new arithmetic runs no command and reads no path | none needed |

Measured after the review, with the official release binaries of jq 1.5, 1.6, 1.7 (which names
itself `jq-1.7-dirty` on Windows) and 1.7.1, over the 124,993 prices of at most 17 significant
digits: jq 1.7.0 differed from PowerShell 7 on 8,686, every one of them written with 17 significant
digits; jq 1.5, 1.6 and 1.7.1 on none. The jq 1.7.1 release notes name the change: the conversion
through decimal64 was replaced ([NEWS](https://github.com/jqlang/jq/blob/jq-1.7.1/NEWS.md)). The API
writes these prices with at most 7 significant digits, so with jq 1.7.0 every published price matches
PowerShell 7's cent; a refusal of jq 1.7.0 would stop an install over a price form the API does not
use. The admin preflight warns instead: "jq 1.7.0: a price written with 17 significant digits can be a
cent off; jq 1.7.1 or later matches the PowerShell installer", with how to upgrade. The developer
setup computes no price and is not warned. `tests/Test-BashInstaller.ps1` has two more runs, with jq
reporting `jq-1.7-dirty` and `jq-1.7.1`: the first is warned and installs, the second is not warned,
and neither is the jq on the machine (66 checks, in 43 s).

Council round 4 (gpt-6-astra, five seats, read-only, over `dcca62c..9cd7b77`): all five seats PASS.
B2 is closed as a warned limit, not an arithmetic fix: the warning is proportionate for prices the
API writes with at most 7 significant digits, and it does not make jq 1.7.0 exact for a price
written with 17. The Coder seat checked the pattern against `jq-1.7`, `jq-1.7-dirty`, a trailing
carriage return and distribution suffixes (warned) and `jq-1.7.1` and `jq-1.8.2` (not warned), in
bash 3.2 syntax; the merge of main changed only the Active packets line.

After the review, under the shared lock (2026-09-28 13:03-13:05 IST): the suite against the preflight
before the warning (`dcca62c`) fails one check, the jq 1.7.0 warning, and passes the other 65; the
two new mutations, each in its own copy and counted at 66 checks, are caught: no warning on jq 1.7.0
(the jq 1.7.0 check fails), and the match without its guard (the jq 1.7.1 check fails).

- [x] Council, five seats (round 4, all PASS)
- [x] The packet gate exits 0 on the tree that merges: at `e830a6d` (P75 on `main` `e39c3e4`, with
      P76), 2026-09-28 13:07:14-13:35:32 IST under the shared lock: 22 passed, 2 warned, 0 failed,
      2 skipped; Test-All passed in 1,688.3 s of its 1,800 s budget, the Bicep build in 7.8 s. The first
      gate, at `f32bcde` (P75 on `f98f885`), 12:11:23-12:34:23: the same counts, Test-All 1,371.1 s.
      Other agents' reviews ran during the second gate: the serial-lane flow checks, whose code P75 does
      not change, took twice as long (the permutations 215.2 s against 91.0 s in P76's gate and 103.2 s
      in the first), and the checks' seconds summed to 3,756 against 3,127.

## P76 one plan, one order on both shells, 2026-09-28

Merged to `main` as `d731023` (`--no-ff`, 2026-09-28); the merge tree equals the tree of the branch
head `2738cff`, which differs from the gated `ffa7000` only in this file.

P72 made the guided flow write its canonical text itself, so that one plan has one fingerprint
on PowerShell 7 and Windows PowerShell 5.1, and documented that
([GUIDED-FLOW](GUIDED-FLOW.md#review-and-fingerprint)). A live, read-only
`Start-ClaudeGateway.ps1 -Action Setup -PlanOnly` over the reference record on 2026-09-28 at
02:50 UTC printed the same review on both shells and two fingerprints (`9ec3475f...` on 7,
`1cd0781d...` on 5.1). Each step's canonical text, dumped on both shells, differed in one step:
Monitoring lists `infra\workbook-chargeback.json` before `infra\workbook.json` on PowerShell 7 and
after it on 5.1. `Sort-Object` compares by culture, and .NET Framework (NLS) gives a hyphen almost
no weight where .NET's ICU does not. P72's suite compared fingerprints over the Foundation step
and stub steps only, so it passed. Four sorts in `scripts/flow` feed plans: the workbook and KQL
lists (`Monitoring.ps1`), the priced model list (`Budgets.ps1`), and the named values that the
policy references (`lib/LifecycleCommon.ps1`), which the Update migration `0002` carries in its
plan and creates in that order. Work is isolated to `p76-ordinal-order`, based on `38ad175`.

- [x] `Sort-ClaudeFlowOrdinal` in `scripts/flow/FlowContract.ps1` orders by code point, ignoring
      case as `Sort-Object` does, with `-Unique`; the same list gives the same order on both shells
- [x] The four sorts use it, so no `Sort-Object` remains in `scripts/flow`; a check refuses a new one
- [x] `tests/Test-FlowOrdinalOrder.ps1`: every step of Setup with the shipped modules, planned
      offline from one record on both shells, has the same canonical text and the same fingerprint;
      the Update migration's named values are the same list in the same order on both shells
- [x] GUIDED-FLOW and CHANGELOG

Measured after the fix: PowerShell 7's culture order already matched code-point order for the
shipped workbook list and the policy's 24 named values, so its plans keep their fingerprints;
on Windows PowerShell 5.1 the Monitoring and Update plans have new ones. Found while testing:
`[Array]::Sort($keys, $items, [StringComparer]::Ordinal)` in PowerShell binds the generic overload
and passes it a converted copy of the items, so only the keys were sorted; the plan comparisons
still passed, because NTFS and the policy file already listed both in one order, and the checks of
the helper's own output failed. Casts select the overload that sorts both.

Mutations, each in its own copy of the worktree, counted as caught only when a suite ran its
baseline number of checks (Test-FlowOrdinalOrder 14, Test-FlowFinOps 33, Test-FlowLifecycle 33)
and at least one failed: 10 of 10 caught. They are the casts removed, a culture comparer in the
helper, `Sort-Object` back in Monitoring and in `lib/LifecycleCommon.ps1`, the `sort` alias, `-Unique`
dropped from the price book and from the named values, `-Unique` keeping every item, case not
ignored, and no code-point tie-break after the folded key. The last one survived at first: the
suite compared the orders with `-eq`, which ignores case, so `b,B` equalled `B,b`. Every string
comparison in the suite is now case-sensitive, and two checks were added that no suite had: the
Budgets price book lists each unpriced model once, and the Update migration reads each named value
once (the policy holds 39 references to 24 named values).

Found after that, by reading the call sites the flow shares: three more culture sorts sat outside
`scripts/flow`. `Start-ClaudeGateway.ps1` ordered the step modules by file name with `Sort-Object`,
and `scripts/Update-ClaudeGateway.ps1` the migrations; both orders set the order of the plans that
the fingerprint covers. A third, the resume check in `Start-ClaudeGateway.ps1`, compares two sorted
lists on one host. All three use `Sort-ClaudeFlowOrdinal`, and the scan now covers every script at
the root or in `scripts/` that loads `FlowContract.ps1`, besides `scripts/flow`; a check names the two
entry points, so a scan that found neither fails. The shipped module and migration names hold no
hyphen or underscore at a position where culture and code-point order differ, so no plan's
fingerprint changes with this. The helper also compared keys joined as `folded` + U+0000 + `key`: a
key holding U+0000 moved another key out of place, so `a` sorted after `a<U+0000>A` and
`a<U+0000>b`. It now compares the folded keys, then the keys, then the input positions, with
`[string]::CompareOrdinal`.

Mutations after that, the same rule: 13 of 13 caught at 17, 33 and 33 checks, the 10 above
rewritten for the new comparer, the keys joined by a separator again, and `Sort-Object` back in the
module and migration orders and in the resume check.

Council round 1 (gpt-6-astra, five seats, read-only, over `38ad175..893c354`): BLOCK.

| Seat | Verdict | Finding | Fix |
|---|---|---|---|
| Architect | BLOCK | Two culture sorts outside `scripts/flow` set the order of fingerprinted plans: the step modules (`Start-ClaudeGateway.ps1:144`) and the migrations (`scripts/Update-ClaudeGateway.ps1:38`); `Sort-Object Name` put hyphenated names first on 7 and last on 5.1 | `5019cdb` (found in parallel before the report arrived), and the scan below |
| Coder | PASS | should-fix: a key holding U+0000 moved another key, because the helper joined keys with it | `5019cdb`: keys compared as values |
| QA | PASS | two temporary mutations caught; the checks did not cover the sorts outside `scripts/flow` | the scan below |
| UX | PASS | GUIDED-FLOW and CHANGELOG state the fingerprint change and what to do | none needed |
| Security | PASS | should-fix: the same U+0000 order | `5019cdb` |

Merging main (`f98f885`, P70) into this branch (`00b8376`) failed the scan: P70's model lifecycle
(`scripts/ClaudeModelLifecycle.ps1`, which loads `FlowContract.ps1`) sorted its deployments, tier
lists, questions and assignments with `Sort-Object`. The flow's plans also run code that loads
neither: the price book (`scripts/ClaudeModelPrices.ps1`), the deployment list
(`scripts/ClaudeModelDeployment.ps1`), the region choice (`scripts/ClaudeGatewayRegion.ps1`) and
the installer's default tier model lists (`Install-ClaudeGateway.ps1`). Measured on Windows
PowerShell 5.1 at `00b8376`, with names whose culture order differs between the shells: a model
change over tier lists already in code-point order proposed `Update models-standard` and
`Update models-premium` to write the same members in another order, and its fingerprint differed
from PowerShell 7's; a deployment whose model matched two price-book spellings took
`claude-x-1.5` on 5.1 and `claude-x-1-5` on 7; regions at one price were listed `usa, us-b` on 5.1
and `us-b, usa` on 7; the deployable models were listed in reverse.

All 14 of those sorts use `Sort-ClaudeFlowOrdinal`, which now takes keys as `Sort-Object`'s
`-Property` does (script blocks, property names, hashtables with `Expression` and `Descending`),
compares numbers, times and versions by value, and has `-Descending`. The three libraries load
`FlowContract.ps1` only when the helper is not already defined, and the installer loads it.
`tests/Test-FlowOrdinalOrder.ps1` follows every script the fingerprinted plans load (the
orchestrator and every step module, the Update, the model sync and the installer, and what they
dot-source, 43 scripts, read from the syntax tree) and lists the 17 `Sort-Object` calls left in them,
each with its reason: a value key (prices, integers, versions), an order that reaches only the
console (menus, an error), or an order used inside one process (a cache key, set comparisons). A
listed call that is gone or changed fails the check. `scripts/ClaudeClientSupport.ps1` keeps its
three: the workstation bundle fetches only the files `Setup-ClaudeWorkstation.ps1` names, so it
loads nothing more. Against `00b8376`, 22 of the 35 checks fail, on 5.1 each of the four cases above;
after the fix all 35 pass (`d723f90`).

Mutations after that, the same rule, at 35, 33 and 33 checks: 25 of 25 caught. The ten helper
mutations above rewritten for the new comparer, the three outside `scripts/flow`, and twelve new:
`-Descending` ignored, a key hashtable's `Descending` ignored, numbers compared as strings, only
the first key used, `Sort-Object` back in the tier lists, the model-list reader, the price-book
entry and the installer's tier lists, the regions at one price in arrival order, the deployable
models ascending, the price book no longer loading the helper, and a listed sort changed. `-Unique`
keeping every item first counted as broken, not caught: the probe of the Setup steps failed, and
the seven checks that read it were skipped, so the suite made 34 checks. Those checks are now made
whether or not the probe ran, and the mutation is caught at 35. The 15 suites that load the changed
scripts pass, among them P70's lifecycle mutations (62 of 62 caught at 138 checks), the installer
permutations and the guided flow.

Council round 2 (gpt-6-astra, five seats, read-only, over `893c354..48dd68a`): all five seats PASS;
the round-1 Architect BLOCK and the U+0000 should-fix are closed. Should-fix (Architect): the check
follows dot-sources only, so a script a step runs as a separate command is not read;
`scripts/flow/Monitoring.ps1:76-80` runs `Publish-ClaudeWorkbook.ps1` with `&`, and its `Sort-Object`
at line 207 is not listed. Read after the review: that sort orders the names in an error message
only. Following every `.ps1` name written in the flow's scripts reaches 123 scripts, most of them
named in the Guide's text or run as their own tools. The one among them with its own fingerprint,
the network edge review, hashes the stored text of its review file on apply
(`scripts/ClaudeNetworkReview.ps1:39`), so the shell that applies it does not change what was
approved. The check's comment and this section state the boundary: the scripts the plans load, not
the scripts their steps run.

- [x] Council, five seats (round 2, all PASS); the packet gate exits 0: `node .ironclad/gate.mjs --stage packet`
      at `ffa7000`, 2026-09-28 11:48:23-12:11:20 IST under the shared lock: 22 passed, 2 warned, 0 failed,
      2 skipped; Test-All passed in 1,368.1 s of its 1,800 s budget, the Bicep build in 7.3 s

## P72 permutation tests of the guided flow and the installer, 2026-09-28

The owner's test on 2026-09-27 found the guided flow's defects one path at a time. P72 tests the
combinations the [ROADMAP](ROADMAP.md) entry names. Work is isolated to `p72-permutations`, based
on `aa7ed19`. Reading the installer to size the matrix found two defects before any test ran, both
measured against the reference subscription with `-WhatIf -Yes` (read-only) at 20:17 UTC on
2026-09-27:

- The Claude Desktop sign-in section of `Install-ClaudeGateway.ps1` is inside the `else` branch
  that asks the developer sign-in, so `-AuthMode` skips it. With `-AuthMode device
  -DesktopSignInKind external-idp-browser -DesktopEntraClientId <id>` the run printed no Desktop
  gateway audience; the same run without `-AuthMode` printed `Desktop gateway audience: <id>`.
  The flow's unattended Setup and Change foundation pass both parameters.
- The installer's summary is the approval ([ADR-0032](adr/0032-guided-flow-starts-at-once.md)).
  It names the developer sign-in, and not the entitlement store, the Claude Desktop sign-in or the
  developer address.

Measured before the tests: each live installer run under `-WhatIf -Yes` with every placement
parameter given takes 18-20 s, of which nine Azure CLI calls take nearly all; a matrix of 54
combinations on two shells takes about 36 minutes that way. The suites therefore stub the Azure
CLI and the Retail Prices API, and the live matrix runs once, outside Test-All.

What the suites found, each fixed test-first (commits `acf993b`, `bf78e0a`, `12821ca`):

| # | Found by | Defect | Now | Held by |
|---|---|---|---|---|
| 1 | reading, then live `-WhatIf -Yes` | `-AuthMode` skipped the Claude Desktop sign-in section, so an external IdP choice became the helper script | the section runs whatever `-AuthMode` is | installer suite: the gateway audience in the 36 external IdP cases with `-AuthMode` |
| 2 | reading | the summary, which is the approval, named 1 of 7 choices | it names the store and resolver access, revocation window, team budget behaviour, developers with no team, address, developer and Desktop sign-in | installer suite: each row in 96 cases on both shells |
| 3 | installer suite | the address question showed `https://<prefix>.azure-api.net`; the gateway is `apim-<prefix>` | the gateway's hostname | installer suite: the question and the summary row |
| 4 | installer suite | under `-Yes`, an external IdP sign-in without its app, scope or audience reached the summary (with `-AuthMode`) or stopped naming a record field | stops before the summary, naming the parameter, saying that nothing was created | installer suite: 6 refusals |
| 5 | flow suite | one plan had two fingerprints: `ConvertTo-Json` escapes `' < > &` on 5.1 only, and `Sort-Object` compares by culture; 10 of 12 plans differed | the flow writes its canonical JSON strings itself and sorts keys ordinally | flow suite: 11 plans on both shells; `Test-FlowContract.ps1`: the canonical text of a pinned value |
| 6 | flow suite | 24 of 29 refusals printed PowerShell's code excerpt, and one wrapped the reason across lines | a top-level run prints the reason and exits 1; an in-process call still gets the exception ([U36](UNKNOWNS.md#u36--a-top-level-run-and-an-in-process-call--closed-2026-09-28)) | flow suite: 26 refusals; `Test-GuidedFlow.ps1`: the in-process refusals |
| 7 | flow suite | every apply ran `git`: without it, or outside a repository on 5.1, the apply stopped after writing `activeRun` | the release info records no commit | flow suite: the applies without an Azure CLI (PATH without git) and 3 applies on 5.1 in a copy that is not a repository |
| 8 | flow suite | the merge recorded Desktop sign-in as `external-idp`, which `-DesktopSignInKind` refuses, and dropped the app, issuer, scopes, audience, token type, tier groups, budgets and request ceiling, so an unattended Change foundation failed or reset them | the merge maps them back in parameter values; the flow passes `-DesktopBearerTokenType` and `-ResolverInboundAccess`; the installer records `requestsPerMinute` | flow suite: Setup then Change foundation give the installer the same 15 values; 3 recorded Desktop shapes; the installer's record holds the 17 fields the merge reads |
| 9 | flow suite | unattended, an external IdP sign-in without its app was approved and failed in the installer | the plan refuses, naming `foundation.desktopEntraClientId` | flow suite: 4 cases |
| 10 | flow suite | Guide went on silently over drift, and with nothing recorded wrote placeholders and then failed its verification | Guide names the drift; with nothing recorded it refuses before planning | flow suite: 4 and 3 cases |
| 11 | flow suite | Status with no record said "none detected" | it says that nothing is recorded | flow suite: Status in each record state |

Found and not fixed here: an installer re-run over an existing gateway offers the installer's
defaults for the budgets, request ceiling, groups and Choices, since only
`entitlement-cache-seconds` is read back, so pressing Enter through an attended
`-Change foundation` resets them. Filed as P73 in the [ROADMAP](ROADMAP.md).

Mutations, each in its own copy of the worktree, counted as caught only when the suite ran its
baseline number of checks and at least one failed: 33 of 33 caught, 25 before the council, 7 for the round-1 fixes and 1 for the round-2 fix. The first run caught 20 of 22.
The two survivors were the budget merge, masked because the round trip's answers already put the
budgets in the decision, and Status with no record file, masked by the branch for a record
without a gateway. The tests now check the merge from a decision that holds no budgets, and Status
in both cases. The 25th mutation keeps a resolver access for a named-value store; the check added with that fix catches it.

- [x] `tests/Test-FlowPermutations.ps1` runs the real orchestrator, discovery and Foundation step,
      with a stub installer and a stub Azure CLI, over action (Setup, Change foundation, Guide,
      Status) × record state (none, recorded and matching, another gateway URL, missing, signed
      out, no Azure CLI) × mode (attended, `-PlanOnly`, unattended apply). In each combination:
      the installer runs only for Change foundation or a Setup with no gateway recorded; `-Yes` is
      passed exactly when unattended; drift (another URL, missing) stops Setup and Change before
      planning, and Guide goes on; a read that failed is reported as not read, never as drift;
      Status and `-PlanOnly` write nothing; a refusal prints its reason and no PowerShell code
      excerpt ([U36](UNKNOWNS.md#u36--a-top-level-run-and-an-in-process-call--closed-2026-09-28)).
      77 runs, 11 of them on 5.1; 16 boundary runs (`-WhatIf`, Update with no record, cancels through `&`, dot-sourced and prompt callers on both shells, unexpected errors); 8 store and 4 round-trip runs; 43 checks; about 110-130 s
- [x] In process, Foundation's installer arguments over entitlement store × Desktop sign-in ×
      developer sign-in × tier × attended or unattended × new or recorded gateway:
      `-DeployProjection` exactly when unattended with the projection store; with
      `-ExistingApimName`, the recorded region, tier, name and publisher are never passed; an
      external-IdP Desktop sign-in without a client id is refused by the plan, before approval;
      distinct inputs give distinct fingerprints. 432 plans; every argument is checked against the
      installer's parameter block and its ValidateSets, read from its AST
- [x] `tests/Test-InstallerPermutations.ps1` runs the real installer under `-WhatIf -Yes`, with
      the Azure CLI and the Retail Prices API stubbed in process, over tier × entitlement store ×
      developer sign-in × Desktop sign-in, with and without `-AuthMode`, on PowerShell 7 and
      Windows PowerShell 5.1: the summary names each choice, and each refusal comes before the
      summary with its reason. Offline, every combination: 96 cases, plus 6 refusals and a
      reused gateway, 103 per shell, 44 checks, about 40 s; `-Live` and `-Pairs` run 16 cases that
      cover every pair of levels (62 pairs, checked by the suite), 23 per shell
- [x] Each failure found is fixed test-first, starting with the two above
- [x] The installer matrix runs once live and read-only against the reference subscription on
      both shells; the result and timings are recorded here. 2026-09-27 22:18-22:26 UTC, `-Live`
      with the reference Foundry account and, for the reuse case, the reference gateway read only:
      23 of 23 cases on PowerShell 7 and 23 of 23 on Windows PowerShell 5.1, one process per shell;
      42 checks passed (the two about the stub's Azure CLI calls apply offline only); 458 s and
      455 s in the installer, about 20 s per case; 470 s wall. Nothing was created: every case stops
      at the `-WhatIf` summary
- [x] The address dimension: P69 owns the installer's address section and adds its parameter.
      The harness adds the address when P69 merges, or the follow-up is recorded in ROADMAP.
      Recorded in P73; the summary row and the address question's hostname are tested now
- [x] GUIDED-FLOW.md names the suites and what they hold
      ([What the tests hold](GUIDED-FLOW.md#what-the-tests-hold)); SETUP.md describes the summary
      and the `-Yes` Desktop parameters, with a live image
      ([70](guide/70-installer-summary-every-choice.png)); CHANGELOG
- [x] Council, five seats; the packet gate exits 0. Round 3 passed on all five seats; the gate on `347b702` passed

Council round 1 (gpt-6-astra, read-only, over `aa7ed19..6d5320f`): BLOCK. It ran the installer,
flow-contract and flow suites; all passed, and the blocks come from reading the code.

| Seat | Verdict | Finding | Now |
|---|---|---|---|
| Architect | BLOCK | A1: the docs said every fingerprint changes; a plan with only ASCII text and code-point-ordered keys keeps its own | GUIDED-FLOW and CHANGELOG say which plans change |
| Coder | BLOCK | C1: the merge kept a resolver access for the named-value store | fixed in `744fd18` before the review ended; 25th mutation |
| Coder | BLOCK | C2: a cancelled installer and a mistyped confirmation still ran `exit 1`, so a caller got no exception, and a dot-sourced run could exit its caller | both raise `OperationCanceledException`; the trap exits only at top level; a dot-sourced run is a call ([U36](UNKNOWNS.md#u36--a-top-level-run-and-an-in-process-call--closed-2026-09-28)); 8 caller runs, `&`, dot-sourced from a script and at a prompt, on both shells |
| QA | BLOCK | Q1: "before the summary" was the `-WhatIf` stop line, so a refusal after the summary would pass | the driver records the Summary heading; a refusal must print neither |
| QA | BLOCK | Q2: "nothing read from Azure before the installer" was true whenever the installer ran, and saw only `apim show` | every Azure CLI call is logged with its time and compared with the installer's start |
| QA | should-fix | Q3: no orchestrator `-WhatIf` or Update runs | `-WhatIf` for Setup, Change and Guide; Update with no record. Update over a live gateway reads it through several Azure CLI calls the stub does not answer; `tests/Test-FlowLifecycle.ps1` covers its plan and apply |
| UX | PASS | the debugging hint read `set CLAUDE_FLOW_DEBUG=1` on every refusal | it shows only for an error the flow does not expect, as `$env:CLAUDE_FLOW_DEBUG = '1'` |
| Security | PASS | no new path to `az.cmd`; the values the merge adds are either az-bound and checked, or ValidateSet parameters, or Desktop configuration | none needed |

The gate on `f474fe4` failed on one check: the architecture manifest was stale after `744fd18`
changed `scripts/flow/Foundation.ps1`, a source of a diagram, without a re-render. Rendered again.

Gate on `9f4a7ee`, 05:03-05:27 IST (23:33-23:57 UTC): 22 passed, 2 warned (the existing file-size
and open-unknowns warnings), 0 failed, 2 skipped (the AUM suites, which need a worktree venv).

Council round 2 (the same agent, over `6d5320f..9f4a7ee`): BLOCK. It reran the flow suite (43
checks), the installer suite (103 cases per shell, and 23 with `-Pairs`) and probes of the trap.

| Seat | Verdict | Finding | Now |
|---|---|---|---|
| Architect | BLOCK | A1 again: the new wording still tied a changed fingerprint to particular characters; on PowerShell 7 a plan with `' < > &` kept its fingerprint, and a plan with a newline changed on both shells | GUIDED-FLOW and CHANGELOG say that an earlier fingerprint may no longer match, and to run `-PlanOnly` again when one is refused |
| Coder | PASS | C1 and C2 closed; a trap from a dot-sourced run left in the caller's scope rethrows and the caller goes on, on both shells | none needed |
| QA | BLOCK | Q4: the suite's child processes inherited `CLAUDE_FLOW_DEBUG`, so with it set the unexpected-error check failed | each child starts without `P72_*` variables and `CLAUDE_FLOW_DEBUG`; the suite passes with both set; 33rd mutation |
| UX | PASS | yellow for a cancel, red otherwise, and the hint only for an unexpected error | none needed |
| Security | PASS | no new path to Azure CLI or credentials | none needed |

Council round 3 (the same agent, over `9f4a7ee..347b702`): all five seats PASS, no BLOCK. It reran its
reproduction with `CLAUDE_FLOW_DEBUG` and `P72_FINOPS_FAIL` set: 43 of 43.

Gate on `347b702`, 05:53-06:19 IST (00:23-00:49 UTC): 22 passed, 2 warned (the existing file-size and
open-unknowns warnings), 0 failed, 2 skipped (AUM, no worktree venv). Test-All passed in 1,538.1 s of its
1,800 s budget; the P72 suites took 115.5 s (serial lane), 53.7 s and 86.6 s (flow start).

Merged to main as `cac1260` (`--no-ff`; the merge tree is the branch tree).

## P71 AUM answers fast and says why it cannot, 2026-09-28

**Merged as `01bb6c7` on 2026-09-30 with the owner's approval.** Council round 11 passed on
all five seats at `0e88d19`. The packet gate passed on `72607c8`, the merge of `0e88d19` with main
`844a786`: 97 of 97 Test-All checks in 1,883.7 s, the AUM check in 401.2 s. The merge tree is
the gated tree.

### Stale tab activation without main content, 2026-09-30

**PLAN / CONTRACT:** A retained `TabActivated` must be ignored when the
default screen has no `#main-tabs`, both during a running remount gap and
after shutdown. It must not query `active`, write presentation or start a read.
A current activation with mounted main content must still refresh normally.
This is a separate lifecycle correction, not a relaxation of publication guards.

The lead reproduced the assistant-context case **4 times in 12 runs** on P85's
`bcf8554` P71 base under 16 CPU burners, without `WorkerCancelled` or the
later `f122985` sealing change. Local history shows `d7cd2f2` added the
`event.pane.id != self.active` comparison and `89852aa` added the principal
notice clause. The comparison dereferences main content before deciding an
activation is stale. Two short probes reproduce the exact `NoMatches` against
real empty default screens while running and after shutdown. The earlier
record's secondary-error diagnosis applies to its captured cancellation
traces, not to every missing-main-content failure.

**RED:** Both deterministic lifecycle cases failed in **2.44 s** with the
exact missing-`#main-tabs` error, without a cancelled worker.
The new guard uses the existing approved DOM query before `active`; only the
changed function's exact context fingerprint is renewed.

An initial nine-case control had 7 passes and 2 failures in the earlier
single-refresh detector. A message trace identified its distinct test setup
race: worker completion precedes the initial overview `TabPane.Focused`
message being handled, so it counted an overview refresh along with the
requested budgets/requests refresh. That detector now awaits completion of
the real native initial-focus handler before measuring the next activation;
its one-worker and non-cancellation assertions are unchanged.

**GREEN / REFACTOR:** All **14 targeted lifecycle, navigation, assistant and
closed-contract cases passed in 16.93 s**. No new ordinary member, exception
capability, sleep, retry or timeout allowance was introduced. The lifecycle
cases join the existing standard diagnostics selector.

The lead's stress harness completed **30 iterations with 16 CPU burners:
270/270 executions passed**, with zero failures, errors, skips or identity
mismatches. Every iteration ran the two missing-main cases, two live-navigation
controls, the assistant-context case and the prior four identities. The full
AUM suite then passed **all 831 cases in 350.98 s** (353.722 s wall), with no
errors or skips. Both proofs used the same production source.
Receipts and exact JUnit identities persist in
`.finops-evidence\p71-stale-tabs`; long raw logs remain under TEMP.

The existing architecture witness was regenerated and checked (16 specs /
18 PNGs). Only the witnessed TUI source hash changed; there is no new component,
data flow or diagram imagery.

All long jobs now use the lead's `with-gate-lock.ps1` wrapper with owner
`p71-r10b`; it acquires the shared lock and releases only its own token.
This supersedes the earlier absence-only and between-test-pause protocols.
The earlier pause plugin is not used while holding the wrapper's lock.
The loaded run held the wrapper lock from 03:56:31 to 04:17:04 +05:30; the
architecture/full run held it from 04:17:49 to 04:23:57 +05:30 on 2026-09-30.
Council, packet gates and integration remain with the lead. U26 remains OPEN
for other historical failures; no merge or push was performed.
Implementation and recorded proof: `7a28b74`
(`fix(aum): ignore tab activations without main content`).

### Startup and navigation cancellation correction, 2026-09-30

**PLAN:** Reproduce the round-10 cancellation deterministically, preserve the
closed publication contract, and prove the four reported identities under four
CPU burners for at least 30 iterations plus one complete AUM run. The lead owns
council and packet gates; this builder does not push or merge.

**CONTRACT / investigation:** The saved full-run traceback first raises
`WorkerCancelled` after navigation; `NoMatches` is a secondary shutdown error
in `FinOpsApp.switched`, not evidence of an uncomposed initial screen.
Round-10 commit `f122985` added `_seal_message`, whose diagnostic subclasses
change `type(message)`. Textual 6.12.0 filters disabled/prevented messages by
exact type in `MessagePump.check_message_enabled` and
`Widget.check_message_enabled`. Sealed `Tabs.TabActivated` and `Select.Changed`
therefore evade the framework's suppression and start replacement exclusive
refresh workers. A short trace on `e1586c5` observed two refresh workers for
one budgets navigation, cancelling the first even though that run passed.
A read-only probe also posted a supposedly prevented `Select.Changed`.
The compatibility rule and its positive/negative tests are recorded in
[ADR-0035](adr/0035-aum-bounded-readiness-and-progressive-reads.md).

**RED:** All **12 deterministic regressions failed in 2.70 s** on unchanged
`e1586c5` production source: ten original/forwarded message-control cases and
two event-held real navigation cases. Loaded RED completed **4 iterations,
16 cases: 4 failures across 3 iterations**, with four owned CPU burners.
The requested 20-iteration baseline stopped when another gate appeared;
uncompleted iterations are not counted. An earlier gate-aborted load attempt
and an aborted combined short invocation are retained but excluded from proof.

**GREEN / REFACTOR:** The initial **16-case** selection (the 12 regressions and
four reported identities) passed in **11.84 s**. Four additional native
disabled-widget press/scroll controls passed in **0.63 s**. The adapter retains
an exact reverse type mapping, checks original suppression/disabled types and
still delegates every other native eligibility rule. The reverse mapping is
initialized before its adapter can be reused by another posting thread.
The boundary and changed exact-context fingerprints were reviewed with these
counterexamples; no ordinary member or publication guard is newly allowed.
The exact source-contract/default-deny selection passed **44 cases in 4.96 s**.

The first complete corrected-source AUM run was retained: **828 passed,
1 failed in 342.66 s** (345.50 s wall). The native `FooterKey-description`
probe queried a child during Textual's post-refresh footer rebuild, before its
guard assertion. `Footer.bindings_changed` schedules `recompose`, which removes
then asynchronously remounts keys under `Widget.batch`'s lock; a worker wait
does not await that lifecycle. Event-held native mounting reproduces that
exact gap without a clock: **2 failed, 2 passed in 5.42 s** before the await.
The probe now awaits the footer's after-refresh callback and acquires the same
batch lock, then tests the current attached receiver. Direct recomposition
from the app's test task was rejected by Textual's reactive binding-owner
check; the final probe keeps the native footer callback context. Its
refusal, payload-absence and app-liveness assertions are unchanged. No production
change or timing allowance was needed for this additional test precondition.
All **4 event-held chrome cases passed in 5.25 s**.

**Final proof:** With the same four-burner load as RED, **30 completed
iterations / 120 executions passed, with zero failures, errors or skips**.
The completed batches were 7 and 23 iterations; a gate-interrupted partial
iteration was excluded. The complete AUM invocation then passed **all 829
cases in 585.16 s** (587.95 s wall), including four 60-second gate pauses
between tests. Every case ran once, with zero errors or skips. Its production
source hash matches the loaded proof. The earlier 828/829 result is retained,
not replaced by the final pass.

The deterministic regressions are in the existing standard diagnostics/native
selectors; the three new default-deny cases stay in the existing attribute
selector. There is no new architecture component, data flow, identity or
network path. The existing source witness was regenerated and checked
(16 specs / 18 PNGs); diagram images are unchanged and the AUM image was inspected.

All long output stays under TEMP, with receipts and the rerunnable harness in
`.finops-evidence\p71-startup-race`. The lock was never created or deleted;
the stress harness also stops its own load if a new gate starts. Repeated gate
arrivals interrupted full-suite attempts, so the final evidence-only pytest
hook yields the machine between completed cases, polling the lock every 60 s
before starting the next case. It does not retry, skip, change in-test timing
or alter results; the longest case in the first complete run was 6.526 s.
The hook was checked with a simulated lock, without changing the real lock.
The original aborted attempts and their output remain available.
U26 stays OPEN for historical failures outside this diagnosed regression.
No sleep, retry, relaxed
assertion or readiness timeout is added to application or test synchronization.

Private receipts: `stress-red-v2.json`, `stress-green-total.json`,
`full-green-batch-04.json` and `full-gate-aware.json`; their JUnit results are
preserved alongside the harness. Reproduce from this worktree root with an
unused label:

```powershell
& .\.venv-finops\Scripts\python.exe .\.finops-evidence\p71-startup-race\stress.py --label review-stress --iterations 30 --burners 4 *> "$env:TEMP\p71-review-stress.log"
& .\.venv-finops\Scripts\python.exe .\.finops-evidence\p71-startup-race\stress.py --label review-full --full --iterations 1 --burners 0 *> "$env:TEMP\p71-review-full.log"
```

**Builder handoff:** Implementation and recorded proof are committed as
`2be0973` (`fix(aum): preserve native message controls after sealing`).
Council and packet gates remain with the lead. ROADMAP P71 remains unticked.
Nothing was pushed or merged.

### Council round 10 corrections

The tenth review of `860abc9` returned UX PASS and Architect, Coder, QA and
Security BLOCK. B9a/b/c and their receipts were accepted. Remaining paths:
native content descendants obtained through approved DOM queries (B10a),
Textual exit messages (B10b), and backend payloads in native diagnostic
message representations before dispatch (B10c).

The correction tests the real native child, exit renderer and `TEXTUAL_LOG`
path before implementation. Native DOM content has a receiver-level
publication boundary; unsupported content types cannot be attached without
protection. Exit results remain values, while displayed exit text requires
guarded publication. Queued messages/notifications have payload-free normal
and Rich representations before framework logging.

The round 9 scheduler claim was incorrect: the intended `notifications=True`
edit did not reach the seven-scheduler case. This round changes that exact
case and gives it a visible current-notification control, rather than relying
on a flag or caplog alone. The earlier receipts remain historical results.

The inherited tests were run against a frozen archive of `860abc9`'s source:
**17 failed, 7 passed in 32.98 s**. The expanded set produced **33 failed,
7 passed in 47.95 s**. Failures included the actual A-only caption, exit output
and `TEXTUAL_LOG` payloads, not import or collection failures. The inherited
implementation still failed **3 of 24 cases in 41.60 s**. Additional tests
exposed its native class-prefix approval, unguarded chrome and cached rendering:
**12 failed, 3 passed in 15.18 s**.

The corrected runtime selection passed **41 cases in 49.82 s**. It covers
native query aliases, supported and refused content families, fixed app titles,
guarded chrome, cached output, exit values/messages, both object representations,
the real Textual log and all seven notification-enabled scheduler cases.
Source-contract approval, mutation and full-suite receipts follow below.

The first expanded standard run had **358 passed, 3 failed in 166.58 s**.
One failed people-selector precondition was reproducible: repainting a caption
from a replaced backend entered the global refusal path and cancelled the new
read. Cached paint now blanks the stale output and reports a fixed notice
without cancelling that newer read. A separate command-palette check exposed
an unguarded native search worker; its exact worker and input handlers now retain
their source. The new search/selection control passed in **2.16 s**.
Visible-notification controls now wait for their actual rendered text, within
three seconds, rather than assuming one event-loop pause completes toast mounting.
The isolated request-action case passed; the earlier worker cancellation and
shutdown `NoMatches` remain recorded, not diagnosed by that pass.

The next standard run had **358 passed, 4 failed in 172.79 s**. All 40 new
native/diagnostic cases passed. The four failures were existing startup/navigation
`WorkerCancelled` cases, with `NoMatches` during shutdown in two cases; their
receipts are retained under U26. The final focused runtime baseline passed
**48 cases in 65.11 s**; the exact source-approval baseline passed **5 cases
in 4.62 s**. Both ran every collected identity, without skips or collection
errors. Native command search, current-source refresh after stale paint and
real posted/prequeued Textual logging are included in that runtime baseline.

An initial passive-paint isolation removal ran all **48 cases** and failed one
navigation case in **65.07 s**, but did not reach its intended assertion. It
is not counted as a caught mutation. The native cached-render case now records
the global rejection callback directly and asserts that expired paint does not
clear the current source. Its test identity is unchanged. The strengthened
48-case control passed in **59.78 s** before the replacement removal probe.

#### Round 10 mutation proof

All **21 rules** have caught removal probes. Nineteen runtime probes each ran
the same **48 collected and executed test identities**; two approval probes
each ran the same **5 identities**. Every accepted probe failed its intended
detector, with zero errors and skips. These are **922 test executions**.
The runtime selector is `test_publication_native.py`,
`test_publication_diagnostics.py`, the seven scheduler cases in
`test_publication_widgets.py`, and the existing delayed `people-selector` case.
The standard publication selector is the prior ten files plus the two new
native/diagnostic files; it contains **362 cases**.

| Removal | Failed / passed | Seconds |
|---|---:|---:|
| Native registration protection | 25 / 23 | 59.29 |
| Exact native type approval | 8 / 40 | 62.66 |
| Native method guards | 7 / 41 | 66.04 |
| Native property guards | 6 / 42 | 60.33 |
| Native constructor origin | 1 / 47 | 62.85 |
| Native cached-render guard | 2 / 46 | 60.52 |
| Passive-paint refusal isolation | 2 / 46 | 66.00 |
| Native chrome content guards | 4 / 44 | 62.86 |
| Static application titles | 2 / 46 | 62.47 |
| Native command-search worker origin | 2 / 46 | 65.85 |
| Native command input/selection origins | 1 / 47 | 63.36 |
| Framework watcher origin | 2 / 46 | 61.48 |
| Unused watcher coroutine cleanup | 2 / 46 | 62.41 |
| Raw exit-message refusal | 3 / 45 | 64.35 |
| Queued-message representation sealing | 6 / 42 | 60.94 |
| Sealing messages already in the queue | 2 / 46 | 61.42 |
| Payload-free normal representation | 7 / 41 | 61.84 |
| Payload-free Rich representation | 3 / 45 | 65.33 |
| Visible notifications in all seven scheduler cases | 7 / 41 | 80.35 |
| Native boundary fingerprint | 2 / 3 | 2.49 |
| Exact exception-context fingerprint | 2 / 3 | 4.79 |

Failure totals can include an incidental navigation cancellation; a catch also
requires the intended detector to fail. In addition to the uncounted paint
probe above, an initial watcher removal also removed cleanup and produced a
pytest teardown error (**3 failed, 45 passed, 1 error in 63.34 s**). It is not
counted. The narrower watcher-origin probe retains cleanup and has no errors.
All original receipts remain available.

After the probes, the untouched production tree passed **48 runtime cases in
60.17 s** and **5 approval cases in 4.55 s**. Each command acquired and released
its own lock in `finally`, waiting 60 seconds between acquisition attempts.
Mutations used isolated temporary source copies; imports were checked before
each run. Identity lists, source hashes, stdout, JUnit, lock receipts and the
runner persist in `.finops-evidence\p71-r10-resume`.

| Round 10 BLOCK | Correction status; lead re-review still required |
|---|---|
| Architect B10a | Exact native receiver approval, registration/write/cache guards, query/query_one/children controls and guarded/static chrome |
| Coder B10b | Raw exit text refused before shutdown; return values preserved |
| Security B10c | Payload-free normal/Rich representations before posting and dispatch; real `TEXTUAL_LOG` posted/prequeued cases |
| QA | Visible positive controls for all seven schedulers; native, exit and real-log counterexamples in the standard selector |
| Maintenance | Receiver/effect review and exact fingerprint-update recipe in ADR-0035; approvals remain code-reviewed |

The architecture source and manifest were regenerated, the AUM image was
inspected, and **36 architecture assertions** passed. The pre-commit gate
passed with **13 passed, 2 warnings, 0 failed**. This is not a new packet-gate
or council verdict.

#### Final round 10 full AUM run on `70b6919`

The requested single full AUM/FinOps run executed **810 cases: 806 passed,
4 failed in 360.31 s** (**363.59 s wall**), with **0 errors and 0 skips**.
The command-local lock was held from **2026-09-29 18:22:17Z to 18:28:21Z**
(**23:52:17-23:58:21 IST**). All collected test identities ran, including all
**40 new native/diagnostic cases**, which passed.

The failures were:

| File | Test identity | Observed failure |
|---|---|---|
| `test_publication_generation.py` | `test_deferred_detail_retains_cached_or_fresh_origin_after_b_verifies[budgets]` | `WorkerCancelled` at the worker wait, then `NoMatches` during shutdown |
| `test_publication_generation.py` | `test_deferred_detail_retains_cached_or_fresh_origin_after_b_verifies[requests]` | `WorkerCancelled` at the worker wait, then `NoMatches` during shutdown |
| `test_publication_generation.py` | `test_principal_change_closes_prior_forms_and_clears_state_before_input` | `WorkerCancelled` at the worker wait, then `NoMatches` during shutdown |
| `test_revision4_tui.py` | `test_approval_paging_and_queue_change_reset_cursor` | `WorkerCancelled` while awaiting workers |

The worktree's `.venv-finops` interpreter imported this worktree's package.
From `cli\finops`, the full selector was `-m pytest tests -q
-p no:cacheprovider --tb=short`, with the identity-recording plugin and JUnit
receipt. The exact command, source hash, all identities, complete output and
lock receipt persist as `full-aum.*` in `.finops-evidence\p71-r10-resume`.
No second full run, timeout relaxation or production change follows this run.
U26 remains open: these failures were retained, not diagnosed by a passing
focused control. The full suite is not green and this packet is not merge-ready.

The lead owns integration, the next council and the final packet gate. This
worktree remains on `p71-aum-speed`; no merge or push is performed here.
Each mutation and the one final full AUM run acquire and release their own
shared lock in one command. U26 remains open.

### Council round 9 corrections

The ninth review of `b186cf3` returned UX PASS and Architect, Coder, QA and
Security BLOCK. Imports were closed, but objects still exposed a console
stream (B9a), an unwrapped superclass implementation (B9b), and raw
notifications (B9c). The earlier probes, boundary/exception fingerprints and
711-case full run were verified by the council.

This correction closes attribute loads and literal reflection with an
explicit member allowlist. Private names, streams, drivers, raw notification
delivery and unwrapped implementations have no ambient approval. Necessary
internal expressions use the existing reason and context-fingerprint
mechanism. Parameterized `super` is not a presentation API. Notifications
carry their source through queued delivery and visible rendering.

The exact counterexamples and current-origin controls precede implementation,
with notifications enabled. Every new rule has a same-test-ID removal probe.
Each long command owns and releases its lock in its own `finally`; one full
Python suite follows the fixes. No push, merge, Azure operation, packet gate
or council invocation is part of this correction. Round 10 remains with the lead.

The installed Textual 6.12.0 path was inspected on 2026-09-29:
`App.notify` queues a `Notify` message; `_on_notify` adds its record and
`_refresh_notifications` separately schedules `ToastRack.show`. A check only
when `notify` is called therefore does not cover actual delivery. Native
toasts also cache renderables. The correction retains the origin through
both queue stages and the visible toast path. The initial read-only audit
exited 0 (20 passed, two existing warnings, four skipped commands/checks).

The capability RED selection reported **46 failed, 8 passed in 8.02 s**.
It reproduced the stream write, superclass method alias and visible raw
notification after B verification. The expanded notification-only RED file
reported **7 failed in 6.49 s**, including queue acceptance and cached-toast
rendering controls.

`publish_notification` now requires an origin, stores it in the queued
record, and validates it at acceptance, toast creation and rendering.
Protected toasts recheck cached render strips; refusal clears/hides them and
reports the safe error. Principal clearing also clears old notifications.
All former presentation notification calls use the new API. Static/safe
explanations use the local-message guard; action acknowledgements retain
their request/reply origin. Raw `notify` refuses rather than borrowing the
current identity.

Notification/liveness verification passed **28 cases in 25.15 s**. The
existing delayed-read observers were moved to the new API while still
calling it; no outcome assertion was removed. The combined notification,
lifecycle, structural and identity selection then passed **202 cases in
58.32 s**. The seven scheduler tests now render notifications instead of
relying on the headless default that hides them. Attribute enforcement
follows as a separate correction.

The notification correction is committed as `ea98113`. The attribute policy
now approves 387 public member names and excludes console/stream/driver,
private, raw-writer and raw-notification access by default. The reviewed
inventory adds 190 exact internal/forwarding expressions with 103 function
fingerprints; combined with the earlier entries there are 202 expressions
and 106 contexts. A matching function name alone grants no exception.
Parameterized or escaping `super` is rejected; forwarding exceptions use
only zero-argument `super` in reviewed wrapper/adapter methods.

The new attribute/source selection passed **183 cases in 8.26 s**. Synthetic
legacy detector fixtures now use the actual approved UI member vocabulary,
so an unrelated unknown-attribute finding cannot mask removal of the rule
they test. The clipboard/backend fixture retains both original sink checks
and additionally requires the new raw-`write` finding. The complete
publication selection passed **322 cases in 100.30 s** (102.65 s wall),
including all B9 counterexamples, notification rendering and the prior
identity, deferred-publication and source-policy cases.

#### Final round 9 proof on `125f352`

| Seat | Round 9 verdict | Finding | Correction |
|---|---|---|---|
| Architect | BLOCK | B9a: an object exposes the raw console stream through literal reflection | `125f352`: every attribute load and literal `getattr`/`hasattr` member needs approval; console, file and writer capabilities have no ordinary approval. |
| Coder | BLOCK | B9b: parameterized `super` returns an unwrapped method that can be aliased | `125f352`: selected-base and escaping superclass access are rejected; existing zero-argument forwarding is exact and fingerprinted. |
| QA | BLOCK | The default headless harness hides notification rendering | `ea98113` / `125f352`: exact A-to-B stream, superclass and notification replays, current-origin controls and visible notification tests are in the standard selector. |
| UX | PASS | Existing scheduler refusal paths remain responsive | Prior liveness checks remain, with notification rendering enabled in the seven-scheduler regression. |
| Security | BLOCK | B9c: raw notifications display prior-principal data | `ea98113`: `publish_notification` retains and checks the source through queuing, delivery and cached rendering; raw `notify` refuses and principal clearing removes old toasts. |

**16/16 removal probes were caught.** Every probe executed the same **322
test identities** as its green baseline, exited 1 with at least one failing
test, and had zero pytest error or skip results. The code was syntax-checked
before execution and restored byte-for-byte in `finally`; the final source
SHA-256 values match their pre-mutation receipts.

| Removed or broken rule | Failed / passed | Pytest seconds |
|---|---|---|
| Attribute-load allowlist | 15 / 307 | 100.81 |
| Literal-reflection allowlist | 22 / 300 | 100.38 |
| Both object-capability access checks | 37 / 285 | 101.49 |
| Superclass-selection restriction | 4 / 318 | 102.05 |
| Superclass-builtin escape restriction | 1 / 321 | 104.87 |
| Exact attribute-exception context | 1 / 321 | 101.04 |
| Raw-capability exclusion from the ordinary list | 2 / 320 | 101.61 |
| Private-name exclusion from the ordinary list | 1 / 321 | 102.51 |
| Raw-notification API refusal | 3 / 319 | 99.80 |
| Notification enqueue-origin validation | 3 / 319 | 98.28 |
| Retained notification origin through delivery | 4 / 318 | 100.20 |
| Cached-toast origin validation | 3 / 319 | 99.33 |
| Principal-change notification cleanup | 4 / 318 | 101.93 |
| Blank rendering after a cached-toast refusal | 2 / 320 | 99.90 |
| Protected notification caller route | 2 / 320 | 99.83 |
| Capability policy wired into the standard selector | 97 / 225 | 99.76 |

The probes took **1,613.79 s** in pytest (**1,651.63 s wall**), excluding
lock waits. Removing both attribute access checks reproduces the actual
stream write. Removing superclass selection reproduces the actual A-to-B
screenshot. Replacing the retained notification delivery origin fails the
accepted-but-not-yet-created and cached-render controls; removing the
cached-strip origin check also fails the visible cached-toast replay.
Changing a reviewed boundary additionally fails source-integrity checks.
The blank-refusal fallback probe was caught by those integrity checks;
the remaining hide/cleanup defenses prevented a separate output failure in
that probe. It is not reported as another observed payload leak.

| Selection | Result | Pytest seconds | Wall seconds |
|---|---|---|---|
| Capability RED | 46 failed, 8 passed | 8.02 | Not separately measured |
| Notification-stage RED | 7 failed | 6.49 | Not separately measured |
| Notification/liveness GREEN | 28 passed | 25.15 | Not separately measured |
| Notification/identity/source GREEN | 202 passed | 58.32 | Not separately measured |
| Attribute/source GREEN before final controls | 183 passed | 8.26 | Not separately measured |
| Complete publication GREEN | 322 passed | 100.30 | 102.65 |
| Locked pre-mutation baseline | 322 passed | 102.77 | 105.17 |
| Restored publication selector | 322 passed | 106.32 | 108.75 |
| Full AUM/FinOps Python suite, run once | **770 passed**, zero failures/errors/skips | **283.15** | **285.94** |

The full run acquired its own lock at **2026-09-29 03:43:39Z
(09:13:39 IST)** and released it at **03:48:25Z (09:18:25 IST)** in that
same command's `finally`. Baseline, each probe, restored selection and full
suite have separate acquisition/release receipts. No lock was reserved
between commands or removed for another owner.

All 322 publication cases were included and passed in the full suite.
The references are
[`test_publication_attributes.py`](../cli/finops/tests/test_publication_attributes.py)
for the exact object-capability counterexamples and member/super rules,
[`test_publication_notifications.py`](../cli/finops/tests/test_publication_notifications.py)
for queue acceptance, deferred delivery, visible and cached rendering, and
[`publication_attributes.py`](../cli/finops/tests/publication_attributes.py)
for the reviewed member vocabulary and exact exception data. The earlier
principal, attachment, import, renderer and scheduler regressions remain in
the selector.

The runner used `accel\.venv-finops\Scripts\python.exe` with
`PYTHONPATH=accel-p71\cli\finops\src` and asserted the imported package path.
The standard selector is the prior eight publication files plus
`test_publication_attributes.py` and `test_publication_notifications.py`.
The full command was `-m pytest cli\finops\tests -q -p no:cacheprovider
--tb=short`, with JUnit receipts. Per-run output, exact test identities,
source hashes and command-local lock receipts persist in
`.finops-evidence\p71-r9`.

U26 remains open for its historical failures; this passing run is not a
cause diagnosis. Only the ledger update follows the full run. No push,
merge, Test-All, packet gate, council invocation or Azure operation occurred.
Round 10 remains with the lead, and ROADMAP P71 remains unticked.

### Council round 8 corrections

The eighth review of `f89e1c0` returned UX PASS and Architect, Coder, QA and
Security BLOCK. It verified the round 7 mutation and full-suite receipts and
closed B7b. The remaining counterexamples are stale widget attachment/reuse
(B8a), presentation-class mutation (B8b) and module-level raw-output aliases
(B8c).

The correction uses a closed presentation import contract, not another
spelling denylist. Output and data-bearing widgets come from the protected
modules; source-level metaprogramming has checked, justified exceptions only.
The threat model is maintainer-written presentation code, not a sandbox for
deliberately malicious code in the Python process. Runtime checks cover
construction, writes, instance class changes, retained-widget attachment/reuse
and deferred execution. [ADR-0035](adr/0035-aum-bounded-readiness-and-progressive-reads.md)
records the boundary.

Exact A-to-B counterexamples and current-origin controls precede the fixes.
Each new rule has a removal probe that executes the same test identities as
its baseline. Every green implementation is committed locally. Each long
validation command owns and releases its lock in that command's `finally`;
one full AUM/FinOps Python run follows the fixes. Round 9 and the packet gate
remain with the lead. No push, merge or Azure operation is part of this round.

Textual 6.12.0 source inspection found that `_register_child` inserts a node
before calling the child's `_attach` hook. The runtime boundary therefore
validates retained widget subtrees before registration mutates the DOM, not
only in a post-attach event. The renderer also caches visuals, which makes
checking only the public `render` method insufficient for reuse. Sources:
the installed `textual/app.py`, `textual/dom.py` and `textual/widget.py`,
inspected on 2026-09-29. The initial read-only Ironclad audit exited 0
(20 passed, two existing warnings, four skipped commands/checks).

| Seat | Round 8 verdict | Finding | Correction |
|---|---|---|---|
| Architect | BLOCK | B8a: a retained or shallow-copied widget can attach after its principal changes | `970cd88`: original-source validation precedes DOM insertion and covers supplied subtrees, compose and reparent. |
| Coder | BLOCK | B8b: class mutation can remove presentation enforcement | `970cd88`: protected instances refuse class replacement. `92b5de8`: the closed source policy rejects class/imported-namespace mutation and raw-state access. |
| QA | BLOCK | Exact A-to-B counterexamples and current-origin controls were missing | `970cd88` / `92b5de8`: screenshot/output counterexamples and current-origin controls are in the standard selector. `2fe50e2` corrects the pin-chart control's source and adds module-interface controls. |
| UX | PASS | Seven scheduler routes remain responsive; B7b is closed | All prior liveness and no-output-leak cases remain in the final selector and full run. |
| Security | BLOCK | B8c: a raw imported output alias escapes the spelling detector | `92b5de8`: default-deny imports and member interfaces, a checked module inventory, and exact justified metaprogramming exceptions. |

The first runtime RED run reported **6 failed, 4 passed in 9.75 s**
(11.61 s wall), with `A_ONLY_BUDGET` visible in B's screenshot after mount,
shallow copy, compose and reparent, plus both protected-instance class-change
probes. The subtree extension reported **7 failed, 5 passed in 11.74 s**.
Current-origin attachment controls already passed. Registration now holds the
kept origins while validating the complete supplied subtree before insertion.
Class changes fail independently of the caller's active scope. The compose
fixture uses an approved protected parent; its retained child still has A's
origin. Its screenshot and refusal assertions are unchanged.

The first implementation run exposed a missing helper import; the next
exposed the unwrapped test parent's stopped message pump. Neither result is
credited as RED evidence or a mutation catch. With the shared import wired
and composition using the protected parent, the runtime/reuse/lifecycle and
existing publication selection passed **113 cases in 85.92 s** (88.24 s wall),
including B4/B5 and all seven round 7 scheduler routes. The closed source
contract and its exact import/exception controls follow separately.

The retained-widget correction is committed as `970cd88`. Preparation for
the import boundary moves console creation, prompting and profile/report
filesystem effects behind the existing protected output module. Its readers
return text/path values rather than stream or writer handles; configuration
loading accepts path text without requiring presentation code to import
`pathlib.Path`. The new interface tests reported **9 failed, 1 passed in
0.46 s** before implementation, then the IO/runtime/CLI/structure selection
passed **140 cases in 25.63 s** (26.94 s wall). Profile replacement still
requires the explicit `force` choice, and stale origins create no directory,
file or prompt.

The IO adapters are committed as `e52d42a`. The closed-contract RED run
reported **47 failed, 7 passed in 2.33 s**. It reproduced the module-level
`typer.echo` alias printing A's value after B verification and class mutation
putting the same value in B's screenshot. Unknown imports, raw IO classes,
module escape, computed reflection, class mutation and dynamic code were
accepted by the previous structural contract.

`publication_policy.py` now declares all 59 source modules: 24 presentation
modules and 35 explicitly classified non-presentation modules. Presentation
imports and imported-member access are approved by name, independently of
local aliases. The two native boundary modules have reviewed AST fingerprints;
their filenames alone grant no exception. Metaprogramming exceptions name an
exact expression, its reason and the fingerprint of its enclosing function.
Changing the fixed cache-field tuple therefore invalidates its reflection
exception. The 51 static presentation entries keep their scope; only the
three command metadata writes changed from `typer.echo` to protected
`write_text`, with the registry fingerprint updated.

The source-policy selection passed **132 cases in 4.63 s**. Protected-widget
and CLI rewiring passed **42 cases in 12.54 s**. The combined publication,
snapshot and terminal selection reported **275 passed, 1 failed in
138.82 s** (141.85 s wall): the previously recorded U26 pin-chart setup
`KeyError: 'ask'`, before its stale-origin assertions. A bounded follow-up of
that unchanged publication file passed **40 cases in 31.42 s**. No assertion,
deadline or synchronization was changed, and this is not a cause diagnosis.
The new B8 counterexamples, round 7 scheduler/output checks and settled
snapshots passed in the combined run.

The closed source contract and protected import wiring are committed as
`92b5de8`. The first 263-case pre-mutation run again failed only at the
pin-chart setup lookup (**262 passed, 1 failed in 95.05 s**, 97.89 s wall).
Inspection found that the replay asks directly against a fixture that does
not advertise the Ask view, then looks up the active view's guard. Focus can
activate Ask without a corresponding view-cache entry. The completed reply
already has `ask_reply_guard`, and `action_pin_chart` uses that guard, not the
view-cache guard.

The test control now selects the actual reply guard for pin-chart and asserts
that it is current before B verification. All stale-origin, dialog, screenshot
and no-A-data assertions are unchanged. No production synchronization or
timeout changed. The corrected complete baseline passed **263 cases in
94.00 s** (96.33 s wall). The earlier failing receipts remain; this fixture
correction does not close U26's other historical failures. Module-namespace
escape/immutability controls and the subtree's pre-insertion assertion are
also included in that baseline.

#### Final round 8 proof on `2fe50e2`

**26/26 removal probes were caught.** Each ran the same **263 test identities**
as the green baseline, exited 1 with at least one failing test, and had zero
pytest error or skip results. Every mutation was syntax-checked first and
restored byte-for-byte in `finally`; the final SHA-256 checks agree with the
pre-mutation source. No collection failure or syntax error was counted.

| Removed or broken rule | Failed / passed | Pytest seconds |
|---|---|---|
| Retained attachment origin, replaced with a local-message scope | 7 / 256 | 94.05 |
| Pending-subtree prevalidation | 3 / 260 | 93.80 |
| Protected-instance class identity | 4 / 259 | 96.11 |
| Native-boundary implementation fingerprint | 1 / 262 | 91.19 |
| Named-import allowlist | 20 / 243 | 97.27 |
| Module-import allowlist | 2 / 261 | 97.97 |
| Imported-member allowlist | 2 / 261 | 97.67 |
| Module-name escape restriction | 1 / 262 | 94.11 |
| Module-attribute escape restriction | 1 / 262 | 92.54 |
| Class and imported-namespace assignment restriction | 3 / 260 | 88.90 |
| Reflective class-mutation restriction | 3 / 260 | 88.07 |
| Computed-reflection restriction | 3 / 260 | 89.34 |
| Unapproved dunder-attribute restriction | 2 / 261 | 88.66 |
| Literal raw-state reflection restriction | 2 / 261 | 90.28 |
| Interpreter-namespace restriction | 1 / 262 | 87.99 |
| Builtin-capability allowlist | 6 / 257 | 87.30 |
| Metaprogramming exception-context fingerprint | 1 / 262 | 88.52 |
| Metaprogramming exception justification | 2 / 261 | 90.89 |
| Default rejection of unclassified source modules | 1 / 262 | 87.00 |
| Import-approval justification | 1 / 262 | 86.74 |
| Runtime IO origin check | 50 / 213 | 86.90 |
| Explicit profile-overwrite choice | 3 / 260 | 89.94 |
| Protected CLI output route | 2 / 261 | 88.53 |
| Closed policy wired into the standard structural selector | 52 / 211 | 87.22 |
| Direct module-registry restriction | 1 / 262 | 87.28 |
| Reflective module-registry restriction | 1 / 262 | 86.99 |

The probes took **2,355.26 s** in pytest (**2,417.39 s wall**). Altering a
reviewed runtime boundary also fails its source-integrity checks; the runtime
counterexamples still execute independently. Replacing the retained attachment
origin reproduces all five stale-widget paths. Removing instance class
protection reproduces both class-replacement cases. Removing the reflective
class restriction reproduces the council's class-mutation screenshot, not
only an AST assertion.

| Selection | Result | Pytest seconds | Wall seconds |
|---|---|---|---|
| Runtime/reuse/lifecycle/publication GREEN | 113 passed | 85.92 | 88.24 |
| IO/runtime/CLI/structure GREEN | 140 passed | 25.63 | 26.94 |
| Closed source contract GREEN | 132 passed | 4.63 | Not separately measured |
| Initial compatibility selection | 275 passed, 1 pin-chart setup failure | 138.82 | 141.85 |
| Initial complete baseline | 262 passed, 1 pin-chart setup failure | 95.05 | 97.89 |
| Corrected complete baseline | 263 passed | 94.00 | 96.33 |
| Restored complete publication selector | 263 passed | 89.18 | 91.41 |
| Full AUM/FinOps Python suite, run once | **711 passed**, zero failures/errors/skips | **267.15** | **269.77** |

The requested full run acquired its own lock at **2026-09-29 00:57:04Z
(06:27:04 IST)** and released it at **01:01:34Z (06:31:34 IST)** in that
command's `finally`. Baseline, each removal probe, restored selection and
full suite have separate acquisition/release receipts. No lock was reserved
between validation commands or removed on behalf of another owner.

All 263 publication cases were included in the full 711-case run. This
includes B4/B5, every round 7 scheduler/liveness case, the no-traceback-payload
proof, and the exact B8 screenshot/output controls:

- [`test_publication_reuse.py`](../cli/finops/tests/test_publication_reuse.py)
  checks current/stale mount, shallow copy, compose, reparent and nested
  subtree paths, plus protected-instance class replacement. A rejection
  precedes insertion; current origins still display their data.
- [`test_publication_allowlist.py`](../cli/finops/tests/test_publication_allowlist.py)
  gates the exact `setattr(type(widget), "render", ...)` and raw
  `typer.echo`/`sys.modules` alias sources before execution. The original RED
  runs displayed or printed A's value after B verification; the approved
  current-origin output alias remains a positive control.
- [`publication_policy.py`](../cli/finops/tests/publication_policy.py)
  defines the closed import/member/builtin capabilities, module
  classification, reviewed native boundaries and exact metaprogramming
  exceptions. The existing lexical scope detector remains a second check,
  not the default authority for unknown imports.

Every runner asserted that `claude_finops.__file__` belongs to
`accel-p71\cli\finops\src` while using the main worktree's interpreter.
The standard selector is the prior five publication files plus
`test_publication_reuse.py`, `test_publication_io.py` and
`test_publication_allowlist.py`. The full command used `-m pytest
cli\finops\tests -q -p no:cacheprovider --tb=short`, with JUnit receipts.
Private stdout, source hashes, exact test identities and command-local lock
receipts persist in `.finops-evidence\p71-r8`.

No pin-chart setup failure occurred in the 26 removal runs, restored selector
or final full suite after its control was bound to the completed reply's
origin. U26 remains open for the other historical failures; no production
timing fix is claimed. Only the ledger update follows this final full run.
There was no push, merge, Test-All, packet gate, council invocation or Azure
operation. Round 9 remains with the lead, and ROADMAP P71 remains unticked.

### Council round 7 corrections

The seventh review of `9fabf42` returned Architect PASS and Coder, QA, UX and
Security BLOCK. The existing B4/B5 and round 6 protections remain required.

| Seat | Round 7 verdict | Finding | Correction |
|---|---|---|---|
| Architect | PASS | Existing publication structure accepted | The component and source-guard boundary remain. |
| Coder | BLOCK | B7a: `Static.content` writes bypass runtime and AST enforcement; descriptor/raw-state and additional deferred/dynamic spellings escape the detector | `bee62d2`: `content` validates and retains its source; the structural contract rejects unchecked descriptor setters, raw widget state, dynamic code, added scheduler spellings and partial methods. |
| QA | BLOCK | Only `call_later` exercised refusal liveness | `95a6475`: seven actual scheduler routes retain responsive input and emit no payload. `530a8dd` adds finite cycle-removal probes and stopped-app loop ownership. |
| UX | BLOCK | Timer and screen callbacks report exit 3, then terminate Textual | `95a6475`: shared application handling recognizes direct and wrapped refusals before fatal rendering; message dispatch and the owned loop preserve liveness. Unrelated errors retain their handling. |
| Security | BLOCK | B7b: a refused Overview callback exposes its data arguments through error rendering | `95a6475`: only the safe underlying refusal is presented, never wrapper text, callback arguments or traceback locals. The real Overview replay makes zero renderer calls and emits no sentinel. |

Each correction starts with failing behavior/structural cases. Each new rule
has a removal probe that retains the baseline test identities, executes the
suite and fails at least one test. Every green implementation is committed
locally. The shared lock covers one long command at a time and is released in
that command's `finally`, never reserved between validation commands. One final full
AUM/FinOps Python run follows the fixes. Council round 8 and the packet gate
remain with the lead; no push, merge, Azure read or Azure write is part of
this correction.

The installed Textual 6.12.0 source explains the observed error path:
`Timer._tick`, next-callback dispatch and screen refresh callbacks can reach
`App._handle_exception`; its fatal renderer includes traceback locals.
`MessagePump.on_timer` can wrap a callback exception in `CallbackError`.
Event-loop callbacks use the loop's separate exception handler. The correction
therefore covers the application boundary and its owned event-loop lifetime,
without changing process-wide handlers outside that lifetime. Sources:
the installed `textual/app.py`, `textual/message_pump.py`,
`textual/screen.py` and `textual/timer.py`, inspected on 2026-09-28.
The initial read-only Ironclad audit exited 0 (20 passed, two existing
warnings, four skipped commands/checks); no packet gate executed.

B7a's first RED selection reported **41 failed, 66 passed in 47.50 s**
(50.15 s wall). `content` was accepted by the live sink, the real `call_soon`
probe wrote the old principal's value without refusal, and replacing content
left the previous origin attached. The final structural RED selection,
including imported `exec`/`eval` aliases and an altered internal setter call,
reported **41 failed, 29 passed in 3.38 s**. These are behavior failures, not
collection errors. With the runtime setter and structural rules implemented,
the complete two-file selection passed **110 cases in 45.20 s** (47.15 s
wall). The original 51 static exceptions are unchanged; only three exact
sink-implementation expressions are recognized separately, as recorded in
[ADR-0035](adr/0035-aum-bounded-readiness-and-progressive-reads.md).

B7a is committed as `bee62d2`. The refusal/liveness RED run reported
**13 failed, 5 passed in 23.28 s** (25.01 s wall). Six newly exercised
scheduler routes exposed `ROUND7_A_ONLY_COSTS` in fatal output or asyncio
logging. The real Overview `on_resize`/screen-refresh reproduction made
**zero renderer calls**, yet leaked its callback's argument through the
fatal traceback. Direct, explicit-cause and implicit-context refusals also
terminated the app. The initial shared-boundary GREEN selection passed
**89 cases in 21.31 s** (22.78 s wall), covering the seven live scheduler
routes, input after refusal, safe output, unrelated errors and loop ownership.
The complete publication selector then passed **176 cases in 81.48 s**
(83.42 s wall), including B4/B5, all previous runtime protections and a bounded
exception-cycle control. That single command acquired and released its own
lock. The architecture renderer verified 16 specs and 18 PNGs; the updated AUM
readiness image was inspected. Final removal-probe results follow below.

The refusal boundary is committed as `95a6475`. Mutation preparation adds a
stopped-app ownership control and bounds the cyclic-exception fixtures: a
removed cycle detector produces a failing test rather than hanging collection
or the test process. The final pre-mutation baseline passed **177 cases in
79.05 s** (80.99 s wall). Its command waited in one-minute intervals for the
shared lock, then released the lock in `finally` before returning. The 27
removal probes each ran that same complete selector in a separate command.

#### Final round 7 proof on `530a8dd`

**27/27 removal probes were caught.** Each executed the same **177 test
identities** as the green baseline, exited 1 with at least one intended
failing test, and had zero pytest error or skip results. Every mutation was
syntax-checked before execution and restored byte-for-byte in `finally`;
the final source SHA-256 values match the recorded originals.

| Removed or broken rule | Intended failures / 177 | Other setup failures | Pytest seconds |
|---|---|---|---|
| `content` runtime check | 3 | 0 | 92.65 |
| `content` origin retention | 1 | 0 | 86.85 |
| `content` structural check | 4 | 1 | 87.01 |
| Annotated and augmented assignment check | 2 | 0 | 73.24 |
| Descriptor/raw attribute check | 15 | 1 | 72.80 |
| Raw-state/dynamic-code name check | 8 | 0 | 73.64 |
| Imported dynamic-code alias check | 2 | 0 | 73.78 |
| Indirect raw-state access check | 5 | 0 | 72.68 |
| Raw-access rejection inside a guard | 8 | 0 | 73.26 |
| Exact internal-expression boundary | 1 | 0 | 73.48 |
| `call_next` scheduler check | 1 | 1 | 71.63 |
| `call_at` scheduler check | 1 | 0 | 72.37 |
| `threading.Timer` scheduler check | 2 | 0 | 72.16 |
| Keyword callback check | 2 | 0 | 73.07 |
| `partialmethod` check | 2 | 0 | 72.59 |
| Shared application refusal boundary | 11 | 0 | 73.07 |
| Safe underlying error text | 2 | 0 | 73.59 |
| Explicit-cause unwrapping | 1 | 1 | 72.71 |
| Implicit-context unwrapping | 2 | 1 | 73.37 |
| Exception-cycle detection | 2 | 0 | 74.70 |
| Wrapped-message dispatch recovery | 1 | 1 | 74.08 |
| Loop-refusal routing | 2 | 1 | 75.24 |
| Foreign-app loop ownership | 1 | 0 | 74.80 |
| Stopped-app loop ownership | 1 | 1 | 74.06 |
| Previous loop-handler restoration | 3 | 0 | 73.31 |
| Newer loop-handler ownership | 1 | 0 | 75.93 |
| Unrelated exception forwarding | 3 | 0 | 74.82 |

The probes took **2,030.89 s** in pytest (**2,077.67 s wall**), excluding
lock waits. The eight additional setup failures all name
`test_cached_dialog_handoffs_retain_origin_during_deferred_composition[pin-chart]`:
`KeyError: 'ask'` at the precondition reading `app._data_guards[app.active]`,
before that test's stale-origin assertions. They are not credited as mutation
catches. This case passed in both the restored selector and the full suite;
its intermittent setup failure remains recorded under U26, without a claimed
cause or a changed assertion.

| Scope | Result | Pytest seconds | Wall seconds |
|---|---|---|---|
| B7a structure/runtime GREEN | 110 passed | 45.20 | 47.15 |
| Initial refusal/structure GREEN | 89 passed | 21.31 | 22.78 |
| Complete publication GREEN before final fixture controls | 176 passed | 81.48 | 83.42 |
| Final pre-mutation baseline | 177 passed | 79.05 | 80.99 |
| Restored complete publication selector | 177 passed | 73.71 | 75.52 |
| Full AUM/FinOps Python suite, run once | **625 passed**, zero failures/errors/skips | **247.21** | **248.95** |

The final full run acquired its own lock at **2026-09-28 21:07:43Z
(2026-09-29 02:37:43 IST)** and released it at **21:11:52Z
(02:41:52 IST)**, in the same command's `finally`. Baseline, every mutation,
restored selection and full run have separate acquisition/release receipts;
the lock was never reserved between commands. Other owners' gate windows
were left untouched, with retries every 60 s. No process priority was changed.

All 177 publication cases were included and passed in the full run, including
B4's pre-input clearing and B5's outgoing assistant-context protection.
The regression references are:

- [`test_runtime_publication_sinks.py`](../cli/finops/tests/test_runtime_publication_sinks.py):
  `test_content_property_refuses_a_scheduled_old_principal_value` executes
  the A-to-B `call_soon` reproduction; `test_content_assignment_replaces_and_retains_its_actual_source`
  proves replacement of the previous origin and later invalidation of the
  actual content origin.
- [`test_publication_structure.py`](../cli/finops/tests/test_publication_structure.py):
  content assignments, descriptor/raw-state operations both inside and outside
  a guard, `exec`/`eval` aliases, new schedulers, keyword callbacks,
  `partialmethod` and exact internal expressions each have failing-removal cases.
- [`test_publication_widgets.py`](../cli/finops/tests/test_publication_widgets.py):
  `test_rejected_raw_scheduled_publication_keeps_the_app_open_and_explains`
  runs `call_later`, `set_timer`, `call_after_refresh`, `call_next`,
  `loop.call_soon`, `loop.call_at` and a real wrapped timer event. Each case
  observes callback execution, types into the terminal afterward and rejects
  the sentinel in terminal/error consoles, captured stdout/stderr, logging and
  the screen. `test_refused_overview_screen_callback_never_renders_its_arguments`
  uses the real `on_resize`/screen-refresh path and requires zero renderer calls.

Every run used `accel\.venv-finops\Scripts\python.exe` with
`PYTHONPATH=accel-p71\cli\finops\src`; the runner asserted the imported
`claude_finops.__file__` before executing pytest. The complete selector consists
of `test_publication_generation.py`, `test_publication_structure.py`,
`test_guarded_publication.py`, `test_runtime_publication_sinks.py` and
`test_publication_widgets.py`. The full command was `-m pytest
cli\finops\tests -q -p no:cacheprovider --tb=short`, with a JUnit receipt;
it did not use the worktree-venv wrapper that would skip.

Private stdout, JUnit, per-rule test identities, source hashes and individual
lock receipts persist in `.finops-evidence\p71-r7`. U26 remains open: the
passing full run does not establish the cause of the earlier failures.
Only this ledger update follows the final full run. No push, merge,
Test-All, packet gate, council invocation or Azure operation occurred.
Round 8 remains with the lead, and ROADMAP P71 remains unticked.

### Council round 6 corrections

The sixth review over `4cf7508..dd46186` confirmed the runtime B4/B5 fixes on
reviewed paths but found that indirect/deferred calls bypass the structural
contract. Runtime sink enforcement, not another call-site convention, is the
required boundary.

| Seat | Round 6 verdict | Finding | Fix |
|---|---|---|---|
| Architect | BLOCK | A deferred callable can outlive a syntactically guarded scope | `a7dc395` / `5c1eb74`: sink-layer validation and explicit guarded deferral |
| Coder | PASS | Reviewed runtime implementation accepted | Retained |
| QA | BLOCK | Lambda, dynamic attribute and partial spellings evade the detector | `b6aef61`: RED fixtures and extended detector; 17/17 full-selector mutations caught on `36f3088`, below |
| UX | PASS | Reviewed B4/B5 behavior accepted | Retained |
| Security | BLOCK | B6a-d: deferred lambda/def, getattr, setattr and partial can publish outside their source guard | `a7dc395` / `5c1eb74`: active/current-origin checks at presentation and egress sinks; `bcf8554`: explicit refusal without ending the UI message loop; `6056989`: synchronous sink functions cannot defer their bodies |

All four probes failed as structural and runtime tests before the fix.
The existing 51 exact static-write exceptions are retained. Heavier affected
selections, repetition and mutation batches take the shared lock and release it
in `finally`; single files and the publication selector remain the initial
work. U26 records the bounded navigation-flake attempt. The earlier correction
pass ran no Test-FinOps, Test-All or packet gate. The resumed correction includes
one full AUM/FinOps Python run under the shared lock. Council round 7, the packet
gate and integration remain with the lead; this branch is not pushed or merged.

The initial structural run on the reviewed detector reported **13 failed,
10 passed in 4.22 s**: the four B6 forms, eight scheduler variants and computed
`getattr` were accepted. The extended detector reports **27 passed**,
including explicit deferral and callback-alias controls. The exact 51-entry
static registry is pinned by a digest. The initial real-Textual runtime
reproductions reported **11 failed in 13.25 s**, all from a missing sink refusal.
Final runtime and mutation receipts are below.

The sink implementation's expanded RED run reported **25 failed in 19.55 s** (21 missing
refusals and four missing explicit-deferral cases). Widget methods/properties,
clipboard, links and the HTTP assistant transport now validate at execution.
The runtime file passes **25 cases**; the existing publication file passes
**40**, and lifetime/structure checks pass **30**. Existing replay setup writes
now declare their input origin; their scheduling, refusal and data assertions
are unchanged. Six specific Textual input/mount handlers retain source guards;
application handlers and layout/idle callbacks gain no publication authority.
Deferred async callbacks hold no identity lock across an await. U26 records
30 passing baseline navigation repetitions and the 20-case file run without
claiming a reproduction or fix for the reported cancellation.

Terminal text/rich output, CSV file creation and command clipboard subprocesses
now use sink wrappers too. Their RED run reported **12 failed, 25 passed**;
the complete runtime file then passed **37 cases**, covering expired,
obsolete-active and current origins at every output sink. Structure coverage
passes **29 cases**, including isolated lambda and partial rules independent
of scheduler detection. The application-level sinks live beside the protected
widgets, and the main UI source remains within its 700-line budget.

An additional scheduled-raw-callback test initially reported **1 failed,
1 passed**: the sink refused the write but Textual closed its message pump.
The dispatch boundary now reports `FinOpsError` before the framework leaves
that loop; both lifecycle cases pass, including 256 ordinary input edits.
The original terminal/form file passes **11 cases** after its direct setup
assignments declare their input origin. No outcome assertion changed.
The remaining directly affected input fixtures also pass as individual files:
Dashboard **19**, directory forms **4**, feature controls **7**, navigation **6**
and review regressions **5**. These six files total **52 cases**. Only setup
assignments gained an originating scope; all deadlines, assertions and
requested values are unchanged. The architecture renderer verified 16 specs
and 18 images; the changed AUM readiness image was inspected and contains
generic component names, not deployment identifiers.

The locked affected run on `3ceaa9f` passed **319 tests in 324.72 s** (328.95 s
wall), 14:43:48Z-14:49:17Z. No full-suite runner or gate was invoked.
A subsequent longer-input probe found that repeatedly wrapping a widget's
previous input origin built a recursive guard chain: **1 failed, 2 passed**,
with `RecursionError` during 1,024 ordinary edits. Input now retains one
immutable content origin and replaces only the current-input check. The
three lifecycle cases and all **37 runtime sink cases** pass; a separate
control proves credential invalidation still rejects that original content
even without an identity-revision change.

The interrupted edit on `2f42fab`, completed in `6056989`, rejects coroutine, generator and
async-generator functions at `publication_sink` decoration. Their bodies run
after the creation-time check would have ended. The resumed RED run restored
the committed implementation while retaining the three new cases:
**3 failed, 3 passed in 3.05 s** (6.48 s wall), each failure
`DID NOT RAISE TypeError`, with all six cases loaded. The completed restriction
then passed the complete publication selection: **115 passed in 116.06 s**
(120.96 s wall), including B4/B5, the 37 runtime-sink cases, 29 structural
cases, six lifetime cases and three input/dispatch cases. No test assertion
or deadline changed. This is a synchronous-sink contract correction within
the existing publication component, with no new architecture path.
The offline architecture check reported the changed source fingerprint
(`SOURCE_STALE: aum-readiness: ...guarded_publication.py`) in 0.91 s.
Rendering and checking again verified 16 specs and 18 unchanged PNGs in
16.50 s. Only the manifest fingerprint changed; the AUM image was inspected.

This worktree uses the main worktree's interpreter with its own source first
on `PYTHONPATH`. The import check and targeted command were:

```powershell
$root = (Get-Location).Path
$python = Join-Path (Split-Path $root) 'accel\.venv-finops\Scripts\python.exe'
$env:PYTHONPATH = Join-Path $root 'cli\finops\src'
$env:PYTHONDONTWRITEBYTECODE = '1'
& $python -c "import claude_finops; from pathlib import Path; print(claude_finops.__file__); assert Path(claude_finops.__file__).resolve() == Path(r'cli\finops\src\claude_finops\__init__.py').resolve()"
& $python -m pytest cli\finops\tests\test_publication_generation.py `
    cli\finops\tests\test_publication_structure.py `
    cli\finops\tests\test_guarded_publication.py `
    cli\finops\tests\test_runtime_publication_sinks.py `
    cli\finops\tests\test_publication_widgets.py -q -p no:cacheprovider --tb=short
```

The import check printed `accel-p71\cli\finops\src\claude_finops\__init__.py`,
not the main worktree's package. The shared lock remained with P79 during
these short targeted runs; no mutation batch or gate ran during that period.

#### Resumed round 6 proof on `36f3088`

The shared lock was acquired at **2026-09-28 15:55:10Z (21:25:10 IST)** after
one-minute retries and released in `finally` at **16:38:50Z (22:08:50 IST)**.
Only this run's lock was removed. Execution was serial and offline, with the
P71 import assertion above. The read-only Ironclad audit (`--stage packet
--no-run --json`) exited 0: 20 passed, two existing warnings, four skipped
commands/checks. This is not an executed packet gate.

Each B6 spelling has a case in
[`test_round_six_indirect_and_deferred_probes_are_rejected`](../cli/finops/tests/test_publication_structure.py)
and in
[`test_raw_sink_refuses_deferred_backend_data_for_every_spelling`](../cli/finops/tests/test_runtime_publication_sinks.py).
The runtime cases cover both unchanged and changed principals; both must
refuse a raw callback after the originating scope ends. The historical RED
failures above name every case, rather than a collection/import failure.

| Item | Additional named test | Mutation proof on the complete 115-case selector |
|---|---|---|
| B6a: lambda/def through `call_later` | `test_lambda_body_never_inherits_the_creation_scope`; `test_nested_callback_created_under_guard_cannot_escape_to_scheduler` (eight schedulers); `test_rejected_raw_scheduled_publication_keeps_the_app_open_and_explains` | Restoring lambda scope inheritance fails 1/115; removing escaped-callback detection fails 9/115. Removing widget method enforcement fails 16/115, including both lambda and nested-def principal variants and the actual scheduled callback. |
| B6b: `getattr` | `test_computed_getattr_in_presentation_code_is_not_silently_trusted` | Removing literal attribute resolution fails 1/115; removing computed-attribute detection fails 1/115. Removing widget method enforcement fails both runtime `getattr` principal variants. |
| B6c: `setattr` | Runtime spelling `setattr`, both principal variants | Removing setter detection fails 1/115. Removing widget property enforcement fails 5/115, including both runtime `setattr` cases. |
| B6d: `functools.partial` | `test_partial_sink_reference_requires_explicit_deferral_without_a_scheduler` | Removing partial-sink detection fails 1/115. Removing widget method enforcement fails both runtime partial principal variants. |

**17/17 mutations were caught.** Every run loaded and executed the exact
baseline's **115 test identities**, with at least one failing test,
exit 1, zero skips and zero pytest error results. Each altered file was
restored in `finally`, and its SHA-256 was compared with its pre-mutation
bytes. An invalid syntax or changed test count did not count as a catch.
The 51-entry static registry remained unchanged in the restored source.

| Removed or broken protection | Failed / passed | Pytest seconds |
|---|---|---|
| Runtime `publication_sink` source check | 14 / 101 | 64.32 |
| Deferred sink-body rejection | 3 / 112 | 93.69 |
| Explicit backend-origin deferred wrapper | 5 / 110 | 125.21 |
| Lambda creation-scope isolation | 1 / 114 | 79.51 |
| Escaped callback scheduler detection | 9 / 106 | 114.65 |
| Literal `getattr` sink resolution | 1 / 114 | 114.41 |
| Computed `getattr` detection | 1 / 114 | 117.53 |
| `setattr` sink detection | 1 / 114 | 109.34 |
| Partial sink-reference detection | 1 / 114 | 116.09 |
| Refusal recovery before Textual ends dispatch | 1 / 114 | 132.86 |
| Bounded input-origin depth | 1 / 114 | 142.14 |
| Original content credential guard | 1 / 114 | 118.13 |
| Structural check of a new unguarded handler write | 1 / 114 | 116.40 |
| Widget method sink enforcement | 16 / 99 | 112.43 |
| Widget property sink enforcement | 5 / 110 | 105.45 |
| Exact static-registry reason/digest | 1 / 114 | 86.58 |
| Accepted explicit-deferral AST path | 3 / 112 | 126.06 |

The 17 runs took **1,874.80 s** in pytest (**1,931.21 s wall**).
The positive explicit-deferral controls still accept a current source and
preserve ordinary input. Changed sources fail before writing, and the async
control proves that identity verification can finish while the callback awaits.
B4's pre-input row clearing and B5's B-authenticated assistant request remain
green in both publication baselines and the full run.

| Selection | Result | Pytest seconds | Wall seconds |
|---|---|---|---|
| Initial resumed publication selection | 115 passed | 116.06 | 120.96 |
| Locked pre-mutation publication baseline | 115 passed | 66.64 | 69.00 |
| Locked restored publication selection | 115 passed | 107.23 | 110.25 |
| Full `cli\finops\tests`, run once | 560 passed, 3 failed; 563 total | 498.64 | 502.38 |

**Full-suite validation is not green.** The requested one full Python run
started at **16:30:27Z** and ended at **16:38:50Z**. All 115 publication tests
passed in it, including B4/B5. Its three failures were:

- `test_timeout_terminates_started_children_and_grandchildren`: the child
  startup marker was absent.
- `test_scheduling_delay_before_assignment_cannot_release_uncontained_children`:
  the child startup marker was absent.
- `test_redacted_queries_do_not_leak_through_input_or_filter_echo`:
  `WorkerCancelled` at `app.workers.wait_for_complete()` after the lookup handoff.

The missing startup markers and worker cancellation resemble earlier U26
observations, but this run does not establish their cause. No deadline,
assertion or synchronization was changed, and no second full run replaced
the failure. [U26](UNKNOWNS.md#u26---p71-observation-2026-09-28) records the
exact cases. The Python command was the same interpreter/environment above
with `-m pytest cli\finops\tests -q -p no:cacheprovider --tb=short`.
`Test-FinOps.ps1` was not used because its worktree-venv check would skip;
pytest actually executed all 563 cases.

Private per-run stdout, JUnit reports, source hashes, mutation test identities,
and the lock receipt persist in `.finops-evidence\p71-r6-resume`.
The earlier interrupted mutation logs remain historical, not the final proof.
The branch remains unpushed and unmerged, with no Azure access or writes in
this resumed work. Council round 7 and the packet gate remain with the lead;
P71 is not marked complete in ROADMAP. No additional implementation or full
test run follows this recorded handoff.

### Council round 5 corrections

The fifth review closed B3 and retained Architect/Coder/QA/UX PASS. Security
requires a class-wide boundary rather than further isolated guard handoffs.

| Seat | Round 5 verdict | Finding | Fix |
|---|---|---|---|
| Architect | PASS | Round-4 structure accepted | Retained |
| Coder | PASS | Cached detail retains its source guard | Retained |
| QA | PASS | Unchanged-A details and close invalidation pass | Retained |
| UX | PASS | Round-4 behavior accepted | Retained |
| Security | BLOCK | B4: highlighted rows write old-principal data to status | `89852aa`: common `guarded_publish` boundary and pre-input reset; `9b4e258`/`164780a`: formatter/property/async structural enforcement |
| Security | BLOCK | B5: old assistant conversation/history is sent under a new principal | `89852aa`: verify current identity, clear old conversation/history before reuse and guard the outgoing assistant request; principal lifecycle consolidated in `a526061`/`b326db5` |

The B4/B5 replays and a structural bypass detector fail before implementation.
Backend-derived widget/status/clipboard/export/JSON/CSV and assistant egress
share one publication function taking the source guard. Principal transitions
invalidate UI state before later input, including tables, selections, open
forms/dialogs and assistant history. Static presentation writes have an explicit
commented allowlist checked by the structural test. Only affected pytest and
the full publication selector run; no Test-FinOps, Test-All, gate or merge.

The bearer-aware replays failed before implementation (**3 failed, 33 passed**):
an A-only budget scope/figures reached the highlighted status under verified B,
A's conversation/history reached B's assistant request, and a prior-principal
form remained open. The new structural contract also failed before
centralization (**1 failed, 4 passed**). B4's final test observes the state at
Textual's input-dispatch boundary; clearing after the handler is insufficient.
B5's B-authenticated request has no A conversation or history, and the UI cache
retains only B's response. Tables, selections, picker options, forms/dialogs,
capabilities, preferences and assistant state clear on the verified transition.

`guarded_publish(origin)` is the sole guarded execution boundary. Synchronous
render helpers and generators delegate to it; formatters refuse calls outside
it. UI origins retain engine/revision provenance and rejection cleanup. A
deferred child cannot inherit an expired publication scope; generators recheck
their source per item, and async publication decorators or guarded scopes
spanning an `await` are rejected. Lookup and saved-view APIs now require an
explicit source guard rather than guessing one after a handoff.

The AST detector automatically discovers **16 presentation/output modules**,
including `tui.py`, `ui_features.py`, the new principal lifecycle, formatter and
assistant egress modules. It checks widget calls and value/label assignments,
status, clipboard subprocesses, export writes and assistant requests. Its
**51 exact static-write exceptions** each have a comment/reason; no entire
handler is allowlisted. Aliasing a widget as `result` does not hide a write.

Final publication selector: **53 tests passed** (40 end-to-end publication,
10 structural, 3 execution-lifetime tests). **Four mutations caught**, each at
the full 53-case count: an unguarded handler status write failed 1/53; skipping
principal clearing failed 4/53; bypassing the central origin check failed 10/53;
a direct handler property write failed 1/53. Exact source bytes were restored.
The affected pytest selection passed **232 tests in 182.41 s**, with existing
settled snapshots unchanged; the 53-case selector passed again after the
principal-lifecycle consolidation. No assertion or time budget was relaxed.

Reset now closes obsolete dialogs rather than leaving a refusal dialog open;
the prior replay assertions were updated to require cleared state and no
old-principal output. A pre-existing `ChangeScreen.remove` boolean shadowed
Textual's removal method and was renamed to `removing` so actual closure works.
No Test-FinOps, Test-All, gate, main merge, push or database operation was run.
The lead owns integration and full validation; ROADMAP P71 remains unticked.

### Council round 4 corrections

The fourth review over `05605e8..c909708` closed B1/B2 and confirmed the unchanged
Windows fixture assertions and retained U35/U36/U37. Deferred cached-item guard
handoffs remain the Security finding.

| Seat | Round 4 verdict | Finding | Fix |
|---|---|---|---|
| Architect | PASS | Completed-source cycle/publication structure accepted | Retained |
| Coder | PASS | Round-3 implementation accepted | Retained |
| QA | PASS | B1/B2 replays reject with exit 3 before cache or render | Retained |
| UX | PASS | Publication failures are explained without stale output | Retained |
| Security | BLOCK | B3: cached detail replaces its originating guard with an unpinned new-cycle guard | `3188a20`: capture the source guard when scheduling and retain it through cached detail composition; `f80808f`: propagate cached guards through other dialogs/actions and connection closure |

The real Engine/Turnstile/Textual reproduction is tested before the fix. This
round runs only the publication selector and affected pytest files; the lead
owns main integration, Test-FinOps, Test-All and the packet gate. No new merge,
gate, database operation or history rewrite is part of this correction.

The bearer-aware real Engine/Turnstile/Textual replay failed before the fix:
**1 failed, 21 passed**. After scoped B verified, A's cache was cleared and its
origin guard returned exit 3, but the deferred budget dialog's guard returned
0. The fresh-request control already rejected the stale result. Cached details
now retain their original guard; only a real new read supplies a replacement.
The worker captures its source before scheduling rather than looking up a
possibly replaced active-view guard later.

The cached-item audit additionally reproduced missing guards in dashboard
panel/list/row dialogs, budget edits, chart pinning and request copy/ledger
actions (**7 failed, 22 passed**); prefilled mode/request forms (**2 failed,
29 passed**); and guards surviving HTTP/Direct connection closure (**2 failed,
31 passed**). These handoffs now retain the source guard, including chained
forms, and closing the source invalidates retained guards. Fresh exports,
membership reads and optional detail reads already kept their actual read-cycle
guard and do not substitute a new empty cycle.

Targeted verification only: **157 affected pytest tests passed in 218.31 s**,
including the complete **33-case publication selector**, navigation, snapshots,
forms, groups, tokens and both HTTP backends. **11 mutations caught**, each
running all 33 publication cases before exact restoration: B3, panel detail,
dashboard list, dashboard row, budget edit, chart pin, request copy, ledger link,
prefilled form, HTTP close and Direct close. The B3 regression alone fails
1/33 while the fresh-request control still passes; the list and prefilled-form
mutations each fail 2/33 and the other mutations fail 1/33.

No Test-FinOps, Test-All, packet gate or main merge was run in round 4. Those
remain the lead's integration work; ROADMAP P71 remains unticked. There is no
new component or endpoint: the correction preserves the originating guard at
existing UI handoffs. Full-suite and gate results from earlier rounds remain
historical evidence, not round-4 acceptance.

### Council round 3 corrections

The third review over `0e11417..05605e8` confirmed that both round-2 Direct
reproductions now reject obsolete results with exit 3. Completed HTTP sources
and progressive publication still require the same protection.

| Seat | Round 3 verdict | Finding | Fix |
|---|---|---|---|
| Architect | PASS | Round-2 cycle structure accepted | Retained |
| Coder | PASS | Round-2 implementation accepted | Retained |
| QA | PASS | Direct stale-cycle reproductions reject with exit 3 | Retained |
| UX | PASS | Round-2 error behavior accepted | Retained |
| Security | BLOCK | B1: completed HTTP sources survive a principal change during aggregate assembly | `de22369`: HTTP generation pinned through complete assembly, subsequent reads and cycle exit |
| Security | BLOCK | B2: partial results reach UI cache/render before the outer cycle check | `739b9a7`: captured publication guard before each partial/final cache write and render; mismatch clears the refresh |

Both council reproductions become failing tests before implementation. A bounded
follow-up review covers other cache, screen and JSON publication points for
already-completed results. After the fixes, main `f98f885` is merged normally,
P70/P72 ledger entries and U35/U36 remain alongside P71/U37, and architecture is
regenerated. The packet gate retains its 1,800 s budget and shared lock. No
database stop/start or history rewrite is performed.

The real Engine/Turnstile reproduction failed with **2 failed, 1 passed** before
the HTTP fix. The real Engine/Direct loader's held partial and final arrivals
both published A-only values after B verified; that selector also reproduced
JSON and capability-cache publication (**4 failed, 3 passed**). These cases now
raise exit 3 before publication, not after a brief display or cache write.

The additional publication review reproduced completed identity JSON, CSV,
Turnstile feature and AUM-service catalog-cache writes (**4 failed, 7 passed**),
then deferred lookup choices/results, detail dialogs, file exports and people
selectors (**5 failed, 11 passed**). Optional assistant dialogs/answer state and
membership links also failed before the same guard was applied (**4 failed,
16 passed**). Fixes: `76dd6e7`, `f8f0270`, `841eb9f`. Tests observe actual widget
updates, output and file creation; clearing an already-published result does not
satisfy them. HTTP backend caches and cached redraws retain generation guards;
publication is serialized with verification of a new identity.

The final publication selector contains **20 cases**. Fourteen deliberate
mutations cover HTTP pinning/exit, Direct publication, JSON/CSV, identity,
capability/backend caches, five screen/export boundaries and the shared optional
publisher. All run at the complete selector count before byte-for-byte restoration.

The final repeated mutation run caught **14/14**, each with **20 cases**:
HTTP pinning 15 failures, HTTP exit 1, Direct publication 2, JSON 2,
capabilities 1, identity output 1, CSV 1, backend caches 2, each of the five
screen/export boundaries 1, and the shared optional publisher 4. The restored
affected selection passed **108 tests**.

Normal merge **`b6d64b5`** incorporates main **`f98f885`** (P70 on P72).
CHANGELOG and STATUS conflicts retain both sections; UNKNOWNS merged with
U35/P70, U36/P72 and U37/P71 intact. The architecture manifest was regenerated
from both source sets (16 diagrams, 18 PNGs), and the changed AUM image inspected.
The diff against main contains only P71 ledger additions/owned edits; removing
P71's section and changelog item leaves main's content unchanged, and ROADMAP
is identical to main with P71 unticked.

The first integrated AUM run reported **466 passed, 2 failed**: the two Windows
child/grandchild marker tests, not publication tests. Direct reproduction found
the Windows venv redirector's fixture startup taking **0.596-1.114 s**, exceeding
the unchanged 0.75 s deadline. The same imports through the base interpreter
took **0.161-0.207 s**, or **0.109-0.142 s** without site imports. The fixture
now invokes the base interpreter with `-S`; all startup markers, PID-termination
assertions and timing limits are unchanged, including the original 150 ms test.
The five existing C1/Q1 mutations were reconfirmed at their full seven cases.
The restored integrated `Test-FinOps.ps1` then ran **468 tests, all passed in
197.89 s**, with no warnings. The failed run remains recorded, not erased.
The 14 new publication mutations bring distinct historical receipts to 104.

**Round-3 packet gate: BLOCKED before execution.** The shared lock was
unavailable at every one-minute acquisition attempt through the permitted
**60-minute** wait, including the final retry. The wrapper exited 1 without
running the packet gate or Test-All; there is therefore **no round-3 Test-All
duration or gate verdict**. The 1,800 s suite budget is unchanged. The lock was
not owned by P71 and was not removed. The read-only observation at
**2026-09-28 06:47:08Z** still found it present; the private blocked receipt
explicitly records `testAllExecuted=false`, rather than reusing an earlier
passing gate receipt.

The implementation, mutation proof and requested P70 integration are committed
at `51a5915`; the remaining acceptance step is the locked gate on that tree.
Main advanced independently to `e39c3e4` (P76) during the wait; this branch
integrates the requested `f98f885`, not the later main tree. Preservation of the
requested main ledger and unticked ROADMAP P71 was verified at integration.
No push, history rewrite or database stop/start occurred in round 3. Security
re-review and a new gate lock window remain with the lead.

### Council round 2 corrections

The lead's second review closed A1, C1, Q1, U1 and S2. S1 remains blocked:
an old Direct cycle can rebind its cached account after another cycle verifies a
different principal, and cached snapshots or pending budget aggregates can
outlive the change.

| Seat | Round 2 verdict | Finding | Fix |
|---|---|---|---|
| Architect | PASS | A1 closed | One shared monotonic credential deadline retained |
| Coder | PASS | C1 closed | Suspended wrapper/job assignment retained |
| QA | PASS | Q1 closed | Process-start and descendant-termination evidence retained |
| UX | PASS | U1 closed | Fatal data errors interrupt metadata waits |
| Security | BLOCK | S1: obsolete cycle accounts, snapshots and aggregates remain returnable | `d6e239c`: immutable cycle generation, no cached-account rebinding, snapshot/read/cycle-completion checks; `2c2eb8f`: one cycle through multi-source assembly |

The two reported A-to-B principal transitions are reproduced offline before the
fix. The cycle's verified generation is pinned once, not rebound from cached
account metadata. Snapshot reads and aggregate completion must validate that
generation. A replacement principal needs a new read cycle. Main remains
`38ad175`, already merged; this round makes no database changes and no new merge.
The affected pytest selectors, full AUM runner and unchanged locked packet gate
are rerun after deliberate full-selector mutations.

Both council reproductions failed before the fix: the old catalog remained
readable after B verification, and A's pending budget returned after A's usage
query had already completed and B was verified. The first selector reported
**8 failed, 12 passed**, including cached catalog/tiers/USD variants, bridge and
assembly delays, and a completed-cycle aggregate. Fresh B reads in that fixture
remain denied; an obsolete cycle neither returns A's data nor performs a new
bridge read.

Four further tests showed chargeback, lookup, trend comparison and person detail
combining completed A data with subsequent B reads (**4 failed, 20 passed**).
Those pure multi-source operations now keep the same cycle open through
assembly, matching the existing status/governance cycle boundary. Fresh account
verification is serialized, so a delayed older account acquisition cannot
overwrite a newer verified generation.

**Seven round-2 mutations caught**, repeated against the final full **24-case**
principal selector: disabling the generation check failed 12/24 cases;
restoring cached-account rebinding failed 9/24; removing final aggregate
validation failed 1/24. Removing each of the four multi-source cycle boundaries
failed 1/24. Every mutation ran the entire selector before restoring exact
source bytes. The restored affected selection passed **83 tests**;
`Test-FinOps.ps1` executed pytest, not SKIP: **448 passed in 242.17 s**.
The prior 83 mutation receipts remain historical evidence (90 cumulative).
The terminal layout is unchanged; the architecture source/image and its
fingerprints are regenerated for the added cycle boundary.

**Round-2 packet gate: PASS, exit 0**, at **`45dd9c6`**, on 2026-09-28
**03:52:06-04:14:40Z**. Test-All passed in **1,344.6 s**, within the unchanged
1,800 s limit; Bicep build passed in **7.4 s**. Gate scorecard: **22 passed,
2 existing warnings, 0 failures**; lint/typecheck remain unconfigured.
Test-All ran **79 checks: 78 PASS, 1 SKIP**, the separate optional AUM-service
venv. **AUM ran all 448 tests and passed in 202.71 s** (206.3 s for its enclosing
check). The shared lock was acquired after five one-minute waits and removed
in `finally`. Full output and the copied timings file are retained under
`.finops-evidence`.

The unchanged batch suite passed **14/14 on PowerShell 7 and 5.1**. The updated
architecture diagram was inspected and its source/image fingerprints validated.
No Azure resource was changed, no new merge was needed, and nothing was pushed
or rewritten. This final ledger entry is the only change after the passing
gate. Security's S1 fix remains for the lead's re-review; the other four
round-2 PASS verdicts are preserved, and ROADMAP P71 remains unticked.
At final verification, the shared `main` ref had independently advanced to
`f98f885` with P70. This gate covers the requested `38ad175` integration plus
P71; the newer P70 tree was not merged during the completed round. Ledger
preservation and unchanged ROADMAP were verified against `38ad175`.

### Council round 1 corrections

The lead's read-only council over `aa7ed19..aa9070c` returned **BLOCK** on
2026-09-28. It confirmed 408 pytest cases, both 14/14 PowerShell batch runs,
59 mutation receipts and the recorded timing medians. The previous gate is
historical evidence, not acceptance of these findings.

| Seat | Round 1 verdict | Finding | Fix |
|---|---|---|---|
| Architect | BLOCK | A1: lock waiting and token acquisition each receive the whole deadline | `9653ffc`: one monotonic deadline; only remaining time reaches acquisition; two mutations caught at all 11 token cases |
| Coder | BLOCK | C1: a wrapper can spawn children before job assignment | `12b5c38`: suspended creation, job assignment, Toolhelp resume; assignment failure executes no child code |
| QA | BLOCK | Q1: the deadline test can pass on an immediate launch failure | `12b5c38`: real process creation plus child/grandchild markers and PID exit checks; original 150 ms bound retained; five C1/Q1 mutations caught at all seven cases |
| UX | BLOCK | U1: a fatal Direct data result waits behind identity/capabilities | `16fc0a7`: fatal completion is observed alongside either metadata stage; partial data clears and edits disable immediately; two mutations caught at all 17 UI cases |
| Security | BLOCK | S1: resource credentials survive a principal change | `3176bd3`: verified principal/session generations bind reuse; Direct verifies one account per cycle, rejects stale sends/results; HTTP identity credentials refresh and old responses are rejected; nine mutations caught at all 23 credential cases |
| Security | BLOCK | S2: changed public text contains deployment identifiers | `8d44530`: P71 and the U32 row/section use capture 60's synthetic aliases; privacy/U37/TEMP mutations caught at all five cases |

Related corrections: the P71 single-server assumption moves from U35 to U37
(P70 owns U35; P72 owns U36); batch-read fixtures move to TEMP; the Direct
`whoami` regression receives a measured phase investigation. After the fixes,
`main` is merged normally, both ledgers are retained, architecture is regenerated,
and the merged packet gate runs under the shared lock without changing its
1,800 s limit. This correction round performs no database stop or start.

The cache tests retain their reuse/expiry counts with explicit verified
principal fixtures. The Direct independence tests now require exactly one
account read and still prohibit an RBAC permission lookup before data. This
is the security correction in S1, not removal of the data-arrival requirement.
The batch-fixture test intercepts its actual writes on both PowerShell hosts,
requires TEMP containment and verifies the JSON files were removed.

The `whoami` investigation alternated three before/after pairs against the same
read-only reference target, using the `aa7ed19` Azure CLI runner and the corrected
runner with identical account/permission requests. In-process medians were
**5.172 s before / 4.646 s after**. Account-call medians were **1.652 / 1.594 s**;
permission-call medians **3.520 / 3.054 s**. Permission calls ranged **2.758-4.097 s**;
parent Python CPU was **0-0.016 s** per operation. The external account/permission
calls account for the measured latency and variability; the original
4.254-to-5.187 s sample's increase was not reproduced in these paired runs.
No phase timings were retained for that historical sample, so its specific
cause is not established retrospectively. Evidence: private
`p71-r1-whoami-phases.json`; no identities or token bodies were recorded.

The full correction suite initially passed 433 tests but emitted unawaited
coroutine warnings. `d7cd2f2` allocates metadata work only inside its owning
task; it also ignores delayed activation events from a previous pane. The
existing rapid-navigation test and two new deterministic lifecycle tests pin
those behaviors. Two mutations fail the full 20-case lifecycle selector, and
the restored navigation/snapshot selection passes 35 cases.

Normal merge **`bf4de20`** integrates `main` **`38ad175`**. Conflicts in CHANGELOG
and UNKNOWNS retain both packets; U36 and every other non-P71 unknown row remain.
The diff against main contains the P71 section, P71 changelog additions and
P71-owned U26/U32/U37 edits only; ROADMAP is identical to main and P71 is unticked.
The merged worktree's `Test-FinOps.ps1` passed **436 tests with no warnings**.

Round 1 adds **24 caught mutations**: A1 2 (11-case selector), C1/Q1 5 (7),
U1 2 (17), S1 9 (23), privacy/U37/TEMP 4 (5), lifecycle 2 (20). Each mutation
ran the complete selector and failed before byte-for-byte restoration.
The 59 original receipts remain historical evidence; the cumulative count is 83.
Both PowerShell hosts still execute the 14/14 batch-read assertions, now in TEMP.

A read-only check during the full-suite run returned current Direct data at
8.015 s and completed at 8.843 s. Turnstile credential/metadata reads exceeded
their short deadline and returned explicit unverified exit 7 in 3.473-3.640 s;
the terminal did so in 2.625 s after refresh start. No stopped-server diagnosis
or successful running-backend read is claimed for that loaded sample. The
database was neither stopped nor started in this round.
The updated Direct captures show a later read at **7.359 s** first data and
**7.718 s** complete; the current account/RBAC header was already available.
Capture 60 (stopped) and 63 (running Turnstile) remain dated original-packet
evidence; this round did not recreate either resource state. Updated captures
61/62 and the U37/principal-bound architecture image were inspected.

**Integrated round-1 gate: PASS, exit 0**, at **`b0e7000`**, on
2026-09-28 **02:33:58-02:57:38Z**. Test-All completed in **1,408.8 s**, below the
unchanged 1,800 s budget; build passed in **9.6 s**. Scorecard: 22 passed,
2 existing warnings, 0 failures; lint/typecheck remain unconfigured. Test-All
ran **79 checks: 78 PASS, 1 SKIP** (the separate optional AUM service venv).
The AUM check ran **436 pytest cases, all passed in 224.22 s**, with 227.8 s
for the enclosing check. The shared lock was obtained after 14 one-minute
waits and removed in `finally`.

The retained timings file's five slowest checks were business-unit mutation
shards 0/4 **396.4 s**, 3/4 **301.5 s**, 1/4 **298.6 s**, 2/4 **281.3 s**, and
Turnstile mutation shard 1/2 **274.5 s**; all passed. Full Test-All output,
gate receipt and copied timings remain under `.finops-evidence`. No deadline,
assertion or command was weakened. Only this final ledger update follows the
passing gate. Council re-review and merge into main remain with the lead;
ROADMAP P71 remains unticked, and this branch was not pushed.

Implementation is on `p71-aum-speed`, based on `aa7ed19`. The packet gate passed
at `84bddeb`; the lead owns the council review and merge. The ROADMAP box remains
open until that merge. The owner's 2026-09-27 investigation measured Turnstile reads
at 33-36 s followed by exit 7, despite a healthy liveness endpoint. Direct reads
paid repeatedly for Azure CLI tokens and PowerShell bridge processes. Research:
**U20**, **U26**, **U32**, **U37**, [ADR-0018](adr/0018-terminal-finops.md) and
[ADR-0035](adr/0035-aum-bounded-readiness-and-progressive-reads.md).

- [x] A stopped Turnstile database produces an actionable command/UI failure in
      about 5 s, naming the verified server and its Azure CLI start command; the
      client never starts a paid resource automatically
- [x] One process reuses each resource's token until near expiry; Direct batches
      gateway reads and overlaps independent Log Analytics queries without
      changing authorization, accounting, write confirmation or compensation
- [x] Terminal panels render as their data arrives, with named waits and estimates;
      identity is no longer a global Direct-data barrier, and scoped HTTP data
      remains subject to the existing identity and scope checks
- [x] Offline tests are written and observed failing before implementation; each
      new detector is broken deliberately and catches its mutation at the full
      relevant test count, then passes after restoration
- [x] Read-only before/after time-to-first-data is recorded for `whoami`, `budget
      list`, `usage show` and `status` on the reference gateway; stopped and running
      Turnstile results are recorded separately
- [x] The database is started only after stopped-case evidence, under the owner's
      explicit authorization, and remains running for the morning test; no other
      Azure, Entra or Turnstile resource is changed
- [x] ADR-0035, AUM, troubleshooting, changelog and architecture records describe
      the behavior; terminal captures numbered 60 onward are redacted and inspected
- [x] The worktree venv runs pytest through `Test-FinOps.ps1`, and the locked
      `node .ironclad/gate.mjs --stage packet` passes with that AUM check included

Initial observation, 2026-09-27 **20:13:35Z**: PostgreSQL
`contoso-e8f7782d` in `contoso-534a5930` was `Stopped` (synthetic aliases matching
capture 60). Its activity
log records tonight's stop starting at **19:05:18Z** and succeeding at
**19:07:19Z**. The authorized start was requested at **22:23:22Z**, and `Ready`
was verified at **22:25:35Z**; the database was left running. No gateway named
value, App Service setting, Entra object or stopping automation was changed.

### Measurement method and results

Three sequential fresh `aum.exe` processes per Direct command, saved profiles,
warm Azure CLI session, `--json --plain --redact`; `perf_counter` starts at process
launch and stops at the first stdout byte. Successful JSON is first data; error
JSON is not data. CLI output is one completed object, whereas terminal panels
arrive independently. The same reference gateway, workspace and current-month
selection were used before and after. Other workloads shared the workstation;
no claim of a network SLA or an isolated benchmark is made.

| Direct command | Before median, s (range) | After median, s (range) |
|---|---:|---:|
| `whoami` | 4.254 (4.195-4.284) | 5.187 (4.459-5.918) |
| `budget list` | 11.278 (11.137-16.094) | 6.704 (5.618-8.578) |
| `usage show` | 6.539 (6.109-9.151) | 3.737 (3.567-5.929) |
| `status` | 24.619 (24.119-26.946) | 6.205 (6.032-6.234) |

Before: 2026-09-27 20:22-20:24Z. After: 22:30-22:31Z. Budget, usage and status
median reductions were 41%, 43% and 75%. `whoami` retains its account/permission
lookups and was not faster in the final sample; an earlier after sample was
4.360 s. The earlier Direct after sample was 5.031 / 2.868 / 5.417 s for budget /
usage / status. Both samples are retained rather than selecting only the faster
one. The original configure baseline was measured separately; setup/discovery
is not included in the saved-profile timings.

Stopped Turnstile, repeated before changes: `whoami` **34.297 s**, `status`
**33.364 s**, exit 7; the first cold attempt took 65.660 s. With bounded readiness,
successful stopped diagnoses returned exit 9 at **5.249 s** for `whoami` and
**4.947 s** for `status` (22:09Z); another loaded status run took **6.218 s**.
The final stopped terminal capture rendered the error at **4.046 s** after
refresh start, with **4.725 s** including Textual harness startup; its displayed
capture was taken at 4.156 s. The error named the verified server and the exact
manual start command. Credential/metadata timeouts also occurred under load;
they remain explicit unverified exit 7 rather than a false stopped diagnosis.
The five-second goal is approximate, not guaranteed for a cold or loaded
workstation. These limits remain a council decision for the lead.

After the separate database start, Turnstile `whoami` returned current identity
at **4.126 s** and `status` at **8.938 s** (22:26Z). Its terminal rendered first
data at **3.578 s**, settling at **4.968 s**. Direct's terminal rendered first
data at **3.437 s**, with identity and other sources still pending, and settled
at **6.625 s**. Textual `run_test` supplied the real read-only backend; timestamps
were taken at render callbacks and the final worker completion, not by a tight
screen-polling loop.

Private timing-only JSON and mutation logs are in this worktree's ignored
`.finops-evidence` directory. Public captures are
`docs/guide/aum-60-turnstile-stopped.png`, `aum-61-direct-progressive.png`,
`aum-62-direct-ready.png` and `aum-63-turnstile-ready.png`, all inspected for
identifiers. [Capture provenance and hashes](guide/aum-p71-captures.json);
[rendered evidence](AUM.md#read-latency-and-progress).

### Tests, detector mutations and branch history

`tests/Test-FinOps.ps1` ran pytest, not SKIP: **408 passed** on 2026-09-27 after
the final code changes (baseline 320). Settled 80x24 and 160x48 snapshot grids
are unchanged. `Test-AumReadBatch.ps1`: **14/14** on PowerShell 7 and Windows
PowerShell 5.1. Existing Direct write/compensation checks: **19**. Architecture:
**36 assertions**, including its isolated mutations, plus 19 Node checks.
Documentation references and screenshot checks passed; the latter ran 27 Node
provenance/privacy checks. Script encoding: 259 files checked.

**59 deliberate mutations caught**, each restoring exact source bytes and
running its whole relevant selector, with no focus/skip or reduced count:

| Detector group | Mutations caught | Full cases per mutation |
|---|---:|---:|
| Initial stopped-state diagnosis | 10 | 32 |
| Resource token reuse/context/expiry/sign-out | 7 | 7 |
| ARM boundaries, readiness and token-lock deadline | 12 | 49 |
| Direct snapshots, concurrency, scope, writes and PowerShell USD batch | 11 | 26 |
| Progressive UI, errors, scope, stale generations and redaction | 12 | 55 |
| Queued focus completion | 1 | 15 |
| Windows wrapper/MSI/sign-in deadlines | 3 | 3 |
| Credential-timeout stopped diagnosis | 1 | 46 |
| Modal row-event origin | 1 | 11 |
| Complete database inventory | 1 | 44 |

Two initial mutations survived and exposed weak detectors: the ARM redirect
stub did not record the redirected host, and a timing-only focus race was not
deterministic. Both assertions were strengthened; the repeated mutations failed
at their full counts, then restored runs passed. No assertion was weakened.
The refresh work also exposed the Textual `loading` reactive-name collision,
queued old-pane focus and a dismissed lookup event bubbling into the destination
table; each was read in the failing existing tests and fixed before green.
These observations do not establish the cause of every historical U26 failure.

Ordered commits: plan `183b3e4`; ADR/unknowns `8932e26`; initial readiness
`c213ac3`; resource tokens `bb9dad7`; ARM readiness `52a915d`; Direct speed
`d121598`; progressive terminal `1f4f5fd`; Windows deadline `a44e239`;
credential timeout `d6f0021`; lookup event origin `bdbf654`; complete inventory
`f2e2514`. Every green implementation cycle was committed without rewriting
history. Council remains with the lead; U32 external automation and U37's
single-server deployment association remain explicit. U20's unavailable AUM
service and large-directory limits are unchanged.

### Packet gate

Attempt 1, `6c5d6fd`, **2026-09-27 23:03:14-23:33:30Z**: the shared lock was
acquired after 15 one-minute waits and released in `finally`. The gate returned
1 because Test-All exceeded the unchanged 1,800 s command limit. Build passed;
scorecard: 21 passed, 2 warnings, 1 failure, 2 unconfigured checks skipped.
The Windows shell timeout left the child Test-All process running briefly.
Its own subsequently written receipt was recovered by the verified runner PID:
**77 checks, AUM PASS in 249.5 s**, optional AUM service SKIP, and guided-flow
start FAIL in 225.2 s. The child tree then exited; no other operator's process
was stopped.

The exact guided-flow assertion was not retained by the original gate, which
discards captured output on timeout. Direct `Test-FlowStart.ps1` then passed in
**90.8 s**; that is a rerun, not proof that the prior failure was harmless.
No guided-flow code or assertion was changed. A second gate retains the
unchanged Test-All command's stdout/stderr through a local observational Node
preload; it does not replace the command, alter arguments/results, relax a
timeout or skip a check. Any timed-out descendant of that gate is cleaned up
before its lock is released. Evidence remains under `.finops-evidence`.

Attempt 2, `84bddeb`, **2026-09-27 23:58:37Z to 2026-09-28 00:22:51Z**:
**PASS, exit 0**. The gate reports **22 passed, 2 warnings, 0 failures**;
lint and typecheck are the two unconfigured checks, not omitted AUM tests.
The declared Test-All command passed in **1,443.0 s** and the Bicep build in
**8.9 s**. Its complete output confirms **77 registered checks: 76 PASS,
1 SKIP** (the separate optional AUM service venv is absent). **AUM ran all
408 pytest cases, passed in 192.82 s**, with 196.3 s for its enclosing check.
The guided-flow check also passed on this run. No command, assertion, deadline
or charter setting was changed. The shared lock was acquired after 18 one-minute
waits and released in `finally`. Both gate receipts and the second full runner
output are retained.

Final read, **2026-09-28 00:23:34Z**: the authorized Turnstile PostgreSQL server
is still **Ready**. The worktree venv and private evidence remain for the lead.
Only this final ledger record follows the passing gate; implementation and
published images are unchanged. No merge or push was performed. Council
verdicts and the ROADMAP completion remain the lead's responsibility.

## P70 newly deployed models reach the tiers and the workstations, 2026-09-28

Merged to `main` as `bb75aab` (`--no-ff`, 2026-09-28); the merge tree equals the tree of the
gated branch head `a0c3e33`. Council round 2 passed all five seats. Integration on
`p70-model-lifecycle`: the AST-derived renderer import guard passed, `main` (`38ad175`,
including P72) was merged normally, the requested permutation suites passed, and the merged
packet gate exited 0 at `586b6f6`. No Azure or real workstation writes were made in this
integration.

### Council round 2, 2026-09-28

| Seat | Verdict supplied | Evidence / remaining integration work |
|---|---|---|
| Architect | PASS | Round-1 dependency fingerprints verified; A2 now has AST-derived transitive import coverage and a caught added-import mutation |
| Coder | PASS | Initial Sonnet-only allowlist and picker agree; all round-1 fixes verified |
| QA | PASS | Round-1 regressions verified; P72 installer/flow permutations passed on the merged tree without assertion changes |
| UX | PASS | No BLOCK or additional UX finding supplied |
| Security | PASS | Every S1 refusal made zero Azure resource writes; no tracked ignored generated files were found |

Acceptance for this integration: the new import detector catches an added renderer
dot-source with the complete assertion count and passes after restoration; the normal
merge retains every `main` ledger entry; the specified P72 suites pass without weakening
their assertions; the unchanged packet gate exits 0. A P70/P72 behavior contradiction
is reported rather than resolved by changing an assertion.

The A2 import-coverage follow-up is green. The lifecycle suite derives the renderer's
transitive dot-source closure from PowerShell ASTs and compares it with paths actually
hashed by the production stamp function, rather than another handwritten list. Dynamic
or unresolved paths fail coverage; renderers are never executed to discover imports.
Baseline and restored runs passed all 138 assertions on PowerShell 7 and 5.1.
Adding a dot-source to the renderer in a private copy caused exactly one coverage failure,
with all 138 assertions still run, on both hosts. Variable-bound imports and a transitive
cycle are covered by the detector's own fixtures.

Integration uses a normal merge of `main` at `38ad175`. The two conflicts were the
changelog and architecture manifest: both changelog entries were retained, and the
manifest was regenerated from the merged sources (15 specifications, 17 PNGs).
The ledger comparison against `main` contains only P70 additions: no removed lines
in CHANGELOG, STATUS or UNKNOWNS, and no ROADMAP difference. The P72 permutation
suites and locked packet gate are the remaining integration checks.

Normal merge commit: `5d4353e`, parents `d2b063e` and `38ad175`. The requested merged-tree
suites all passed on this machine:

| Suite | Checks | Coverage / duration |
|---|---|---|
| `Test-InstallerPermutations.ps1` | 44 | 103 cases on each of PowerShell 7 and 5.1: 96 combinations, six refusals and one reused gateway; 96.3 s |
| `Test-FlowPermutations.ps1` | 43 | 77 base runs plus boundary/store/round-trip cases and 432 Foundation plans; 130.0 s |
| `Test-FlowStart.ps1` | 114 | Startup, installer handover, fingerprint and resume checks; 133.3 s |
| `Test-ModelLifecycle.ps1` | 138 per host | Passed on PowerShell 7 and 5.1 after the merge |

No installer-driver stub extension was needed. No P72 assertion or behavior requirement was
changed. `git diff main HEAD -- CHANGELOG.md docs/STATUS.md docs/UNKNOWNS.md docs/ROADMAP.md`
contains only P70 additions and no removed lines; ROADMAP matches main. The regenerated
architecture check passes, and `git ls-files -ci --exclude-standard` lists zero files.
The merged packet gate exited 0 at `586b6f6`, 2026-09-28 03:26:10-03:51:13 UTC:
22 passed, 2 existing warnings, 0 failed, 2 skipped. Test-All passed in 1,492.0 s,
within the unchanged 1,800,000 ms command budget; Bicep passed in 9.2 s. The complete
gate took 1,503.0 s. The shared lock was acquired after 2,940.9 s of 60-second retries
(within the 60-minute limit) and released in `finally`.

Round-2/integration commits: plan `4dfdd69`, AST coverage `d2b063e`, normal merge
`5d4353e`, merged-suite evidence `586b6f6`, then a ledger-only commit for this result.
No assertion was weakened, no P70/P72 behavior conflict was found, and no requested work
remains blocked. No push, rebase or history rewrite was performed. The lead owns the
merge of this branch back to main.

### Council round 1, 2026-09-28

The lead's five-seat review over `aa7ed19..a017814` returned BLOCK. The supplied findings
and remediation acceptance are recorded below. Each fix requires a failing regression,
passing tests on PowerShell 7 and 5.1, and a caught mutation with the complete assertion
count. The gate keeps its 1,800,000 ms command budget and uses the shared lock.

| Seat | Verdict supplied | Finding | Fix / evidence |
|---|---|---|---|
| Architect | BLOCK | A1: helper changes can alter generated capabilities without changing the plan fingerprint | Fixed: the stamp hashes seven render/serialization dependencies; change/removal tests cover each, including a real capability-output change |
| Coder | BLOCK | C1: the installer records the deployment union but not each tier's selections; a Sonnet-only premium tier gets an Opus picker entry | Fixed: tier entries persist normalized models and exact allowlists; real generated standard/premium profiles match a Sonnet-only initial install |
| Coder | BLOCK | C2: bash setup retains an alias whose model family disappeared | Fixed: absent Opus, Sonnet and Haiku aliases are deleted; the shell's actual jq writer agrees with Windows in all three family-removal cases |
| QA | BLOCK | Q1: filtering hides malformed raw deployment rows and turns them into apparent removals | Fixed: shared raw identity validation runs before filtering, covering ten mixed valid/malformed array shapes |
| Security | BLOCK | S1: failed/empty discovery or whitespace/comma-only explicit selections can create allow-all lists | Fixed: failed/malformed discovery and empty normalized tier selections stop before provisioning; zero Claude deployments cannot discard supplied restrictions |
| Architect | Should-fix | A2: standalone history omits the prior decision and principal | Fixed: history records the preceding model decision and the signed-in account from the target subscription, read after approval |
| Coder | Should-fix | C3: the empty named-value REST write scopes its URI but not its token | Fixed: the same subscription arguments reach token acquisition and the REST URI |
| Security | Should-fix | S2: nested reference records and snapshots are not git-ignored | Fixed: nested records, profiles and snapshots are ignored; onboarding documentation remains visible |
| UX | No separate verdict supplied | No additional finding was included in the handoff | Existing model review and error wording remain in scope |

Completion criteria: all eight findings addressed, no relaxed detector or timeout, directly
related docs/ADR and architecture hashes updated, and the packet gate exits 0 under the shared
lock. ROADMAP P70 stays unticked for the lead.

First remediation green: Q1/S1/C1 reproduced as 24 failures at 108 assertions on each
PowerShell host, then all 108 passed on each host. Existing ModelDeployment checks passed.
The installer config edit changes only the two tier entries; P72's organisation/request
fields and summary rows are untouched. Detector mutations follow after the remaining fixes.
Second remediation green: the remaining model regressions reproduced 22 product failures
at 133 assertions (a two-path `git check-ignore --quiet` fixture error was corrected
separately), then all 133 passed on each host. The fast workstation suite reproduced
three alias-retention failures and now passes all 13 assertions on each host. It executes
the setup's own jq writer against temporary files and compares its full model environment
with the Windows helper, without installing clients or making Azure calls.
Final lifecycle assertions: 135 on each host, all passing. A valid single-deployment
object cannot substitute for an inventory array. A missing principal now stops before
the snapshot or any model write; its regression failed on both hosts before the guard.

Negative verification completed: 21 mutations caught on each host, with no incomplete
run. The 18 lifecycle mutations each ran all 135 assertions; the three alias mutations
each ran all 13 workstation-model assertions. Baseline and restored runs passed on
PowerShell 7 and 5.1. The matrix covers raw identity shape/fields and both callers,
native discovery failure and array shape, empty/normalized selections, both initial tier
records, renderer stamps and rechecks, history fields, missing principal, token scoping,
nested generated paths and each removed model-family alias.

Related regressions passed: ModelDeployment 46, ModelsAndPlugins 92, FlowContract 29,
GuidedFlow 44 and Architecture 36 assertions, plus Azure CLI argument checks, documentation
references, named-value guards, script encoding and Test-All runner integrity. The 15-spec
architecture was regenerated and its changed model-lifecycle image inspected. The added
workstation suite takes about 2 seconds per run; no new long-running suite is registered.
The packet gate passed at `e6566cc` on 2026-09-28, 00:55:24-01:15:44 UTC:
22 passed, 2 existing warnings, 0 failed, 2 skipped. Test-All took 1,210.9 s,
within the unchanged 1,800,000 ms budget; Bicep passed in 7.3 s. Total gate time
was 1,219.5 s. The shared lock was acquired immediately and released in `finally`.
The warnings remain the eight oversized files and 21 unrelated open unknowns;
no test, detector, timeout or charter constraint was relaxed.

Remediation commits: plan `e32b671`; raw discovery and initial tiers `fac106d`;
renderer/alias/history/scoping fixes `749b9c4`; unattributed-change guard `2983b8d`;
mutation proof and architecture `e6566cc`. The final ledger-only commit records this gate.
No requested finding remains unfixed. Council re-review and merge remain with the lead;
ROADMAP P70 is still unticked, and no merge, push or history rewrite was performed.

Acceptance criteria:

- [x] A Change-only `models` step and a standalone model-sync command discover the chosen
      Foundry account's Claude deployments, compare tier lists and the record, and show model,
      version, SKU/capacity and price-book status before a write
- [x] Each deployment has an explicit tier choice, from the console or the flow's answers file;
      missing deployments have a keep/drop choice. Empty-list allow-all semantics cannot turn
      removal into an unintended access grant
- [x] A fingerprint binds the target, discovered state, decisions, prices and generated outputs.
      Apply refuses stale or incomplete plans and takes a named-value snapshot before writing;
      only `models-standard` and `models-premium` can change
- [x] The record preserves unrelated fields and per-deployment client overrides, updates
      `deployments` and `models`, and regenerates per-tier device profiles. The developer handover
      states how rerunning setup changes `availableModels`, pinned aliases, capabilities and
      Desktop `inferenceModels`
- [x] Unpriced models are labelled unpriced, never free. Pricing and named-value propagation
      have cited research or measured evidence in UNKNOWNS and ADR-0034; every wait names its
      purpose, estimate and elapsed time
- [x] Offline stubbed-Azure tests run on PowerShell 7 and Windows PowerShell 5.1; each new
      detector is broken deliberately, its failure and full assertion count recorded, and restored
- [x] An isolated gateway in `rg-p70-models`, with dedicated `claude-p70-*` groups, returns
      `403 model_not_allowed` before and `200` after a deployment is added to the caller's tier.
      The proof costs less than USD 5; its resource group, soft-deleted gateway, groups and exact
      shared-Foundry role assignment are removed with creation/deletion times recorded
- [x] A read-only reference-gateway plan, an exact owner apply command, redacted live terminal
      images numbered 50 onward, updated model/flow/developer docs and architecture artifacts
      accompany a passing `node .ironclad/gate.mjs --stage packet`. ROADMAP remains unticked

Baseline audit: `node .ironclad/gate.mjs --stage packet --no-run` passed on `aa7ed19`
(20 passed, 2 warned, 0 failed, 4 skipped). Existing warnings are file size and open unknowns.

First implementation green: `Test-ModelLifecycle.ps1`, 69 assertions, 0 failed on PowerShell 7
and Windows PowerShell 5.1. RED on both hosts was `model lifecycle implementation exists`.
The real flow, standalone command, backup and profile generators run against an offline Azure
stub. Related FlowContract, FlowLifecycle, ModelDeployment, GovernanceAuthority and
ModelsAndPlugins suites passed. Mutations, isolated live proof and packet gate remain pending.
Second green: 77 assertions, 0 failed on both hosts. Explicit `-StandardModels` and
`-PremiumModels` support an unattended initial subset; unknown selections are refused before
deployment. Price status appears in each model question. Reusing the same answers after a
retirement succeeds without another named-value write. `Test-On-PS51.ps1` reached the
complete installer's summary and stopped under `-WhatIf`.
Detector preflight: 80 assertions on each host, adding valid-JSON/nonzero-exit failure,
the named-value writer's own exit check and renderer drift before apply.
Third green: 83 assertions on each host, including subscription validation before account
discovery, record-version/new-deployment labels in the review and a subscription-bound backup
token. The first 39 PowerShell 7 mutations were all caught at 80 assertions with the tree restored.
The final mutation run uses a frozen test/source copy on each host.

First isolated proof attempt, 2026-09-27 20:56-21:22Z: Basic v2 installed and a real standard
Sonnet request returned 200. Haiku returned 403 with `error.type=invalid_request_error`;
the proof runner incorrectly checked that field for `model_not_allowed` instead of
`error.code`, so the bounded wait expired before the Change. This was a proof-runner error,
not a gateway failure. All resources were removed: Foundry role assignment 21:13:04Z,
`rg-p70-models` 21:15:29Z, soft-deleted API Management 21:21:59Z, and the two dedicated
groups 21:22:06Z / 21:22:13Z. Estimated API Management cost including cleanup: USD 0.09.
The corrected proof will rerun; no reference gateway or default tier group was written.
Second isolated attempt: the installer completed in 330.6 s, Sonnet returned standard-tier
200, and Haiku returned `403 error.code=model_not_allowed`. The Change took its snapshot
but refused before named-value writes because a fresh installer record omits `decisions`;
the flow journal introduced an empty decisions object after the model decision was excluded
from the comparison. Reproduced offline on both hosts (84 assertions, one failure), then
fixed by normalizing absent/empty decisions without ignoring other decision changes.
Removing the fix fails exactly that test; all 84 assertions pass before and after the
mutation on PowerShell 7 and 5.1. Cleanup continues before the final live retry.
Second-attempt cleanup finished with no failures: exact shared-Foundry assignment
21:35:01Z, resource group 21:38:04Z, soft-deleted gateway 21:39:41Z, dedicated groups
21:39:49Z and 21:39:57Z. Estimated API Management cost USD 0.0483.

Related regressions: GuidedFlow 44, FlowLifecycle 33, GovernanceAuthority 132, Backup 43,
ModelsAndPlugins 92, WorkstationClients 178 and Architecture 36 assertions, all passing.
The GuidedFlow suite also passed on Windows PowerShell 5.1. Full installer previews passed
on both hosts; the PowerShell 7 preview with explicit model subsets took 23.7 s.
The 15-spec architecture render passed; its new model-lifecycle image was inspected.
The existing FlowStart suite passed with the new Change-only module present.
All 42 frozen-source detector mutations on PowerShell 7 were caught at the full 83
assertions; the restored run passed. The additional fresh-record detector was caught
at all 84 assertions on both hosts. The PowerShell 5.1 42-case run also caught every mutation at 83 assertions and passed after
restoration. The two full runs plus the fresh-record case provide 43 caught mutations per host.

Post-purge cleanup detail: after the second attempt, ARM again listed the old resource group
and its already deleted gateway while `az apim show` returned `ServiceNotFound`; the activity
log showed successful deletions and no new resource-group write. With no other resource in
that group, a second group deletion completed at 21:46:53Z after 73.6 s. The next proof
refused to reuse the lingering group until it was absent. Its cleanup now rechecks the
resource group after purging API Management.

Final live attempt: Basic v2 installation completed in 269.3 s. The first Haiku request,
21:55:00Z, returned `403 error.code=model_not_allowed` (0.597 s). The approved guided Change
completed in 330.5 s: its non-secret snapshot took 17.5 s, the standard-model write 21.3 s,
readback 22.5 s and both profiles 1.0 s; the later management reads account for the remaining
time. At 22:01:49Z, the first request after apply returned standard-tier 200 in 1.539 s.
That is 1.6 s after apply returned, not a claim of 1.6 s propagation after the named-value
write. The post-write management verification ran before that request.
At 22:04:28Z Sonnet returned premium-tier 200 (2.649 s), and at 22:04:29Z Haiku returned
`403 error.code=model_not_allowed` (0.603 s), proving the other tier remained restricted.
The generated standard files list Haiku and Sonnet; premium lists only Sonnet.
Images 50-54 were rendered from live, dated command transcripts and inspected; the apply
image is labelled as an excerpt, with its complete raw transcript retained privately.

Final cleanup completed with no failures. Times below are UTC on 2026-09-27; principal and
group object ids remain only in private evidence. Creation of the managed identity and role
was part of the installer, completed before the first gateway read.

| Created object | Created / first verified | Removed / absence verified |
|---|---|---|
| `rg-p70-models`, tagged `purpose=p70-proof` | 21:47:54 | Deleted 22:07:32; independently absent at 22:13:51 |
| Basic v2 `apim-p70eb00b`, its managed identity, Log Analytics and Application Insights | Installer completed 21:52:33; gateway verified 21:52:36 | Group deletion 22:07:32; soft-deleted API Management purged 22:09:08 |
| Cognitive Services User on the shared Foundry account, for that identity only | Created by the installer | Exact assignment deleted 22:04:49; all three proof identities have zero remaining assignments at 22:13:51 |
| `claude-p70-standard` | 21:47:59 | Deleted 22:09:19; absent at 22:13:51 |
| `claude-p70-premium` | 21:48:03 | Deleted 22:09:25; absent at 22:13:51 |

The final independent read found no resource group, no soft-deleted proof gateway, no dedicated
group and no role assignment for any proof identity. Estimated API Management cost across all
three resource-bearing attempts is USD 0.2136 (0.09 + 0.0483 + 0.0753), calculated at
USD 150 / 730 hours and including cleanup time. Successful requests used at most 16 output
tokens each; rejected requests did not call Foundry. No extra compute or Foundry deployment
was provisioned. This is below the USD 5 ceiling with a wide margin, but is not invoice
reconciliation (U2). Image 55 shows the final cleanup; it was inspected after redaction.

**Owner command and current reference state.** The following exact read-only command ran at
21:57Z and produced fingerprint
`12a41e22c399b185385c3127d96e0861ca209514cbf345650ecf4c500ae11a47`.
It uses a separate reference record rather than the disposable proof record:

```powershell
.\scripts\Sync-ClaudeModels.ps1 -RecordPath .\onboarding\reference\claude-gateway.json `
    -ResourceGroup rg-contosohub -ApimName apim-claude-gw-fzgql9 `
    -FoundryAccount ai-contosohub530569751908 -FoundryResourceGroup rg-contosohub `
    -TierAssignments @{ 'claude-opus-5-5' = 'premium'; 'claude-haiku-4-5' = 'both' } -PlanOnly
```

Observed preview: `models-standard` would change from `,,` to
`,claude-haiku-4-5,claude-opus-5,claude-sonnet-5,`; `models-premium` stays `,,`.
The plan copies the dated Haiku price to its deployed spelling, leaves Opus 5.5 unpriced,
and writes the new record and tier profiles. No reference file or Azure value was written.
Both models are already allowed by the current unrestricted lists. This choice would
**restrict standard**, not merely add access. The current authority is Turnstile, so apply
is refused until the owner chooses the authoritative change path.

After an owner-reviewed ownership decision, the exact apply command is the same command
with `-PlanOnly` replaced by `-ApprovedPlanFingerprint <fresh-reviewed-fingerprint>`.
The old captured fingerprint is not an approval for a later changed estate.
The alternate authoritative path is Turnstile's Gateway governance page; P70 does not switch
authority or write through a second control plane.

Open decisions for the owner: the reference ownership/access choice; a separate cache-rate
schema change before pricing Opus 5.5 automatically. The council verdicts and the merge are
recorded above.
MDM assignment and actual Windows/macOS/Linux fleet rollout remain operator actions.
No real managed device or Desktop app was changed by this live proof.
**Packet gate:** `node .ironclad/gate.mjs --stage packet` exited 0 at `9447488`,
2026-09-27 22:17:16-22:40:22Z (1,385.6 s). Test-All passed in 1,376.6 s; the Bicep build
passed in 7.2 s. Scorecard: 22 passed, 2 warned, 0 failed, 2 skipped (no lint/typecheck
commands declared). Warnings remain the existing eight oversized files and 21 unrelated
open unknowns; no detector or budget was relaxed. The shared lock was acquired after
60.1 s and released in `finally`. Another packet acquired it afterwards; P70 did not
remove that later owner's lock.

P70 commits before the gate: plan `0204d5d`, contract `02a45c9`, first green `dfc75f0`,
selection/installer `8f3fe54`, detector preflight `9b2571e`, subscription/record-delta
checks `7c1c28b`, live fresh-record fix `dc1847f`, guides/architecture `2676a90`, live
evidence `9447488`. No merge, push or history rewrite was performed. ROADMAP's P70 box
remains unticked. Council verdicts are intentionally left to the lead, as assigned.

Read-only reference drift, 2026-09-27 20:19Z: both `models-standard` and `models-premium` are
`,,` (allow all), and `turnstile-integration` reports `governanceAuthority=Turnstile`,
`budgetAuthority=Gateway`. This differs from the supplied starting inventory. The Foundry
account has all four stated Claude deployments in `Succeeded`, version 2, GlobalStandard.
No reference write was made. The owner plan will describe the current state and refuse an
apply over Turnstile ownership.

## P69 the company address in the flow, 2026-09-28

Merged to `main` as `69db07a` (`--no-ff`, 2026-09-28); the merge tree equals the tree of the branch
head `c31d372`, which differs from the gated `d73e3fd` only in this file. The ROADMAP entry stays
open for its last clause, a request proven through a company address, which is P74.

The owner's installer run selected a company address but ended with manual hostname, certificate
and DNS instructions. P69 makes that choice an applied, priced and verified part of installation
and a later Change. Work is isolated to `p69-company-address`, based on `aa7ed19`; council review
and merging belong to the lead. The reference gateway and other existing services are read-only.

Live finding, 2026-09-27 20:44 UTC (2026-09-28 locally): the isolated Basic v2 instance deployed in
148.0 s, but its uploaded-PFX hostname PATCH returned `CustomHostnameOwnershipCheckFailed` for
`<company-host>.test`. Azure requires public CNAME ownership even on Basic v2; a zone
that answers only when queried at its Azure name servers does not satisfy that requirement.
The sequence is corrected to DNS before binding. Positive company-hostname TLS proof is blocked
without a delegated domain; none is bought or borrowed. The lead accepted this scope deferral on
2026-09-28; the positive proof moves to P74 and is not complete. U30 covers the research;
P69 did not need the reserved U33 identifier.

### P76 ordinal-sort integration, 2026-09-28

The lead merged `040ca87` (P76 and P75) as `555be85`, retaining P69's explicit Models
decision/record results and P76's code-point assignment-key order. The focused integration
check at that merge fails one of 35 checks: four string sorts in the network/recovery helpers
are culture-dependent, and the numeric free-prefix sort needs its documented value-key entry.

- [x] Gateway hostname projections, network regions, subscription scopes and NSG IDs use the
      existing `Sort-ClaudeFlowOrdinal`; each helper also loads it when used alone
- [x] The numeric `Last` address sort remains native and is listed with the value-key reason;
      null/empty inputs and case-folded uniqueness retain their caller semantics
- [x] A hyphen-versus-letter regression passes on PowerShell 7 and Windows PowerShell 5.1;
      restoring a string `Sort-Object` is caught with the complete selector count
- [x] P69 and the requested network suites pass with their scratch dependencies copied;
      the lead runs the packet gate and council round 4, not this integration task

Initial measurement: native sorting gives `eastus-b,eastusa` on PowerShell 7 and
`eastusa,eastus-b` on Windows PowerShell 5.1. The ordinal helper gives the same order on
both and applies its documented case-folded uniqueness. Native sorting already drops null
pipeline items; NSG IDs additionally filter null/empty values before sorting. No null sentinel
is needed by these four callers. A null element in the typed discovery-subscription argument
becomes an empty string and remains refused rather than silently omitted. No Test-All or gate
is run for this request.

`Test-CompanyFlow` now has 34 assertions on each host, including ordinal hyphen/letter order,
case-folded region duplicates, null/empty lists, scoped ID ordering and fresh standalone imports.
P76's strict entry-point scan uses the same exact exception signatures as its transitive scan:
loading FlowContract directly must not reject the explicitly allowed numeric `Last` sort.
The numeric line still has to exist unchanged, and no string sort was added to the exception
table. P69's installer and mutation sandboxes already copy FlowContract; the network review
mutation sandbox now copies it into its `scripts\flow` directory too.

Implemented in `73ce7c0`. Focused validation on PowerShell 7 and Windows PowerShell 5.1:
CompanyAddress 79/79, CompanyCertificate 31/31, CompanyFlow 34/34, CompanyInstaller 17/17,
FlowAppliedState 20/20, CompanyMutationRunner 5/5 and AddressDeadline 6/6. The full P69
mutation harness catches 105/105 cases with complete 79/31/34/17/20/6 selector counts
(330.2 s PS7, 597.2 s PS5.1). Three new mutations restore the native region sort or remove
one standalone ordinal import; each is caught by CompanyFlow at its full 34 assertions.

`Test-FlowOrdinalOrder` passes all 35 checks, including its cross-host probes. The requested
network suites pass on both hosts: NetworkEdge 67/67, NetworkImpact 26/26,
NetworkReviewNegative 10/10 mutations, NetworkEdgeNegative 14/14 mutations. One concurrent
validation run hit existing timing-sensitive PS5.1 address/deadline checks while the network
tests ran; both passed in isolation, then the two full mutation harnesses ran sequentially.
No bound, selector or assertion was changed to pass those checks. The numeric free-prefix loop
is unchanged. No Test-All or packet gate was run; the lead owns the gate and council round 4.

### Council round 3 corrections

The lead's read-only review of `1345956..cabc4c4` returned the following verdicts on 2026-09-28.
The round-2 A2, C2, C1 and UX findings are closed. The P72 merge semantics, ADR-0025 lane
changes and main's ledger were confirmed intact. The remaining Coder finding is handled test-first.

| Seat | Verdict | Finding | Fix / evidence |
|---|---|---|---|
| Architect | PASS | Round-2 state and integration contract accepted | No further change requested |
| Coder | BLOCK | A saved record for gateway A is ignored for inheritance but passed to address apply for gateway B, which fails after deployment | `f015de3`: check the saved target and shared subscription resolver before approval; refuse the conflict with both gateway names, scopes, record path and a corrective action |
| QA | PASS | Round-2 regressions accepted | Add an executable installer conflict case and a full-count mutation |
| UX | PASS | Applied-only read consumers and P72 refusals retained | New conflict refusal names the selected and recorded gateways |
| Security | PASS | Existing PFX, scope and deadline boundaries retained | No boundary relaxation |

The requested gate at unchanged `cabc4c4` finished before this correction. It acquired the lock
after 120.1 s, reached Test-All's unchanged 1,800-second limit, and exited 1 after 1,808.7 s.
The late timing file contained 87 PASS, zero FAIL and two existing AUM-environment SKIPs.
Across 31 total-machine samples (including the gate), CPU averaged 61.7%, peaked at 100%, the
processor queue peaked at 29 on 16 logical processors, and available memory stayed above
13,463 MB. The slowest check was business-unit mutations 0/4 at 502.0 s; P69's 94 mutations
took 288.2 s. That run is not a passing gate; its lock was released in `finally`.

- [x] An existing installer record for another gateway is refused before summary approval and
      resource creation, without overwriting it; the refusal names both gateways and the record path
- [x] The executable installer regression and mutation pass on both PowerShell hosts
- [x] The corrected tree runs the packet gate under the shared lock with the unchanged budget;
      its final timeout is recorded below, not counted as a pass

The real installer regression reproduced the failure before the fix on both hosts: 16 assertions
ran, with the different-gateway and legacy-subscription cases failing after a deployment write.
After the fix, `Test-CompanyInstaller` passes all 16; the adjacent address and applied-flow
suites pass 79 and 20. All 96 mutations are caught on PowerShell 7 and Windows PowerShell 5.1
with the full applicable 79/31/27/16/20/6 selector count. The two new mutations remove the
pre-approval record-target guard or only its subscription comparison. No check or selector is
removed. The existing architecture boundary is unchanged; its installer source hashes were
regenerated with all 16 diagrams.

An intermediate gate at `d361d5d` passed: Test-All 1,683.9 s; gate 1,694.3 s, 22 passed,
2 warned, zero failed, 2 skipped; 87 of 89 checks passed and the same two missing-environment
checks skipped. The lock was acquired after 1,200.4 s and released in `finally`.

A closely related compatibility case was then reproduced before handoff: first-time Setup
writes an unbound run journal before it invokes the installer. The new refusal must not treat
that journal as another gateway. The executable test failed, then passed after recognizing
only schema-v2 Setup/Change-foundation journals with no gateway identity. Address apply binds
the selected identity after approval and retains an unverified receipt on the injected 503;
bound, partial, direct-Foundry and unrelated-action records cannot use this path. Targeted totals
are now 17 installer, 28 flow and 79 address assertions on both hosts. The final gate follows
this compatibility correction; the intermediate gate does not certify the later tree.
All 102 mutations now pass on both hosts with full 79/31/28/17/20/6 selector counts. The
additional draft mutations prove recognition, reject bound or unrelated records, and require
the approved identity to be retained in the failure receipt. Installer permutations and
documentation/source checks pass, and the architecture manifest is current.

**Final round-3 gate at `1cd1567`: timeout, not pass.** The lock was acquired after 360.2 s and
released in `finally`. The gate ran 2026-09-28 08:06:05-08:36:15 UTC and exited 1 after
1,809.3 s: Test-All reached the unchanged 1,800-second limit; Bicep passed in 7.7 s.
Scorecard: 21 passed, 2 warned, 1 failed, 2 skipped. The late Test-All timing file, written at
08:37:32 UTC, reported 87 PASS, zero FAIL and the same two AUM-environment SKIPs (89 checks).
That late result and the intermediate passing gate do not certify the final tree.

The slowest final-run checks were business-unit mutations 0/4 (392.3 s), 3/4 (313.6 s),
company-address mutations, all 102 cases (301.7 s), business-unit mutations 1/4 (300.1 s),
2/4 (296.4 s), and Turnstile mutations 1/2 (220.5 s), 0/2 (218.3 s). Aggregate machine samples,
including the gate, averaged 68.4% CPU, peaked at 100%, with a maximum processor queue of 82
and minimum available memory of 14,372 MB. Receipts, load samples and timings are retained in
session artifacts. No timeout, selector or detector was relaxed.

The Coder correction and first-Setup compatibility tests are ready for re-review; the final
packet remains blocked on gate duration. ROADMAP P69 is unticked and P74 remains deferred.

### Council round 2 corrections

The lead's five-seat review of `c82f951..1345956` (read-only, 2026-09-28) returned BLOCK.
A1, Q1, U1 and S1 are closed by that review. P74 remains an accepted scope deferral, not done.
The following corrections passed their targeted tests and mutations; the merged packet gate and
council re-review follow. The review verdicts below are the supplied verdicts, not self-issued passes.

| Seat | Verdict | Finding | Fix and regression required |
|---|---|---|---|
| Architect | BLOCK (A2 partial) | Only the owning decision advances; DesktopSignIn loses `deviceProfiles.regenerate` | `f3f6672`, `51ca117`: explicit cross-decision results; real DesktopSignIn and Models success/failure regressions |
| Coder | BLOCK (C2 partial) | Foundation's Azure-transition result merges deletions back into old metadata | `f3f6672`: returned snapshots replace applied decisions; explicit property removals clear both address copies |
| Coder | BLOCK (C1 partial) | Installer omits the receipt path; legacy Foundation-only subscription fails recovery | `6a2eee2`: real installer 503 after replacement leaves an unverified receipt; shared subscription resolver |
| QA | PASS, coverage gaps noted | Single-decision fixture missed cross-decision writes and removal propagation | `4d7c4d0`: 94 full-selector-count mutations on both hosts, including every new boundary |
| UX | BLOCK | Status, Guide and discovery read proposed answers | `f3f6672`: applied-only read consumers; only selected planning/apply decisions receive proposals |
| Security | PASS for prior S1 | Validated PFX buffer and deadline cleanup retained | Preserve the passing round-1 detectors |

Integration is normal merge `51ca117`, with parents `6a2eee2` and `f98f885` (P72 and P70), not a rebase.
P72's refusal handling and Guide drift warning, P70's Models prepare/apply boundary, and the
scoped address recovery exception are retained. Ledger differences against main must contain
only P69's own contributions: additions to CHANGELOG/STATUS/ROADMAP, and the U30 row/detail in
UNKNOWNS. U34-U36 and P73 remain unchanged. The Models integration exposed a PowerShell 5.1
JSON round-trip array wrapper and loss of one-element arrays; recursive value copies now retain
their shape without sharing nested objects. Model records are published after profile generation
succeeds, and their return values declare both profile decisions and top-level model data.

Both hosts pass `Test-CompanyAddress` 79, `Test-CompanyCertificate` 31, `Test-CompanyFlow` 27,
`Test-CompanyInstaller` 13, `Test-FlowAppliedState` 20, `Test-AddressDeadline` 6 and
`Test-CompanyMutationRunner` 5 assertions. The real P70 lifecycle suite passes 138 assertions
on each host; P72's complete flow and installer permutation suites pass after their shadow
repositories gained the new helper dependency. All 94 P69 mutations are caught, each running
the full applicable 79/31/27/13/20/6 selectors (314.3 s PS7, 526.3 s PS5.1).

**Lane evidence (ADR-0025).** Certificate, CompanyFlow, Installer and MutationRunner were
inspected for writes, ports, native tools and process-wide state. They use GUID-named private
scratch, mocked Azure/prices and process-local helpers; they neither write tracked source nor
use live Azure, shared configuration or listening ports. Only those four checks moved to the
parallel lane. The mutation harness and deadline probes remain exclusive; no timing-sensitive
check was moved or omitted.

The same Test-All scheduler and four registrations ran serially once, then three times at
parallel throttle 4, each in a fresh process. All four full suites passed in every run.

| Check / wall duration, seconds | Before: serial | Parallel 1 | Parallel 2 | Parallel 3 |
|---|---:|---:|---:|---:|
| Certificate | 3.7 | 2.4 | 2.3 | 2.0 |
| CompanyFlow | 3.4 | 2.5 | 2.6 | 2.1 |
| Installer | 4.8 | 4.9 | 5.0 | 4.0 |
| MutationRunner | 1.3 | 1.5 | 1.3 | 1.2 |
| Four-check wall | 13.3 | 5.2 | 5.3 | 4.2 |

These are the selected-check lane measurements, not whole-suite timings. The unchanged
1,800-second full-gate budget still applies.

**Round 2 merged-tree gate: timed out, not passed.** At `51e816e`, the gate acquired the shared
lock immediately and ran from 2026-09-28 04:52:43 to 05:22:57 UTC. Exit 1 after 1,814.5 s:
21 passed, 2 warned, 1 failed, 2 skipped. Test-All reached the unchanged 1,800-second command
limit; Bicep passed in 12.5 s. The lock was released in `finally`.

The owned Test-All child finished at 05:26:20 UTC, about 2,017 seconds after gate start, and
its timings file recorded 89 checks: 87 PASS, zero FAIL, two existing missing-environment SKIPs
(AUM service and AUM Python environments). That late completion is not a passing packet gate.
The timings and gate receipts are retained as session artifacts. No budget, selector or detector
was relaxed, and the late child had exited before temporary files were removed.

| Slowest checks from the late timings file | Seconds | Result |
|---|---:|---|
| Business-unit mutations, shard 0/4 | 513.7 | PASS |
| Business-unit mutations, shard 1/4 | 387.9 | PASS |
| Business-unit mutations, shard 2/4 | 377.5 | PASS |
| Business-unit mutations, shard 3/4 | 376.2 | PASS |
| Turnstile mutations, shard 1/2 | 358.8 | PASS |
| Turnstile mutations, shard 0/2 | 352.1 | PASS |
| Company-address mutations, all 94 cases | 304.3 | PASS |

The round-2 functional corrections, normal main merge, dual-host mutations and lane measurements
are ready for the lead's re-review. The merged packet remains blocked on the full-gate duration.
P69 stays unticked in ROADMAP; the accepted P74 positive TLS proof remains deferred, not done.

### Council round 1 corrections

The lead's five-seat review of `aa7ed19..c82f951` (gpt-6-astra, read-only, 2026-09-28)
returned BLOCK. The following corrections are implemented and targeted checks pass; a passing targeted test is not a
council re-review verdict.

**Round 1 correction gate: PASS** at `215d43a`, 2026-09-28 02:57:55-03:26:09 UTC.
The lock was acquired after 840.4 s of 60-second retries and released in `finally`.
`node .ironclad/gate.mjs --stage packet` exited 0 in 1,694.4 s: 22 passed, 2 warned,
zero failed, 2 skipped. Test-All completed in 1,684.1 s with 85 registered checks:
83 PASS, zero FAIL, two existing missing-environment SKIPs (AUM service and AUM Python environments).
The 1,800-second budget is unchanged; Bicep passed in 8.6 s. The complete 82-mutation check
passed in 213.5 s in this gate. The branch is ready for the lead's council re-review, not a
claim that the deferred P74 live criterion is done.

| ID | Seat | Finding | Required evidence |
|---|---|---|---|
| A1 | Architect | Inherited custom address writes escaped Foundation pricing and fingerprinting | `d2a61d5`: effective inputs are resolved once, passed exactly and fingerprinted; executable installer/Foundation mutations |
| A2 | Architect | Proposed answers were saved as applied decisions and as history's previous value | `f469bbc`: generic real-orchestrator tests preserve pre-question history and applied state on failure |
| C1 | Coder | Replacing the old hostname then failing proof made Change reject recovery as drift | `e030301`: integrity-checked unverified receipt; only matching Change address recovery, with fresh approval |
| C2 | Coder | Returning to Azure retained company metadata and old generated settings | `d2a61d5`, `74fab21`: metadata, Foundation inputs and generated artifacts agree with the Azure URL |
| Q1 | QA | Source-position assertions did not execute installer approval guards | `d2a61d5`, `387f2fd`: real installer with mocked Azure; deleting its fingerprint, decline or WhatIf guard fails the named test |
| U1 | UX | A slow check could succeed after its advertised deadline | `a6b9d21`, `74fab21`: cancellable checks, bounded native reads, late-result refusal and parent-owned private-file cleanup |
| S1 | Security | PFX bytes were reread after hash approval | `5128a28`: one validated/hashed buffer is uploaded despite file replacement during DNS waiting |

Round 1 correction evidence, both PowerShell 7 and Windows PowerShell 5.1:

| Test | Assertions or mutations |
|---|---|
| `Test-CompanyAddress.ps1` | 78/78 |
| `Test-CompanyCertificate.ps1` | 31/31 |
| `Test-CompanyFlow.ps1` | 27/27 |
| `Test-CompanyInstaller.ps1` | 11/11, executing the real installer with external services stubbed |
| `Test-FlowAppliedState.ps1` | 9/9, executing the real orchestrator for an arbitrary step |
| `Test-AddressDeadline.ps1` | 6/6, including real child-process timeouts, native Azure-command stubs and private-directory ownership |
| `Test-CompanyMutationRunner.ps1` | 5/5 |
| `Test-CompanyAddressNegative.ps1` | 82/82; every case runs the full applicable 78/31/27/11/9/6 assertions |

The 81 mutations took 257.1 s on PowerShell 7 and 437.6 s on Windows PowerShell 5.1.
Each suite owns a temporary directory, including deliberately broken cleanup cases; no assertion
or mutation is skipped. Native timeout checks include termination/cleanup time in the reported
elapsed duration. Structured values, secure strings and PFX byte arrays also passed through the
real worker transport on both hosts without being placed on a native command line.

P72 merge boundary: the trap, Show-Status, main drift call and cancellation catch blocks were
not rewritten. Shared changes are the applied-decision snapshot/serializer, history capture and
the narrowly scoped recovery branch inside `Assert-RecordMatchesLive`.

The first round-1 locked gate at `1adb5c6` completed Test-All in 1,226.3 s, below the unchanged
1,800-second budget, but failed two checks (81 passed, 2 failed, 2 skipped). The format scanner
found a regex fixture that resembled an invalid format alignment and emitted-script paths that
were relative to the test source rather than its generated location. Both fixtures were corrected
without changing either detector. The mutation baseline failed only under Test-All's nested
temporary paths: Windows returned the user directory instead of an overlong worker TEMP path,
and could not start its deeply nested `az.cmd` fixture. Workers and mutation copies now use
short, unique per-user temporary directories; workers verify that the runtime directory matches
their parent's owned path before executing. The nested-path reproduction passes. Final counts:
82/82 mutations on both hosts, with full 78/31/27/11/9/6 assertions; `Test-AddressDeadline` is 6/6.
The final packet gate follows this correction; the earlier failing result is not counted as pass.

The next locked gate at `386bb22` hit the unchanged 1,800-second command deadline. Its child
Test-All finished just after the gate timeout with 83 PASS, zero FAIL and two dependency SKIPs;
that late completion is not a passing gate. The new mutation check passed in 222.1 s. The
deadline probes were shortened without reducing coverage: the simulated blocked native command
lasts 8 rather than 30 seconds, its required return bound is stricter (6 rather than 8 seconds),
and the deadline mutation doubles rather than multiplies the wait by 100. All 82 mutations
remain caught with full assertion counts (195.8 s PS7, 372.0 s PS5.1). The gate is rerun without
changing its command budget or test selectors.

- [x] U30 is closed with dated Microsoft Learn and Azure Retail Prices API evidence for every
      v2 tier, certificate source, DNS record, update wait and component price; ADR-0033 records
      the design before production code
- [x] One script plans without writes and applies the hostname, certificate and DNS records;
      existing hostname configurations and service/network properties survive the ARM update
- [x] Azure DNS records are created in the selected writable zone; external DNS gets exact
      records and a bounded resolution wait; every wait names its purpose, estimate and elapsed time
- [x] Certificate choices match the selected tier; Key Vault access uses the gateway managed
      identity; no certificate password, private key or token enters the record, plan or logs
- [x] The installer asks for the address and certificate alongside its other choices, states
      each component's cost before confirmation, and applies only after deployment
- [x] `-Action Change -Change address` has an ADR-0030 plan, cost, fingerprint, apply and verification;
      a successful HTTPS proof updates the onboarding address and developer-facing artifacts
- [x] Offline tests run on PowerShell 7 and Windows PowerShell 5.1; every new detector is
      negative-tested with the complete assertion count; each green is committed
- [ ] **Deferred to P74, not done:** positive HTTPS through an owned, publicly delegated company
      hostname with its matching certificate. The isolated authoritative CNAME and ownership
      refusal were measured; all proof resources were deleted and the gateway purged below USD 5
- [x] Redacted, inspected live terminal images numbered 40 onward are embedded in the updated
      setup/flow documentation; architecture sources, images and manifest remain current
- [x] The current merged tree's locked packet gate exits 0. Round 1 passed at `215d43a`;
      round 2 at `51e816e` timed out at the then 1,800 s budget, and so did `1cd1567` and, on the
      merge of `main` `040ca87`, `b4e970b` (at throttle 8 and at the default throttle), which led to
      P77 ([ADR-0036](adr/0036-gate-budget-until-sharded.md)). Council round 4, all five seats PASS.
      On `d73e3fd`, `b4e970b` with `main` `9635426` (P77) merged, 2026-09-28 16:43:46-17:17:30 IST
      under the shared lock at the default throttle: 22 passed, 2 warned, 0 failed, 2 skipped;
      Test-All passed in 2,015.2 s (89 PASS, 2 SKIP of 91 checks) within the 3,600 s budget, the
      Bicep build in 7.2 s

Implementation: `b10e945` (certificate/TLS), `99ade80` (shared script and installer/Change wiring),
`e607df8` (unattended Foundation plan and price binding), `c6b5749` (DNS-before-binding and
handover consistency), `643ae41` (negative detectors). Plan `c433f89`; contract `10c7a41`.

| Evidence | PowerShell 7 | Windows PowerShell 5.1 |
|---|---|---|
| `Test-CompanyAddress.ps1` | 71/71 assertions | 71/71 assertions |
| `Test-CompanyCertificate.ps1` | 30/30 assertions | 30/30 assertions |
| `Test-CompanyFlow.ps1` | 24/24 assertions | 24/24 assertions |
| `Test-CompanyAddressNegative.ps1` | 59/59 mutations caught | 59/59 mutations caught |
| `Test-CompanyMutationRunner.ps1` | 5/5 assertions | 5/5 assertions |
| Actual `Invoke-ClaudeAddressHttps`, read-only against the reference Azure hostname without a token | HTTP 401; trusted chain and exact pin; 0.91 s | HTTP 401; trusted chain and exact pin; 1.24 s |

The first RED runs completed 61 address and 30 certificate assertions on both hosts, all failing
for the absent implementation or empty-region price restriction. Unattended Foundation then
failed three of 22 integration assertions before its wiring was added. The live DNS sequence
failed its new offline ownership assertion before being corrected. Mutations run each complete
suite in a private copy and restore the source after every case. One mutation initially survived:
removing the discovery HTTPS-scheme check was concealed by the port check on ordinary HTTP.
An HTTP URL explicitly using port 443 now isolates that detector. The full assertion counts
above run under each mutation; no test is skipped.

Related checks passed: `Test-NetworkTransport`, `Test-FlowContract`, `Test-AdminSurface`,
`Test-FlowStart` (114 assertions, including its own PowerShell 5.1 probes), `Test-On-PS51` (real
installer `-WhatIf` reaches the summary), `Test-DocReferences` and `Test-Architecture` (36
assertions). The architecture generator rendered 15 specs and 17 PNG outputs with current
source hashes. The new company-address diagram and images 40-42 were inspected after rendering;
the screenshots' hashes and redacted command provenance are in
`docs/guide/company-address-captures.json`.

**Live resources and cleanup, all times UTC on 2026-09-27.** No resource outside the owned proof
group was written. The existing Foundry account was only referenced by the template with
`grantFoundryRole=false`; no Entra group or Key Vault was created.

| Created | Time / scope | Deleted or purged |
|---|---|---|
| `<proof-resource-group>`, tag `purpose=p69-proof` | 20:38:41.905 | Delete requested 20:52:14.326; confirmed absent 20:55:00.080 (165.7 s) |
| Azure DNS `<proof-zone>.test` | 20:38:49.248, in the proof group | With the group |
| Basic v2 `<proof-apim>` | Template deployment finished 20:41:14.822; 148.0 s including final read | With the group; `az apim deletedservice purge` finished 20:56:31.515 (91.4 s); absence confirmed |
| `<proof-workspace>`, `<proof-application-insights>`, and its Failure Anomalies smart-detector rule | Same template deployment, in the proof group | With the group |
| Local, self-signed RSA PFX for the reserved test hostname | Supplied to APIM; never imported into a certificate store | Temporary PFX and public PEM removed after capture |

The authoritative CNAME resolved after 15.1 s in the retry, and a separate
`Resolve-DnsName -Type CNAME -Server <Azure-nameserver>` at 20:52:06.873 returned the planned
target and TTL 300 in 0.576 s. Both PFX hostname PATCHes failed
`CustomHostnameOwnershipCheckFailed`; the second failure followed that DNS readiness.
`curl.exe --resolve <company-host>:443:<gateway-IP> --cacert <proof-public-certificate>` then
failed the handshake, exit 35 (0.472 s). The isolated Azure hostname returned the policy's
`401 A Microsoft Entra ID token is required`, TLS verification 0, in 6.770 s.
**The positive company-hostname TLS acceptance is deferred to P74**, not passed, without an
administrator-owned public domain. No ownership validation was bypassed and no domain was
bought or borrowed.

The proof group's 0.2717-hour lifetime gives an elapsed-time Basic v2 list-price estimate of
USD 0.0558, plus one short-lived DNS zone, a handful of queries and unauthenticated telemetry;
the USD 5 ceiling was retained. Invoice reconciliation is unavailable (**U2**). A first cleanup
log calculation mixed local `DateTime` and UTC strings; a final UTC-offset calculation corrected
it from USD 1.1860 to USD 0.0558. A read-only cleanup check at 21:27 UTC again found no resource
group and no matching soft-deleted gateway.

Council review and the decision about the blocked public-domain proof belong to the lead.
The roadmap entry remains unticked.

First locked packet gate, `e6ddf0d`: exit 1 after 1,817.3 s because Test-All exceeded its unchanged
1,800-second budget. The P69 mutation check alone occupied 10 minutes 38 seconds in the serial
lane, repeatedly starting native PowerShell processes. The gate's timed-out shell left its
Test-All child running; only that verified P69 process tree was stopped by explicit process IDs.
The fix retains every mutation and assertion but uses a fresh, disposable PowerShell runspace
for each case. Dedicated runner tests cover exit codes, output, missing summaries and isolation.
All 59 cases then passed in 82.9 s on PowerShell 7 and 164.8 s on Windows PowerShell 5.1, with
the same 71/30/24 full assertion counts. The charter budget is not increased.

**Prior handoff at c82f951: blocked, not packet-complete.** At `81508b1`, the corrected gate attempt retried
the shared `.gate-lock` every 60 seconds for the full permitted 60 minutes. Another run retained
the lock, so this attempt never started the packet gate and exited 1. That lock was not removed.
The last executed packet gate therefore remains the timeout above: 21 passed, 2 warned, 1 failed,
2 skipped, with the Bicep build passing in 15.2 s. Targeted checks and all 59 mutations pass after
the speedup, but there is no passing full gate to claim. The lead still needs an available gate
window, the five council verdicts, and a decision about the positive company-domain proof that
requires a delegated domain. No merge, push, history rewrite or roadmap completion was performed.

## P68 the guided flow starts at once and gives the foundation to the installer, 2026-09-27

The owner's test on 2026-09-27: `Start-ClaudeGateway.ps1` showed nothing for a long time and asked
nothing first; Setup took the installer's decisions away (`-Yes`) and stopped on the Cosmos store;
a region choice showed no cost; the installer did not offer the FinOps tool; its next steps were
numbered 0, 0, 1. Measured on this workstation against the reference subscription: 66 s before
the first line of output, all of it discovery that no step reads. Reading `Foundation.ps1` also
found that its apply runs the installer for a recorded gateway while its plan says `Check`; under
`-Yes` the installer's reuse menu defaults to a new gateway. Design:
[ADR-0032](adr/0032-guided-flow-starts-at-once.md); research: **U31**.

- [x] Discovery makes no listing call. With an empty record it makes no Azure call, and the first
      line of output appears within 3 s and says that nothing is read. Live, reference
      subscription: first line 0.76 s, review 2.3 s (was 66 s); `Test-FlowStart` asserts no az call
      and the first line under 3 s
- [x] With a record that names a gateway, discovery reads that one gateway, printing what it reads
      with an estimate before and the time it took after; a gateway Azure reports missing is drift,
      and a read that fails for another reason is reported and is not drift. Live: one
      `az apim show`, announced "about 4 s", read in 2.8 s; `Test-FlowStart` covers match, URL
      drift, not found, not signed in, no Azure CLI and Status
- [x] In an attended run with no recorded gateway, Setup prints a Foundation review that names the
      installer's questions and runs the installer without `-Yes`, passing only the record's
      values; an installer that writes no record stops the flow; then Setup reads the new gateway
      and asks the remaining questions, FinOps priced in the gateway's region, and asks for the
      typed fingerprint for those steps only. `Test-FlowStart` drives it end to end with a stub
      installer; live on 2026-09-27 the real installer asked 26 questions and, declined at its
      summary, created nothing ([GUIDED-FLOW](GUIDED-FLOW.md#attended-setup), images 30-34)
- [x] With a recorded gateway, Setup and Guide check it and never run the installer;
      `-Change foundation` runs it with `-ExistingApimName`, which updates that gateway and keeps
      its region, tier, name and publisher (attended: nothing else is passed and the installer
      asks; unattended: `-Yes` with the recorded choices). Live with `-WhatIf` on PowerShell 7
      and 5.1: the reference gateway was adopted with no menu or placement prompt
- [x] Without a console, Setup passes `-Yes`, and `-DeployProjection` with the Cosmos store, so the
      installer deploys the projection instead of stopping; every argument a plan passes is a
      parameter of the installer
- [x] The installer's region prompt lists the Foundry account's region and the others in its
      geography with each v2 tier's monthly list price; its tier prompt lists each tier's price in
      the chosen region; a price the API does not publish reads as not published; the agreement's
      price sheet is named as the authority. Live on PowerShell 7 and Windows PowerShell 5.1: nine
      US regions at USD 150 / 700 / 2,800, matching the summary's USD 150/month
- [x] The installer records `sku`, `location`, `foundryAccount` and `foundryResourceGroup`; run on
      its own in a console it ends by offering the FinOps tool; its next steps are numbered 1, 2, 3
      and so on
- [x] Live: `-Action Setup -PlanOnly` against the reference subscription prints its first line
      within 3 s with an empty record, and reads the reference gateway in one call with a record
      that names it
- [x] Found in the live runs and fixed with tests: the installer's Foundry search was silent for
      about 56 s (now an estimate and one line per account); Windows PowerShell 5.1 listed only the
      Foundry region; FinOps monthly totals had six decimals; a recorded gateway's price was
      counted as new; declining at the summary ended in a stack trace
- [x] Council verdicts and `node .ironclad/gate.mjs --stage packet` exits 0: three council rounds, five PASS verdicts in the third; gate PASS at `57b8d3a` (22 passed, 2 warned, 0 failed, 2 skipped; Test-All passed in 1,192.5 s)

Council, first review (gpt-6-astra, 2026-09-27): BLOCK on all five seats, seven findings, each
reproduced on PowerShell 7 and 5.1. All fixed in `fe53ac7`, each with a test that fails when the
fix is removed (ten mutations caught with the full 109 assertions run):

| # | Seat | Finding | Fix |
|---|---|---|---|
| 1 | Security (BLOCK) | Unattended `-Change foundation` forwarded the live publisher email to the installer, which passes it to `az.cmd`; an `&` in it ran a second command | `-ExistingApimName` lets the installer adopt the gateway's own values, so the flow forwards none; the flow refuses record values holding `& \| < > ^ ( ) " %` before the installer; the installer checks what it passes to `az` before its summary |
| 2 | Architect (BLOCK) | With no Claude deployment in the subscription, the installer created one before its summary, which the attended flow treats as the approval | The summary lists the deployment; it is created after the confirmation, never under `-WhatIf`; an AST check keeps every `New-ClaudeDeployment` call after the confirmation |
| 3 | Architect, QA | A failed step after the installer did not resume: the retry planned the new foundation check, so the fingerprint changed and FinOps ran twice | `activeRun` records the phase and steps; a retry plans the same steps and resumes with one run id |
| 4 | Coder | Discovery honoured the record's `subscriptionId`, the installer was not given it | One resolver for both; the id is passed and fingerprinted; a name instead of an id is refused |
| 5 | Coder, UX | The Change review priced the recorded tier and region, not the live ones kept | Priced from the live gateway, as already running |
| 6 | UX | A mistyped fingerprint after the installer said "nothing was written" | It says the foundation is set up and the remaining steps were not applied, without a stack trace |
| 7 | UX | Attended Change passed the recorded values, so the installer skipped the reuse menu the review promised | Only the recorded gateway is passed; the review says the installer updates it and asks the rest |

The mutation that made attended Change copy the recorded choices also exposed a loose assertion: the
attended Change test checked that four arguments were absent, not that nothing else was passed. It
now checks the exact argument set.

Council, second review of those fixes (gpt-6-astra, 2026-09-27): all seven fixes confirmed on
PowerShell 7 and 5.1, and BLOCK on three new findings, each reproduced. Fixed in `5c5ee36`; five
mutations that undo these fixes are caught, with the first round's ten, at the full 114
assertions:

| # | Seat | Finding | Fix |
|---|---|---|---|
| N1 | Security (BLOCK) | A JSON list in the record passed the flow's check (non-strings were skipped); binding joined it into text that reached `az` before the installer's check | The flow refuses a list or object where the installer takes one value; the installer checks its bound parameters before its first `az` call that uses one |
| N2 | Coder, UX | The flow refused an organisation name such as `AT&T`, which reaches Azure in a JSON body, not `az`; the first-round test enforced that refusal | The character check covers only the parameters that reach `az`, measured on the installer's `az` calls; the test now requires `AT&T` to pass and refuses `ai&calc` as a Foundry account |
| N3 | Architect, QA | A retry resumed the recorded steps after a step gained a new prerequisite, which then never ran | A second phase resumes only when the present steps are the recorded ones; otherwise every step is planned again, and the output says so |

The shadow repository in `Test-FlowStart` now prices API Management from a stub, so its child runs
make no network call; the first-round live-price change had made them reach the Retail Prices API.

Council, third review (gpt-6-astra, 2026-09-28): N1-N3 confirmed on PowerShell 7 and 5.1, no new
high-confidence defect. Its probes: lists, objects and hashtables refused with and without the
shim (8 of 8); zero executions past either installer check for the malicious list, an unsafe bound
audience and an unsafe derived audience; legitimate values accepted for all twelve parameters that
reach `az` (spaced group names, a plus-addressed email, an `api://` audience) and all 132 tested
character and parameter combinations refused; organisation and industry values with `&`, `( )`
and quotes passed unchanged; unchanged step sets resume, changed sets are planned again, and a
different action or `-Change` ignores the stale run.

Council: Architect PASS (discovery reads only the recorded gateway; an attended run applies the
installer first and the other steps in a second phase with its own fingerprint and resume; Change
foundation uses the installer's own reuse path by name; resume is restricted only to an unchanged
step set). Coder PASS (one subscription resolver; destination-aware checks of the installer
arguments; lists refused before binding; values priced from the live gateway; the reuse adoption
shared by the named path and the menu). QA PASS, with gaps named (Test-FlowStart, 114 assertions;
22 mutations of P68's detectors caught with the full assertion count, the last fifteen together at
114; the installer's region, tier, reuse and named
paths run live with `-WhatIf` on PowerShell 7 and 5.1; not run: an attended apply that creates a
gateway, a subscription with no Claude deployment, the macOS/Linux installer, which has no priced
prompts yet). UX PASS (first line in 0.76 s with an empty record; every Azure read states an
estimate and its time; prices at the region and tier prompts; numbered next steps; cancellation and
a mistyped fingerprint say what exists). Security PASS (no record, typed or adopted value that
reaches `az` can carry what `cmd.exe` re-reads; recorded names are allow-listed for discovery; the
five captures were inspected for identifiers; the flow asks for no fingerprint only where the
installer's own confirmation precedes every write).

## P67 developer workstation fixes from the owner's test, 2026-09-27

The owner ran the flows on another workstation on 2026-09-27. After `Setup-ClaudeWorkstation.ps1`,
the Claude Code CLI (2.1.101) returned `400 "thinking.type.enabled" is not supported` for
`claude-opus-5`, Claude Desktop showed an empty **Credential kind** and no Entra sign-in, and
Diagnose waited for minutes on `claude doctor` and printed its output unreadably. Design:
[ADR-0031](adr/0031-client-keys-every-release-reads.md); research: **U27**, **U28**; open: **U29**.

- [x] Desktop Entra sign-in is written in the spelling the Desktop release that reads it knows:
      `interactive`, `inferenceGatewayOidc` and `inferenceGatewayOidcAuthFlow` before 2.7032.0 or
      when unknown, `external-idp`, `inferenceIdpOidc` and `inferenceIdpAuthFlow` from 2.7032.0;
      on Windows the older of the installed and running builds decides; the MDM generator
      defaults to the original spelling (`-DesktopKeySpelling current` for a 2.7032.0 fleet);
      the helper-script keys are unchanged
- [x] Claude Code settings declare capabilities by model family, not by a list of models (Opus
      4.7 and later, Sonnet, Fable and Mythos 5 and later), with per-deployment `capabilities`
      and `claudeCode` overrides in the record; each alias is pinned to the newest recorded model
      in its family; in the Windows and macOS/Linux setups and the MDM profiles
- [x] The installer records each Claude deployment's name, model and version in
      `claude-gateway.json`
- [x] Workstation setup compares the installed Claude Code and Claude Desktop with the releases the
      recorded models and keys need, updates an older Claude Code with `claude update` unless
      `-SkipInstall`, names every Claude Code on PATH and which one runs, keeps the developer's
      own settings and VS Code variables, and ends by asking Claude Code itself for one reply
- [x] Diagnostics run `claude doctor` with no input, a time limit and UTF-8 decoding; read the
      Desktop configuration from its real sources and check it against the release that reads
      it; report a running Desktop build older than the installed one and versioned shortcuts;
      show Desktop's recent `[custom-3p]` log errors; flag a pinned model newer than the release
      table without its declaration; name an unfinished decision record; never print an empty
      `--tenant`. The macOS/Linux diagnostics gain the model check and read the `Claude-3p`
      profile instead of `claude_desktop_config.json`, which is Desktop's MCP file
- [x] Live: Claude Code 2.1.101 answers through the reference gateway with the settings the setup
      writes, by every model selection; without the declarations it returns the 400 (**U28**)
- [x] Council review of the packet diff (gpt-6-astra, 2026-09-27): five findings, all confirmed
      and fixed, below; a second review of those fixes found five more, and a third review six
      more, all confirmed and fixed
- [x] `node .ironclad/gate.mjs --stage packet` on the merge `ea31a5f`, 2026-09-27 11:40-11:57Z:
      22 passed, 2 warned (file size, open unknowns), 0 failed; pushed to `origin/main`
- [x] The same gate on the merge of the second review's fixes, `4327563`, 12:52-13:10Z: 22
      passed, 2 warned, 0 failed; held back from `origin/main` for the third review's findings
- [x] `node .ironclad/gate.mjs --stage packet` on the merge of the third review's fixes, `25bda4d`,
      2026-09-27 13:38-13:57Z: 22 passed, 2 warned (file size, open unknowns), 0 failed; pushed to
      `origin/main` with `4327563`

Found while testing P67, and fixed in it:

| Defect | Evidence | Fix |
|---|---|---|
| On PowerShell 7 the setup and diagnostics ran npm's extensionless `claude`, which Windows cannot start ("not a valid application for this OS platform") | `Test-GuidedFlow.ps1` on this workstation, whose npm folder holds `claude`, `claude.cmd` and `claude.ps1`; `Group-Object` sorts its groups on PowerShell 7, which put the extensionless file first. PowerShell 5.1 kept PATH order | `Get-ClaudeCodeInstall` keeps one install per folder in PATH order and chooses `.exe`, `.cmd`, `.bat` or `.ps1`; `Invoke-ClaudeClientCommand` returns a start failure instead of throwing |
| Under a Windows `jq.exe` every bash value ended in a carriage return, so no model matched a rule | The macOS/Linux setup run end to end from Git Bash wrote `claude-opus-5\r`; WSL appends the Windows PATH, where `WinGet\Links\jq` is that `jq.exe` | `jq_value_` strips carriage returns for all 17 value reads |
| The macOS/Linux setup pinned the haiku alias to Sonnet even with a Haiku deployment recorded, replaced the developer's VS Code variables, and ignored `claudeCode` overrides | The same end-to-end run, compared key by key with the PowerShell module | Same pinning, merge and release rules as `ClaudeClientSupport.ps1` |
| On Windows PowerShell 5.1 the setup's gateway check threw `Object reference not set to an instance of an object` and sent nothing | The new end-to-end run of the Windows setup against a local gateway stand-in, on both hosts; the same POST returned 200 with `-UseBasicParsing` | `-UseBasicParsing` in the setup, the diagnostics and the preflight |

Council findings (all reproduced before fixing):

| # | Finding | Verdict | Fix |
|---|---|---|---|
| 1 | The MDM generator skipped a one-deployment record on Windows PowerShell 5.1 | Confirmed | `@(...)` around the assignment; test with one deployment, run on 5.1 |
| 2 | The onboarding email fetched only the setup script, which now needs its helpers | Confirmed | The email fetches every file the setup reads, taken from the script; the setup stops at once and names a missing helper; the Windows end-to-end run uses only those files |
| 3 | Diagnostics passed a declaration that breaks requests when the release knew the model | Confirmed, and refined by measurement: 2.1.272 retries after the 400, 2.1.101 does not | Per-alias verdicts from the request capture (**U28**), in PowerShell and bash, compared word for word over fifteen cases |
| 4 | The MDM haiku alias ignored an explicit `-SonnetModel` | Confirmed | Only a recorded Haiku deployment takes the alias |
| 5 | The bash watchdog could be outlived by a command that ignores TERM | Confirmed | KILL 5 s after TERM to the process group; `timeout -k 5`; tested with a TERM-ignoring child on both paths |

Second review of those fixes (gpt-6-astra, 2026-09-27; all reproduced before fixing):

| # | Finding | Verdict | Fix |
|---|---|---|---|
| 1 | A child that outlived the command on TERM kept the output open: the watchdog was cancelled when the command exited, and GNU `timeout` stops when its own child exits | Confirmed | The command runs in its own process group from perl, `setsid` or GNU `timeout` (with a longer timer than the watchdog's); once the time is up the watchdog always sends KILL to the group; tested with a child that ignores TERM after its parent exits, on each provider present |
| 2 | The email's download URL was expanded as PowerShell: a `$web` segment vanished, and an `&` broke the command | Confirmed | One single-quoted literal; files joined to it; a file share or folder is copied; the test runs the email's command over HTTP from `/$web/Engineering&Tools/claude`, and from a folder path with a space and `&` |
| 3 | The onboarding wrapper's final check, `Debug-ClaudeCode.ps1`, still called `Invoke-WebRequest` without `-UseBasicParsing` | Confirmed | Added there, and in the administrator diagnostics and `Show-Governance.ps1`; the test runs the check on both hosts |
| 4 | Bash did not count a name in an older record's `models` list as recorded | Confirmed; the review also exposed the reverse case, where PowerShell counted names read from `settings.json` as a record | Both follow the record only; four more alias cases, for an older record and no record, compared word for word |
| 5 | Without Git Bash or jq every bash check was skipped and the suite still passed | Confirmed | The suite fails unless `CLAUDE_TEST_SKIP_BASH=1` asks for the skip by name |

The end-to-end run of the email's command on Windows PowerShell 5.1 then found one more defect: a
record the installer writes on 5.1 starts with a UTF-8 byte-order mark, and the setup could not read
it over HTTP there. The setup decodes the bytes as UTF-8 and drops the mark, and the test writes its
record with a mark so both hosts check it.

Third review, of the second review's fixes (gpt-6-astra, 2026-09-27; all reproduced before fixing):

| # | Finding | Verdict | Fix |
|---|---|---|---|
| 1 | The email-command runs have no `-SkipInstall`, and on a machine without Node the setup would run the real winget and then reload PATH from the registry, dropping the test's stubs | Confirmed on reading `Install-With-Winget`; not reached here, where Node is installed | `node`, `winget` and `npm` are stubbed; winget and npm only record a call and fail, and a call fails the test |
| 2 | After the command ended on TERM, the watchdog still sent KILL to its PID 5 s later, which may belong to another process by then | Confirmed | The watchdog stops as soon as the command is reaped, and signals go through the group, whose ID cannot be reused while a member lives |
| 3 | A command that exited on its own before the limit could leave a child holding the captured output past it | Confirmed | Once the command has exited, anything left in its group is ended; tested with `sleep 30 & echo done`, which now returns `done` and exit 0 within about 1 s |
| 4 | A curly apostrophe (`’`) in a share path broke the email's command, since PowerShell reads it as a quote | Confirmed | `EscapeSingleQuotedStringContent`, as PowerShell itself escapes |
| 5 | A relative share path was resolved inside `claude-setup` | Confirmed | `Convert-Path` where the developer runs the command, before it changes folder |
| 6 | A record in another encoding was read with its characters replaced | Confirmed | A strict UTF-8 decoder: such a record is reported as unreadable |

A harness defect also surfaced: Windows PowerShell 5.1 drops the double quotes inside a native
argument, so a `bash -c` script lost the quotes of its JSON and its `trap "" TERM`. The tests now
pass bash scripts as files.

Tests: `tests/Test-WorkstationClients.ps1`, 178 assertions on PowerShell 7 and 5.1, about 200 s.
It runs the macOS/Linux setup and diagnostics against a scratch HOME with the clients stubbed, and
the onboarding email's own command, which fetches the setup files and runs the Windows setup,
against a local listener standing in for the gateway and the distribution site. Every new detector
was broken on a copy and seen to fail with the full assertion count: 3 in the model rules, 1 at
the 2.7032.0 boundary, 8 in the bash setup, 3 in install selection, 5 in the diagnostics and rule
copies, and 11, 8 and 5 for the three reviews' fixes, four of them on Windows PowerShell 5.1
because only that host shows them.

Council: Architect PASS (the model rules and the bounded client command live in one PowerShell
module and one bash library, compared case by case; the Desktop key spelling follows the release
that reads it; the gateway, its policy and its components are unchanged, so no architecture
picture changed, and only the manifest's source hash for the Windows setup moved). Coder PASS (the
setups, the MDM generator and both diagnostics share those modules; the 21 defects the three
reviews found are fixed, each with a test). QA PASS, with gaps named (178 assertions on PowerShell
7 and 5.1, both setups run end to end against a local stand-in, 44 mutations caught, Claude Code
2.1.101 proven through the reference gateway; not run: a real macOS or Linux machine, bash 3.2, a
real Desktop Entra sign-in, an Intune deployment). UX PASS, with a reservation (every client
command waits a stated time and says what it waits for; the setup ends with a real Claude Code
reply; diagnostics name the running Desktop build and the fix; the guided flow's own delays and
choices are P68). Security PASS (no secret in source or logs; the tests use stubs and a local
listener, and their fake token is built at run time; the published unknowns drop tenant and
principal ids; client commands take fixed words only).

## P66 guided flow, 2026-09-27

Asked by the owner: one product-like flow for setup, updating older setups, tier upgrades,
moving named values to the Cosmos store, configuring AUM or Turnstile, deploying the workbook
collection, generating reports and a how-to guide, plus debug scripts for the administrator
deployment and the developer machine. Design: [ADR-0030](adr/0030-guided-flow.md). Entry point:
`Start-ClaudeGateway.ps1` ([GUIDED-FLOW.md](GUIDED-FLOW.md),
[UPDATE-AND-CHANGE.md](UPDATE-AND-CHANGE.md), [DIAGNOSE.md](DIAGNOSE.md)).

- [x] One entry point with Setup, Update, Change, Diagnose, Guide and Status; step modules under
      `scripts/flow/` share the ADR-0030 contract (merged `ae39184`)
- [x] Every apply is planned, priced where a retail price exists, fingerprinted and resumable,
      and the fingerprint binds the target estate (`98b74d6`)
- [x] Update of a gateway built by an older release; tier change in place; named values to the
      projection; network edge review; Desktop sign-in change (merged `8a1615a`)
- [x] Read-only diagnostics for the administrator deployment and the developer workstation, with
      redacted support bundles (merged `c210462`)
- [x] FinOps tool, token and dollar budgets with a scheduled reconciler, workbooks and reports as
      flow steps (merged from `flow-finops` at `9e5237c`)
- [x] `node .ironclad/gate.mjs --stage packet` on the integration merge: `4ffa97b`, 2026-09-27
      01:59-02:13Z, 22 passed, 2 warned (file size, open unknowns), 0 failed; Test-All 856.8 s

| Live proof | Result |
|---|---|
| Orchestrator, 2026-09-26 | Isolated Basic v2 `rg-p66-guided-flow-09262008`: PlanOnly, Setup, resume, Status, a second Setup that replans, a Change plan, a request returning 200; torn down. That 200 came through the tenant's default `claude-code-*` groups (defect 5 below) |
| Lifecycle, 2026-09-26 | A gateway from the `280a16e` installer updated, then 200; Basic v2 to Standard v2 and back in place (Standard window about 68 s); projection deployed, compared clean, flipped, then 200; torn down; under $0.60 |
| Diagnostics, 2026-09-26 | Read-only against the reference gateway: request 200; one stale premium entitlement; organisation ceiling 100M below unit budgets of 6.94B; 13 bypass principals plus 4 partial |
| FinOps, 2026-09-27 | `rg-p66-finops-p66finops09270431`, Basic v2: HTTP 200; AUM Direct `aum whoami` (owner, azure-rbac); saved functions and both workbooks deployed; the scheduled reconciler job (template, pinned image and commit, every 5 minutes) wrote `usd-budget-state` status `stop` at $0.0157 against a $0.00005 budget and the next request returned 403 `usd_budget_exceeded`; after raising the budget to $1 the next scheduled run wrote `allow` and the next request returned 200; one chargeback report generated; torn down; about $3.05 list across five attempts |
| Integrated run, 2026-09-27 00:24Z onward | `rg-p66i09270024`, eastus2. Review priced Basic v2 at $150.00/month from the Azure Retail Prices API; Setup took 12 minutes. Entitled through the gateway's own group: HTTP 200, tier standard, 20 tokens. Health: 7 of 8 pass; the bypass check fails on the shared Foundry account. Status: no drift. Update: all three migrations report no change. Diagnose: administrator and workstation checks with two support bundles |

Defects the integrated run found, each fixed with a test seen failing first:

| # | Defect | Fix |
|---|---|---|
| 1 | The Setup fingerprint did not bind the target: two setups a day apart against different resource groups printed the same fingerprint | `98b74d6` |
| 2 | Module helper functions were undefined when the plan ran (dot-sourced inside a function) | `98b74d6` |
| 3 | Setup called present Change-only modules absent | `98b74d6` |
| 4 | `-Action Update` could only plan | `b2023f9` |
| 5 | Sync and the entitlement comparison used the default tier groups on a gateway installed with other group names (health: "drift: missing=7") | `070b11b` |
| 6 | The health check stopped at the bypass check when Foundry is in another resource group, and Verify passed with the health check failing | `070b11b` |
| 7 | `-Action Diagnose -SupportBundle` wrote `True.zip` | `070b11b` |
| 8 | Update planned a false change on every current gateway (`az apim nv list` shape) | `f50ee43` |
| 9 | Diagnose gave the health check 90 s; it measured 182-201 s | `3c08504` |

Council: Architect PASS (the orchestrator now keeps module helpers in one session, as ADR-0030
states). Coder PASS (reuses the lifecycle price helper and `Get-ClaudeGatewayTarget.ps1`). QA PASS
(every fix above has a test that failed first; PS 7 and 5.1). UX PASS (the review names the estate
and its price; Setup names the Change command for each module; Update names its apply command).
Security PASS (recorded tier groups apply only to the gateway they were recorded for; support
bundles are git-ignored; nothing secret is written).

Open: the gateway's 403 message still names `claude-code-standard` and `claude-code-premium` on a
gateway installed with other group names (`infra/policy.xml`); the FinOps modules have not yet run
in the same session as the other steps on one estate; the reference gateway's diagnostics
findings above; the tenant-blocked items in [UNKNOWNS](UNKNOWNS.md).

## P46 acceptance criteria — managers scoped, and budget modes

- [x] A manager-only token reaches an allow-list of 13 read routes and the budget writes; every other protected route is refused by default, asserted on each protected router
- [x] Scope comes from the manager groups in the person's token, resolved against the catalog on each request; a unit manager's scope includes its teams and direct members; missing or overage groups grant nothing
- [x] Usage, budgets, people, the catalog and a request's detail are filtered to the scope; a filter or id outside it is refused
- [x] A unit manager sets its teams' budgets and any manager sets person budgets in scope; the unit budget, catalog, tiers, modes and **Apply now** stay the owner's; Turnstile still refuses a child above its parent
- [x] An owner records a unit's or team's manager group and budget mode on the Gateway governance page (`manager_group_id`, `enforcement`, `allowance_percent`)
- [x] The gateway enforces strict, allowance and notify per unit and team: `bu-modes` holds only the exceptions (missing means strict); allowance admits up to its percentage above the budget; notify skips only that scope's limiter, and the parent, organization and tier limits still apply. Invalid mode metadata stops the whole apply before any write
- [x] An apply run rechecks Turnstile's catalog, per-budget and tier revisions immediately before writing, reconciles again from newer state up to three times, then defers with no writes and no membership refresh. This narrows the out-of-order race; P48's single writer closes it
- [x] A live sign-in with a manager-only account: done 2026-09-25 01:21-01:26Z in P53. With the account's admin group membership and its direct `Turnstile.Admin` assignment both removed, a fresh token carried exactly `Turnstile.Manager` and the manager group; Turnstile answered `member`, scoped to one unit and its three departments, refused three admin routes with 403, and the replayed code with 401. Everything was restored admin-group first and verified against the snapshot
- [x] `node .ironclad/gate.mjs --stage packet` exits 0 on the merge: `690015d`, 2026-09-24 17:16-17:46Z, Test-All 1,797.2 s of the 1,800 s budget then in force (see "The suite's time budget" below)

| Measured | Result |
|---|---|
| Fork checks at `c0c345a` | 770 platform tests passed, 5 skipped, the six known environmental failures only; 203 manager-scope tests; 17 page-rule tests |
| The built console against test-signed manager tokens, in a browser | 30 API requests, none outside the allow-list; forbidden pages redirected; team-only budgets shown as roots |
| Turnstile redeploy | 9 min 22 s; the owner's live sign-in afterwards: `owner`, `entra`, no scope |
| Two manager attributes added to the live catalog, then restored | The restore read back identical, write-payload hash unchanged; every budget unchanged |
| Modes on the reference gateway, 2026-09-24 14:26-14:28Z | Strict at a budget of 1 refused with 403 naming the team. Allowance 10%: served at an estimated 104.0% of the budget with an `estimated-over-budget` notice, refused once usage exceeded the 110% effective quota. Notify at a budget of 1: three requests served with `usage-reported`, and their 48 tokens joined the ledger through `BudgetRequestId`. The original registry and `bu-modes` (`,,`) restored exactly; a policy-only deploy left every named value byte-identical |
| Modes tests | 206 governance and 146 team assertions; 108 of 108 Turnstile mutations caught; the policy's own expression bodies compiled and executed for 1, 10 and 100%, zero, rounding and the Int64 limit |
| The guard against live data, 15:35Z | Real catalog, budget and tier reads through the guard against a gateway held in memory: verified before writing, 0 newer snapshots, 0 writes |
| Rolled out live, 17:51-18:02Z | Main's merged policy (`690015d`) deployed to the reference gateway: all 28 named values byte-identical before and after, and a request through the gateway returned 200 with every budget header. Both Turnstile jobs repinned to `690015d`; their first run succeeded. The only named value that run changed was `turnstile-integration`'s `connectedAt`, re-stamped by the connect step; tiers match Turnstile (`tpm-standard` 20,000, `tpm-premium` 80,000) |
| A mode set in Turnstile's UI, 21:12-21:20Z | Notify on one team: `bu-modes` read `,<team>=notify,` on the gateway 113.4 s after the save (apply job succeeded at 151.8 s). Strict: exactly `,,` after 113.2 s. The originally unset attribute was restored too; the catalog and every non-secret named value then equalled the snapshot (P53) |

The notices are advisory. `llm-token-limit`'s remaining quota is an estimate, so an allowance
notice cannot promise the exact request that crosses the budget, and notify has no monthly counter
to report against: it says `usage-reported` before and after 100%, and the ledger is the source
for the total. Switching a scope from notify back to strict does not backfill its usage into the
limiter. Found by testing: the budget trace first went out before the identity trace and shared
its join key, which broke the ledger's first-trace contract; it now follows identity and joins on
`BudgetRequestId`.

**Found by running it.** Two catalog saves one second apart started two apply runs that
finished out of order, 13:36:15Z and 13:36:05Z, so the earlier save's run wrote last. Harmless
this time, because manager attributes do not reach the gateway, but budget modes will: a guard
against stale runs is being added with the modes, and a single queue-driven writer (P48) is the
full fix. Routes that FastAPI composes into an aggregate router needed the manager check on
their own routers, not only on the aggregate.

## Final integration, 2026-09-26

Main at `c25d246` holds every packet started for the owner on 2026-09-25 and 2026-09-26. Its
integration gate passed with 67 of 67 checks on the second run (13:26-13:40Z). The first run
(13:06-13:20Z) failed in one check only, "AUM - commands, dashboard and pilot"; the same tree then
passed directly (320 tests) and in three concurrent runs. That intermittent failure has now appeared
three times under the full suite and its test is not identified; the PS 5.1 wizard check shows the
same pattern (**U26**). A live request through the
reference gateway returned 200 with the tier and budget headers at 12:59Z; the reference gateway was
not changed. Every isolated test estate built today was removed, and the three soft-deleted test API
Management instances left from 2026-09-25 and 2026-09-26 were purged.

## P62 dollar budgets in AUM, merged 2026-09-26

Asked by the owner: "One more thing to be ensured to be managed in the AUM is setting budget in dollar
value which considers exact token cost budget and cache cost with enforcement applied at gateway."
P59 had built the gateway side and the AUM service routes but no terminal client. `aum usd
list|set|clear|status|reconcile` and `aum usd price-book show|set` now manage dollar budgets with
decimal strings (zero is a real stop), preview first, typed confirmation for a clear, and **Saved;
awaiting reconciliation** after a write; the Budgets tab shows each scope's dollar budget, priced
spend with its completeness flags (`exact`, cache known, unpriced models), status and reconciled
time. The Direct backend reuses P59's writer, reconciler and authority guard; the AUM service backend
follows its capability flags and `If-Match`; with Turnstile as the authority, dollar writes are
hidden and refused rather than falling back to token writes. [AUM.md](AUM.md), [BUDGETS.md](BUDGETS.md),
[ADR-0018](adr/0018-terminal-finops.md), [client contract](aum-usd-budgets-client-contract.md).

Measured live on 2026-09-26 on an isolated Basic v2 gateway, through AUM's Direct backend: a $0.00005
unit budget set with `aum usd set`; a warm-up, a cache-creating prompt (5,724 five-minute cache-write
tokens), a cache-reading prompt (5,724 cache-read tokens) and a tiny request, all 200; `aum usd
reconcile` then `aum usd status` showed $0.000068 spent and status `stop` (the first snapshot had
priced the rows ingested by then; the cache rows arrived later, and the client showed the flags rather
than inventing their cost); the next request returned 403 `usd_budget_exceeded` 73.8 s after the
crossing request; raised to $0.001 with AUM and reconciled, the next request returned 200. Torn down;
the final run cost about $0.32 and all attempts under $3. Live runs found three bridge defects, each
fixed with a test. The dollar Budgets pictures are kept as their own live evidence
(`direct-usd-budgets-*`), and the banner's Budgets pictures stay unchanged. Branch gate PASS, 67 of 67.
Open: exact streaming cache-creation detail (**U13**), and a live AUM-service deployment of the
dollar routes.

## P61 the Cosmos entitlement store on every v2 tier, merged 2026-09-26

Asked by the owner: "Even for Basic APIM Tier admin can choose to go with comos backend for scale
between 100-500." Named values hold about 93 developers in `bu-members` and about 110 per tier list
([SCALE.md](SCALE.md)). The installer now asks for `named-value` or `projection`, states that
ceiling against the operator's developer count, and chooses the resolver's inbound path by SKU:
private on Standard v2 and Premium v2; on Basic v2, which has no outbound VNet integration
([v2 tiers](https://learn.microsoft.com/azure/api-management/v2-service-tiers-overview)), a public
resolver that requires Microsoft Entra authentication pinned to the gateway's managed identity
([App Service authentication](https://learn.microsoft.com/azure/app-service/overview-authentication-authorization)),
with Cosmos private behind the resolver's VNet integration. `Deploy-ClaudeProjection.ps1` deploys,
populates from Entra, compares against the named-value decisions and flips `entitlement-source`
only after a clean comparison. APIM v2 outbound addresses are not used as the security boundary.
[ADR-0028](adr/0028-basic-v2-projection-resolver.md), [SECURE-PROJECTION.md](SECURE-PROJECTION.md).

Measured live on 2026-09-26 on an isolated Basic v2 gateway: an unauthenticated call to the public
resolver returned 401 and a wrong-identity token was refused; after a clean comparison the flip
happened and a real count-tokens request returned 200 (first request 9.9 s, then about 0.8 s warm);
500 synthetic records were written from inside the VNet and counted. Live runs found and fixed two
deployer defects (resolver parameters passed as GUIDs, then inline JSON mangled by Azure CLI; now a
parameter file). Torn down; about $0.40. The five portal pictures were captured live on 2026-09-26
from a short-lived capture estate ([SECURE-PROJECTION.md](SECURE-PROJECTION.md)): the Basic v2
gateway, the resolver's App Service authentication (401 for unauthenticated requests) and public
inbound with VNet-integrated outbound, Cosmos with public access disabled, and `entitlement-source`
set to `projection`. The first two capture estates were removed before the batch finished (the
ready file's times carried no zone and were read as local time), and two early pictures were
rejected on review; the third estate was captured and then removed.
The lead's merge found the branch's CHANGELOG entry pasted after every "### Added"
heading in the file; it was repaired and `Test-ReleaseLog.ps1` now refuses repeated or run-together
entries. Branch gate PASS, 67 of 67. Open: a live add-then-remove through a projection-backed gateway
(**U25**), bursts of different identities and coalescing across instances (**U18**).

## P64 add and remove developers from AUM by email, merged 2026-09-26

Asked by the owner: "Is add and remove developer available with AUM and turnstile, with
discovering developers in the org by just typing email id". It was not: only
`Set-ClaudeDeveloper.ps1` took an email. `aum developer find` now searches the whole Entra directory
while an administrator types an email, UPN or name, guests included, using the administrator's own
delegated Graph token from Azure CLI; `aum developer add` and `remove` resolve exactly one account
with the script's rules, preview the tier and unit/team group changes, write each membership once
and verify it, and publish to the gateway (Direct: the selected-scope refresh and the tier
allow-list sync; Turnstile authority: the delegated publish path). The People screen has the same
flow. Permission is Graph's decision: a 403 names the rights needed (group owner, or a role such as
Groups Administrator, [add member](https://learn.microsoft.com/graph/api/group-post-members)). An
already-issued Entra token stays valid until it expires; the allow-list refresh refuses new requests.
`Set-ClaudeDeveloper.ps1` now reads the tier group names the installer recorded. Turnstile does not
change Entra membership (**U17**, **U19**). [ADR-0029](adr/0029-aum-developer-membership.md),
[AUM.md](AUM.md).

Measured live on 2026-09-26 on an isolated Basic v2 gateway with test-only tier groups: a request
returned 200 after `aum developer add` and 403 after `aum developer remove`; groups, gateway and the
temporary role were removed, about $0.06. The lead's review blocked the first delivery, because every
removal published with `-AllowEmpty` and so switched off the empty-list guard for both tiers; the fix
allows an empty list only for a tier a successful pre-check proves the removal empties, with four new
tests. The branch had also committed a half-resolved conflict marker into the changelog, which the
gate did not notice; `Test-ReleaseLog.ps1` now refuses conflict markers in any tracked text file.
Open: **U24** (full-email `$search`), **U25** (publication on a projection-backed gateway).

## P60 Claude Desktop sign-in chosen by the admin, merged 2026-09-26

The installer asks how Claude Desktop signs in and records it as `desktopSignIn` in
`claude-gateway.json`: `helper-script`, the default and the previous behaviour (Desktop runs the
Azure CLI credential helper), or Desktop's own sign-in through an Entra public-client app,
`external-idp-browser` or `external-idp-broker`. One validator and renderer
(`scripts/ClaudeDesktopSignIn.ps1`) feeds both workstation setup scripts and `New-ClaudeCodePolicy.ps1`,
so a developer machine and an MDM payload write the same keys ([Anthropic configuration
reference](https://claude.com/docs/third-party/claude-desktop/configuration)). With an `id_token` the
audience is the Desktop app's client id, so the gateway accepts it only when the
`external-idp-extra-audience` named value is set; empty keeps the previous two audiences, and the
tenant stays pinned. `New-ClaudeDesktopEntraApp.ps1` creates or finds the public-client registration
with the browser or broker redirect URIs and grants no consent.
[ADR-0027](adr/0027-claude-desktop-sign-in-choice.md), [DEVELOPER.md](../DEVELOPER.md).

Measured live on 2026-09-26 on an isolated Basic v2 gateway: an Azure CLI token returned 200 (tier
`standard`), an ARM token 401; a token for the proof Desktop app stopped at `AADSTS65001
consent_required`, because this tenant grants no consent, so Desktop's own sign-in is not proven end
to end here (**U23**). Proof gateway, app registration and role removed; under $0.07. Branch gate PASS,
67 of 67. The app-registration portal pictures wait for a registration and the owner's Entra step-up.

## P65 fleet deployment with Intune, Jamf or Group Policy, merged 2026-09-26

Asked by the owner: "Also create a intune or similar MDM guidance". [MDM.md](MDM.md) lists what
each device needs and why, how to generate per-tier profiles with `New-ClaudeCodePolicy.ps1`, Intune
on Windows (custom OMA-URI and what it needs, platform scripts and remediations with their script
settings, Win32 and Store apps, user or device group assignment, monitoring, removal) and on macOS
(`.mobileconfig`, PKG/DMG), Jamf Pro and Group Policy, device verification and troubleshooting, each
step with a Microsoft Learn or Anthropic reference. It cross-links
[Migration section 2](MIGRATION.md#2-mass-deployment-through-mdm) rather than repeating it.

Tested: the generated standard profile, from read-only discovery of the reference gateway, drove one
real `claude -p` request through the gateway from an empty configuration directory (result `P65-OK`,
provider `foundry`). The pilot at `HKCU\SOFTWARE\Policies\ClaudeCode` was refused by this
workstation's ACL; nothing was written. The lead's review found that the guide's detection script
used `SHA256.HashData`, which Windows PowerShell 5.1 lacks, so Intune would always report drift; it
now uses `ComputeHash`, and `Test-DocReferences.ps1` runs that block under `powershell.exe`. Intune
admin center pictures are not captured: the owner holds no Intune role here; the guide lists them.

## P59 dollar budgets at the gateway, merged 2026-09-26

A budget can now be set in dollars and enforced from priced categories instead of one blended
token figure. Definitions are decimal strings with a pinned price-book date, stored in two named
values (`usd-budgets`, `usd-budget-state`) beside the token guards. A reconciler prices each
scope's observed input, output, cache-read, 5-minute and 1-hour cache-write tokens with Decimal,
refuses unpriced models rather than counting them as $0, and publishes expiring scoped stops:
strict stops at the amount, allowance above its percentage, notify never blocks and adds
`x-claude-usd-budget-notice`. The gateway's refusal is a distinct 403 `usd_budget_exceeded`
naming the scope, amounts, observed spend and reconciliation time; enforced state older than 15
minutes gives 503 `usd_budget_state_stale`. It runs on demand (`Sync-ClaudeUsdBudgets.ps1`) or
on the AUM service's five-minute timer, and the AUM service has the dollar routes
([client contract](aum-usd-budgets-client-contract.md)). [ADR-0026](adr/0026-usd-budget-reconciliation.md),
[BUDGETS.md](BUDGETS.md).

**Measured live on 2026-09-25** on an isolated Basic v2 gateway: a $0.02 unit budget; 65 input,
264 output, 12,492 cache-read and 12,492 five-minute cache-write tokens priced at $0.0364984;
the next request returned 403 `usd_budget_exceeded` 175.9 s after the crossing request
completed (146.3 s of it waiting for the categories to arrive in the logs); raised to $0.50 and
reconciled, the next request returned 200. The estate was removed, its gateway purged and its
role grants deleted.

What it is not: a hard invoice cap. Enforcement trails usage by log ingestion (Azure documents
resource logs as usually available within 3 to 10 minutes, [data ingestion time](https://learn.microsoft.com/azure/azure-monitor/logs/data-ingestion-time))
plus the reconcile interval, and streaming responses do not expose cache-creation detail without
buffering the stream (**U13**, narrowed). Dollar writes go through the shared authority guard
(`-Write UsdBudgets`), so they refuse while Turnstile owns budgets or governance. The AUM terminal
client cannot manage dollar budgets yet: P62. Branch `usd-budgets` at `a046aae`, its own gate
PASS with 66 of 66 checks and no skips, merged as `254b27d`; the in-flight merge the previous agent
left was finished with 512 of 512 business-unit mutations caught.

## P52 AUM (Azure Usage Management), merged 2026-09-26

`claude-finops` is now `aum`; the old command still starts it. One engine behind a terminal
dashboard and scriptable commands, backed by Turnstile, the gateway directly, the AUM service or
example data, so it does not depend on Turnstile. Guide: [AUM.md](AUM.md); the earlier guide
stays at [CLI-FINOPS.md](CLI-FINOPS.md); decisions in [ADR-0018](adr/0018-terminal-finops.md).

It adds an executive overview, budgets by unit, team and person, gateway governance (groups,
tiers, modes), usage breakdown and trends, a request trace, anomalies, reports through P50's
generator, and settings. Entra groups can be found, created, given members and deleted, each
previewed first; `governance refresh-membership` rebuilds `bu-members` with the repository's
serializer; `requests probe` and a bounded usage-only `usage refresh` are preview-first. Clients
for approvals, boosts, notifications, conditional catalog and tier writes, anomaly dispositions,
request paging past 200 and global search are built and stay hidden until a server advertises
them in `/api/v1/finops/capabilities`.

**Measured live on 2026-09-25**, with the owner's existing rights, through Direct and through
Turnstile: two test Entra groups created, the owner added, a unit and a team registered,
budgets and the strict, allowance and notify modes set, and three tiny real Claude requests per
mode. Strict refused with 403 naming the team; allowance (10%) and notify served 200 with
`x-claude-budget-notice`. From save to the confirming response, as upper bounds including the
probe: Direct 8.0-26.5 s, Turnstile 130.6-157.1 s (its apply job). The attributed requests
appeared in Direct within 321 s, and in Turnstile after a bounded usage-only export. Then
everything was restored: 13 named values byte-identical to the originals, the 14 direct
memberships equal, both groups deleted, no test catalog entries, rechecked after the gate.

Tests: 297 Python tests pass, and the existing 108 mode and freshness mutations are all caught;
150 live, redacted terminal captures and 10 portal pictures, each with a manifest record.

Not done, and why: a mutation journey through the AUM service (P55's deployment was removed
after its own live journeys: `ResourceGroupNotFound`); exact limiter-counter continuity across a
mode change (the parent's remaining count read 99,968 in every mode, so it is not claimed); and
full-directory scale (**U20**). Council, from the branch: Architect, Coder, UX and Security PASS;
QA blocked on the README's missing `docs/AUM.md` link and the service journey. The branch's last
gate (`de793ae`: 57 PASS, 5 FAIL, 1 SKIP) failed only on that link, in Test-Scale and the four
mutation shards that refuse its red baseline. The integration adds the link (the README is the
lead's) and gives the worktree the service venv the SKIP lacked.

## The scripts refuse what Turnstile would overwrite, merged 2026-09-25

The FinOps guide's open gap: while Turnstile owned governance, `Set-ClaudeBusinessUnit.ps1` and
`Set-ClaudeTier.ps1` wrote named values that Turnstile's next apply replaced. They now refuse,
before any write, exactly what the apply owns, name the Turnstile page to use instead, and show
the explicit switch (`Connect-ClaudeTurnstile.ps1 -GovernanceAuthority Gateway -BudgetAuthority
Gateway`); there is no force option. Read from the apply's code: full governance owns the unit
registry, parents and modes and both tiers' limits and models; budget-only authority owns the
monthly amounts of existing units and teams. Neither owns personal daily overrides
(`Set-ClaudeBudget.ps1`) or Entra membership (`Set-ClaudeDeveloper.ps1`), so those stay
available; `personBudgets` is an outbound monthly mirror, not an inbound owner. A failed read of
the integration value stops the write; an absent or disconnected one leaves the gateway in
charge. 114 assertions on PowerShell 7 and 5.1, five mutations caught, and both guarded scripts
refused live against the Turnstile-governed reference gateway with zero write attempts. Branch
`authority-guard` at `a002617` (its own gate PASS, 62 checks), merged into main. Not closed by it:
P48's single writer and races around an authority switch.

## Portal pictures recaptured live, and the test environments removed, 2026-09-25

Asked by the owner: every portal picture live, from his own sign-in, not from another
repository. One batch runner, one original profile, 75 steps across the gateway, Foundry,
the telemetry workspace, the projection and resolver, the report resources, Turnstile and
AUM's Entra registrations. Each capture is recorded in `docs/guide/portal-captures.json`
with its route, time, redaction result and the SHA-256 of the published pixels; the tests
fail if a published image differs from its record. The documents that said "pending batch
capture" now show the pictures.

Found by doing it, and fixed test-first:

- **A mapped suffix inside a longer name escaped redaction.** Pairs matched only at word
  boundaries, so a report storage account named from a deployment suffix appeared on the
  admin job's environment-variable blade, and the leak check, using the same rule, passed it.
  Distinctive values now match anywhere.
- **Colleagues' names on a group's Members blade.** People are not in any private map. The
  discovery now reads the page's own members or assigned principals, shows each as
  `Contoso user N`, hides initials, and refuses to capture a people page without them.
- **Eighteen steps failed on blades that had rendered**, because the runner took the first DOM
  match for a label and the portal keeps hidden copies. Visible-first matching, locator names
  in timeouts, and spec fixes from replaying each failure (see the CHANGELOG).

Neither leak reached a commit: both were in uncommitted batch output, found on review, and
every resource image was recaptured afterwards (63 steps, 13:51-14:14Z). Entra blades asked for
step-up approval every few pages, so the resource and Entra steps now run as separate batches.
Six of the twelve Entra pictures were taken under the new rules: three at 14:24Z, and AUM's
Expose an API, Manifest and Properties at 18:05Z from committed capture code (`310c6f8`). Four
Turnstile registration pictures were taken at 13:24-13:26Z under the earlier rules and are kept
after a review of each
(identifiers zeroed, no person shown); Turnstile's assignments page is its older committed
version. AUM's Users and groups picture showed the owner's initials beside his pseudonym and was
dropped. **2026-09-26, 16:50Z:** with the owner's sign-in, AUM's Users and groups (the owner shown
as Contoso Admin, initials hidden) and Turnstile's app Overview and Expose an API were recaptured
from committed code (`c6517f0`). **17:37Z:** the capture profile was refreshed from the owner's Edge
Work profile after he opened the remaining blades there, and Turnstile's App roles, enterprise
Properties and Users and groups were recaptured from `7e73bc0` without a further sign-in prompt. All
twelve Entra pictures are now taken under the current redaction rules; nine come from committed
capture code, and three (14:24Z on 2026-09-25) from capture code that was committed unchanged in
`1da331b` and are marked `accel_dirty`.

Still pending, and why: 7 AUM Function and storage pictures target a service deployment that was
removed after its live journeys; the documents keep them as inline pending paths. The 24 P54
edge pictures were captured later the same day from a short-lived isolated copy of the
evaluation estate (Standard v2 gateway, WAF_v2 edge, private Foundry and vault; list price about
$1.55 an hour), with the private vault's Certificates list reached through a loopback PAC route
into the network (`PORTAL_PROXY_PAC_URL`). Eleven steps first failed or captured the wrong page:
deep links that no longer render, and click waits that matched the landing page (a non-exact
`Port` matches **Report a bug**); each was fixed in the spec and every picture reviewed. The
vault's Role assignments tab was deliberately not captured, because it lists inherited
assignments that name other people. The estate was removed after the batch: its resource group
read 404 at 18:19Z, and its gateway, Foundry account and vault were purged, with every recorded
resource reading 404 by 18:26Z. Building it found one bug, fixed test-first in `ae267ea`: the
first reviewed edge deployment refused a VNet that did not exist yet ([CHANGELOG](../CHANGELOG.md)).

**Test environments removed.** The SKU tests (the Basic v2 test gateway, and the second test
resource group with its Foundry account, deleted and purged at 10:06-10:19Z). The Premium v2
environment's resource group (the Premium v2 gateway, the projection's Cosmos account, the
resolver, their private endpoints and DNS zones), after its pictures were recaptured: gone at
16:10Z, its gateway and Foundry account purged, all three ARM reads 404 at 16:17Z. Found by doing
it: five group deletes rolled back on the resolver's Flex Consumption plan, which ARM listed and
the Web provider called NotFound; re-creating it under the same name and deleting it cleared it
([Troubleshooting](TROUBLESHOOTING.md#deployment)). The Standard v2 SKU-test gateway,
about $700 a month, is kept: Turnstile's model-gateway integration points at it (its
`APIM_SERVICE_NAME` setting, and roles on Turnstile's Event Hubs and ledger table), and
deleting it would break those features. It is the owner's decision.

**Review of the recapture, fixed in `fbc0307`** (gate PASS, 63 checks, on the second run: the first
failed Terminal FinOps once under six agents' concurrent load and it passed unchanged on the
rerun). A code review found four gaps, each fixed test-first: a tenant-name pair could put a
colleague's address on the placeholder domain; a real value running past a replacement was
hidden; an application's assignments were read from Graph's first page only; and the records
named a commit that did not contain the code that took them. The runner now refuses to capture
from uncommitted capture code, and today's records are marked `accel_dirty` with a provenance note.

**Next, started 2026-09-25 on the owner's request.** P60: the admin chooses how Claude Desktop
signs in (today it always uses the Azure CLI credential helper) and the developer scripts write the
matching Desktop configuration. P61: the Cosmos entitlement store as an installer choice, including
on Basic v2 through an Entra-authenticated public resolver, for 100-500 developers, which named
values cannot hold (about 93).

## FinOps tools in one guide, 2026-09-25

Asked by the owner, who had no single place that compared the FinOps tools, how each person signs
in, the end-to-end flow for each, and what each costs. [FINOPS-TOOLS.md](FINOPS-TOOLS.md) puts them
side by side:

- saved queries and workbooks, the scripts, Terminal FinOps (Direct and Turnstile), the AUM
  service, Turnstile, chargeback reports and Grafana;
- a matrix of who signs in to what, and eight sign-in methods: Azure CLI interactive and device
  code, consent-free API tokens, Turnstile's web sign-in and one-use code, break-glass, managed
  identities, developers;
- six end-to-end flows with their commands;
- a bill of materials from live list prices on 2026-09-25.

Measured for it, read-only:

| Measured | Result |
|---|---|
| Gateway | Basic v2, $150.00/month |
| Connected Turnstile, Central US | $158.84/month at rest, $0.52 of usage in 30 days |
| Turnstile shapes, East US 2 | $55.47/month lean, $150.54/month dedicated and private |
| Terminal FinOps in Direct mode | Month status came back with role `owner` through `azure-rbac` |
| Month's estimated cost | Unknown: 10 usage rows had no price. `ClaudeCost` priced 534 `claude-sonnet-5` requests at $1.59 |

**Found while writing it.** `Set-ClaudeBusinessUnit.ps1`, `Set-ClaudeBudget.ps1` and
`Set-ClaudeTier.ps1` do not check which tool owns governance. Terminal Direct mode and the AUM
service do, and refuse. While Turnstile owns a gateway, a script edit lasts only until the apply
job's next run. The guide says so. The scripts should refuse the same way; that is queued behind
the script-choices sweep, which edits the same files.

## Scripts ask for what they were not given, 2026-09-25

Asked by the owner after `Publish-ClaudeWorkbook.ps1` stopped with "3 workspaces in
rg-...: Pass -WorkspaceName" and gave no way to tell which. `scripts/ClaudeChoice.ps1` is the
shared answer: a value a script was not given is offered from what Azure actually holds,
numbered, with where each option comes from, where to look it up (command and portal path),
and the one the deployment points at marked recommended; Enter takes it. Without a console
(a pipeline, a scheduled job, the test suite, `pwsh -NonInteractive`, `CLAUDE_NONINTERACTIVE=1`)
a certain recommendation is used and its source printed, and anything else stops, naming the
candidates. A value the installer recorded counts as given and is not asked for.

Applied to the monitoring flow: `Publish-ClaudeQueries.ps1`, `Publish-ClaudeWorkbook.ps1` and
`Publish-ClaudeGrafana.ps1` (resource group, gateway, workspace, Grafana instance), and
`Get-ClaudeTelemetry.ps1`, which no longer takes the first API Management instance in a group
and now prints the linked `Workspace`. On the reference gateway the workbook publisher chose the
workspace behind the gateway's Application Insights out of three in its group, and published the
owner's "Claude gateway - platform" workbook. `tests/Test-ClaudeChoice.ps1`:
34 assertions on PowerShell 7 and 5.1, and four mutations in the business-unit harness. Nothing architectural changed.

**Sweep, merged 2026-09-25 from `script-choices` at `c62b4b4`** (gate PASS, 928 s, 63 checks passed,
none skipped). The same chooser now covers administration, Turnstile, reporting, model probes and
workstation migration, about 24 more scripts. New selectors pick the Foundry account (the gateway's
backend recommended), the Turnstile resource group and identities, report resources, models,
Application Insights and local backups (newest first). Restore choices are settled before any
write. The two Turnstile jobs and the three report jobs pass their targets explicitly in their
Bicep command lines, so none of them can reach a prompt; no job was repinned.

Test coverage: 191 chooser assertions and 20 in-process mutations, on PowerShell 7 and 5.1.

Read-only checks against the reference gateway left its named values byte-identical. The bypass
audit reported 13 principals with full data-plane access to the Foundry account, which skips every
control here. That is up from 7 in the earlier audit; they are the tenant's to review, and none
was changed.

One exception is kept on purpose: the Turnstile apply job's exact-name custom-role lookup.

## Premium v2 injection: where the private IP is, 2026-09-25

Asked by the owner, whose own injected Premium v2 gateway showed no private IP, so its URL could
not be reached or given a DNS record. Tested live on a new instance, `virtualNetworkType:
Internal`, in a /24 `Microsoft.Web/hostingEnvironments` subnet in Canada Central (729 s to
create; deleted and purged afterwards, under $4 at list price). The VIP, `10.232.4.4`, is in
ARM `properties.privateIPAddresses` only at api-versions `2024-05-01`, `2023-09-01-preview` and
`2023-05-01-preview`, and in Azure Resource Graph. It is `null` at `2022-08-01`, which
`az apim show` requests, and at every newer preview through `2025-09-01-preview`. While the
instance is `Activating` the property shows a transient `100.96.x.x` address. The injection subnet
shows only an IP configuration of a load balancer in a Microsoft-managed subscription. Azure
publishes no DNS for the gateway name, publicly or in the VNet. A per-host private zone
(`<name>.azure-api.net`, apex A record) linked to a peered VNet made it answer 200 by name; before
that, the same request pinned to the IP answered 200 with a valid certificate. Steps are in
[NETWORK-ENTERPRISE.md](NETWORK-ENTERPRISE.md#find-a-premium-v2-injected-gateways-private-ip).

## P54 the enterprise network, 2026-09-25

Merged from `enterprise-network` at `50dd6d4`, gated on that commit: 816.8 s, 61 checks passed and
one explicit skip (the worktree had no FinOps environment; that check runs on main). The owner's
hub-and-spoke deck was reviewed against Microsoft Learn; the result is a regional design, in
[NETWORK-ENTERPRISE.md](NETWORK-ENTERPRISE.md) and [ADR-0022](adr/0022-enterprise-network-edge.md):
an Application Gateway WAF_v2 as the gateway's only ingress (internal, internet or hybrid
listeners), APIM accepting only the edge subnet, and Foundry, Key Vault and the verifier behind
private endpoints.

Nothing is hardcoded. `scripts/New-ClaudeNetworkEdge.ps1` discovers the regions, networks and
resources an administrator can choose from and shows numbered options, each with its dated
regional list price from the retail price list (or an explicit "unknown", never zero) and its
security, availability, disruption and rollback implications. It then freezes one review with a
fingerprint, valid for 30 minutes, that lists the current, proposed and incremental monthly cost
and the identities that may lose access, and it writes nothing until that exact review is
confirmed. Removal has its own reviewed plan. Front Door, firewall routing and conversions of the
rest of the estate stop the whole plan before any write.

| Measured live, 2026-09-24 and 25 | Result |
|---|---|
| Streaming through the WAF | Complete SSE for six code-heavy cases (SQL, HTML, shell, Python, JSON, JavaScript) in Detection and in Prevention; 8,192 output tokens streamed in 95.6 s |
| Claude Code through the edge | Claude Code 2.1.272 finished a two-turn code review in 51.1 s, with TLS verified end to end |
| Timeouts and size | A 20 s backend timeout returned 504 at 20.6 s; 600 s returned 200 at 47.0 s. Real bodies: Messages 134,434 bytes, count-tokens 226,701 bytes; a 2,150,500-byte body was blocked |
| WAF on code | DRS 2.1 flags code prompts: 71 scoped exclusions (rule and field pairs) allow Prevention mode with the SQL injection probe still blocked. No global allow, no inspection turned off |
| Client address | A forged `X-Forwarded-For` or `X-Claude-Client-IP` did not reach the ledger; the ledger's new `client_ip` column holds the edge's socket peer |
| Paths | Private direct APIM refused with 403; private-only refused internet TLS; public and hybrid paths completed verified TLS and SSE. Azure rejected Private Link on Basic v2 |
| Lifecycle | Rerun, WhatIf, removal, an interrupted cleanup retried and an already-removed no-op, on the evaluation deployment. The later review step was tested offline and with a live WhatIf only |
| Access impact, reference gateway, read-only | 7 days, 12.0 s: 5 Entra identities observed, 0 reliable caller addresses; ETag and network unchanged |
| Cost of the evaluation | Removed 2026-09-24 22:29Z; about $7.31 at list price for 4.7 h. A production shape (20 capacity units, with the APIM Standard v2 unit) is about $1,201.59 a month before the hub and variable meters |

The access report is only as good as the logs. On the reference gateway GatewayLogs is off and the
Application Insights components mask IP addresses, so the report can name the five identities
that used it and ask the administrator to acknowledge them, but it cannot show which of them
already have a private path (**U22**). The `client_ip` column is personal data: review its access
and retention with the rest of the ledger.

Open: the 24 portal pictures in `guide/captures/p54.json` (the evaluation edge no longer exists,
so they need an approved redeployment, never the reference gateway); Front Door, hub peering,
firewall routing, DNS Private Resolver and corporate egress allow-lists as tested automation;
Premium v2 injection and multi-region; and P49, converting Turnstile, PostgreSQL, the projection
and the jobs.

Documentation review after the merge: the guide's deployment examples predated the review step,
so two of them (`New-ClaudeNetworkEdge.ps1 -WhatIf`, and the long parameter form) would have been
refused for lack of `-ReviewPath`. The guide now opens its deployment section with the procedure
in order (discover, price, impact, choose, preview, apply, verify, remove) and says which inputs
are decisions and which are names and IDs.

## P58 architecture generation, 2026-09-25

Merged from `architecture` at `345a302`. Every diagram now comes from a text source under
`docs/architecture/` (ten today: system, request path, governance apply, delegated management,
projection freshness, terminal FinOps, Azure resource inventory, chargeback reports, budget modes
and the AUM service), rendered by one command, `node guide/render-architecture.mjs`, with a
manifest that records each source's hash. `docs/ARCHITECTURE.md` is rewritten around them, and the
request-flow picture no longer claims "no database": it states what each profile adds.

`AGENTS.md` now requires an architecture task in every feature packet: a packet that changes a
component, data flow, identity, schedule or network path updates its source, re-renders, and
updates the article, or records that nothing architectural changed. `tests/Test-Architecture.ps1`
fails on drift: a source edited without re-rendering, an image without a source or a reference, a
label naming a script, route or named value that no longer exists, or an Azure resource type in
`infra/*.bicep` that appears in no diagram. 36 assertions with isolated mutations; 28 s.

Pending: the AUM rename (P52 hands its diagram over) and the portal pictures declared in
`guide/captures/architecture.json`. The enterprise network topologies arrived with P54: three
sources, `11-network-private`, `12-network-public` and `13-network-hybrid`.

## P57 documentation review, 2026-09-24

Merged at `0d0ac7c`, its last green commit. Eight reader journeys were walked with the guides
alone: developer, administrator standing it up and running it, FinOps, delegated manager or viewer,
security, network, capacity planner and on-call operator.

| | |
|---|---|
| **Fixed** | 70 findings across README, DEVELOPER and 22 guides; 23 proposals for files other packets own are in the review's report |
| **New guides** | Operations, Budgets, FinOps, Reference and Data governance, each a task guide with value sources, discovery commands and portal paths |
| **README** | From 710 to 278 lines, with every original rendered anchor and image kept; a documentation map routes each reader |
| **No live names** | Where guides named the reference deployment's resources, they now use placeholders plus the command that discovers the reader's own value (ADR-0003's labels only; its decision text is unchanged) |
| **Guard** | `tests/Test-DocReferences.ps1` checks links, anchors, script names and parameters in 33 guides, with ten mutations; it adds 7.1 s to the suite |
| **Gate** | PASS on `0d0ac7c`: 40 checks, 14 min 6 s |

Not yet accepted: the portal walkthroughs. The capture profile's session asks for a fresh sign-in
on resource and Entra blades (tenant Conditional Access), so 16 portal pictures are declared as
capture specs on the review's branch (`da3d77b`), for one batch after the owner signs in again.
That commit is not green until the pictures exist.

## P50 chargeback reports, 2026-09-24

Merged from `chargeback-reports` at `854ea37`. [ADR-0020](adr/0020-chargeback-reports.md);
`docs/CHARGEBACK-REPORTS.md`.

| | |
|---|---|
| **Generate** | `scripts/New-ClaudeChargebackReport.ps1 -Month`: per unit, a CSV of its people and an HTML summary (requests, input, output, cache-read and cache-write tokens, estimated cost, budget against use), an index and a manifest. Unit totals plus an explicit Unassigned line must equal the month's total, or the run fails |
| **Recipients** | `scripts/Set-ClaudeChargebackRecipients.ps1`, per unit and for the admin team, limited to allowed domains, changed with no redeploy |
| **Deliver** | A scheduled Container Apps job archives each run in Storage reachable only through a private endpoint, and emails each unit its own report through Azure Communication Services |
| **Live** | 2026-09-24: current and previous month generated from the reference gateway's ledger and reconciled with the saved function; both emails reached the owner's inbox (17:42:49Z, 18:10:36Z), with only the owner's address configured |
| **Tests** | 276 assertions on each PowerShell host, 12 mutations caught; 100,000 people generated offline |
| **Cost** | $29.70 a month standing (a private endpoint, a private DNS zone, and the Container Apps environment's load balancer and public IP), plus storage and $0.00025 per email; list price, derived |
| **Gate** | PASS on `854ea37`, Test-All 956.2 s |

An Azure-managed sender domain sends at most 10 messages an hour per subscription and cannot be
raised: broad delivery needs a verified custom domain. Team-level recipients wait for team-only
reports. It is left running on the reference deployment;
`Register-ClaudeChargebackSchedule.ps1 -Remove -PurgeArchive` removes it.

## P55 the AUM service, 2026-09-24

Merged from `aum-service` at `aa697fc`. [ADR-0023](adr/0023-aum-service.md); `docs/AUM-SERVICE.md`.
An optional Azure Functions API that gives AUM viewers, scoped managers and budget requests
without Turnstile. A gateway has one governance authority: the service refuses to write to a
gateway Turnstile governs, so the reference gateway stays Turnstile's.

| | |
|---|---|
| **Identity** | Its own Entra app, created by its owner, with `AUM.Admin`, `AUM.Viewer` and `AUM.Manager`, and the Azure CLI pre-authorized, so tokens need no consent |
| **Writes** | Named values written by the Function's managed identity with read-back and conditional revisions (`If-Match`); byte-for-byte parity with the PowerShell serializers, proven on shared fixtures on both hosts |
| **P47, for this service** | Budget requests, approve, reject, escalate; boosts whose expiry a timer reverts |
| **Live** | On a test gateway: admin reads and reversible writes; the real one-minute timer restored the registry byte-identically; anonymous calls refused with 401 |
| **Tests** | 84 Python tests and 5 mutations, 57 PowerShell assertions |
| **Gate** | PASS on `aa697fc`, Test-All 785.1 s |

Open: the manager-only journey (after P53's), the AUM client's end-to-end journey on the dedicated
test gateway, and the portal pictures (after the owner signs in again).

**Follow-up, merged 2026-09-25 from `9ee7304`** (gate PASS, 864 s, 61 checks passed and the missing
FinOps environment skipped). Tested live on an isolated Basic v2 gateway through the service's API
with Azure CLI tokens, then retired with its resource group:

| Journey | Result |
|---|---|
| Real Claude enforcement, 02:30-02:33Z | 200 for a standard entitlement; strict refused with 403 at its limit; allowance 100% served above nominal with an advisory notice and refused at its effective limit (163 nominal, 326 effective tokens); notify served above nominal with `usage-reported` |
| Attribution | 17 requests, 221 prompt and 68 completion tokens in the ledger, $0.001122 at list price, no unpriced rows |
| Manager-only authority, 03:42-03:45Z | A fresh team-manager token wrote and restored a person budget; a unit manager wrote a team budget; 4 protected operations returned 403. Admin, 14 memberships, 22 direct assignments and every named value restored exactly |

**Found by testing live.** A root unit, or a scope with no notice, in allowance or notify mode made
APIM answer 500 ("The value field is required"): the budget trace sent an empty `ParentUnit` or
`Notice`, and APIM trace metadata cannot be empty. Absent values are now `none`, and a test runs
the policy's actual expressions. P46's live probes had used a team with a parent and a notice, so
they never met it. The reference gateway had every unit strict and could not reach it until the
fixed policy was deployed. Also: Kusto keyset cursors needed `strcmp`, `If-Match` has to be quoted,
and a private endpoint needed its provider-specific delete.

Still open: the AUM client (P52) driving the service end to end. The journeys above are HTTP
receipts, not the terminal app. Also still open: twelve portal pictures, which now need a fresh,
priced deployment because the test one is gone.

**Rolled out to the reference gateway on 2026-09-25 at 09:48:52Z**, in a gap between P52's live
windows. The deploy took 4.3 s. The live policy then equalled main's, and all 28 named values were
unchanged. A real request returned 200 with every budget header (unit, parent, organisation and
daily remaining quota) and the new `x-claude-gateway-request-id`. This also shipped P54's
`ClientIp` trace field.

## P53 Turnstile, tested and captured live, 2026-09-24 (phase 1)

Merged at `146fd12`.

| | |
|---|---|
| **Pictures** | All 22 recaptured live from the reference deployment and 4 added, each with a dated, redacted provenance record and a pixel hash that the screenshot check enforces |
| **Sign-in** | The owner through the consent-free Azure CLI code in 8.0 s; the one-use code, replayed, returned 401 |
| **A change in the UI** | Standard tier 20,000 to 20,001 on the page reached the gateway in 105.3 s; restored through the page in 118.6 s |
| **A mode in the UI** | See P46 above: notify reached `bu-modes` in 113.4 s, strict returned it to `,,` in 113.2 s |
| **Capture tooling** | Capture scripts discover their targets instead of defaulting to live names; `Test-NoDeploymentValues.ps1` also scans `.mjs` files |
| **Manager-only (phase 2)** | The first attempt restored everything exactly but proved nothing: the account also holds a direct `Turnstile.Admin` assignment, so leaving the admin group still left Admin, which outranks Manager. The retry, 2026-09-25 01:21-01:26Z, removed both, and passed: a fresh token carried exactly `Turnstile.Manager` and the manager group (checked before anything counted), `/auth/me` answered `member` scoped to one unit and its three departments, three admin routes returned 403 and the replayed code 401. Four pictures captured. Restored admin group first, then the same direct assignment re-created; all 14 memberships, 22 direct assignments and 24 non-secret named values matched the snapshot, and a fresh token carried Admin again |
| **Fresh tokens on Windows** | The Windows account broker (WAM) kept returning the cached token with the old roles: other scope spellings and MSAL's `force_refresh` alone did not renew it. MSAL's `set_access_token_to_renew`, used by a helper that fails closed, did, with no cache deleted and no grant added (**U21**) |

## P51 terminal FinOps, first release, 2026-09-24

**Delivered: `claude-finops`, merged from branch `claude-finops` at `00f296a`.** Nine terminal
views (Textual) and scriptable commands (Typer) share one engine, backed by Turnstile's API with
an Azure CLI token, by the gateway directly (Azure RBAC, Log Analytics and the repository's own
PowerShell writers), or by example data for tests and pictures.
[ADR-0018](adr/0018-terminal-finops.md); `docs/CLI-FINOPS.md`.

| | |
|---|---|
| **Scope** | The first-release routes are pinned by a parity test. Approvals, boosts, bulk allocation and the richer revision-4 views are listed as deferred in the parity manifest, not shown as controls that do nothing |
| **Changes** | Every budget change is previewed, rechecked against the server before the write, never retried, and removal or a limit below usage needs typed confirmation |
| **Managers** | Follows Turnstile's `manager_scope` contract from `c0c345a`: null means unrestricted, an empty scope is still scoped, a team manager's parent unit is context and never a filter, a 403 reads "Not in your scope", and managers stay read-only |
| **Tests** | 93 offline tests; 18 example-only screen pictures at 80x24 and 160x48. `Test-All` runs them when `.venv-finops` exists and otherwise records an explicit SKIP |
| **Live** | 2026-09-24, owner only: command and terminal journeys agreed on identity, budgets, catalog, tiers, month totals (5,394,583 tokens, $1.923207 estimated) and 200 request ids. No live writes |
| **Gate** | The agent's completeness-audited packet gate passed on `00f296a` in 25 min 43 s with all 32 registered checks present in the raw summary |

Found at merge: the CLI's check is registered only when its venv exists, so a copy of the runner
without the venv recorded SKIP, and `Test-RunnerIntegrity` expected every registered check to
run. The invariant it now asserts is the one the false pass broke: every registered check has a
result in the summary, PASS, FAIL or an explicit SKIP; the checks not skipped all run; and the
final lines count the skips. Open: **U20** (scale, and the two sources' totals differ by design).

## The suite's time budget, 2026-09-24

`Test-All` passed on `690015d` in 1,797.2 s, 2.8 s inside the gate's 1,800 s command budget, and a
budget-modes gate on its own branch had already failed on time with no failing check. The suite
runs its checks one after another and grew with every packet (1,477.4 s on `d1f1756`, 1,721.8 s on
`c7f0a29`), while several agents' gates share the machine. The budget is now 3,600 s
([ADR-0024](adr/0024-test-suite-time-budget.md)), `Test-All` prints and saves each check's
duration, and P56 makes the suite parallel so the budget can return to 1,800 s. Nothing it checks
was removed or weakened. **Done the same day:** P56 brought `Test-All` to 790-927 s on a busy
machine and ADR-0025 returned the budget to 1,800 s (below).

## P56 parallel test suite, 2026-09-24

Merged from `parallel-suite` at `15a8a97`. `Test-All` starts each check as its own `pwsh`
process, four at a time (the machine has 16 logical CPUs), and runs alone the checks that share
Azure CLI state or scan the whole tree. A per-check deadline of 600 s stops a hung check without
stalling the gate. The two slow mutation harnesses run as shards: four for business units, two
for Turnstile, with every one of the 476 and 108 mutations kept, in its original order, which
`tests/Test-MutationShards.ps1` proves. [ADR-0025](adr/0025-parallel-test-suite.md).

| Run | Wall time | Result |
|---|---:|---|
| Serial, `49c53bf` (gate receipt) | 1,829 s | 34 PASS |
| Parallel without shards | 1,302.8 s | not enough; shards added |
| Parallel with shards, three busy runs | 927.2, 830.6, 790.0 s | 39 PASS each, FinOps run, not skipped |
| The agent's final gate on `15a8a97` | 809.9 s | 39 PASS, 0 FAIL, 0 SKIP |

It costs more CPU (about 2,450 CPU-seconds against 1,841 serially), because each check now has its
own process. Found by building it, and fixed test-first: the resolver check's wrapper parsed zero
passes from Node's Unicode summary under a headless code page 437, so it now asks Node for ASCII TAP
output; a missing script behind a prerequisite SKIP was reported as skipped instead of failing; a
timed-out check lost the output it had printed; and a check started late could have outlived the
gate's budget, which set the 600 s default deadline.

**One deadline raised, 2026-09-25.** Business-unit shard 0 is always the slowest: 332-430 s in the
four gates before, against 227-307 s for shard 1, and 520.3 s in the gate on `d55fdc9` (the other
three shards 210-229 s) while two agents ran their own suites. It is the only shard that holds a
mutation running the PS 5.1 wizard (`Test-On-PS51.ps1`, 100 s alone). Its registration now carries
`-TimeoutSeconds 900`, the per-check override ADR-0025 provides; every other check keeps 600 s and
nothing it asserts changed.

## A gate that passed on 9 of 32 checks, 2026-09-24

Found while merging P19, before anything was pushed: the packet gate on `c938ec9` passed in 57
seconds. `Test-All.ps1` had run 9 of its 32 checks. A second `Test-All` in another worktree held
the PowerShell 5.1 wizard's fixed temp file, the write threw, and a terminating error travels up
to the nearest `try`: the one around every check. The summary counted only the results it had and
printed "All checks passed." That receipt is not counted.

| | |
|---|---|
| **Fix** | Each check catches its own error and records FAIL; a run that stops early fails; a registered check whose script is missing fails; both wizard tests use one temp file per run |
| **Proof** | `tests/Test-RunnerIntegrity.ps1`, 17 assertions on a copy of the runner with stub checks: a locked-file error, a thrown error, exit 1 and a missing script. Removing the per-check catch still fails the run through the completion guard; removing both reproduces the false pass. Before the fix, 9 assertions failed: exit 0 with 10 of 32 stubs run |
| **Earlier receipts** | They ran for 20 to 30 minutes; a run cut short at the wizard check takes about one |

## P45 acceptance criteria — delegated management, phase 1

- [x] `Turnstile.Viewer` and `Turnstile.Manager` exist beside `Turnstile.Admin`, created by the repository's script as the application's owner, with no directory role
- [x] Tokens carry only the groups assigned to Turnstile, so a manager's token can name their manager groups
- [x] An admin signs in as Owner, a viewer or manager as Member, read-only, and anyone else is refused before an account is written: 21 new tests in the fork
- [x] A person signs in through the Azure CLI with no consent: a link in 13.4 s, a session as role `owner`, method `entra`, and the same link again 401
- [ ] A manager limited to the units and teams of their manager groups, and the admin's enforcement modes (P46)
- [ ] The normal **Sign in with Microsoft**: needs the one-time consent (**U19**)
- [x] `node .ironclad/gate.mjs --stage packet` exits 0

| Measured | Result |
|---|---|
| `New-ClaudeTurnstileEntraApp.ps1` as the app's owner | Added `Turnstile.Viewer` [User/Application], `Turnstile.Manager` [User] and the ApplicationGroup claim; nothing else changed |
| Turnstile's consent grants | None: every Entra user sees Need admin approval |
| A Turnstile token from the Azure CLI | Issued with no consent, carrying `roles=[Turnstile.Admin]` |
| `Open-ClaudeTurnstile.ps1`, then the link in a browser | Link in 13.4 s; session `owner`, `entra`; code gone from the address; the same link in a fresh browser 401 |
| Turnstile redeploy | 630 s; `ENTRA_VIEWER_ROLE` and `ENTRA_MANAGER_ROLE` kept |

**Found by running it.** Nobody in the tenant had ever consented to Turnstile's web sign-in, so the
Microsoft button had never worked for anyone, the owner included; every earlier Entra check had
used the Azure CLI. The fork's `member` role already hides every management control, which is what
made mapping viewers and managers to it a sign-in change rather than a new role.

| Seat | Verdict | Note |
|---|---|---|
| Architect | Accept | Entra decides who; the scope arrives in the person's own token, so no directory permission is needed to read it |
| Coder | Accept | One mapping serves the web sign-in and bearer tokens, so the two cannot drift |
| QA | Accept | The single-use, expiry and workload refusals are tested, and the live link was replayed to prove it |
| Security | Accept, with a reservation | Until P46 a manager sees what a viewer sees; the code is stored hashed, lives a minute and opens only a person's session |

## P44 acceptance criteria — governance authored in Turnstile

- [x] Business units, teams, their Entra groups, budgets and tier limits are edited on Turnstile's pages, with no script for the Turnstile administrator
- [x] A save starts the gateway's apply job, and the gateway enforces it: a tier limit read on the gateway 112 s after **Save and apply**, a budget refusing the next request 123 s after the save
- [x] Turnstile gains one power, starting one job; the job's identity may write the gateway's named values and nothing else
- [x] Governance moves to Turnstile with one command, which seeds Turnstile once; registering the schedule again neither seeds it nor restarts it
- [x] The start of a month never reads as every budget removed: Turnstile rolls the month in before the apply reads it
- [x] No group that cannot be confirmed is applied, tier limits always are, membership is never rewritten from groups that could not be read, and a catalog with no business unit is refused
- [ ] New groups and membership refreshed by the job: needs `GroupMember.Read.All` from a tenant administrator, which the reference tenant's operator cannot grant (**U17**). The script is `Grant-ClaudeGovernanceGraphAccess.ps1`
- [x] `node .ironclad/gate.mjs --stage packet` exits 0

| Measured | Result |
|---|---|
| `Connect-ClaudeTurnstile.ps1 -GovernanceAuthority Turnstile` | 249 s: 3 organizations, 5 departments and 2 tiers seeded; the writer role and Container Apps Jobs Operator granted; validation `ok` |
| **Apply now**, through Turnstile's API | The job started in 1.9 s and succeeded after 152 s: 33 s for the container to start, 55 s to add PowerShell, sign in and fetch the commit, 64 s the pass |
| Standard tier 20,000 to 20,001 on the Gateway governance page | Read on the gateway 112 s after **Save and apply**; put back the same way in 109 s |
| Team budget 1,666,666,666 to 1,000, saved in Turnstile | The first refused request 123 s after the save: 403 `rate_limit_error` naming the unit. Put back: 200 after 102 s, and the registry read back as it was |
| The schedule registered again | Turnstile's tier record and its API's last-modified time unchanged |
| Eight named values read one at a time, against one list call | 21.3 s against 3.1 s, the same values |
| Offline | `Test-TurnstileGovernance.ps1` 132 of 132, 51 new; the fork's 27 API tests and 9 page-rule tests |

**Found by running it.** The first live apply wrote the registry only to reorder it; entries are
now compared by name, as the policy reads them. The pass spent 21 s reading eight named values
one at a time; it reads them in one call. Turnstile's redeploys keep the app's settings, because its
release step merges them, so the apply job's setting survives them. The plan had assumed the
opposite. Turnstile's API answered 405, not 404, for the route it did not have yet. The guide's
one-enforcer check matched the phrase anywhere on the page, and the new section uses it, so the
mutation that drops the section went uncaught; the check now looks for the section. The first gate
failed on the Graph check's address, which carried an `&`: on Windows `az` runs through
`cmd.exe`, which ends a command there, so an administrator's run would have misread the result.

**Found before it ran.** Registering the schedule runs Connect, and Connect seeded Turnstile
whenever governance was Turnstile's, which would have overwritten every save on each
registration; it now seeds on the change only, and a failed seed leaves governance with the
gateway. A new month has no budgets in Turnstile until its five-minute timer rolls the last month's
in, which the apply would have read as every budget removed; Turnstile now rolls the month in when
the apply asks. With the directory unreadable, a tier's limits were dropped whenever its group had
a name other than the default. An empty catalog would have emptied the registry. Connect wrote
Turnstile's app setting on every run, restarting Turnstile's API each time. And at scale the
gateway reads membership from the projection, where the job would have tried to write every member
into a named value that holds about 110; it now leaves membership to the projection's own sync.

| Seat | Verdict | Note |
|---|---|---|
| Architect | Accept | Turnstile stays out of the request path. Its one new power is starting a job whose code and permissions this repository fixes |
| Coder | Accept | The registry format keeps one implementation, and a round trip from the gateway through Turnstile and back is tested |
| QA | Accept | 20 new mutations, all caught; the apply is tested against a gateway held in memory, not by reading its source |
| UX | Accept, with a reservation | About two minutes from save to effect, most of it the job starting, and the page shows the last apply. Membership waits on a tenant administrator (U17) |

## P39 acceptance criteria — Turnstile, from the gateway

- [x] Units, teams and budgets appear in Turnstile, read from the gateway rather than configured twice
- [x] Every request and every hour of cache reads reaches Turnstile exactly: its own ingest code accepts every event unaltered
- [x] Sending the same window twice counts once
- [x] A budget edited in Turnstile is enforced by the gateway, and only after `-Apply`
- [x] Only an assigned administrator can use Turnstile, and the refusal comes from Entra
- [x] Nothing about the Turnstile deployment is written into a script: it is discovered, stored on the gateway, and changed by the same command
- [x] What it costs is read from what is deployed and today's list prices
- [x] Scheduled export and sync as a workload identity (P40): an hourly Container Apps job with no secret ([ADR-0014](adr/0014-turnstile-beside-the-gateway.md)). Run live: it sent usage and wrote a changed budget as `app:<job identity>`, and was refused (`401`) once its Event Hubs grant was removed
- [x] `node .ironclad/gate.mjs --stage packet` exits 0

| Measured | Result |
|---|---|
| Turnstile's `UsageProcessor` at `4e93935` on the exported file | 561 of 561 accepted, none skipped, altered or estimated; $2.972987 sent and stored |
| The same 557 events sent twice to the live hub | 1,114 messages in, 557 calls and $2.972581 stored |
| Budget set to 1,000 in Turnstile, `-Apply` | 57 s; the next request 403 `rate_limit_error` naming the unit; restored, then 200 |
| Admin group's assignment removed | `AADSTS50105` 5 s later; restored, a token again 22 s later |
| 30-day backfill, hourly against day slices | 586.5 s against 66.9 s |
| Turnstile at rest, Central US list prices | $158.84 a month, $62.05 of it a usage observer this integration does not use |

**Found by running it.** Turnstile skips an event with any field it does not define, zeroes a row
with a null count, and pins its reconciliation window on an estimated row it cannot match; the
export checks all three before sending. The batch check's estimated-row guard was untested until
its mutation went uncaught. Upstream Turnstile's catalog is demo data, its sign-in accepts any
organization, and its deployer does not run on Windows; the fork fixes each, in four branches to be
offered upstream (P41). Two working notes were wrong and never reached the guide: object-id rows
are 3, not 20, and an 85 s refusal delay was not reproduced — the refusal came on the first
request after `-Apply` returned.

| Seat | Verdict | Note |
|---|---|---|
| Architect | Accept | Turnstile stays out of the request path; a Turnstile outage cannot refuse a Claude call |
| Coder | Accept | The connection lives in one quote-free named value, because `cmd.exe` strips quotes from JSON arguments |
| QA | Accept | 15 mutations, all caught, after one gap was closed |
| UX | Accept | One command per step, each safe to re-run, with a portal path beside the script |
| Security | Accept | Single tenant, assignment required, role checked on every token; pictures redacted in the page and refused if a real value survives |

## Where P19 stands, 2026-09-24

**Hardened and measured at 500,000 records, but still not the default.** The four review findings
recorded on 2026-09-23 that were code are fixed, deployed to the Premium v2 test gateway, and
measured there. The default install still holds about 93 developers, because the installer still
writes named values: `cos-default` and `cos-upgrade` are not built.
[ADR-0017](adr/0017-projection-freshness-and-admission.md) records the design.

| Finding from 2026-09-23 | Now |
|---|---|
| The resolver accepted a record of any age | Each complete directory observation stamps every member it keeps with a reconciliation generation and an absolute expiry: 7,200 s by default and at most, 60 s at least. The resolver and the gateway's cache both check it, and the cache TTL is clipped to the time left. Measured: a record whose lease was cut to 20 s answered 503, naming the expired projection, although the gateway caches entries for 60 s; restored, it answered 403 again |
| A burst of misses reached the resolver unthrottled | The gateway admits at most 100 concurrent misses and 200 a second before calling the resolver, and answers the rest with a retryable 429 (`Retry-After: 1`). The resolver coalesces concurrent reads of one identity within a process, holds at most 100 distinct reads, and gives up after 3.5 s. Two always-ready instances take 100 concurrent requests each |
| The sync read one page of existing records | Both writers read every continuation page, empty ones included, before publishing, and fail on a repeated token or a failed page |
| `projection.bicep` defaulted to a public account | The enterprise default is private-only; public and selected-IP stay explicit choices |
| Rollback can regrant leavers; allowance is local to one gateway | Not changed: design, not code |

Measured 2026-09-24:

| | |
|---|---|
| **500,000 records** | A throwaway container loaded in 524 s, 954 records a second, 2.95 M RU (5.9 RU a write). 500 point reads of the first, middle and last records cost 1 RU each: p50 47.5 ms, p99 51.0 ms, max 72.1 ms. The container was deleted. This measures storage, not a directory scan or 500,000 people at once |
| **First requests** | 20 concurrent misses right after deployment: no 503, slowest 2,334 ms. The same after 16 minutes idle: no 503, slowest 1,105 ms. Before the fix, 2 of 3 first requests after idle returned 503 |
| **Bursts** | 100, three of 50 and three of 100 concurrent misses: no 503, slowest 1,682 ms. 500 primed connections at once: 279 answered, 221 retryable 429, no 503 |
| **Miss overhead (U14)** | 100 misses against 99 hits: 81 ms more at p50, 192 ms more at p99 |
| **Gate** | Packet gate PASS on `8a19524` in 29 min 35 s; 57 of 57 projection mutations caught |

The lease has a running cost. Every member the scan keeps is written again, changed or not, so the
scan has to run at least hourly and finish inside the lease. At 500,000 members that is about 365
million writes a month: about $538 a month at the measured 5.9 RU a write and $0.25 per million RU,
on top of $91.56 a month at rest, which is $26.28 more than with one warm instance (derived, list
price).

**The test gateway's leases expire at 2026-09-24T15:58:49Z.** Nothing reconciles there on a
schedule: the runner is stopped, and an unattended scan needs `GroupMember.Read.All` (U17). After
that time the test gateway answers every request with 503 until someone reconciles again. That is
the fix working, not a fault.

Still missing before 500,000 can be claimed:

- **Counters at that cardinality (U9).** Unchanged: narrowed, not closed.
- **A scheduled directory scan of 500,000 members.** It needs U17 and has not been run at that size.
- **Coalescing across instances.** It is per process, so two instances can both read one identity.
- **Bursts of different identities, a regional failure, and allowance retention on failover.**
- **Making it the default** (`cos-default`) and a one-command move for existing gateways
  (`cos-upgrade`).
- **Foundry quota.** Unchanged: the model deployment, not the gateway, is the first limit
  ([SCALE.md](SCALE.md)).

## Where P19 stood, 2026-09-23 (superseded by the section above)

**Not finished, but no longer only designed.** The default install still holds about 93
developers, because the projection is not the default and has not been load-tested at 500,000.
What changed is that the whole path now exists and was run: deployed with no public endpoint,
populated, compared, flipped to, failed over, rolled back and flipped to again, on a Premium v2
gateway in Canada Central with the Cosmos account in East US 2
([SECURE-PROJECTION.md](SECURE-PROJECTION.md)).

| | |
|---|---|
| **Built and run** | `infra/resolver.bicep` (the resolver's template, which did not exist), `infra/projection-network.bicep` for an existing VNet, the in-network writer `sync/`, and the projection-against-gateway comparison |
| **Found by running it** | A missing record answered 503 instead of 403; the two syncs charged nested teams to different business units; `Sort-Object` reordered units of equal depth; a gateway redeploy would have removed its VNet integration; the Deploy to Azure template was the first commit's. All fixed |
| **Cost** | $69.09 a month at 500,000 developers, $65.28 of it at rest — five private endpoints, five zones, one warm resolver instance |
| **U15** | Closed: a management-group Modify policy, `CosmosDB_PublicNetwork_Modify` |

Still missing before 500,000 can be claimed:

- **Counters at that cardinality (U9).** Narrowed, not closed: 500,000 identities were accepted
  and charged, but no allowance was exact ([SCALE.md](SCALE.md)). The resolver's p99 on a miss (U14)
  is: 301 ms, with 389 ms the slowest of 150 ([SCALE.md](SCALE.md)).
- **Foundry quota.** One capacity unit is 1 request and 1,000 tokens per minute (measured), so
  the model deployment, not the gateway, is the first limit — see [SCALE.md](SCALE.md).
- **The resolver after idle and under a burst (U18).** With no always-ready instance, 2 of 3 first
  requests after idle returned 503; with one, the first burst of 20 concurrent misses returned
  four. Nothing coalesces concurrent misses.
- **Making it the default** (`cos-default`) and a one-command move for existing gateways
  (`cos-upgrade`).

Found by review, 2026-09-24, and checked against the code before being recorded here:

| Finding | Checked | Fix to make |
|---|---|---|
| The resolver accepts a record of any age. A stopped sync keeps access indefinitely, so the cache TTL does not bound revocation | No expiry, age or generation check in `resolver/src/entitlement.mjs` | A completed-reconciliation generation with an absolute expiry, enforced by the resolver and the cache; an expired projection answers 503 |
| The resolver is called before any limiter, so a burst of cache misses reaches it unthrottled | First `send-request` at line 98 of `infra/policy.xml`, first limiter at line 298. Measured 2026-09-24: every concurrent miss reached the resolver, and the first burst of 20 returned four 503s (U18) | Miss-path backpressure and request coalescing, with Cosmos deadlines under five seconds |
| `Sync-ClaudeProjection.ps1` reads existing records with one query and no continuation, so a revocation beyond the first page is never planned | One `POST .../docs`, no `x-ms-continuation` | Page through continuation tokens. Not changed yet: it needs a Cosmos account reachable from the test machine, and every account in the test subscription is private (U15) |
| `projection.bicep` defaults to a public account | `param networkAccess string = 'public'` | Make the enterprise profile private-only |
| Rolling back to the named-value lists after the flip can regrant leavers, and allowance counters are local to one gateway | Design, not code | Keep both destinations current for a bounded rollback window; treat a replacement or failed-over gateway as restoring allowance (U9) |

Fixed at the same time: `sync/src/apply-projection.mjs` reported `ok: true` when writes or deletes had failed, though it exited 3. It now reports the outcome.

## Where P19 stood, 2026-09-17 (superseded by the section above)

**Not finished, and the shipped product still holds about 93 developers.** That number is
measured, not estimated: `Measure-ClaudeCeiling.ps1` against the reference gateway reports
`bu-members` at 218 of 4,096 characters with room for 88 more entries. Nothing about the 500,000
requirement is in the running product today.

What is settled:

| | |
|---|---|
| **Platform** | Cosmos DB serverless plus a Function resolver — [ADR-0011](adr/0011-projection-platform.md) |
| **Cost** | $11.11/month at 500,000 developers, computed by `Measure-ClaudeProjectionCost.ps1`, after deploying corrected the first figure |
| **Shape** | Two orthogonal switches rather than a size ladder — [ADR-0012](adr/0012-store-and-availability.md) |
| **Storage risk** | Retired. Point reads measured **1 RU flat** at ~1, 500, 20,000 and 100,000 records, 24–47 ms. The collection growing does not make a lookup cost more |
| **Migration** | Shadow comparison built and negative-tested — [ADR-0009](adr/0009-shadow-migration.md) |

What is not built, and is what a 500,000-developer deployment needs:

- **Population.** Nothing writes the projection from Entra. Backfill was measured at ~190
  records/second, so 500,000 identities is about 45 minutes — a number, not a design.
- **The resolver.** No Function exists. It must be Flex Consumption, because Y1 Consumption has no
  VNet integration and the Cosmos account comes back with public access disabled.
- **The policy path.** `cache-lookup-value` plus `send-request` to the resolver, with the failure
  contract ADR-0005 requires: bounded stale authorization, deny past the limit, and never treat a
  lookup failure as user-not-found.
- **The switches.** `-EntitlementStore` and `-ProjectionHa` are described in ADR-0012 and
  implemented nowhere.

The infrastructure template exists and has been deployed once and verified, then torn down —
`infra/projection.bicep`, partitioned on `/oid`. There is no Cosmos account or Function in the
reference resource group today; `az cosmosdb list` and `az functionapp list` both return nothing
belonging to this accelerator.

**The one open input is still not a technical one:** how long the gateway may keep serving someone
the directory has already revoked. That number sets the cache window, and the cache window sets the
cost — 15 minutes is $15.69/month, 4 hours is $0.84. It costs nothing to decide and the design
cannot be finished without it.

## The P19 platform decision, 2026-09-17

The operator chose **Cosmos DB serverless with an Azure Function resolver**, recorded as
[ADR-0011](adr/0011-projection-platform.md). ADR-0005 decided what entitlement becomes and
deliberately did not name a platform; this names it and prices it.

**The standing-cost objection does not survive the arithmetic.** At the full requirement — 500,000
developers, 50,000 active on a working day, a 60-minute cache window — it is **$11.11 a month**:
$1.56 Functions, $2.20 Cosmos request units, $0.05 storage, $7.30 private endpoint. Computed by
`scripts/Measure-ClaudeProjectionCost.ps1`, not quoted, because the number that decides it is the
cache miss rate and nobody can look that up.

The reason it is that small: the resolver is called **once per cache window per active developer**,
not once per request. A developer making 500 calls an hour and one making 5 cost the same.

| Cache window | Misses per month | Per month | A revoked developer keeps working for up to |
|---|---:|---:|---|
| 240 minutes | 2,200,000 | $8.14 | 4 hours |
| 60 minutes | 8,800,000 | $11.11 | 1 hour |
| 15 minutes | 35,200,000 | $22.99 | 15 minutes |

Every row is affordable, and most of each row is a fixed endpoint charge, so **the window is a
revocation decision, not a budget one**. That reframes the one question still open from ADR-0005: it
was never going to be settled by cost.

### The first draft of the costing was wrong, and deploying found it

ADR-0011 originally said $3.81 on Functions Consumption with no private networking. Deploying
`infra/projection.bicep` to the reference subscription returned an account with
`publicNetworkAccess: Disabled`, enforced above the resource group — an update to enable it reported
success and changed nothing. Nothing in the template asks for that; the governance baseline imposes
it.

Two consequences, and an accelerator aimed at six-figure organisations has to assume both:

- Cosmos needs a **private endpoint**, $7.30 a month, billed whether anyone calls the gateway or
  not. It is the first line in this accelerator that bills at rest.
- The resolver **cannot run on Consumption**: the Y1 plan has no VNet integration. Flex Consumption
  does and keeps per-execution billing, so the cost line is unchanged — but the plan originally
  named could not have reached the database at all.

Neither was visible from a pricing page.

**What it costs in latency, not money.** Serverless offers no guaranteed throughput or latency, and
caps at 5,000 RU/s per physical partition — against an average under 15 RU/s at full scale, so
headroom is not the concern. It is survivable only because the resolver sits behind the APIM cache,
which is why ADR-0005 put it there. Functions Consumption cold starts land in p99 on a miss; the
escape is a Premium plan with a warm instance, and that does carry a standing bill.

**Still not decided:** the staleness window itself, and when to build. Eight identities against a
binding ceiling of about 93 — `Test-ClaudeHealth.ps1` flags at 80%.

### Two corrections to SCALE.md, 2026-09-17

**The binding ceiling was the wrong number.** The page headlined *"the binding limit is 110
developers per tier"* while its own table already gave the business-unit map as about 93. Both
figures were right; the prose picked the larger one. A `bu-members` entry is `oid=unit,` — 38
characters plus the unit name, against 37 for a bare object id — so with a six-character unit id it
holds 93 and a longer name holds fewer. Business-unit membership runs out first, and planning
against 110 over-plans by roughly a fifth. Measured on the live gateway: `allow-*` 38 characters per
entry, `bu-members` 44.

**The token-claim alternative was never written down.** The first thing a reviewer proposes for P19
is to put the tier in an Entra app role or the `groups` claim and drop the lookup entirely — no
projection, no resolver, no standing cost. It cannot work: the policy validates the audience
`https://cognitiveservices.azure.com`, a first-party Microsoft resource, and app roles and the
groups claim are configured on the application registration that the token is issued for. Nobody
here owns that registration, so there is nowhere to put the claim. Recorded so it is not
re-proposed each review.

### What P19 actually needs from the operator

Three decisions, and only one of them is technical:

| | |
|---|---|
| **When** | Not yet, on the reference gateway: 8 identities against a ~93 ceiling, and `Test-ClaudeHealth.ps1` flags at 80%. For an organisation that already has more than about 90 developers, the answer is *before rollout*, because the ceiling is reached on the first day rather than gradually |
| **The staleness window** | How long the gateway may keep serving someone the directory has already revoked. Today's implicit answer is "until the next sync", unbounded and unstated. Costs nothing to decide and is the input the design needs |
| **What hosts it** | The billable one. Raising the APIM SKU is the tempting wrong answer — Standard v2 raises the *count* of named values, not the 4,096-character limit per value, which is what binds |

## P37 acceptance criteria — chargeback counts cache reads

Chargeback omitted cache entirely. On measured usage cache is 38.7% of real cost weight, and the
omission is **uneven**: a team reusing a large cached prompt is under-charged against one that does
not. That is the distortion that makes a chargeback figure arguable, which is the one thing it
cannot afford to be.

- [x] Cache read is attributed to a business unit, from a source that carries the object id
- [x] It is reported beside the metered total, not inside it
- [x] Priced at its own rate (0.1x base input), not the blended mix
- [x] What is still missing is stated rather than implied
- [x] `node .ironclad/gate.mjs --stage packet` exits 0

### What the work found

**The recorded blocker was drawn too broadly.** U12 said "no APIM-native source carries the cache
categories". True per request — the log's token columns are `PromptTokens`, `CompletionTokens` and
`TotalTokens`, and that was properly measured. Not true in aggregate: the gateway's own
`llm-emit-token-metric` emits `Prompt Cached Tokens` carrying a `UserId` dimension.

Measured live 2026-09-17 before building anything:

| | Result |
|---|---|
| `AppMetrics`, `Prompt Cached Tokens`, 30 days | 162 rows, **6,833,717** tokens |
| Dimensions on the metric | `UserId`, `User`, `Tier`, `Model`, `SessionId` |
| `UserId` value | `43cc5304-...` — the same object id `bu-members` keys on |

So the join was available all along. The comment in `chargeback-ledger.kql` claiming the metric was
"bounded but **not per-user**" was simply wrong, and that one wrong clause is what kept the gap open.

**What the report now shows**, on the reference deployment over 30 days:

```
Id        Members   Budget           Used   Used %   Cache read
mcaps           4  5,555,555,555    6,105      0%    6,833,717
  ites-1        2  1,666,666,666    6,105      0%    6,833,717
```

6,105 metered tokens against 6,833,717 cache reads. The scale of what was invisible is the finding.

**Cache read sits in its own column, not inside `tokens_used`.** The quota still cannot see it, and
folding it into the same number would imply the budget counts it. Three states are now distinct:
reported and counted, reported and not counted, neither.

### What is still missing

Cache *write* — the 5-minute and 1-hour categories at 1.25x and 2x. They exist only in the Anthropic
response body, and reading that in an outbound policy buffers the response and ends streaming. The
report says so rather than implying cache is solved. Enforcement is unchanged and still blind to
every cache category, which is U13.

### Council

| Seat | Verdict | Note |
|---|---|---|
| Architect | Accept | Per-user is the granularity chargeback bills at, so an aggregate metric is not a compromise here — it is the right shape |
| Coder | Accept | `union` in both directions rather than a join: a caller can have a metered request whose trace never landed, or a metric row whose request did not |
| QA | Accept | Two of the first four assertions passed while measuring nothing — `cache_read` matched three other fields, and "cache write" matched the comment. Both now assert the field and its value |
| UX | Accept | A separate column makes the previously invisible number the most striking thing in the report, which is what it should be |

## P36 acceptance criteria — the two things an admin does after go-live

- [x] A new model is one command: deploy-check, deploy, allow, price, and what developers change
- [x] The price book is configuration rather than code, and git-ignored because it may hold negotiated rates
- [x] Retiring a model is one command too, and keeps its price so past months still reconcile
- [x] Marketplace and extension controls are emitted for both clients from one input
- [x] The limits of those controls are stated rather than implied
- [x] One command answers whether the gateway needs attention at all
- [x] `node .ironclad/gate.mjs --stage packet` exits 0

### What the work found

**Forty-seven scripts, and no single answer to "is it healthy?"** `Test-ClaudeHealth.ps1` runs the
read-only checks and reports one verdict with the fix beside each finding. It composes the shipped
checks and reads their exit codes rather than reimplementing them, so there is no second copy to
drift. On the reference deployment it reports four passes, one failure (11 principals can reach
Foundry directly) and one warning (3 developers in no business unit).

Two bugs in it, both found by running it. Splatting an array passes arguments **positionally**, so
the entitlement check ran with the resource group as its first positional parameter and compared
0 identities against 0 — reporting "In sync" while measuring nothing. And `Write-Host` does not
travel on the success or error stream, so `2>&1` captured none of the sub-check output and sixty
lines printed over the summary meant to replace them; `*>&1` captures it.

**Four things have to agree for a model to work, and the third fails quietly.** Deployed, allowed,
priced, selectable. A model with no price is served and reported at **$0**, which reads as nobody
using it rather than as a configuration gap. `-List` marks it red and the command refuses to add
one unless `-SkipPrice` is passed.

**The Desktop profile was built and thrown away.** `New-ClaudeCodePolicy.ps1` assembled a `$desktop`
block — and its own comment said the keys were "emitted here so one run produces one tier's
complete profile" — but nothing ever wrote it. Every Desktop tab setting the script has accepted
since it was written reached no machine. It now writes `claude-desktop.managed-settings.json` and
`claude-desktop.reg`.

**A one-element array became an object.** `allowedPluginMarketplaces` is `object[]`. Piping a
one-element array to `ConvertTo-Json` unwraps it, so a single allowed marketplace was written as
`{...}` instead of `[{...}]` and would have been read as the wrong type. `-InputObject` fixes it.

**My own docstring claimed a feature that did not exist.** It said the command "offers to deploy it
when it is not" deployed; the code only threw. Astra's review caught it. `-Deploy` now exists and
uses the existing helper, so a quota refusal is still reported as quota rather than as a retry.

### Two more tests that measured nothing

The mutation reverting one model's price to doubles stopped being caught once the sandbox began
copying `config/`, because a developer's own `price-book.json` overrides the built-in table and
made it dead code inside the sandbox. The sandbox now copies only `*.example.json`.

The assertion that the Desktop profile is written matched the string anywhere in the file, so
commenting out the `Save` left it passing. Anchored at line start.

### Council

| Seat | Verdict | Note |
|---|---|---|
| Architect | Accept | The price book belongs in configuration: a model release is an operational event, not a reason to edit and redeploy code |
| Coder | Accept | Both clients are emitted from one input, because two files kept in step by hand drift and govern half a fleet each |
| QA | Accept | Three defects here were found by running the thing rather than reading it, and two were tests that passed while measuring nothing |
| UX | Accept | `-List` answers "where am I" before anything changes, and the unpriced case is the one it shouts about |

## P25 acceptance criteria — state the overshoot, and stop calling it a hard cap

- [x] The bound is measured on a live deployment, not asserted
- [x] The worst case is used, not the median
- [x] Terms that cannot be measured here are named rather than filled in
- [x] Nothing is left changed: the override is restored in a `finally`
- [x] It is not described as a hard cap anywhere
- [x] `node .ironclad/gate.mjs --stage packet` exits 0

### What the work found

| Term | Measured |
|---|---|
| Telemetry lag | 193s worst, 87s median, over 102 requests |
| Propagation | 17s |
| Job interval | 300s, a parameter |
| **Window** | **511s** |

Roughly eight and a half minutes of continued spending after a threshold is crossed, plus
in-flight requests.

**Two bugs in the measurement itself, both found by running it.**

The first version polled: make a call, then query the ledger every few seconds until it appeared.
It reported *"not visible within 420s"*. The real lag was around 80 seconds. The poll loop wrapped
its query in `catch { }`, so a failing query and an empty result were indistinguishable, and the
answer came out four times too large. Replaced with `ingestion_time()`, which measures it directly
and gives a distribution instead of one sample.

The second was resolving the Log Analytics workspace with `[0].customerId`. The reference resource
group holds **three** workspaces and `[0]` was not the gateway's, so the first run reported "no
requests in the last 24h" against a ledger holding 29. This is the same shape as the bypass audit
picking the wrong Foundry account with `[0].name`. It now refuses an ambiguous group and names the
workspaces.

Both failures shared a property worth naming: each returned a plausible number rather than an
error. A measurement that cannot fail loudly is not a measurement.

### Council

| Seat | Verdict | Note |
|---|---|---|
| Architect | Accept | The bound is the honest description of what the architecture can do; naming it a hard cap would be a claim the request path cannot support |
| Coder | Accept | Propagation had to be observed through the gateway — ARM returns the new value instantly and says nothing about when the policy sees it |
| QA | Accept | Both defects produced believable numbers. The silent catch is now asserted against, and `[0]` selection is asserted against by name |
| UX | Accept | The window is reported in seconds with its terms itemised, so an operator can see which one to shorten |

## P20b acceptance criteria — settle the financial semantics

Money code that is wrong is worse than none, because the output looks authoritative. P21 and P23
both compute dollars and neither should be built before the rules are the same in both.

- [x] Eight questions answered in [ADR-0010](adr/0010-financial-semantics.md), each grounded in a recorded measurement
- [x] The implementation moved to decimal to match the decision
- [x] Rounding behaviour asserted on values, not on source text
- [x] `node .ironclad/gate.mjs --stage packet` exits 0

### What the work found

The ADR said money is decimal; the code was `[double]` throughout — `$Usd`, `$MonthlyBudgetUsd`,
`$OutputShare` — and token spend was accumulated as `0.0`. Writing the decision without changing
the code would have left a document contradicting the thing it describes, which is the failure this
session has spent its time removing elsewhere.

After the change, $5,000 converts to 1,388,888,888 tokens and back to exactly $5000.00.

**A test that asserted nothing, caught before it shipped.** The first rounding assertion claimed
that rounding per row differs from rounding once, using 333,333 tokens. Under decimal accumulation
both came to 3.60, so the assertion asserted a difference that did not exist. The apparent
difference in the earlier manual check — 3.5999999999999996 — came from `Measure-Object -Sum`
promoting to double, not from the rounding at all.

Replaced with an input where the rule genuinely bites: 1,389 tokens is $0.0050004 and rounds to a
cent on its own, so three rounded rows total $0.03 while the same 4,167 tokens priced once is
$0.0150012 and rounds to $0.02.

**A mutation that proved the guard was weak.** Reverting one model's price to doubles was not
caught. Two reasons, both worth recording: the source assertion matched the three other models that
were still decimal, and PowerShell promotes to decimal when *either* operand is decimal, so a double
price book still produced decimal output while `OutputShare` stayed decimal. The price book's type
was a latent problem, not a visible one. The assertion now walks every entry and checks its runtime
type.

### Council

| Seat | Verdict | Note |
|---|---|---|
| Architect | Accept | The eight questions are the ones that have to agree across P21 and P23; settling them separately is why those two can now be built independently |
| Coder | Accept | Decimal is the mechanism, but the property is reproducibility — a chargeback figure that changes between two runs cannot be argued with |
| QA | Accept | Both defects here were tests that measured nothing, and both were found by running the mutation rather than by reading the assertion |
| UX | Accept | "Soft cap" is the term most likely to be misread by a finance reader, and it now says which of the two meanings it has |

## P19b acceptance criteria — migrate without resetting allowances

- [x] The sequence is written down, with authorization unchanged until the canary — [ADR-0009](adr/0009-shadow-migration.md)
- [x] Phase 2's comparison ships and runs against a live gateway
- [x] It resolves tier with the policy's precedence, so it cannot invent drift
- [x] It was negative-tested by creating real drift, not assumed to work
- [x] A rollback restores authorization and never consumption; counter keys are preserved
- [x] The mid-period opening balance is deferred to P20b rather than quietly decided
- [x] `node .ironclad/gate.mjs --stage packet` exits 0

### What the work found

The comparison had to be negative-tested, because a comparison that always says "in sync" is
indistinguishable from one that is not measuring. Removing the test service principal from
`claude-code-premium` in Entra, without running the sync, produced:

```
stale (1)
  On the gateway, not in the directory. Still entitled after removal.
  d6cd24b0-...  gateway: premium   directory: denied
```

and exit 1. Re-adding it returned the comparison to clean. That is also a demonstration of the
revocation gap documented in ONBOARDING.md: removal from a group does not take effect until the
sync runs.

The Graph membership read moved to `ClaudeGraphMembership.ps1` and is now shared by the sync and
the comparison. Two readers of the same directory that implement the read separately will drift,
and this particular read took six measured combinations to get right.

The extraction was caught by the existing tests, which is what should happen: five assertions in
`Test-Teams.ps1` failed because they pointed at the old location. One mutation then had to be
repointed as well — `transitiveMembers/microsoft.graph.user` now survives only inside the comment
holding the measured table, so mutating it changed a comment and nothing failed. That is the
seventh instance of an assertion or mutation matching prose rather than behaviour.

### Council

| Seat | Verdict | Note |
|---|---|---|
| Architect | Accept | Phases are ordered by blast radius: everything before the canary is observation, so being wrong costs a report rather than a 403 |
| Coder | Accept | Sharing the membership read is the whole point — a comparison with its own Graph call measures itself |
| QA | Accept | Proven in both directions against live Entra. A clean result now means something because a dirty one was produced on purpose |
| UX | Accept | `missing` and `stale` are named rather than both called drift; one is a developer waiting, the other is access that should have gone |

## P18b acceptance criteria — the load envelope

"500,000 employees" is not a capacity specification. It gives no rate, no concurrency and no
shape, so it cannot be designed against or tested.

- [x] Every ceiling the tooling enforces is measured, not copied from a document
- [x] The identity ceiling is derived from the character limit rather than written as a literal
- [x] `Measure-ClaudeCeiling.ps1` reports a live gateway's headroom and exits non-zero past a threshold
- [x] The five numbers a capacity figure actually needs are named
- [x] What has not been measured is stated rather than filled in
- [x] A capacity test is defined by what it must prove, not by how many keys it creates
- [x] `node .ironclad/gate.mjs --stage packet` exits 0

### What the work found

| Measured on BasicV2 | Result |
|---|---|
| Named value of 4,096 characters | Accepted, HTTP 201 |
| 4,097 characters | Rejected, HTTP 400 `ValidationError` |
| 110 object ids (4,071 characters) | Accepted |
| 111 object ids (4,108 characters) | Rejected |

So a tier holds **110 developers**, which ADR-0005 already stated and this confirms exactly.

Two things the measurement changed:

**Per-entry cost is not constant.** A `bu-members` entry carries `oid=unit` and costs 44 characters
against a bare object id's 37. Assuming 37 overstates remaining room by about 19% on the list that
fills first, so the script measures the real cost from the data it is reading.

**Sharding looks like it works and does not.** 5,000 named values x 110 identities is 550,000,
which clears a 500,000 requirement on paper. It requires the policy to scan every shard on every
request. The arithmetic was never the constraint: materialising 500,000 records in a data store is
unremarkable, and materialising them in API Management policy configuration is what cannot work.

### What was deliberately not done

The traffic half is empty. The reference deployment's ledger holds **111 requests across 2 days**,
and an envelope extrapolated from that would read as evidence while being none. The page states the
method and the traffic-independent ceilings, and says why it stops there.

### Council

| Seat | Verdict | Note |
|---|---|---|
| Architect | Accept | Confirms ADR-0005's premise by measurement rather than restating it, and closes off sharding as the escape a reviewer would otherwise propose |
| Coder | Accept | The ceiling is derived from the limit, so it stops being correct out loud rather than silently if the service changes |
| QA | Accept | The README reachability check was negative-tested: an unlinked page fails with its own name. Six pages were unreachable before it existed |
| UX | Accept | The report names what runs out first rather than listing limits, and the failure path says writes fail outright instead of truncating |

## P35 acceptance criteria — a service principal in a tier group is entitled

A tier group can hold a workload identity as well as people. Adding one was a silent no-op:
the portal listed it as a member and the gateway returned 403.

- [x] The sync reads service principals as well as users
- [x] The Graph request form is measured, not assumed — six combinations, one works
- [x] Proven on the live gateway: premium 2 members to 3, total 7 authorised identities to 8
- [x] A service principal in no business unit is attributed to `unassigned`, reported as 2 to 3
- [x] Three mutations, one per component of the request, each failing the run on its own
- [x] `node .ironclad/gate.mjs --stage packet` exits 0

### What the work found

The sync used `transitiveMembers/microsoft.graph.user`, which excludes workload identities by
construction. The obvious fix — add the `servicePrincipal` cast — returns an empty collection.

| Request | Returned |
|---|---|
| `transitiveMembers` | 3 — service principal missing |
| `transitiveMembers/microsoft.graph.user` | 2 |
| `transitiveMembers/microsoft.graph.servicePrincipal` | 0 — missing |
| the same, plus `ConsistencyLevel: eventual` | 0 — missing |
| the same, plus `$count=true` | 0 — missing |
| the same, plus **both** | 1 — found |

Graph answers 200 with an empty collection in the four failing rows rather than erroring, so
every wrong form reads as "this group holds no service principals".

The first fix attempt added the cast alone, was run against the live tenant, and changed
nothing — the sync still reported 2 members. That negative result is what produced the table.

### Council

| Seat | Verdict | Note |
|---|---|---|
| Architect | Accept | Entitlement is identity-shaped, not person-shaped; a build agent calling the gateway is the ordinary case, not an edge one |
| Coder | Accept | Both casts are issued identically rather than leaving one subtly different, so the next reader cannot conclude the header is optional |
| QA | Accept | Caught only because the fix was run against live Entra and the count did not move. A source-only check would have passed on the broken version |
| UX | Accept | The measured table is in the code comment, the changelog and here, because the failing forms return success and look correct |

### Note

The first assertion written for the guide matched the phrase `service principal`, which appears
in the alt text and twice in the prose. The mutation that removed the explanation was missed.
This is the sixth time an assertion has matched prose rather than the claim; it now matches a
sentence that occurs once.

### Documentation review

`guide/ask-astra.mjs` asks gpt-6-astra to judge a page on four fixed points — jargon used before
it is explained, rationale placed ahead of the command, missing steps, and length that carries no
instruction. Run against `BUSINESS-UNITS.md`, `ONBOARDING.md` and `SETUP.md` it returned 22, 24 and 24 items.

Most were style. Four were factual errors, each verified against the live tenant before changing
anything, and each now carries an assertion and a mutation:

| Claim as written | Measured |
|---|---|
| A user's Groups blade shows "two rows, one per axis" | It lists direct memberships. One account shows two rows, another shows one; both resolve identically. The business unit never appears |
| Changing a tier is "one membership edit" and "nothing in the gateway changes" | Two edits, and the entitlement lists change when the sync next runs. The sync is not automatic |
| Revocation is `az ad group member remove` from `claude-code-standard` | Leaves a premium or dual-tier member entitled, and leaves business-unit membership behind |
| A disabled Entra account revokes access "at that moment, ahead of any sync" | It stops new tokens. `validate-jwt` does not call Entra per request, so an issued token works until it expires |
| `SETUP.md` Options B and C produce "the same result" as the wizard | Only `Install-ClaudeGateway.ps1` writes `onboarding/claude-gateway.json`; it is the single writer in the repository. The portal button deploys the template alone |

The last is the one worth keeping in view: it reads as a security control and is not one.

## P16 acceptance criteria — close the bypass

Every control in this repository governs traffic that passes through the gateway. A principal
with data-plane access directly on the Foundry account skips all of it.

- [x] `scripts/Get-ClaudeBypass.ps1` lists them, graded by what the role actually grants
- [x] Roles are classified from their `dataActions`, not from a name
- [x] Inherited assignments are included
- [x] The gateway's own identity is excluded
- [x] Exits non-zero on a finding, so it works as a check and not only a report
- [x] `node .ironclad/gate.mjs --stage packet` exits 0

### What the work found

The audit in `SETUP.md` 4.2 checked one role name by hand and reported clean. The reference
deployment had **11 assignments that could call Foundry directly**, plus four with partial
data-plane access.

| | |
|---|---|
| `Foundry User` grants `Microsoft.CognitiveServices/*` | The same as `Cognitive Services User`. Three assignments held it, and no version of this documentation mentioned the role. Matching role names would never have found it — classifying by `dataActions` did |
| Inherited assignments were invisible | Two of the three `Foundry User` grants came from subscription and resource group scope. They apply to the Foundry account and do not appear without `--include-inherited` |
| The first draft audited the wrong account | `[0].name` picked `dhwani` rather than the account the gateway calls, and reported 2 findings instead of 11. The account is now read from the gateway's own API backend |

Not remediated here. Several holders are Defender, deployment and platform service principals, and
removing them autonomously would break things that are not this repository's to break. The finding
is that the access is ungoverned, which is the operator's decision to act on.

### Council

| Seat | Verdict | Note |
|---|---|---|
| Architect | Accept | The audit belongs next to the gateway because it measures the gateway's own assumption — that traffic arrives through it |
| Coder | Accept | Deriving the role set from `dataActions` is what makes this survive Azure adding another role, and it is the only reason `Foundry User` was found |
| QA | Accept | Verified against the live account, and the wrong-account bug was caught by reading the output rather than trusting the exit code |
| UX | Accept | Findings are graded rather than flattened, the removal command is printed with the scope the grant actually came from, and the output says to check a principal before deleting it |
| Security | Accept | Read-only. It reports and refuses to remediate, which is right: several holders are legitimate platform identities, and an audit that deletes things is one nobody runs twice |

## P17 acceptance criteria — named value writes fail loudly

Every named value write in this repository was made with `az apim nv update ... -o none 2>$null` and
no exit check. Named values cap at 4,096 characters, so past about 110 object ids the write failed,
the error went to `$null`, and the caller reported success.

- [x] `scripts/ApimNamedValue.ps1`, dot-sourced by both callers
- [x] An oversized value is refused before the request, naming the limit and how many entries fit
- [x] A failed write throws, carrying what the service actually said
- [x] No script writes a named value with errors suppressed — asserted, not just replaced once
- [x] The governance demo restores `tpm-standard` in a `finally`
- [x] Verified live: a valid write lands and reads back identical
- [x] `node .ironclad/gate.mjs --stage packet` exits 0

### What the work found

The sync was the obvious victim: past ~110 members a tier stops updating while the run reports
success. The second one was worse. `Show-Governance.ps1` lowers `tpm-standard` to 100 to demonstrate
throttling, then restores it — with the same suppressed error and no `finally`. A failed or
interrupted demo left the **standard tier capped at 100 tokens per minute**, silently. That restore
now runs in a `finally`, and refuses to lower the value at all if it could not first read what to
restore.

Negative-tested end to end. A 150-entry allow list is refused with "5551 characters, which is 1455
over the limit ... roughly 107 fit", and an invalid write throws with the service's own
`ValidationError`. Neither created anything.

### Council

| Seat | Verdict | Note |
|---|---|---|
| Architect | Accept | One helper, dot-sourced, matching the existing `Show-Banner.ps1` pattern. No new dependency |
| Coder | Accept | The detector forbids the old shape repo-wide rather than fixing two call sites, so it cannot creep back. It skips comment lines, which it had to learn after flagging its own documentation |
| QA | Accept | Both failure modes negative-tested against live Azure, and the live half asserts a read-back rather than trusting the exit code |
| UX | Accept | The refusal says how far over the limit it is and roughly how many entries fit, so an operator learns the real capacity instead of a rejected request |
| Security | Accept | Entitlement failing loudly is the point: the old behaviour froze an allow list while reporting success, which is a stale-authorization bug wearing a green tick. The helper never echoes a value |

## P18 acceptance criteria — the chargeback ledger

- [x] `analytics/chargeback-ledger.kql`, one row per request with the caller attached
- [x] Built on `ApiManagementGatewayLlmLog`, a log rather than a metric, so no cardinality cap
- [x] Identity joined on `context.RequestId`, carried deliberately
- [x] Streamed requests carry correct completion tokens
- [x] Cache recorded as null with `cache_tokens_known = false`, never zero
- [x] Message capture left off; the template deploys both halves of the switch
- [x] Verified live, and both failure modes negative-tested
- [x] `node .ironclad/gate.mjs --stage packet` exits 0

### What the work found

**The quota scalar excludes cache tokens.** Two identical calls with a cacheable 10,000-token
prompt wrote and then read 10,003 cache tokens; both metered 16. Documented behaviour — "counts
prompt and completion tokens only" — but the consequence had not been drawn. Against thirty days of
live usage here, weighted at Claude's published rates, **38.7% of the real cost weight is invisible
to the per-user budget**. That is a property of the shipped P11 and P12 budgets, not of this packet,
and it is why P21 may not express a dollar budget as a token quota.

**The quota scalar is also wrong for streaming**, reporting 11 tokens for a 41-token completion. The
built-in log gets the same request right. Since streaming is most of Claude Code, that alone
justifies the move.

**Neither APIM source carries the cache categories.** They are in the response body, but reading it
in `outbound` buffers the response and ends streaming. The gap is recorded rather than closed.

**Two switches, not one.** `GatewayLlmLogs` on the resource decides where rows land;
`largeLanguageModel.logs` on the API diagnostic decides whether they are produced. Enabling only the
first found an empty table with a full schema.

### The test that measured nothing

The first version asserted that the `actor` column was populated. The query fills it with
`coalesce(actor, "unattributed")`, so it was always populated and the assertion passed while every
row was in fact unattributed — the join had not worked at all. It was caught by reading the output
rather than the exit code. The assertion now requires a real caller, and breaking the join key turns
it red.

### Council

| Seat | Verdict | Note |
|---|---|---|
| Architect | Accept | The ledger is a built-in log, so the scale fix costs no new component. The one thing written is the identity the log lacks |
| Coder | Accept | The join key is carried rather than inferred, because the two candidate ids look similar and are not |
| QA | Accept | Both failure modes negative-tested: a broken join gives 0 attributed, and a zero in place of null fails. The first version of this test was vacuous and is recorded above rather than quietly fixed |
| UX | Accept | A row says whether it was streamed and where its numbers came from, so a report can state what it does not know instead of implying zero |
| Security | Accept | `RequestMessages` and `ResponseMessages` are left unset and asserted off. Enabling LLM logs without that check would have turned on prompt capture, which P15 keeps opt-in |

## P20–P22 acceptance criteria — business units

A business unit is an Entra security group registered with a monthly budget.
[ADR-0007](adr/0007-business-unit-model.md) records why: a group already exists, is already
governed, and already has joiner/mover/leaver handling, so membership needs no second roster.

- [x] **P20** A stable identifier separate from the display name. The registry key is the
      identifier; renaming the Entra group does not move spend to a new line
- [x] **P20** Transfer is group membership, deletion returns members to `unassigned`, and a
      developer in two business-unit groups takes the first in registry order
- [x] **P22** A unit that exhausts its budget gets a fourth, distinct `403` naming the unit;
      other units are unaffected; an unpriced unit is skipped rather than walled off
- [x] Unassigned developers are allowed by default, because nobody has a unit on the deployment
      that first installs this. `bu-unassigned=deny` is the target state once the report reads zero
- [x] Verified live: add, list, edit and remove all work; sync mapped 3 developers to `platform`;
      the report showed 544 tokens and 1 unassigned; `x-bu-quota-remaining: 2222222195` came back
      on a real request
- [x] No regression: an unassigned developer still received HTTP 200
- [x] 66 assertions in `tests/Test-BusinessUnits.ps1`, and every one of the 11 things they guard
      negative-tested by `tests/Test-BusinessUnitsNegative.ps1`
- [x] `./tests/Test-All.ps1` passes offline and with `-IncludeAzure`
- [x] `node .ironclad/gate.mjs --stage packet` exits 0
- [ ] **P21** remains open. The admin surface takes dollars and the report is categorised, but
      enforcement converts to one blended token figure at write time. "One counter cannot represent
      money" was P21's acceptance criterion and it is not met — see **U13**

### What the work found

| | |
|---|---|
| Five of ten mutations survived the first negative run | The colon-in-group-name case was never exercised, so `LastIndexOf` versus `IndexOf` made no difference to any assertion — the entire reason the split is on the last colon was untested |
| `'38\.7|cache'` is an alternation | The word "cache" alone satisfied it while the measured figure was wrong. Split into two assertions |
| A caveat in a `<# #>` help block is not a caveat | `-match` over raw file text cannot tell a comment from output. Comments are now stripped, and the terminal and JSON surfaces asserted separately — matching either one passed while the other had been deleted |
| A refusal check scoped to the whole file tail | `$policy.Substring(IndexOf(...))` matched `businessUnit` 200 lines above the message. Now scoped to the branch that builds it |
| `Test-Discovery.ps1` printed FAIL and exited 0 | It fell off the end without an exit code, so `Test-All` read whatever the last child process left. `Test-PreflightBothHosts.ps1` never checked its result at all — both were in a suite whose PASS was partly vacuous |
| `RESULT=` is printed even when nothing ran | A failed dot-source is non-terminating, so the child carried on and printed an empty value. The check now requires `True` or `False` |

### Council

| Seat | Verdict | Note |
|---|---|---|
| Architect | Accept | Membership comes from the group that already governs joiner/mover/leaver, so there is no second roster to reconcile. No new always-on component: three named values and a policy branch |
| Coder | Accept | The registry format has one owner, `ClaudeBusinessUnit.ps1`, read by the writer, the reader, the sync and the test. Splitting on the last colon is now covered by a case that fails on the first |
| QA | Accept | Eleven mutations, all caught — but only after five survived the first run and three assertions were found to measure nothing. That is recorded above rather than quietly fixed. Two unrelated suites that could not fail were repaired as a result |
| UX | Accept | Every command states list price and the cache gap in its own output, so a figure cannot be read without them. An edit reports the previous value alongside the new one |
| Security | Accept | No new identity path: membership is the same Graph read entitlement already does, under the same guard that refuses to empty a populated map. The refusal names the unit but not its members |

## P20c acceptance criteria — teams and tiers

[ADR-0008](adr/0008-teams-and-tiers.md) sets the model. A team is a business unit that names a
parent; tier is a separate axis attached by nesting the team group inside the tier group.

- [x] A request is charged to its team **and** to the unit above it. Verified live: one call
      returned `x-bu-quota-remaining: 1666666644` (ITES 1) and
      `x-bu-parent-quota-remaining: 5555555533` (MCAPS), with the org ceiling unchanged
- [x] Depth is capped at two and cycles are refused when written, not discovered when a budget
      stops cascading. Verified live: a third level was refused and **nothing was written** —
      the registry still held four units and no partial entry
- [x] Membership resolves to the most specific unit. Verified live: MCAPS transitively contains
      four people, all four were claimed by their teams first, and MCAPS itself took none
- [x] Tier resolves through nesting with no change to the tier mechanism. Verified live:
      `claude-code-premium` resolved to 2 members via the nested team, `claude-code-standard` to 5
- [x] Removing a business unit promotes its teams rather than leaving a dangling parent
- [x] A parent's reported figure is the roll-up of its own members and its teams, matching what
      its counter enforces
- [x] `./tests/Test-All.ps1` passes; 19 of 19 mutations caught
- [x] `node .ironclad/gate.mjs --stage packet` exits 0

### What the work found

| | |
|---|---|
| `transitiveMembers` returns nested **groups**, not only users | Measured on `claude-code-standard` with one team nested inside: 7 objects, 2 of them `#microsoft.graph.group`. `Get-GroupMemberOids` did not filter by type, so a group's object id would have been entitled and would have eaten a 4,096-character budget that holds about 110 ids. The defect predates teams and was unreachable only because nothing was nested |
| A client-side `@odata.type` filter would have been worse | Under the typed cast Graph omits that property, so the filter would have discarded every user. The cast `/transitiveMembers/microsoft.graph.user` filters server-side — measured 5 users, 0 groups |
| A test can assert the comment instead of the behaviour | The ordering check matched the prose explaining "most specific" and passed while the sort had been replaced with a constant. Fixed by extracting `Sort-ClaudeBuByDepth` and asserting against real data |
| A parent reads zero from the ledger | Members map to their team, so the roll-up has to be computed or the parent's percentage would contradict its own counter |

### Council

| Seat | Verdict | Note |
|---|---|---|
| Architect | Accept | A team is not a new object — it is a unit with a parent, so the ledger, the reports and the refusal path were unchanged. Tier stays orthogonal, so re-organising one axis does not disturb the other |
| Coder | Accept | The parent map is a second named value rather than a fourth registry field, because the group name may contain a colon and the budget is already found by splitting on the last one. A variable field count is where the previous defect in this area came from |
| QA | Accept | 19 mutations, all caught. One assertion was found matching a comment rather than behaviour, which is the same failure mode recorded in P20–P22 and was fixed by making the ordering a function with a data-driven test |
| UX | Accept | Teams are indented under their parent in both the writer and the reader, and the depth cap explains itself at the point of refusal rather than in documentation |
| Security | Accept | The typed cast closes a path where a group object could have been written into an entitlement list. No new identity surface: the same delegated Graph read as before |

## P26 acceptance criteria — the installer finds or creates a model

- [x] Claude deployments are listed with SKU and capacity, not just a name — a name alone does not
      say whether the deployment can carry the traffic
- [x] The operator chooses which models each tier may call, and the choice reaches the template.
      `modelsStandard` and `modelsPremium` were previously never passed at all
- [x] When no account has a Claude deployment, the installer offers to create one rather than
      stopping. Verified live: `foundry-plus-resource` has no Claude deployment and returned 12
      deployable Claude models, one row per model at its newest version
- [x] Selection matches on the model and publisher format, never the deployment name. Verified live
      on an account with **27 deployments**, of which 2 are Claude — OpenAI, OpenAI-OSS, Mistral and
      DeepSeek were all excluded
- [x] Quota is a distinct failure with its own advice, tested against both a quota error and an
      authorisation error
- [x] `./tests/Test-All.ps1` passes; 25 of 25 mutations caught
- [x] `node .ironclad/gate.mjs --stage packet` exits 0

### What the work found

**A redeploy would have wiped every business unit, team and membership.** The installer preserves
`allow-standard`, `allow-premium` and `quota-overrides` by reading them off the gateway and handing
them back. `bu-registry`, `bu-members` and `bu-parents` were never added to that list, and their
template parameters default to `,,` — so omitting them clears them.

Confirmed with `what-if` against the live gateway:

| Parameters | Planned `bu-registry` |
|---|---|
| Omitted, as the installer did | `,,` — four units and two teams gone |
| Supplied, as it now does | `,mcaps=…,gbb=…,ites-1=…,ites-2=…` unchanged |

Every existing "a redeploy preserves X" assertion checked only the Bicep expression, never that the
caller supplied the value. The template was willing to preserve and nothing proved anyone asked it
to. Both ends are now asserted.

| | |
|---|---|
| Azure lists a model once per version | `claude-sonnet-5` came back as v1 and v2. Offering the same model twice is a choice nobody wants; newest wins |
| `$args` is an automatic variable | Assigning to it inside a function is at best confusing. Renamed |
| A `quota` match on the installer proves nothing | The installer contains `quotaStandard`, `quotaOrg` and more, so the assertion passed on unrelated text. The classification moved into `Get-DeploymentFailureReason` and is tested against both error kinds |

### Council

| Seat | Verdict | Note |
|---|---|---|
| Architect | Accept | The installer already holds the subscription context needed to create a deployment. Sending the operator elsewhere to do it by hand was a gap in the installer, not a property of the gateway |
| Coder | Accept | Deployable models are read from the account rather than hard-coded, because what is offerable depends on region and entitlement, and a hard-coded list goes stale and then offers something that cannot be created |
| QA | Accept | 25 mutations, all caught. The quota assertion was found matching unrelated text in the installer and was replaced with a function tested against a quota error and an authorisation error |
| UX | Accept | SKU and capacity are shown because they are what an operator changes when a deployment cannot carry the load. Opus is excluded from standard by default with the reason given at the prompt |
| Security | Accept | No new permission: creating a deployment needs the Cognitive Services contributor rights the operator already needs to stand up the gateway, and failure states which right was missing |

## P24/P27 acceptance criteria — the Observe half

- [x] The client that made the call is recorded. Nothing in API Management carried it — measured
      2026-09-16, `AppRequests.Properties` held only API and service metadata, `ClientType` read
      `PC`, `ClientBrowser` was empty
- [x] The surface is **parsed** from the agent string, not matched against a list. Verified live
      with the real Claude Code CLI plus Desktop-, VS Code- and SDK-shaped agents, all five
      distinguishable in one query
- [x] The queries are callable functions. Verified the window parameter is honoured rather than
      pinned: `ClaudeChargeback()` 44 rows, `(ago(2h), now())` 5, `(ago(30d), now())` 44,
      `(ago(1m), now())` 0
- [x] The publisher refuses when a window line has moved, rather than shipping a function that
      ignores its arguments
- [x] A workbook exists, bound to one workspace, updating in place on re-run
- [x] It refuses to publish against a workspace without the functions. Verified: pointed at a
      second workspace it named the missing function and the script to run first
- [x] Every currency figure on the pane says list price and states the 38.7% cache gap
- [x] No always-on component added — a saved search and a workbook both store and run nothing
- [x] `./tests/Test-All.ps1` passes; 39 of 39 mutations caught
- [x] `node .ironclad/gate.mjs --stage packet` exits 0

### What the work found

| | |
|---|---|
| The obvious guess at the CLI's agent string was wrong | Claude Code 2.1.241 sends `claude-cli/2.1.241 (external, sdk-cli)` — `sdk-cli`, not `cli`. A classifier written from the guess would have bucketed the real CLI as "other" and looked correct doing it. The surface is now extracted from whatever follows `external,` |
| A classifier in policy is a redeploy; in KQL it is a query edit | The policy captures the fact and the query interprets it, so a client that changes its agent string costs nothing to accommodate |
| A portal link built from the management endpoint opens nothing | `https://management.azure.com/subscriptions/...` concatenated after `#@/resource` produced a link that looked plausible and went nowhere. The ARM path is now kept separate from the base URL |
| A workbook bound to the wrong workspace reads as no usage | It renders empty rather than erroring, so both publishers refuse to guess when a resource group holds more than one |

### Council

| Seat | Verdict | Note |
|---|---|---|
| Architect | Accept | Observe was the last box in the flow with nothing behind it. It is filled with metadata only — a saved search and a workbook — so the constraint of not adding an always-on bill of materials held |
| Coder | Accept | The `.kql` files stay the single source; the publisher rewrites only the window lines and refuses if it cannot find them. A copy of the query inside the publisher would have been a second thing to keep current |
| QA | Accept | 39 mutations, all caught. The parameter check was made non-vacuous by proving four different windows return four different counts — a pinned function returns the same number every time and passes a weaker test |
| UX | Accept | Both publishers list, publish and remove, and refuse with the name of the script to run first rather than an Azure error. The caveats sit on the pane, not in a footnote |
| Security | Accept | The agent string is a request header the caller already sends, truncated and stored beside data already held. No prompt content is captured and no new permission is needed |

## Commands that prove it```powershell./tests/Test-All.ps1                                    # 17 checks, offline
./tests/Test-All.ps1 -IncludeAzure                      # plus the seven that call Azure
./scripts/Get-ClaudeTelemetry.ps1                       # where this gateway logs, and whether metrics are on
./scripts/Get-ClaudeAnalytics.ps1 -Days 30              # the usage report
./scripts/Get-ClaudeBudget.ps1                          # effective limits and spend to date
./scripts/Get-ClaudeBusinessUnit.ps1                    # budgets, members and spend by business unit
./scripts/Publish-ClaudeQueries.ps1 -List               # the callable KQL functions
./scripts/Publish-ClaudeWorkbook.ps1 -List              # the Observe pane, and where it opens
./scripts/New-ClaudeCodePolicy.ps1 -Tier premium        # one managed-settings profile per tier
./scripts/Find-ClaudeUserData.ps1 -User <upn>           # what is held about one person
./scripts/Get-ClaudeBypass.ps1                          # who can skip the gateway entirely
./tests/Test-OrgCeilingLive.ps1 -ProveRefusal           # exhausts each budget, then restores it
./tests/Test-BusinessUnitsNegative.ps1                  # breaks each business-unit check and confirms it goes red
node .ironclad/gate.mjs --stage packet                  # definition of done
```

## Next

In flight on 2026-09-25, each on its own branch and merged when its gate passes:

- **P52 AUM (Azure Usage Management).** The terminal console renamed, redesigned as a
  dashboard, and independent of Turnstile (the gateway directly as a first-class backend, and the
  AUM service), with live redacted screens; then the end-to-end journeys driven from AUM on each
  backend: groups, unit and team, budgets, modes, and enforcement proven with real requests.
- **P55's journey.** AUM driving the AUM service on its dedicated test gateway, and the
  service's manager-only journey.

Merged on 2026-09-25: P54, the regional enterprise network edge ([above](#p54-the-enterprise-network-2026-09-25)),
which delivers the gateway's part of P49; P58 architecture generation; and P53 phase 2, the
manager-only journeys (**U21**).

Waiting on the owner:

- **One portal sign-in**, for one batch capture of every packet's portal pictures: run
  `node guide/auth.mjs` with `AZURE_TENANT` set, then the lead runs all `guide/captures/*.json`
  specs in one window with the original profile. P54's 24 edge pictures also need the owner to
  approve a short-lived redeployment of the evaluation edge, because it was removed.
- **Cost decisions on running test resources**: the Premium v2 test gateway (about $2,800 a month
  at list price), the dedicated AUM test gateway (Basic v2, about $150 a month), and the chargeback
  reports deployment ($29.70 a month standing).

Waiting on a tenant administrator: **U17** (Graph `GroupMember.Read.All`, so the apply job can
refresh membership itself) and **U19** (consent for Turnstile's web sign-in button). Neither
blocks use today: an admin's own delegated refresh and the consent-free Azure CLI sign-in work.

Planned: P47's endpoints in Turnstile, so AUM is complete on that backend too; P48, budgets and
overrides in the projection with one queue-driven writer; P14, the plugin marketplace, whose
acceptance U6 rewrote to immutable approved content rather than signing; and P19's installer
default (`cos-default`, `cos-upgrade`).

Fourteen unknowns are open: U2, U3, U8, U9, U10, U11, U13, U16, U17, U18, U19, U20, U21 and U22.

Outside the packet queue: an earlier audit found seven principals holding `Cognitive Services
User` directly on the Foundry account, which bypasses every budget here. Re-run the audit in
`SETUP.md` section 4.2.
