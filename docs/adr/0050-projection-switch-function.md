# ADR-0050: The projection switch is one function over the renewal receipt

- **Status:** Proposed for P95
- **Date:** 2026-10-05
- **Packet:** P95
- **Refines:** [ADR-0049](0049-projection-renewal-deployment.md) decisions 6, 7 and 9,
  [ADR-0045](0045-scheduled-projection-renewal.md)
- **Revised:** 2026-10-05 after council round 1 ([P95 status](../status/P95.md#council)): decisions
  1-3, 5 and 6 changed, 7-9 and options 5-6 added; after round 2, decisions 3, 8 and 9 changed

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
5. **Confirm the receipt in ARM during discovery.** Every plan of every flow run would read ARM, and
   the result could be stale by the write. Rejected: admission reads the job definition in the
   switch, before the backup and the write (decision 3).
6. **The switch writes the resolver named values.** Rejected: the switch keeps one write that changes
   traffic. The deployer's normal run points the gateway at the resolver, as section 9 of
   [SECURE-PROJECTION](../SECURE-PROJECTION.md) and the Azure CLI guide do by hand, and the switch
   checks it (decision 8).

## Decision

1. `Invoke-ClaudeProjectionSwitch` in `scripts/ClaudeProjectionSwitch.ps1` takes the gateway, the
   tier group names and the renewal evidence, and runs, in order: the receipt check (decision 7); the
   gateway read and its tenant; the resolver check (decision 8); `Compare-ClaudeEntitlement.ps1
   -FailOnDrift` with the gateway export; the package upload and the read-only
   `apply-projection.mjs --compare` in the runner; admission; a backup; one `entitlement-source`
   write; a rollback note. `-WhatIf` stops before the backup, and `-Confirm` asks about the write
   alone. Nothing is deployed, published or applied.
2. The deployer's `-FlipAfterCleanCompare` runs only that function. It reads
   `onboarding/projection-renewal-<prefix>.json`, or `-RenewalReceiptPath`, and refuses
   `-ReconcilerResourceId`, `-RenewalImageDigest`, `-RenewalActionGroupResourceId` or
   `-RenewalEntryPoint` values that differ from the receipt.
3. The guided flow's discovery (`Get-ClaudeFlowDiscovery`, and `Get-ClaudeFlowLifecycleLiveDiscovery`
   for updates) reads the receipts beside the decision record and under the repository's
   `onboarding/`, and keeps the one whose `gatewayResourceId` is the discovered gateway; two are
   ambiguous. It reads files only: admission confirms in ARM that the job exists and runs
   the receipt's digest, inside the switch and before any write. The flow's switch calls the same
   function, with the flow's own snapshot gate as the backup; `Initialize-ClaudeFlowStep` names the
   snapshot, and the gate takes it at the write.
4. Admission reads the action group from ARM and requires `enabled` and at least one email
   receiver with status `Enabled` (U119).
5. The job writes `AZURE_CLIENT_ID`, the tier group ids and the gateway id into each status record.
   `check-admission.mjs` counts only status records written under the settings the job definition
   now carries. The switch requires the job's gateway to be the gateway being switched, its tier
   groups to be the compared groups, its client id to be the receipt's, and its Cosmos account and
   tenant to be the ones admission reads.
6. The backup is `onboarding/projection-switch-<apim>-<UTC time>-<8 hex digits>.json`, created once,
   with the gateway's `entitlement-source`, `allow-standard`, `allow-premium` and `bu-members` values
   before the write. The flow's backup is its snapshot, `backups/before-entitlement-<apim>-<UTC time>.json`.
7. Receipt values reach `az.cmd` arguments, which `cmd.exe` re-reads; the runner's command line,
   which the runner splits on spaces and URL-decodes; and ARM URLs, which carry the management
   token. Before any call, each value must have the form Azure gives it, the job, action group and
   Cosmos account must be in the receipt's resource group and the gateway's subscription, and the
   account id must name the receipt's Cosmos account. After the gateway read, the receipt's tenant
   must be the tenant of the gateway's managed identity. Admission builds its two ARM URLs before the
   token exists and refuses an id whose URL would leave `management.azure.com`; the runner refuses a
   command with a quote, `+`, `%` or a `cmd.exe` metacharacter; and the entry point travels
   base64url-encoded (U121).
8. After the switch, the gateway calls `entitlement-resolver-url` for every request. The switch reads
   the deployment `projection-resolver-<prefix>` in the receipt's resource group (U120) and refuses
   unless its `cosmosAccountName` is the receipt's Cosmos account and the gateway's
   `entitlement-resolver-url` and `entitlement-resolver-audience` are its outputs. It then reads the
   site that deployment names and its application settings (U122), because the resolver reads those
   at run time whatever was redeployed since: the site must serve the gateway's URL, and
   `COSMOS_ENDPOINT`, `COSMOS_DATABASE`, `COSMOS_CONTAINER` and `PROJECTION_TENANT_ID` must be the
   receipt's account, `claude`, `entitlement` and tenant. The deployer's normal run points the
   gateway at the resolver it deployed, and refuses to point a gateway already on the projection at
   another resolver.
9. Other writers of `entitlement-source`: `scripts/Restore-ClaudeGateway.ps1` does not move it to
   `projection`, and names the switch instead; `infra/main.bicep` receives the live value from the
   installer, which reads it, and the two resolver values, fail-closed on an existing gateway, and
   defaults to `named-value`; migration 0002 creates a missing value as `named-value`.
   A template deployment with `entitlementSource=projection`, like the manual command in the Azure CLI
   guide, skips admission. `tests/Test-ProjectionSwitch.ps1` lists the code that writes it by name.

## Consequences

+ One order of checks for every caller, tested once.
+ A redeploy of the job with other groups, another gateway or another identity needs fresh runs
  before a switch.
+ A receipt, a resolver or a job that does not belong to the gateway being switched refuses before
  the write, and a receipt value cannot run a command or move the management token.
− Status records written before P95 carry no settings, so the first switch after P95 needs three
  runs of the P95 image.
− The deployer's `-FlipAfterCleanCompare` no longer deploys or populates; deployment and population
  stay a separate run without it.
− A resolver deployed under another deployment name than `projection-resolver-<prefix>`, or a
  resource group whose name holds parentheses, cannot be switched by this function.
− The switch lists the resolver site's application settings, an action
  (`Microsoft.Web/sites/config/list/action`) that the Reader role does not include (U122).

## How we'd know this was wrong

- A live switch is refused for a reason the offline tests do not reproduce.
- An action group whose receivers have not confirmed their passcode reads `Enabled`, so admission
  accepts alerts that reach nobody (U116).
- The gateway serves requests from a resolver other than `projection-resolver-<prefix>` after a
  switch, for example because its named values were changed by hand between the check and the write.
