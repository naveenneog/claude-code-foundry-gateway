# ADR-0047: Lean installer phase 0 uses one answers schema, one preflight, and checkpoint step selection

- **Status:** Accepted for the unmerged `lean-installer` branch: the lead accepted the plan and contract on 2026-10-02, and P92 GREEN and REFACTOR implement them (decisions below). Merging needs the owner's approval.
- **Date:** 2026-10-02
- **Packet:** P92
- **Deciders:** owner (merge), lead (review), P92 builder

## Context

`Install-ClaudeGateway.ps1` exposes installer parameters at `Install-ClaudeGateway.ps1:31-118`.
`install-claude-gateway.sh` exposes its flag-backed inputs at `install-claude-gateway.sh:310-324`.
The guided flow accepts `-AnswersPath`, `-PlanOnly` and `-ApprovedPlanFingerprint` for a reviewed
plan and answer file (`docs/GUIDED-FLOW.md:126-172`). P91 supplies stable checkpoint step ids and
live verification before a skip (`scripts/ClaudeInstallCheckpoint.ps1:7-11`).

The customer session on 2026-10-01 showed the current failure mode: the installer asks many
questions, then stops at the first field or Azure error. The spike recommends phase 0 before a web
form: one answers contract, one read-only preflight, and selected step execution
(`docs/spikes/architecture-install-form-ui-spike.md`).

P91 raised the bash checkpoint suite's Test-All timeout to 900 s on this branch
(`docs/STATUS.md:11-12`, `docs/STATUS.md:249`). AGENTS.md treats a budget loosening as a decision
that needs either an ADR or a shard split (`AGENTS.md:53-59`).

## Options considered

1. **Generated schema from current scripts.** This avoids duplicate field lists but keeps the
   installers and guided flow as the source, which conflicts with the phase-0 requirement that the
   answers contract is the source for both installers, the guided flow and the later UI.
2. **Hand-authored canonical JSON Schema with generated drift inventories.** The schema is the
   source. Tests generate inventories from PowerShell parameters, bash flags and flow question keys
   and fail when they disagree with the schema.
3. **Keep guided-flow `When` scriptblocks only.** Existing behavior is unchanged, but the UI cannot
   evaluate a PowerShell scriptblock.
4. **Replace every `When` scriptblock with data in phase 0.** The UI receives declarative conditions,
   but a full replacement risks breaking existing flow planning behavior while phase 0 is adding
   installer parity.
5. **Accept the 900 s bash checkpoint timeout with an ADR.** This records the local branch state, but
   it leaves the permanent suite slower instead of reducing it.
6. **Shard the bash checkpoint suite.** This keeps the detector and returns the per-check budget to
   the existing 600 s default.

## Decision

Phase 0 uses option 2. `schemas/claude-gateway.answers.schema.json` is hand-authored as the
canonical answers schema. A drift test generates four inventories and compares them with the schema:
PowerShell installer parameters, bash installer flags, guided-flow question keys and prompt-only
installer answers.

Conditional questions keep their current `When` scriptblocks for compatibility. Each conditional
schema entry also has a declarative `requires` clause. Phase 0 supports equality, membership and
presence checks. A question with `When` and no equivalent `requires` is a drift-test failure. A
condition that cannot be expressed by that grammar remains in PowerShell only and is recorded as an
unknown before implementation.

`-Preflight` and `--preflight` call the same check engine that the guided flow uses before plan
approval. `-PlanOnly` remains a plan and fingerprint operation; it invokes the shared preflight and
adds its results to the plan review. `-Preflight` returns only preflight results and never produces
an approved-plan fingerprint.

The 900 s bash checkpoint timeout is not accepted as a lasting budget. P92 adds RED names for a
bash checkpoint shard split, and the GREEN phase must either shard that suite or replace this ADR
section with a separate accepted timeout ADR before branch merge.

## Acceptance criteria

A1. The answers file validates against one JSON Schema. The schema has `$id`, `version`, `title`,
`properties`, `$defs`, `required`, `additionalProperties: false`, `requires` metadata and UI labels.

