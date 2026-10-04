# ADR-0047: Lean installer phase 0 uses one answers schema, one preflight, and checkpoint step selection

- **Status:** Accepted for the unmerged `lean-installer` branch: the lead accepted the plan and contract on 2026-10-02, and P92 GREEN and REFACTOR implement them (decisions below). Merging needs the owner's approval.
- **Date:** 2026-10-02
- **Packet:** P92
- **Deciders:** owner (merge), lead (review), P92 builder

## Context

`Install-ClaudeGateway.ps1` exposes installer parameters at `Install-ClaudeGateway.ps1:31-146`.
`install-claude-gateway.sh` exposes its flag-backed inputs at `install-claude-gateway.sh:101-115`.
The guided flow accepts `-AnswersPath`, `-PlanOnly` and `-ApprovedPlanFingerprint` for a reviewed
plan and answer file (`docs/GUIDED-FLOW.md:122-172`). P91 supplies stable checkpoint step ids and
live verification before a skip (`scripts/ClaudeInstallCheckpoint.ps1:7-11`).

The customer session on 2026-10-01 showed the current failure mode: the installer asks many
questions, then stops at the first field or Azure error. The spike recommends phase 0 before a web
form: one answers contract, one read-only preflight, and selected step execution
(`docs/spikes/architecture-install-form-ui-spike.md`).

P91 raised the bash checkpoint suite's Test-All timeout to 900 s on this branch
(`docs/status/P91.md:9-11`, `docs/status/P91.md:246-248`). AGENTS.md treats loosening a budget as a
decision that needs an ADR and a stated reason (`AGENTS.md:62-63`).

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

A2. The schema covers every non-secret installer input from `Install-ClaudeGateway.ps1:31-146`, the
15 bash flags at `install-claude-gateway.sh:101-115`, and the guided-flow question keys declared
under `scripts/flow/*.ps1`.

A3. Prompt-only installer answers become named schema entries and installer parameters:
`RevocationWindowSeconds`, `TeamBudgetBehaviour`, `UnassignedDevelopers`, `DeveloperEstimate`,
`PendingClaudeDeployment`, and `BusinessUnits`.

A4. Business-unit and team answers are structured. Each item has `id`, `group`, optional `parent`,
`monthlyUsdBudget` and `mode`. `id` matches `^[a-z0-9-]+$`; `group` has no comma, colon or single
quote; `parent` permits two levels at most; `mode` is `Strict`, `Allowance` with `percent` 1-100, or
`Notify`. ADR-0008 sets the two-level model (`docs/adr/0008-teams-and-tiers.md`).

A5. The schema never contains secrets. `AddressCertificatePassword` remains a runtime parameter only
(`Install-ClaudeGateway.ps1:48`, `docs/spikes/architecture-install-form-ui-spike.md`).

A6. A drift test fails when installer parameters, bash flags, guided-flow question keys, prompt-only
answer names or the schema disagree.

A7. `-Preflight` and `--preflight` read answers, merge precedence, validate schema and cross-field
rules, run read-only Azure checks, print every result and exit nonzero if any required check fails.
Each line has `id`, `PASS` or `FAIL`, message and remedy. `-Json` emits the same records as JSON.

A8. Preflight checks reuse existing functions where they exist, including `Test-ClaudePrerequisites
-Mode Admin` (`Install-ClaudeGateway.ps1:354`, `scripts/Test-Prerequisites.ps1:27`).

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
P91 binding fields still refuse when they differ from the checkpoint (ADR-0046 decision 5,
`docs/adr/0046-installer-checkpoint-and-resume.md:295-331`).

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
   The merge of `main` at `cfb9dd7` brought P86's `-ProjectionRenewalImageDigest`,
   `-ProjectionRenewalEntryPoint` and `-ProjectionRenewalActionGroupResourceId`
   (`Install-ClaudeGateway.ps1:65-67`), which the drift test reported by name. They are answers, as
   `ProjectionReconcilerResourceId`, the fourth input that P86 admission requires
   (`Install-ClaudeGateway.ps1:167-171`), is: a digest of `sha256:` and 64 lower-case hexadecimal digits,
   a non-empty entry point, and an action group's resource ID in its request or response casing
   (`schemas/claude-gateway.answers.schema.json`; `docs/status/P92.md`, round 3).
