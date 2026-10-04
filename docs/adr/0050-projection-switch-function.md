# ADR-0050: The projection switch is one function over the renewal receipt

- **Status:** Proposed for P95
- **Date:** 2026-10-05
- **Packet:** P95
- **Refines:** [ADR-0049](0049-projection-renewal-deployment.md) decisions 6, 7 and 9,
  [ADR-0045](0045-scheduled-projection-renewal.md)

## Context

P94 deploys the renewal job and writes a receipt for it. Three callers can still switch
`entitlement-source` to `projection`, and none can succeed or is fully guarded
([P95 status](../status/P95.md#p95-the-projection-switch-over-runs-end-to-end-2026-10-05)).
Line references in this section are to `d0605cb`:

- The deployer's `-FlipAfterCleanCompare` redeploys and applies a fresh snapshot before admission,
  so admission refuses every attempt (`scripts/Deploy-ClaudeProjection.ps1:111-216`).
- The installer forwards to the deployer (`Install-ClaudeGateway.ps1:1617-1637`).
- The guided flow never receives renewal evidence and never compares
  (`scripts/flow/Entitlement.ps1:71,80-83`).

Admission accepts any action-group id and does not bind the job's settings to its evidence.

## Options considered

1. **Fix each caller in place.** Three copies of the order drift check, compare, admission, write,
   in three files; one of them is 1,830 lines (`Install-ClaudeGateway.ps1`). Rejected: the copies
   drift, which is how the flow came to skip the compare.
2. **One function, called by the deployer and the flow, with the installer reaching it through the
   deployer.** Chosen.
3. **The deployer's switch mode keeps the population step.** Rejected: a snapshot applied before
   admission makes the job's status records older than the live records, so admission refuses
   (P94 simulation).
4. **Bind settings by a hash in the status record.** Smaller records, but a refusal could not say
   which setting differs. Rejected for the four identifiers themselves, which are not secrets.

## Decision

1. `Invoke-ClaudeProjectionSwitch` in `scripts/ClaudeProjectionSwitch.ps1` takes the gateway, the
   tier group names and the renewal evidence, and runs, in order: `Compare-ClaudeEntitlement.ps1
   -FailOnDrift` with the gateway export; the package upload and the read-only
   `apply-projection.mjs --compare` in the runner; admission; a backup; one `entitlement-source`
   write; a rollback note. `-WhatIf` stops before the backup. Nothing is deployed, published or
   applied.
2. The deployer's `-FlipAfterCleanCompare` runs only that function. When `-ReconcilerResourceId`,
   `-RenewalImageDigest` and `-RenewalActionGroupResourceId` are absent, it reads
   `onboarding/projection-renewal-<prefix>.json`.
3. The guided flow's live discovery reads the receipts under `onboarding/`, keeps the one whose
   `gatewayResourceId` is the discovered gateway, and confirms in ARM that the job exists and runs
   the receipt's digest. The flow's switch calls the same function, with the flow's own snapshot
   gate as the backup.
4. Admission reads the action group from ARM and requires `enabled` and at least one email
   receiver with status `Enabled` (U119).
5. The job writes `AZURE_CLIENT_ID`, the tier group ids and the gateway id into each status record.
   `check-admission.mjs` counts only status records written under the settings the job definition
   now carries. The switch requires the job's gateway to be the gateway being switched, its tier
   groups to be the compared groups, and its client id to be the receipt's.
6. The backup is `onboarding/projection-switch-<apim>-<UTC timestamp>.json` with the gateway's
   `entitlement-source`, `allow-standard`, `allow-premium` and `bu-members` values before the write.

## Consequences

+ One order of checks for every caller, tested once.
+ A redeploy of the job with other groups, another gateway or another identity needs fresh runs
  before a switch.
− Status records written before P95 carry no settings, so the first switch after P95 needs three
  runs of the P95 image.
− The deployer's `-FlipAfterCleanCompare` no longer deploys or populates; deployment and population
  stay a separate run without it.

## How we'd know this was wrong

- A live switch is refused for a reason the offline tests do not reproduce.
- An action group whose receivers have not confirmed their passcode reads `Enabled`, so admission
  accepts alerts that reach nobody (U116).