A2. The schema covers every non-secret installer input from `Install-ClaudeGateway.ps1:31-118`, the
15 bash flags at `install-claude-gateway.sh:310-324`, and the guided-flow question keys declared
under `scripts/flow/*.ps1`.

A3. Prompt-only installer answers become named schema entries and installer parameters:
`RevocationWindowSeconds`, `TeamBudgetBehaviour`, `UnassignedDevelopers`, `DeveloperEstimate`,
`PendingClaudeDeployment`, and `BusinessUnits`.

A4. Business-unit and team answers are structured. Each item has `id`, `group`, optional `parent`,
`monthlyUsdBudget` and `mode`. `id` matches `^[a-z0-9-]+$`; `group` has no comma, colon or single
quote; `parent` permits two levels at most; `mode` is `Strict`, `Allowance` with `percent` 1-100, or
`Notify`. ADR-0008 sets the two-level model (`docs/adr/0008-teams-and-tiers.md`).

A5. The schema never contains secrets. `AddressCertificatePassword` remains a runtime parameter only
(`Install-ClaudeGateway.ps1:43`, `docs/spikes/architecture-install-form-ui-spike.md`).

A6. A drift test fails when installer parameters, bash flags, guided-flow question keys, prompt-only
answer names or the schema disagree.

A7. `-Preflight` and `--preflight` read answers, merge precedence, validate schema and cross-field
rules, run read-only Azure checks, print every result and exit nonzero if any required check fails.
Each line has `id`, `PASS` or `FAIL`, message and remedy. `-Json` emits the same records as JSON.

A8. Preflight checks reuse existing functions where they exist, including `Test-ClaudePrerequisites
-Mode Admin` (`Install-ClaudeGateway.ps1:306-311`, `scripts/Test-Prerequisites.ps1:27`).

A9. Preflight check ids are stable:

| ID | Check | Source or rule |
|---|---|---|
| `answers.schema` | JSON Schema validity | A1-A6 |
| `answers.crossField` | one-choice and dependency rules | schema `requires` |
| `target.tenant` | tenant id matches current sign-in | P91 binding rule |
| `target.subscription` | subscription id exists and is selected | P91 binding rule |
| `operator.adminPrereqs` | admin prerequisites | `Test-ClaudePrerequisites -Mode Admin` |
| `foundry.account` | Foundry account exists | installer discovery |
| `foundry.deployments` | Claude deployments exist or pending deployment is specified | installer model discovery |
| `apim.nameAvailability` | new APIM name is available | ARM name check |
| `apim.existingSku` | existing APIM is v2 and acceptable | reuse path |
| `apim.existingIdentity` | existing APIM has system-assigned identity | customer field error |
| `entra.groupNames` | exact group-name match under P91 code-point rule and no single quote | ADR-0046 decision 11 |
| `businessUnits.ids` | ids are lower-case and unique | A4 |
| `businessUnits.depth` | parent depth is at most two | ADR-0008 |
| `address.inputs` | company address fields complete when address is custom | ADR-0033 |

A10. `-ListSteps -Json` and `--list-steps --json` list P91 step ids, titles, dependencies and current
checkpoint state. `-ListSteps` without JSON prints the same ids and titles for operators.

A11. `-Steps <ids>` and `--steps <ids>` execute only selected steps. A selected step whose prerequisite
is not completed and verified live refuses on one line naming the prerequisite. The prerequisite
state is read through P91 live verification, not the checkpoint alone.

A12. Re-running step X is a scoped invocation: P91 checkpoint answers and live reads still bind the
run, and selected step input hashes decide whether a completed step must run again.

A13. Precedence is explicit parameter, answers file, recorded checkpoint answers, defaults, prompts.
P91 binding fields still refuse when they differ from the checkpoint (`docs/adr/0046-installer-checkpoint-and-resume.md:5`).

A14. PowerShell and bash reach parity. Bash remains 3.2-compatible: no `mapfile`, no associative
arrays, and no GNU-only flags.