2. **Two validators, one result.** `Test-ClaudeInstallerAnswers`
   (`scripts/ClaudeInstallerAnswers.ps1:293`) and `validate` (`scripts/install-answers.jq:87`) apply the
   same rules in the same order and report the same problems word for word;
   `tests/Test-InstallerAnswersSchema.ps1` checks one corpus with both. Both first scan the file's text
   with the same strict JSON automaton (`Get-ClaudeAnswersScan`, `scripts/ClaudeInstallerAnswers.ps1:76`;
   `scan`, `scripts/install-answers.jq:52`), because the parsers differ: PowerShell 7 `ConvertFrom-Json`
   accepts comments and trailing commas and keeps the last of two equal keys, and jq accepts `nan`. A
   file with a comment, a trailing comma, a single-quoted string, a repeated key, a leading zero, `NaN`
   or a second value is refused by both. The jq program gives the same output under jq 1.6, 1.7.1 and
   1.8.2 (`docs/status/P92.md`, GREEN (replacement)), and the bash preflight accepts jq 1.5 and later
   (`scripts/preflight.sh:80-88`).
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
   `scripts/ClaudeInstallerPreflight.ps1:125-201`; `preflight_run_`, `scripts/install-preflight.sh:222-286`).
   `Get-ClaudePreflightBlocking` (`scripts/ClaudeInstallerPreflight.ps1:98-101`) returns those checks for
   the result (`:199`) and for the guided flow (decision 9).
   - **Fail closed by construction (lead review of `cb2cd70`).** Every check starts NOT-RUN with reason
     `not-evaluated` (`scripts/ClaudeInstallerPreflight.ps1:133-134`). Only `Set-ClaudePreflightPass`
     (`:104-109`) makes it PASS, and only for a check with no problem, not set NOT-RUN by a branch, and with
     a message. The bash aggregator reports a check with no problem, no NOT-RUN line and no `pf_pass_` line
     that has a message as NOT-RUN `not-evaluated` (`scripts/install-preflight.sh:273-274`). A branch that
     sets nothing therefore fails the preflight. At `cb2cd70` every check started as PASS, so the lead's
     mutants M02 and B06, which remove the `target.tenant` pass line, left it PASS with an empty message
     (`docs/status/P92.md`, round 2). In every scenario of `tests/Test-InstallerPreflight.ps1` and
     `tests/Test-BashInstallerPreflight.ps1`, each PASS has a message and no check is `not-evaluated`.
     Both engines word a check left `not-evaluated` the same way (council round 1, UX): the message "the
     preflight did not evaluate this check, which is a defect of the preflight" and the remedy "Run the
     preflight from the latest checkout; if the check is still not evaluated, report it with this output."
   - **Output that is not JSON is an inconclusive read.** `az account show` output that is not JSON, or
     has no `tenantId`, is a FAIL of `target.tenant` ("did not return JSON", "returned no tenantId"), and
     the other Azure checks are NOT-RUN `prerequisite-failed` (`scripts/ClaudeInstallerPreflight.ps1:161-177`;
     `scripts/install-preflight.sh:231-248`). A Foundry account list that is not JSON is a FAIL of
     `foundry.account` (`scripts/ClaudeInstallerPreflight.ps1:243-252`; `scripts/install-preflight.sh:121-128`).
     A stop of `Test-ClaudePrerequisites`, which parses `az account show` itself
     (`scripts/Test-Prerequisites.ps1:166`), is a FAIL of `operator.adminPrereqs`
     (`scripts/ClaudeInstallerPreflight.ps1:75-85`).
   - **A subscription record is used only with its id and tenant (council round 1, Coder).** A record
     from `az account show --subscription` that is not a JSON object, whose `id` is missing, `null` or
     empty, or that has no `tenantId` is a FAIL of `target.subscription` ("subscription '<id>' is not
     readable by <user> (az account show returned no subscription id)", or "... no tenantId"), and the
     later Azure checks are NOT-RUN `prerequisite-failed`. With no `SubscriptionId` answered, a signed-in
     account without an `id` is the same FAIL ("the current subscription could not be read"). Each later
     read names the record's own `id` (`Get-ClaudePreflightRecordProblem`,
     `scripts/ClaudeInstallerPreflight.ps1:87-96`, used at `:215` and checked at `:224-225`;
     `pf_record_problem_`, `scripts/install-preflight.sh:48-53`, used at `:83` and checked at `:93-94`).
     At `cfb9dd7` such a record passed, and the later reads named `--subscription ''` (PowerShell) or
     `--subscription null` (bash).
