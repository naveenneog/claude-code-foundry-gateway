# Guided flow

`Start-ClaudeGateway.ps1` is the product path for setup, later changes, status
and the generated handover guide. It keeps the existing implementation scripts:
each `scripts/flow/<Step>.ps1` module plans without writing, applies
non-interactively and verifies its own work.

## Run it

```powershell
.\Start-ClaudeGateway.ps1 -Action Setup
```

Without `-Action`, an interactive console shows a menu. Without a console, pass
one of `Setup`, `Update`, `Change`, `Diagnose`, `Guide` or `Status`.

The default record is `onboarding/claude-gateway.json`. It is environment
specific and git-ignored. Use `-RecordPath` to use a different record.

## What the flow asks and why

The orchestrator discovers live options first, then asks the questions exposed
by the step modules present on the branch. It never invents resource names.

| Area | Asked by | Why |
|---|---|---|
| Gateway foundation | `Foundation.ps1` | API Management v2 SKU, entitlement store, developer sign-in and Desktop sign-in affect cost, scale, support and client configuration. Manual equivalent: [Setup](SETUP.md). |
| Entitlement, network, FinOps, budgets, monitoring and reports | Parallel-branch modules when present | These modules are skipped with a clear note until their branches merge. Manual equivalents: [Scale](SCALE.md), [Network](NETWORK.md), [FinOps](FINOPS.md), [Budgets](BUDGETS.md), [Monitoring](MONITORING.md), [Chargeback reports](CHARGEBACK-REPORTS.md). |
| Device profiles | `DeviceProfiles.ps1` | Per-tier MDM payloads must mirror the recorded gateway, model and Desktop sign-in choices. Manual equivalent: [MDM](MDM.md). |
| Verification | `Verify.ps1` | Runs the gateway health checks after setup or change. Manual equivalent: [Operations health](OPERATIONS.md#2-check-health-and-headroom). |
| Guide | `Guide.ps1` | Writes `onboarding/HOW-TO-USE.md` with this tenant's names and the operator/developer/FinOps instructions. |

## Review and fingerprint

After questions, every present module returns a plan. The flow prints one review
with actions, list-price cost where known, unknown-cost reasons, implications,
required roles and rollback notes, then prints a SHA-256 fingerprint.

Preview only:

```powershell
.\Start-ClaudeGateway.ps1 -Action Setup -PlanOnly
```

Apply without an interactive prompt:

```powershell
.\Start-ClaudeGateway.ps1 -Action Setup -ApprovedPlanFingerprint <fingerprint>
```

For scripted runs, put the answers in a JSON object whose keys are the question
keys, then pass `-AnswersPath`. Explicit `-NonInteractiveAnswers` values, when
used from another PowerShell script, override the file.

```json
{
  "foundation.sku": "BasicV2",
  "foundation.entitlementStore": "named-value",
  "foundation.authMode": "interactive",
  "foundation.desktopSignInKind": "helper-script",
  "deviceProfiles.conversationStorage": "local"
}
```

```powershell
.\Start-ClaudeGateway.ps1 -Action Setup -PlanOnly -AnswersPath .\answers.json
.\Start-ClaudeGateway.ps1 -Action Setup -AnswersPath .\answers.json `
  -ApprovedPlanFingerprint <fingerprint>
```

The supplied value must match the printed fingerprint, or at least its first
eight characters. `-WhatIf` prints the same review and writes nothing.

## Resume after failure

When an apply starts, the orchestrator writes `activeRun` with the run id,
action, selected change, fingerprint and UTC start time. After each step applies,
it writes the decision record and appends one history entry with that `runId`,
UTC time, action, decision key, principal and commit. A rerun resumes only when
the record still has an `activeRun` for the same action/change/fingerprint, and
then skips only history entries with that `runId`. A different fingerprint starts
a new run, and a successful verification clears `activeRun`. If a step throws
before returning its changes, no success-shaped history is written for that step.

## Update

```powershell
.\Start-ClaudeGateway.ps1 -Action Update
```

When `Update-ClaudeGateway.ps1` is present, the flow delegates to that lifecycle
script. Until the lifecycle branch is merged, the flow says the module is absent
and exits successfully; use the manual update guidance in [Operations](OPERATIONS.md).

## Change one decision

```powershell
.\Start-ClaudeGateway.ps1 -Action Change -Change foundation
```

`-Change` narrows planning to the present module that owns the decision key.
Future lifecycle modules own tier, entitlement, network and Desktop sign-in
changes. Change re-asks that module's questions even when the record already
has a value; the current value is shown as the default/recommended option. The
review still shows cost and caller impact before applying.

## Diagnose

```powershell
.\Start-ClaudeGateway.ps1 -Action Diagnose
```

When the setup or workstation debug scripts from the diagnose branch are
present, the flow delegates to them with `-RecordPath`; `-SupportBundle` is
passed through when requested. Until the diagnose branch is merged, use
[Debugging](DEBUGGING.md) and [Troubleshooting](TROUBLESHOOTING.md).

## Status and drift

```powershell
.\Start-ClaudeGateway.ps1 -Action Status
```

Status prints the recorded decisions, release metadata, recent history and any
record-versus-live drift discovered by `scripts/flow/Discovery.ps1`. Apply
actions refuse to continue over a known mismatch, naming the differing field.

## Generated guide

```powershell
.\Start-ClaudeGateway.ps1 -Action Guide
```

The guide contains tenant-specific names, gateway URL, cost instructions,
administrator daily tasks, developer setup steps in the requested order (VS Code,
CLI, Desktop, then MDM), FinOps tool usage, workbooks/reports, and the commands
to update, change and diagnose. It is written to `onboarding/HOW-TO-USE.md` and
is git-ignored.

## Manual equivalents

| Guided step | Manual script or guide |
|---|---|
| Foundation | `Install-ClaudeGateway.ps1`, [Setup](SETUP.md) |
| Device profiles | `scripts\New-ClaudeCodePolicy.ps1`, [MDM](MDM.md) |
| Verify | `scripts\Test-ClaudeHealth.ps1`, [Governance checks](GOVERNANCE-CHECKS.md) |
| Guide | [Get started](GET-STARTED.md), [Operations](OPERATIONS.md), [Developer setup](../DEVELOPER.md), [FinOps](FINOPS.md) |
| Status | `scripts\Get-ClaudeGatewayTarget.ps1`, `scripts\Test-ClaudeHealth.ps1`, Azure portal checks in [Operations](OPERATIONS.md) |
