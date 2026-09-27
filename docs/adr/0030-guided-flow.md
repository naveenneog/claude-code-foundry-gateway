# ADR-0030: One guided flow sets up, updates and changes a deployment from one decision record

- **Status:** Accepted; amended by [ADR-0032](0032-guided-flow-starts-at-once.md) for discovery and for the `Foundation` step in a console (2026-09-27)
- **Date:** 2026-09-26
- **Packet:** P66
- **Deciders:** claude-code-foundry-gateway maintainers

## Context

Every feature is built and tested live, but an administrator reaches them through separate
scripts: `Install-ClaudeGateway.ps1` (SKU, models, groups, tiers, entitlement store, Desktop
sign-in), `New-ClaudeNetworkEdge.ps1` (network edge), `Select-ClaudeFinOpsTooling.ps1`,
`Deploy-ClaudeAumService.ps1`, `Connect-ClaudeTurnstile.ps1`, `Install-ClaudeAum.ps1` (FinOps),
`Sync-ClaudeUsdBudgets.ps1` (dollar budgets, on demand only), `Publish-ClaudeWorkbook.ps1`
(one workbook at a time), `New-ClaudeChargebackReport.ps1` (reports), `New-ClaudeCodePolicy.ps1`
(device profiles) and `Test-ClaudeHealth.ps1`. Nothing updates a deployment made by an older
release; there is no path from named values to the Cosmos projection except running the projection
deployer by hand; and no script diagnoses an administrator's or a developer's setup end to end.
The owner asked on 2026-09-26 for one guided flow that sets up, updates, upgrades tiers, migrates
the entitlement store, configures AUM or Turnstile, deploys the workbook collection and reports,
and ends with a guide to using what was set up: "should be like a product".

## Options considered

1. **One more wrapper script that calls the others in order.** Quick, but each script still asks
   its own questions, there is no single review, a failure halfway leaves no record of what was
   done, and "change one decision later" has nowhere to live.
2. **Rewrite the scripts into one program.** Replaces tested code paths that were each proven live.
3. **An orchestrator over step modules that share one decision record and one plan format.** The
   existing scripts stay the implementation; each gains a module that plans without writing,
   applies without prompting, and verifies. The orchestrator asks every question once, shows one
   review with the combined cost, applies in dependency order and records each step as it
   completes, so a rerun resumes.

## Decision

Option 3. `Start-ClaudeGateway.ps1` is the one entry point, with actions `Setup`, `Update`,
`Change`, `Diagnose`, `Guide` and `Status` (a menu when run interactively without `-Action`).

**Decision record.** `onboarding/claude-gateway.json` stays the record (git-ignored; it holds the
tenant's own values). It gains `schemaVersion: 2`, `release` (the repository version and commit
that last applied it), `decisions` and `history`. Existing fields keep their meaning, and fields a
writer does not know are preserved. `decisions` holds `sku`, `network`, `entitlementStore`,
`desktopSignIn`, `finops` (`tool`: `None | Direct | AumService | Turnstile | TurnstileAum`),
`budgets` (`currency`: `tokens | usd`, `reconcile`: `none | job | aum-service`), `monitoring`,
`reports` and `deviceProfiles`. `history` appends one entry per applied step: UTC time, action,
decision, from, to, the signed-in principal and the commit.

**Step modules.** Each step is `scripts/flow/<Step>.ps1`, dot-sourced, exposing:

- `Get-ClaudeFlowStepInfo`: name, title, the decision key it owns, and the steps it depends on.
- `Get-ClaudeFlowStepPlan -Record -Discovery`: the plan, with no writes. A plan is
  `New-ClaudeFlowPlan` from `scripts/flow/FlowContract.ps1`: actions (verb, target, detail),
  costs (item, monthly USD, source, retrieval time; prices from the Azure Retail Prices API
  helpers that already exist), implications, required roles, whether it is reversible, and how.
- `Invoke-ClaudeFlowStep -Record -Plan`: applies the plan without prompting, idempotently, and
  returns the record fields it changed.
- `Test-ClaudeFlowStep -Record`: live verification, returning named checks with pass or fail.

All questions are asked by the orchestrator, from discovered options through `ClaudeChoice.ps1`,
before anything is written. The combined plan is shown once with its monthly cost and
implications; its fingerprint (SHA-256 of the canonical plan JSON) is confirmed interactively, or
passed as `-ApprovedPlanFingerprint` without a console, as `New-ClaudeNetworkEdge.ps1` does.

**Steps.** `Foundation` (the installer), `Entitlement` (named values or projection, including
migration), `Network`, `FinOps`, `Budgets` (price book and a scheduled reconciler for dollar
budgets without the AUM service), `Monitoring` (the whole workbook collection), `Reports`,
`DeviceProfiles` (per-tier MDM profiles and the developer handover), `Verify` (step checks,
`Test-ClaudeHealth.ps1`, one real request) and `Guide` (a generated `onboarding/HOW-TO-USE.md` for
this deployment's administrators, developers and FinOps users).

**Update and change.** `Update` compares `release` with the repository and applies the ordered
release migrations under `scripts/flow/migrations/`, each a step module, after a named-value
snapshot with `Backup-ClaudeGateway.ps1`. `Change` replans one decision against the recorded
state, for example a higher SKU tier, named values to Cosmos (through the projection deployer's
compare-then-flip), a network edge, a FinOps tool or dollar budgets, and shows what the change
does to cost and to callers before applying it.

**Diagnose.** `scripts/Debug-ClaudeSetup.ps1` (administrator: record, gateway, identity, policy,
named values, entitlement, FinOps tools, workbooks, reports, jobs) and
`scripts/Debug-ClaudeWorkstation.ps1` (developer: Azure CLI sign-in and tenant, clients and
versions, managed and user settings and their precedence, network path, a real request) print
pass or fail with the fix for each, and can write a redacted support bundle. Both run standalone
and from the flow.

## Consequences

+ One place to start, one review, one record; a failed run resumes; later changes are planned
  against what is actually deployed.
+ The existing, live-proven scripts remain the implementation, so no proven path is rewritten.
− Every step script needs a module that separates planning from applying, and a test that the plan
  writes nothing.
− The record becomes load-bearing; a hand-edited or stale record is detected by comparing it with
  discovery before any plan is shown, and the flow refuses to apply over a mismatch.

## How we'd know this was wrong

A step whose plan cannot be computed without writing, a migration that cannot be expressed as a
reversible step, or administrators still running individual scripts for a task the flow claims to
cover would each show that the step boundary is in the wrong place.