6. **The preflight only reads.** Each read names the subscription with `--subscription`; the preflight
   runs no `az account set` (U87), no create, update, set, delete or assign call and no child script,
   and writes no checkpoint, lock or temporary file. `tests/Test-InstallerPreflight.ps1` and
   `tests/Test-BashInstallerPreflight.ps1` check the stub log of every scenario for such calls.
7. **One APIM reader for the preflight and the run (U82).** `Get-ClaudeApimReuseState`
   (`scripts/ClaudeInstallerPreflight.ps1:22-43`) reads the instance once through the P91 verdict reader
   `Invoke-ClaudeInstallAzRead` (`scripts/ClaudeInstallResume.ps1:5-18`): present, absent or
   inconclusive. `Get-ClaudeApimReuseProblems` (`scripts/ClaudeInstallerPreflight.ps1:45-61`) names a classic tier and a missing
   system-assigned identity with their remedies, and `Get-ClaudeApimReuseCandidates` (`scripts/ClaudeInstallerPreflight.ps1:63-73`) lists
   the instances the run's menu offers. The run's `-ExistingApimName` path and menu
   (`Install-ClaudeGateway.ps1:661-704`) call the same functions; `pf_apim_`
   (`scripts/install-preflight.sh:151-194`) is the bash twin through `ckpt_az_read_`. A list that cannot
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
   plan is applied only when that result is PASS (`Assert-FlowPreflight`, `Start-ClaudeGateway.ps1:152-166`, called before
   the first step at `:650`). The refusal names each FAIL check with its message and each NOT-RUN check that fails the
   preflight (`not-signed-in`, `prerequisite-failed`, `not-evaluated`) with its reason, adds their remedies, and nothing is
   written. At `cfb9dd7` it refused FAIL checks only, so a signed-out preflight, whose result is FAIL through NOT-RUN checks
   alone, was applied (council round 1, Architect). The Azure checks are NOT-RUN
   `not-answered` when the plan names no subscription, so an empty record reads nothing from Azure
   (P68), and `discovery-skipped` under `CLAUDE_FLOW_SKIP_AZ_DISCOVERY=1`. The flow copies each
   `<step>.<field>` answer onto the record (`Set-FlowAnswersOnRecord`, `Start-ClaudeGateway.ps1:168-176`), so the schema also
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
    (`Install-ClaudeGateway.ps1:1916-1917`; `install-claude-gateway.sh:459-460`). A step id that names no
    step refuses on one line that lists the installer's steps and ends with the command that lists them
    with their state, `./Install-ClaudeGateway.ps1 -ListSteps` or `./install-claude-gateway.sh --list-steps`
    (`Set-ClaudeInstallSelection`, `scripts/ClaudeInstallSteps.ps1:72-82`; `steps_select_`,
    `scripts/install-steps.sh:60-67`; council round 1, UX).
11. **Precedence.** A parameter or flag wins over the answers file, which wins over the checkpoint,
    which wins over the default (A12). The answers file's answers are bound as if passed, so the P91
    binding compares them with the checkpoint and refuses a mismatch, naming the field
    (`Install-ClaudeGateway.ps1:355-363`; `answers_apply_`, `scripts/install-answers.sh:41-64`). A file
    with a problem refuses the run on one line, before any Azure resource is read: the number of problems,
    the first problem with its remedy, "Nothing was changed.", and the command that lists every problem,
    `./Install-ClaudeGateway.ps1 -Preflight -AnswersPath '<file>'` or
    `./install-claude-gateway.sh --preflight --answers-file '<file>'` (`Import-ClaudeInstallerAnswers`,
    `scripts/ClaudeInstallerAnswers.ps1:398-426`; `scripts/install-answers.sh:44-52`; council round 1, UX).