A15. Phase 1 receives four machine interfaces from phase 0: the JSON Schema, preflight JSON, step-list
JSON and a newline-delimited progress stream of step id, state, message and UTC timestamp.

A16. The bash checkpoint check is sharded or a separate accepted ADR records a continued timeout
increase before this branch can merge.

## RED test names

The RED phase adds these tests before product code:

| Test file | RED scenario names |
|---|---|
| `tests/Test-InstallerAnswersSchema.ps1` | `schema-covers-powershell-parameters`, `schema-covers-bash-flags`, `schema-covers-flow-keys`, `schema-covers-prompt-only-answers`, `schema-rejects-secret-answers`, `schema-validates-business-unit-tree`, `schema-requires-declarative-conditions` |
| `tests/Test-InstallerPreflight.ps1` | `preflight-reports-all-failures`, `preflight-json-shape`, `preflight-reuses-admin-prerequisites`, `preflight-fails-existing-apim-without-identity`, `preflight-rejects-group-single-quote`, `preflight-rejects-uppercase-business-unit`, `preflight-checks-address-inputs` |
| `tests/Test-BashInstallerPreflight.ps1` | `bash-preflight-reports-all-failures`, `bash-preflight-json-shape`, `bash-preflight-uses-same-schema`, `bash-preflight-keeps-bash-32-syntax` |
| `tests/Test-InstallerStepSelection.ps1` | `liststeps-json-names-checkpoint-state`, `selected-step-refuses-unverified-prerequisite`, `selected-step-reruns-with-p91-live-check`, `selected-step-keeps-binding-refusal`, `precedence-parameter-answers-checkpoint-default` |
| `tests/Test-BashInstallerStepSelection.ps1` | `bash-liststeps-json-names-checkpoint-state`, `bash-selected-step-refuses-unverified-prerequisite`, `bash-selected-step-reruns-with-p91-live-check`, `bash-precedence-matches-powershell` |
| `tests/Test-GuidedFlowAnswersSchema.ps1` | `planonly-includes-shared-preflight`, `answerspath-validates-with-schema`, `approved-fingerprint-binds-preflighted-plan`, `noninteractive-answers-precedence` |
| `tests/Test-BashInstallerCheckpointShards.ps1` | `bash-checkpoint-shards-cover-every-case-once`, `bash-checkpoint-shard-loads-under-default-timeout` |

## Implementation decisions (P92 GREEN and REFACTOR, 2026-10-02)

1. **One schema, three consumers.** `schemas/claude-gateway.answers.schema.json` (JSON Schema 2020-12
   keywords, `version` 1, `additionalProperties: false`) names each answer by its installer name.
   `x-appliedBy` lists the programs that apply it, `x-bashFlag` its bash flag and `x-flowKeys` its
   guided-flow keys. Two pattern properties hold `schemaVersion` and `models.tiers.<deployment>`.
   `x-secrets` lists `AddressCertificatePassword`, which no answers file holds (A5); `x-runControls`
   lists the switches that are not answers; `x-preflightChecks` lists the 14 check ids in report order.
2. **Two validators, one result.** `Test-ClaudeInstallerAnswers`
   (`scripts/ClaudeInstallerAnswers.ps1:293`) and `validate` (`scripts/install-answers.jq:87`) apply the
   same rules in the same order and report the same problems word for word;
   `tests/Test-InstallerAnswersSchema.ps1` checks one corpus with both. Both first scan the file's text
   with the same strict JSON automaton (`Get-ClaudeAnswersScan`, `scripts/ClaudeInstallerAnswers.ps1:76`;
   `scan`, `scripts/install-answers.jq:52`), because the parsers differ: PowerShell 7 `ConvertFrom-Json`
   accepts comments and trailing commas and keeps the last of two equal keys, and jq accepts `nan`. A
   file with a comment, a trailing comma, a single-quoted string, a repeated key, a leading zero, `NaN`
   or a second value is refused by both. The jq program gives the same output under jq 1.6, 1.7.1 and
   1.8.2 (`docs/STATUS.md`, P92 GREEN), and the bash preflight accepts jq 1.5 and later
   (`scripts/preflight.sh:80-86`).
