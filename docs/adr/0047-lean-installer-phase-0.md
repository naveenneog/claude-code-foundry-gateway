# ADR-0047: Lean installer phase 0 uses one answers schema, one preflight, and checkpoint step selection

- **Status:** Proposed. P92 PLAN and CONTRACT, 2026-10-02.
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

## Consequences

+ The UI, guided flow and both installers consume the same answers contract.
+ A failed preflight produces a complete remediation list before any Azure write.
+ Step selection is bounded by P91 checkpoint binding and live verification.
+ The schema becomes a reviewed compatibility surface and needs versioning.
+ The generated drift inventories become part of the packet gate.
− Existing flow questions need parallel declarative condition metadata while the scriptblock path
  remains for compatibility.
− Some preflight checks still depend on Azure read permissions and can return `WARN` or `FAIL` from
  authorization, not from target absence.
− Bash needs JSON and schema handling without Bash 4 features.

## How we'd know this was wrong

- A UI cannot render a condition represented by `requires`, or a condition in `When` cannot be
  expressed without reintroducing script execution.
- A support case shows `-PlanOnly` and `-Preflight` disagree on the same answers and estate.
- A selected step changes Azure state before a missing prerequisite is named.
- A new installer parameter or flow question reaches `main` without a schema and drift-test failure.
- The bash checkpoint shard split hides a test or depends on execution order.