12. **Progress stream.** `-ProgressPath` and `--progress-file` append one JSON object per line with
    `schemaVersion`, `time`, `runId`, `stepId`, `event`, `message` and `resumeCommand`, in that order.
    `time` is UTC (`yyyy-MM-ddTHH:mm:ssZ`); `runId` is the install checkpoint's; `event` is `started`,
    `completed`, `skipped-verified`, `warning`, `failed` or `refused`; `resumeCommand` is set on
    `warning` and `failed`. A step is `started` once per run, and both installers write the same
    messages (`Write-ClaudeInstallProgress` and `Write-ClaudeInstallStepEvent`,
    `scripts/ClaudeInstallSteps.ps1:29-61`; `progress_event_` and `progress_step_`,
    `scripts/install-steps.sh:24-45`). Each line is one write (U90). No secret is written to the stream,
    the checkpoint or an answers file.
    - **One redaction rule set (council round 1, Security).** Three rules remove a secret from free text:
      a JWT; `Bearer <token>`; and `name=value` or `name: value`, case-insensitive, for `sig`, `signature`,
      `AccountKey`, `SharedAccessKey`, `SharedAccessSignature`, `client_secret`, `clientSecret`,
      `password`, `pwd`, `secret`, `access_token` and `refresh_token`, where the value ends at `;`, `&`,
      white space, a quote or the end of the text. The value becomes `[redacted]`, and the name stays.
      Both engines hold the rules as the same JSON text (`Get-ClaudeInstallRedactionRules`,
      `scripts/ClaudeInstallResume.ps1:36-44`; `CKPT_REDACT_RULES`, `scripts/install-checkpoint.sh:36`)
      and apply them through `Protect-ClaudeInstallText` (`scripts/ClaudeInstallResume.ps1:46-54`) and the
      jq function `redact` (`CKPT_REDACT_JQ`, `scripts/install-checkpoint.sh:37`): to each progress event's
      `message` and `resumeCommand` (`scripts/ClaudeInstallSteps.ps1:34-36`; `scripts/install-steps.sh:27-29`),
      and to every preflight check's `message` and `remedy`, before the text or JSON report is printed
      (`scripts/ClaudeInstallerPreflight.ps1:193-196`; `scripts/install-preflight.sh:265-267`). At `cfb9dd7`
      only a JWT in the stream was redacted. The checkpoint keeps ADR-0046 decision 15: its writers
      serialise an allowlist of fields, and the rules cover free text, such as an error that a message
      quotes. `tests/Test-InstallerRedaction.ps1` checks that both engines hold the same rules and give
      the same text, character for character, over a corpus of the 14 shapes.
    - **The console (council round 2, Security).** The same rules apply to every line either installer
      prints on standard output or standard error from an error or a refusal: the top-level trap
      (`Install-ClaudeGateway.ps1:154-165`), `Stop-ClaudeInstall` (`scripts/ClaudeInstallCheckpoint.ps1:40-48`)
      and `ckpt_refuse_` (`scripts/install-checkpoint.sh:95-100`); the warning and failure lines,
      `Write-Warn2` and `Write-Bad` (`Install-ClaudeGateway.ps1:213-216`), `warn_` and `bad_`
      (`install-claude-gateway.sh:38-42`); and the lines that quote a live read's detail or a deployment's
      error, and the resume lines (`scripts/ClaudeInstallCheckpoint.ps1:612-613`, `:660`, `:675`, `:679`,
      `:690`; `scripts/ClaudeInstallResume.ps1:168`, `:171`, `:185`; `scripts/install-checkpoint.sh:402`,
      `:410`, `:496`, `:539`, `:566`, `:570`; `scripts/install-resume.sh:135`, `:139`, `:152`). An Azure
      CLI call whose error output the run shows goes through `Invoke-ClaudeInstallAzShown`
      (`scripts/ClaudeInstallResume.ps1:20-33`) or `ckpt_shown_` (`scripts/install-checkpoint.sh:47-52`):
      its standard output passes through, and its standard error is printed after the call with the rules
      applied. `ckpt_redact_` (`:41-44`) prints the text as given where jq is missing; the lines printed
      before the installer's jq check (`install-claude-gateway.sh:149-155`) quote no Azure CLI output.
      `az login` is not wrapped, because it writes its sign-in prompt to standard error while it waits
      (azure-cli `src/azure-cli-core/azure/cli/core/auth/identity.py`, `login_with_device_code`). While a
      call's standard error is read, the Azure CLI draws no progress indicator: azure-cli draws it with a
      humanfriendly `Spinner` on `sys.stderr` (`src/azure-cli-core/azure/cli/core/commands/progress.py`,
      `IndeterminateProgressBar`), and the spinner draws only when its stream is a terminal (humanfriendly
      `humanfriendly/terminal/spinners.py`, `Spinner`; both dev and master branches read 2026-10-03). The
      gateway deployment therefore shows the installer's lines before and after it and no spinner while it
      runs. At `c1ed585` these lines printed the error as given.
    - A file that cannot be written, such as a directory, refuses the run at startup on one line that
      ends "Give a writable file path, or run without -ProgressPath." (`--progress-file` in bash), before
      any Azure call (`Initialize-ClaudeInstallProgress`,
      `scripts/ClaudeInstallSteps.ps1:19-27`; `steps_start_`, `scripts/install-steps.sh:134-144`). Neither
      installer writes an event before that check passes, so a refusal before it, or of the file itself,
      writes none (`scripts/install-steps.sh:24-31`); at `cb2cd70` the bash refusal first tried to write its
      `refused` event to the file it refused.