3. **Each problem names its check.** A pattern problem names the property's `x-checkId`, a
   business-unit tree problem `businessUnits.ids` or `businessUnits.depth`, and a type, enum, range,
   unknown-name, secret or consumer problem `answers.schema`. An answer that a program does not apply is
   a problem for that program ("X is applied by A and B; C does not apply it"), and its value is still
   checked.
4. **`requires` refuses a contradiction only.** A `requires` clause holds presence, equality or
   membership conditions over other answers (A1). It refuses an answer only when the condition's answer
   is given and contradicts it (`Test-ClaudeAnswersHolds`, `scripts/ClaudeInstallerAnswers.ps1:170`);
   an answer the run asks for later is not assumed. `x-crossField` holds the rules between answers that
   `answers.crossField` reports (`Get-ClaudeAnswersCrossField`, `scripts/ClaudeInstallerAnswers.ps1:182`).
5. **PASS, FAIL or NOT-RUN.** A NOT-RUN check carries a reason. `not-signed-in`, `prerequisite-failed`
   and `not-evaluated` fail the preflight; `not-applicable`, `not-answered` and `discovery-skipped`
   do not. A check that did not run never passes (P91 R1). The preflight exits 0 only when no check
   fails and none is NOT-RUN for a failing reason (`Invoke-ClaudeGatewayPreflight`,
   `scripts/ClaudeInstallerPreflight.ps1:103-164`; `preflight_run_`, `scripts/install-preflight.sh:208-271`).
   - **Fail closed by construction (lead review of `cb2cd70`).** Every check starts NOT-RUN with reason
     `not-evaluated` (`scripts/ClaudeInstallerPreflight.ps1:111`). Only `Set-ClaudePreflightPass`
     (`:84-89`) makes it PASS, and only for a check with no problem, not set NOT-RUN by a branch, and with
     a message. The bash aggregator reports a check with no problem, no NOT-RUN line and no `pf_pass_` line
     that has a message as NOT-RUN `not-evaluated` (`scripts/install-preflight.sh:258-259`). A branch that
     sets nothing therefore fails the preflight. At `cb2cd70` every check started as PASS, so the lead's
     mutants M02 and B06, which remove the `target.tenant` pass line, left it PASS with an empty message
     (`docs/STATUS.md`, P92 round 2). In every scenario of `tests/Test-InstallerPreflight.ps1` and
     `tests/Test-BashInstallerPreflight.ps1`, each PASS has a message and no check is `not-evaluated`.
   - **Output that is not JSON is an inconclusive read.** `az account show` output that is not JSON, or
     has no `tenantId`, is a FAIL of `target.tenant` ("did not return JSON", "returned no tenantId"), and
     the other Azure checks are NOT-RUN `prerequisite-failed` (`scripts/ClaudeInstallerPreflight.ps1:127-143`;
     `scripts/install-preflight.sh:217-234`). A Foundry account list that is not JSON is a FAIL of
     `foundry.account` (`scripts/ClaudeInstallerPreflight.ps1:201-210`; `scripts/install-preflight.sh:107-114`).
     A stop of `Test-ClaudePrerequisites`, which parses `az account show` itself
     (`scripts/Test-Prerequisites.ps1:166`), is a FAIL of `operator.adminPrereqs`
     (`scripts/ClaudeInstallerPreflight.ps1:71-81`).
6. **The preflight only reads.** Each read names the subscription with `--subscription`; the preflight
   runs no `az account set` (U87), no create, update, set, delete or assign call and no child script,
   and writes no checkpoint, lock or temporary file. `tests/Test-InstallerPreflight.ps1` and
   `tests/Test-BashInstallerPreflight.ps1` check the stub log of every scenario for such calls.
