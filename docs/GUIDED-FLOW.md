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
| Tier, entitlement store, network edge and Desktop sign-in | `Tier.ps1`, `Entitlement.ps1`, `Network.ps1`, `DesktopSignIn.ps1` | These run under `-Action Change`. Setup lists each one with the command that changes it. Manual equivalents: [Update and change](UPDATE-AND-CHANGE.md), [Scale](SCALE.md), [Network](NETWORK.md). |
| FinOps, budgets, monitoring and reports | FinOps modules when present | A module file that is not present is listed as skipped. Manual equivalents: [FinOps](FINOPS.md), [Budgets](BUDGETS.md), [Monitoring](MONITORING.md), [Chargeback reports](CHARGEBACK-REPORTS.md). |
| Device profiles | `DeviceProfiles.ps1` | Per-tier MDM payloads must mirror the recorded gateway, model and Desktop sign-in choices. Manual equivalent: [MDM](MDM.md). |
| Verification | `Verify.ps1` | Runs the gateway health checks after setup or change. Manual equivalent: [Operations health](OPERATIONS.md#2-check-health-and-headroom). |
| Guide | `Guide.ps1` | Writes `onboarding/HOW-TO-USE.md` with this tenant's names and the operator/developer/FinOps instructions. |

## Review and fingerprint

After questions, every present module returns a plan. The flow prints one review
with actions, list-price cost where known, unknown-cost reasons, implications,
required roles and rollback notes, then prints a SHA-256 fingerprint.

The Foundation line names the resource group, gateway, region, Foundry account
and subscription, and the plan carries every installer input. A fingerprint
approved for one estate is therefore refused for another. The API Management
line is priced from the
[Azure Retail Prices API](https://learn.microsoft.com/rest/api/cost-management/retail-prices/azure-retail-prices)
at plan time. When that API cannot be reached, the price shows as unknown with
that reason, the fingerprint differs from a priced plan, and a new `-PlanOnly`
run is needed.

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
.\Start-ClaudeGateway.ps1 -Action Update -ApprovedPlanFingerprint <fingerprint>
```

The first command runs `scripts\Update-ClaudeGateway.ps1` with the record path
and only plans. It compares the record schema, the deployed policy and the named
values the current policy references, and pinned job definitions, with the
current repository, then prints the migrations and a fingerprint. The second
command passes `-Apply` and that fingerprint; the updater takes a named-value
snapshot before its first write. `-PlanOnly` never applies. See
[Update and change](UPDATE-AND-CHANGE.md#1-update-an-older-deployment).

## Change one decision

```powershell
.\Start-ClaudeGateway.ps1 -Action Change -Change sku
```

`-Change` narrows planning to the module that owns the decision key. Change
re-asks that module's questions even when the record already has a value; the
current value is shown as the default/recommended option. The review still shows
cost and caller impact before applying.

| `-Change` | Module | What changes | Runbook |
|---|---|---|---|
| `foundation` | `Foundation.ps1` | Installer inputs for the gateway | [Setup](SETUP.md) |
| `sku` | `Tier.ps1` | API Management tier; Basic v2 and Standard v2 change in place | [Tier](UPDATE-AND-CHANGE.md#2-change-the-api-management-tier) |
| `entitlementStore` | `Entitlement.ps1` | Named values to the Cosmos projection and back, after a clean comparison | [Entitlement](UPDATE-AND-CHANGE.md#3-move-entitlement-between-named-values-and-the-projection) |
| `network` | `Network.ps1` | Enterprise network edge, through its own fingerprinted review | [Network](UPDATE-AND-CHANGE.md#4-change-the-enterprise-network-edge) |
| `desktopSignIn` | `DesktopSignIn.ps1` | Claude Desktop sign-in kind and gateway audience | [Desktop sign-in](UPDATE-AND-CHANGE.md#5-change-claude-desktop-sign-in) |
| `deviceProfiles` | `DeviceProfiles.ps1` | Per-tier MDM payloads | [MDM](MDM.md) |

## Diagnose

```powershell
.\Start-ClaudeGateway.ps1 -Action Diagnose
```

The flow runs `scripts\Debug-ClaudeSetup.ps1` for the administrator deployment
and `scripts\Debug-ClaudeWorkstation.ps1` for the developer machine, passing
`-RecordPath`. Both are read-only. With `-SupportBundle`, each script writes a
redacted zip under `onboarding\support\`
(`claude-setup-support-<utc>.zip` and `claude-workstation-support-<utc>.zip`);
the folder is git-ignored. See [Diagnostics](DIAGNOSE.md) and
[Troubleshooting](TROUBLESHOOTING.md).

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

## Live proof transcript excerpts

The P66 core was exercised against an isolated Basic v2 gateway in eastus2,
using the shared Foundry account only for the gateway managed identity's
temporary data-plane role. The resource group was deleted afterwards and the
soft-deleted APIM instance was purged. The screenshots below are rendered from
redacted terminal transcripts; raw transcripts stay under private evidence.

![Guided flow PlanOnly review with skipped absent modules and fingerprint.](guide/07-planonly-stable.png)

![Guided flow resume completing verification from the same active run.](guide/16-setup-resume-verify-warning.png)

![A real governed request returning HTTP 200 through the isolated gateway.](guide/18-real-200-request.png)

![Status command showing decisions, release, recent history and no live drift.](guide/23-status-final.png)

![Second setup replanning the existing gateway instead of skipping forever.](guide/24-second-setup-replan-final.png)

![Change action scoped to the Foundation decision.](guide/25-change-foundation-final.png)