13. **Business units from answers.** `Invoke-ClaudeInstallBusinessUnits`
    (`scripts/ClaudeInstallSteps.ps1:175-207`) writes units, then teams, through
    `scripts/Set-ClaudeBusinessUnit.ps1`. A unit whose receipt records its input hash and which
    `bu-registry` shows is not written again; a unit whose receipt matches while `bu-registry` lacks it is
    written again (`scripts/ClaudeInstallSteps.ps1:192`). A `bu-registry` that cannot be read stops the
    step on one line with the resume command, before any unit is written or skipped (`:185`). When a
    `usd-budgets` item's scope is not in notify mode, a dollar budget is enforced
    (`infra/policy.xml:533-570`, U88), and the run prints the `scripts/Sync-ClaudeUsdBudgets.ps1` command
    for the gateway (`Write-ClaudeInstallUsdReconcile`, `scripts/ClaudeInstallSteps.ps1:209-227`).
    `install-claude-gateway.sh` applies no business units.
    - **One group rule for both business-unit paths (council round 1, Security).**
      `Resolve-ClaudeInstallUnitGroup` (`scripts/ClaudeInstallSteps.ps1:159-173`) finds a unit's group by
      its exact name through `Find-ClaudeInstallGroupByName` (`scripts/ClaudeInstallResume.ps1:253-286`,
      the rule of ADR-0046 decision 11). One group of that name is reused; with none, the group is created;
      two groups of that name, or a read that fails, leave the group neither reused nor created. The
      answers path stops the step on one line with the resume command (`scripts/ClaudeInstallSteps.ps1:195-197`);
      the installer's attended prompt warns, names a remedy and asks for the next unit
      (`Install-ClaudeGateway.ps1:1795-1800`). Both then call `Set-ClaudeBusinessUnit.ps1` with
      `-SkipGroupCheck`, because the group is already resolved (`scripts/ClaudeInstallSteps.ps1:200`;
      `Install-ClaudeGateway.ps1:1814-1815`). At `cfb9dd7` the prompt read the group with
      `az ad group show --group <name>`. Azure CLI resolves that name with `displayName eq '<name>'` and,
      when no group matches, accepts a single `startswith(displayName,'<name>')` match (azure-cli
      `src/azure-cli/azure/cli/command_modules/role/_validators.py`, `validate_group`, dev branch, read
      2026-10-03), so `claude-bu-platform` could bind to a lone `claude-bu-platform-admins`. Main's scripts
      that use the same call, such as `scripts/Set-ClaudeDeveloper.ps1` and `scripts/Set-ClaudeBusinessUnit.ps1`,
      are outside P92; the lead logged them for the owner (`docs/status/P92.md`, round 3).
    - **A group name the schema refuses, at the prompt (council round 2, Coder).** Before the group
      lookup, the prompt checks the typed name against the answers schema's rule for a unit's group,
      `^[^',:]+$` at `c1ed585` (`schemas/claude-gateway.answers.schema.json:220-221`, which decision 17 extends): a name with a single quote, a
      comma or a colon prints the schema's message and remedy, writes no unit, and the prompt asks for the
      next unit, before any Azure CLI call names the group (`Install-ClaudeGateway.ps1:1783-1791`). At
      `c1ed585` the prompt sent such a name to `az ad group list`.
    - **The cmd.exe metacharacters (round 5, Security).** The group rule also refuses `& | < > ^ " % ( )`,
      which `cmd.exe` re-reads in an Azure CLI argument on Windows; decision 17 records this rule for every
      answer that reaches Azure CLI.