7. **One APIM reader for the preflight and the run (U82).** `Get-ClaudeApimReuseState`
   (`scripts/ClaudeInstallerPreflight.ps1:18-39`) reads the instance once through the P91 verdict reader
   `Invoke-ClaudeInstallAzRead` (`scripts/ClaudeInstallResume.ps1:5-18`): present, absent or
   inconclusive. `Get-ClaudeApimReuseProblems` (`scripts/ClaudeInstallerPreflight.ps1:41-57`) names a classic tier and a missing
   system-assigned identity with their remedies, and `Get-ClaudeApimReuseCandidates` (`scripts/ClaudeInstallerPreflight.ps1:59-69`) lists
   the instances the run's menu offers. The run's `-ExistingApimName` path and menu
   (`Install-ClaudeGateway.ps1:652-698`) call the same functions; `pf_apim_`
   (`scripts/install-preflight.sh:137-180`) is the bash twin through `ckpt_az_read_`. A list that cannot
   be read offers no instance and says so.
8. **The run warns where the preflight fails.** A reused instance without a system-assigned identity
   is a FAIL of `apim.existingIdentity`, with the portal toggle as its remedy (U86). The run prints the
   same message and remedy as a warning and continues: a refusal would change the accepted P91 S2 path,
   in which the deployment shows the ARM identity error and the rerun after the toggle succeeds. A
   classic tier refuses in both.
9. **The guided flow runs the installer's preflight.** `-AnswersPath` is checked against the schema as
   `Start-ClaudeGateway.ps1` reads it; a file with an `answers.schema` problem is refused before any plan
   (`Read-FlowAnswers`, `Start-ClaudeGateway.ps1:109-130`), and the preflight of the plan reports the
   other problems. A plan that runs the installer without a console carries the installer's preflight in
   its data, so the fingerprint binds the result (`Invoke-FlowPreflight`, `Start-ClaudeGateway.ps1:134-150`), and an approved
   plan with a FAIL is not applied (`Assert-FlowPreflight`, `Start-ClaudeGateway.ps1:152-159`). The Azure checks are NOT-RUN
   `not-answered` when the plan names no subscription, so an empty record reads nothing from Azure
   (P68), and `discovery-skipped` under `CLAUDE_FLOW_SKIP_AZ_DISCOVERY=1`. The flow copies each
   `<step>.<field>` answer onto the record (`Set-FlowAnswersOnRecord`, `Start-ClaudeGateway.ps1:161-169`), so the schema also
   lists an answer no question asks, `models.priceBookPath` (`scripts/flow/Models.ps1:13-15`), and a
   field a step records itself, such as `network.approvedFingerprint` (`scripts/flow/Network.ps1:40`), is
   refused as not an answer.
10. **Steps and their prerequisites.** Both installers list the same pairs: `gateway-deployment` needs
    `resource-group`; `company-address`, `projection`, `business-units`, `onboarding-package` and
    `verify` need `gateway-deployment`; `sync` needs `gateway-deployment` and `entra-groups`
    (`scripts/ClaudeInstallSteps.ps1:8-12`; `steps_deps_`, `scripts/install-steps.sh:10-16`, for the
    five bash steps). `-Steps` and `--steps` refuse on one line unless each prerequisite outside the
    selection is completed in the checkpoint and verified live (`Assert-ClaudeInstallPrerequisites`,
    `scripts/ClaudeInstallSteps.ps1:103-131`; `steps_prereqs_`, `scripts/install-steps.sh:87-108`).
    With a selection the checkpoint is kept, and the run stops after the selected steps
    (`Install-ClaudeGateway.ps1:1886`; `install-claude-gateway.sh:457`).
11. **Precedence.** A parameter or flag wins over the answers file, which wins over the checkpoint,
    which wins over the default (A12). The answers file's answers are bound as if passed, so the P91
    binding compares them with the checkpoint and refuses a mismatch, naming the field
    (`Install-ClaudeGateway.ps1:347-353`; `answers_apply_`, `scripts/install-answers.sh:41-62`).