14. **The bash checkpoint suite runs as seven Test-All checks.** `tests/Test-BashInstallerCheckpoint.ps1`
    takes `-Shard i/7`; its checks sit in twelve groups, each run by one shard (`Test-ShardGroup`):
    `static` and `shell` (shard 0), `graph` and `untrusted` (1), `names` and `preexisting` (2), `resume`
    (3), `locks`, `receipts` and `gitbash` (4), `changes` (5) and `corrupt` (6). A shard whose groups rerun
    from the base scenario runs the base's first run itself, and each group copies only its own scenarios.
    Each shard's measured weight is at most half of the 600 s per-check timeout
    (`tests/test-all-durations.json`), so the 900 s registration of `b016b8d` is gone (A14, A16).
    `tests/Test-BashInstallerCheckpointShards.ps1` checks the partition and the weights.
    - **Seven shards, not two (council round 2, QA).** At `c1ed585` the suite ran as two shards, which
      took 408.4 s and 528.7 s alone on the builder's machine against weights of 225.8 s and 262.5 s,
      while Test-All runs up to four checks at once (`tests/Test-All.ps1:26`) with a 600 s limit per
      check. Alone, under the gate lock that the builder took for the measurement on 2026-10-03, the seven
      shards took 80.1, 77.1, 114.9, 124.8, 126.9, 120.7 and 124.6 s (`docs/status/P92.md`, round 4). On
      Windows the two real-mode cases, whose check is skipped there, are not run.
    - **The bash step-selection suite runs as three Test-All checks (council round 1, lead).** On
      `cfb9dd7` it took 363-411 s per run on the lead's machine, against the 600 s per-check timeout,
      while checks run in parallel during the gate. `tests/Test-BashInstallerStepSelection.ps1` takes
      `-Shard i/3`; its checks sit in five groups, and shard 0 runs `list` and `sync`, shard 1 `start` and
      `stream`, and shard 2 `prec`. Alone on the builder's machine the shards took 179.8, 84.7 and
      205.1 s, and the whole suite 349.7 s (`docs/status/P92.md`, round 3). Round 4 added a resume whose
      live reads quote every secret shape to `sync`, which took shard 0 to 249.8 s alone, and moved `sync`
      to shard 1; alone under the gate lock the three shards then took 133.3, 171.6 and 186.1 s
      (`docs/status/P92.md`, round 4). `tests/BashSuiteShards.ps1`
      holds the shard contract that the sharded suites share: each check sits in exactly one group,
      Test-All registers one check per shard at the default timeout, and each shard's weight is at most
      half of that timeout. `tests/Test-BashInstallerCheckpointShards.ps1`,
      `tests/Test-BashInstallerStepShards.ps1` and `tests/Test-BashInstallerPreflightShards.ps1` apply it.
    - **The bash preflight suite runs as two Test-All checks (council round 2, lead).** It took 244, 280
      and 289 s alone in the lead's runs. `tests/Test-BashInstallerPreflight.ps1` takes `-Shard i/2`:
      `core` holds the static checks, acceptance test 2, redaction, the text report and the not-evaluated
      probe, and `branches` holds the round-2 branches and the subscription records of round 3. The JSON
      shape, fail-closed and read-only checks run once per group. Alone under the gate lock the two
      shards took 93.1 and 78.2 s.
    - **The bash suites run in the parallel lane (round 5, `15ada4b`; council round 3).** Test-All runs a check
      registered with `-SerialLane` alone, and runs all such checks before the parallel ones
      (`tests/Test-All.ps1:380-399`). `15ada4b` registered the bash installer suites, their shards and the three
      shard-contract checks there, because on PR #2's Windows runners they failed while other checks ran and
      passed alone. Decision 16 found the cause, a child's output that the harness stopped reading. With the
      reader of decision 16, CI run `37219348012` passed all 12 shards with those 19 registrations in the
      parallel lane again, and they stay there (`tests/Test-All.ps1:217-246`): each check has its own TEMP and
      state directory (`tests/Test-All.ps1:138-140`), its installer scenarios their own copy of the files, stubs
      and HOME (`tests/BashInstallerHarness.ps1:251-298`, `tests/Test-BashInstaller.ps1:215-231`), and the
      library probes only read the checkout, so these checks share no mutable resource; ADR-0036 (option 3)
      rejected moving checks into the parallel lane without such isolation. In a Test-All run without shards the exclusive checks'
      weights summed to 2,724 s (38 checks) with them and sum to 1,193 s (19 checks) without them
      (`tests/test-all-durations.json`), against the gate's 3,600 s budget (ADR-0036). On the gate machine,
      with several bash suites at once, installer runs exceeded the harness's 300 s per run and Git Bash printed
      fork errors (P92 gate attempt 2 and its reproduction, U93 in [UNKNOWNS](../UNKNOWNS.md)); the route of
      P92's packet gate is the owner's decision ([ROADMAP](../ROADMAP.md)).
    - **The prices suite gives its runs 300 s (round 5, `a87c708`).** `tests/Test-BashInstaller.ps1` starts its
      22 installer runs at once and gives them 300 s together, the time the checkpoint harness gives each run
      (`tests/Test-BashInstaller.ps1:246`, `tests/BashInstallerHarness.ps1:304`); it was 150 s. With decision 16,
      the 22 runs took 50.2 s on CI (run `37207970008`, shard 9).
15. **The projection step's inputs (council round 2, Architect).** The install checkpoint records every
    answer the projection step passes to `scripts/Deploy-ClaudeProjection.ps1`. P86's
    `ProjectionRenewalImageDigest`, `ProjectionRenewalEntryPoint` and
    `ProjectionRenewalActionGroupResourceId` join `ProjectionReconcilerResourceId` among the recorded
    parameters (`scripts/ClaudeInstallCheckpoint.ps1:13-18`), as ADR-0046 decision 6 states for every
    parameter that is neither a run mode nor a secret. The step passes all four
    (`Install-ClaudeGateway.ps1:1732-1735`), so its input hash holds them, with the other answers it
    passes and its three templates (`Get-ClaudeInstallInputHash`, `scripts/ClaudeInstallCheckpoint.ps1:547-550`,
    `:557`); the binding compares the resource group, subscription and gateway (ADR-0046 decision 5). The
    gateway step's hash leaves the four out, because `infra/main.bicep` receives none of them (`:551`). A
    resume therefore passes the recorded values to the projection deployment, and a changed value runs the
    step again. `-FlipProjectionAfterCleanCompare` is a run mode and is not recorded; the step's live check
    reads the three deployments, which do not show a switch, so a run that asks for the switch runs the step
    again (`Install-ClaudeGateway.ps1:1712-1716`). P86's check of the switch's inputs runs before the
    answers file and the checkpoint are read (`Install-ClaudeGateway.ps1:167-171`), so a run with the switch
    passes them as parameters; `tests/Test-ProjectionCouncil.ps1:117-118` requires that refusal before any
    Azure CLI call. `tests/Test-InstallerAnswersDrift.ps1` checks that each parameter the answers schema
    lists for `Install-ClaudeGateway.ps1` is recorded by the checkpoint, as a parameter or prompt answer, or
    is a run option or a secret. At `c1ed585` the checkpoint recorded none of the three renewal inputs, and
    the projection step's hash held none of the four.