12. **Progress stream.** `-ProgressPath` and `--progress-file` append one JSON object per line with
    `schemaVersion`, `time`, `runId`, `stepId`, `event`, `message` and `resumeCommand`, in that order.
    `time` is UTC (`yyyy-MM-ddTHH:mm:ssZ`); `runId` is the install checkpoint's; `event` is `started`,
    `completed`, `skipped-verified`, `warning`, `failed` or `refused`; `resumeCommand` is set on
    `warning` and `failed`. A step is `started` once per run, and both installers write the same
    messages (`Write-ClaudeInstallProgress` and `Write-ClaudeInstallStepEvent`,
    `scripts/ClaudeInstallSteps.ps1:29-61`; `progress_event_` and `progress_step_`,
    `scripts/install-steps.sh:24-45`). Each line is one write (U90), and a JWT-shaped value in a message
    is replaced by `[redacted]` (ADR-0046 decision 15). No secret is written to the stream, the
    checkpoint or an answers file. A file that cannot be written, such as a directory, refuses the run
    at startup on one line, before any Azure call (`Initialize-ClaudeInstallProgress`,
    `scripts/ClaudeInstallSteps.ps1:19-27`; `steps_start_`, `scripts/install-steps.sh:134-144`). Neither
    installer writes an event before that check passes, so a refusal before it, or of the file itself,
    writes none (`scripts/install-steps.sh:24-31`); at `cb2cd70` the bash refusal first tried to write its
    `refused` event to the file it refused.
13. **Business units from answers.** `Invoke-ClaudeInstallBusinessUnits`
    (`scripts/ClaudeInstallSteps.ps1:159-197`) writes units, then teams, through
    `scripts/Set-ClaudeBusinessUnit.ps1`. Each group is found by the name rule of ADR-0046 decision 11,
    or created, before its unit is written. A unit whose receipt records its input hash and which
    `bu-registry` shows is not written again; a unit whose receipt matches while `bu-registry` lacks it is
    written again (`scripts/ClaudeInstallSteps.ps1:176`). A `bu-registry` that cannot be read stops the
    step on one line with the resume command, before any unit is written or skipped (`:169`). When a `usd-budgets` item's scope is not in notify mode, a
    dollar budget is enforced (`infra/policy.xml:533-570`, U88), and the run prints the
    `scripts/Sync-ClaudeUsdBudgets.ps1` command for the gateway (`Write-ClaudeInstallUsdReconcile`,
    `scripts/ClaudeInstallSteps.ps1:199-217`). `install-claude-gateway.sh` applies no business units.
14. **The bash checkpoint suite runs as two Test-All checks.** `tests/Test-BashInstallerCheckpoint.ps1`
    takes `-Shard i/2`; its checks sit in four groups (`static`, `first`, `resume`, `corrupt`), each run
    by one shard (`Test-ShardGroup`). Each shard's measured weight is at most half of the 600 s
    per-check timeout (`tests/test-all-durations.json`), so the 900 s registration of `b016b8d` is gone
    (A14, A16). `tests/Test-BashInstallerCheckpointShards.ps1` checks the partition and the weights.

## Consequences

+ The UI, guided flow and both installers consume the same answers contract.
+ A failed preflight produces a complete remediation list before any Azure write.
+ Step selection is bounded by P91 checkpoint binding and live verification.
+ The schema becomes a reviewed compatibility surface and needs versioning.
+ The generated drift inventories become part of the packet gate.
− Existing flow questions need parallel declarative condition metadata while the scriptblock path
  remains for compatibility.
− Some preflight checks depend on Azure read permissions: a read that is refused is a FAIL (inconclusive),
  and a check that needs it is NOT-RUN, so a missing permission and a missing resource read differently.
− Bash needs JSON and schema handling without Bash 4 features.

## How we'd know this was wrong

- A UI cannot render a condition represented by `requires`, or a condition in `When` cannot be
  expressed without reintroducing script execution.
- A support case shows `-PlanOnly` and `-Preflight` disagree on the same answers and estate.
- A selected step changes Azure state before a missing prerequisite is named.
- A new installer parameter or flow question reaches `main` without a schema and drift-test failure.
- The bash checkpoint shard split hides a test or depends on execution order.