16. **The installer and flow harnesses read a child's output on a thread of its own (U92, PR #2 CI).** On
    Windows, .NET 10 redirects a child's standard output and standard error through synchronous anonymous
    pipes, so `ReadToEndAsync` holds a thread-pool worker for each pipe until the child closes it. The
    harnesses ran six children at once (the prices suite 22) and, 5 s after a child exited, recorded a read
    that had not finished as an empty string. On `windows-latest` (4 vCPUs, so a minimum of four workers)
    such reads had not started, and checks of startup refusals and of the `--what-if` region table failed
    with empty details (PR #2 runs `37110260005` to `37127982623`). Diagnostic run `37206003130` logged each
    such read with the pool at 5 to 17 threads and 4 to 24 work items queued, and its output arriving 0.1 to
    21.6 s later. `tests/ChildOutputRead.ps1` reads each pipe with `ReadToEnd` in a `LongRunning` task, which
    runs on a dedicated thread, and a read still open 60 s after its process exited throws, naming the stream,
    instead of returning part of the text. `tests/BashInstallerHarness.ps1`,
    `tests/InstallerCheckpointHarness.ps1`, `tests/Test-BashInstaller.ps1`, `tests/Test-FlowPermutations.ps1`,
    `tests/Test-FlowStart.ps1` and the Windows marker preflight of `tests/Test-InstallerPreflight.ps1` read
    through it. `tests/Test-ChildOutputRead.ps1` checks the reader with
    every pool worker busy and fails on any test that turns an unfinished read into an empty string.
17. **Answers that reach Azure CLI on Windows refuse what cmd.exe re-reads (round 5, Security; council round 3).**
    On Windows Azure CLI is the `az.cmd` shim, and `cmd.exe` treats `&`, `|`, `<`, `>`, parentheses and `^` as
    special characters that are to be escaped or quoted in an argument (cmd reference, ms.date 2025-05-23,
    fetched 2026-10-03: https://learn.microsoft.com/windows-server/administration/windows-commands/cmd).
    PowerShell quotes a native argument only when it holds a space, so an argument without one reaches
    `cmd.exe` as it is (`tests/Test-AzArguments.ps1:6-9`).
    - **The run.** `Assert-AzArgumentsSafe` (`Install-ClaudeGateway.ps1:324-339`) refuses `& | < > ^ ( ) " %` in
      twelve parameters before the run's first Azure CLI call (`:369-374`) and in the values the prompts set
      (`:1356-1361`). `-Preflight` returns before both (`:174-180`).
    - **The schema (round 5, `70f07c0`).** Four answers that the preflight passes to Azure CLI accepted these
      characters: `SubscriptionId` (`schemas/claude-gateway.answers.schema.json:63-64`), `StandardGroup` and
      `PremiumGroup` (`:142-147`) and a business unit's `group` (`:220-221`). Each refuses them now, in both
      validators, and the business-unit prompt reads the same group rule (`Install-ClaudeGateway.ps1:1786-1790`).
      `ProjectionRenewalEntryPoint`, which reaches `az container exec` when the projection is switched, refuses
      them as well (`schemas/claude-gateway.answers.schema.json:124`, council round 3). An answer that names a group with one of these characters is refused
      on every platform, although Azure CLI is a `cmd.exe` shim only on Windows.
    - **The preflight on Windows (council round 3).** The schema accepts parentheses in a resource group name
      (`schemas/claude-gateway.answers.schema.json:69`, `:72`) and any character in the publisher email (`:81`), which the run refuses on Windows. The
      preflight checks the twelve answers of the run's first call (`scripts/ClaudeInstallerPreflight.ps1:17-20`)
      with `Test-ClaudeInstallCmdText` (`scripts/ClaudeInstallResume.ps1:488-493`): each one that holds such a
      character is a problem of its own check, or of `answers.schema`, and is not read from Azure (`scripts/ClaudeInstallerPreflight.ps1:139-149`).
      The install checkpoint's reader applies the same rule to recorded answers
      (`scripts/ClaudeInstallCheckpoint.ps1:131`). `tests/Test-InstallerPreflight.ps1` compares the preflight's
      list with the keys of the run's first `Assert-AzArgumentsSafe` call.
    - **Tests.** `tests/Test-InstallerAnswersSchema.ps1` runs each refused value through both validators.
      `tests/Test-InstallerPreflight.ps1` runs the Windows preflight with a marker-writing `az.cmd` on `PATH`,
      requires each of the four values to be refused by its own rule and to write no marker, and, as a control,
      gives the payload straight to the shim, which writes the marker; it also requires the preflight to refuse
      `rg(dev)` and `r&d@contoso.com` without an Azure CLI call naming them. R6 of
      `tests/Test-InstallerBusinessUnitAnswers.ps1` types such a group name at the prompt.
    - **Outside P92.** Values read from Azure and passed back to Azure CLI are not checked, for example the named
      values the run reads before it deploys the gateway again (`Install-ClaudeGateway.ps1:1510-1532`, passed at
      `:1649-1669`); `main` has the same code (council round 3, Security note 1, `docs/ROADMAP.md`).

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
