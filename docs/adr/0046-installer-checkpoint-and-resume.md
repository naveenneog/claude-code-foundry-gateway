# ADR-0046: The installers keep a per-checkout checkpoint and resume after the last verified step

- **Status:** Proposed. P91 contract, 2026-10-01. Nothing below is implemented at the commit that
  adds this record; the lead reviews it before RED, and the owner approves the merge.
- **Date:** 2026-10-01
- **Packet:** P91
- **Deciders:** owner (merge), lead (review), P91 builder

## Context

Field cases from customer runs in the week of 2026-09-28:

1. Sync stopped at `scripts/ClaudeGraphMembership.ps1:41` with "Graph read failed: ... 404 (Not
   Found)" right after `Install-ClaudeGateway.ps1:1595-1607` created the tier groups. The run was
   in Cloud Shell PowerShell.
2. A reused API Management instance without a system-assigned identity failed the deployment with
   "The language expression property 'identity' doesn't exist"; `infra/main.bicep:506-513` reads
   `apim.identity.principalId`. The remedy is the portal identity toggle, then a rerun with
   `-ExistingApimName`.
3. The business-unit id check at `Install-ClaudeGateway.ps1:1652` refused an upper-case id, and a
   rerun was needed.
4. Cloud Shell ends a session after 20 minutes without interactive activity (U63).
5. ARM runs a deployment as an asynchronous operation (U69). Both installers name each deployment
   `claude-gw-<yyyyMMddHHmmss>` (`Install-ClaudeGateway.ps1:1466`, `install-claude-gateway.sh:558`),
   so a rerun starts a second main.bicep deployment while the first may still run.

A rerun today starts over. It asks every question again, finds the tier groups by display name and
names a new deployment. `az ad group show --group <name>` resolves a name with
`startswith(displayName, '<name>')` and returns the single match, so a group whose name only begins
with the requested one is returned as that group (azure-cli 2.86.0 `role/custom.py:1898-1905`,
`:1960-1968`).

Existing stores and rules:

- The decision record `onboarding/claude-gateway.json` is written at the end of the installer
  (`Install-ClaudeGateway.ps1:1685-1756`), except that the company-address step writes it mid-run
  with a `pendingAddress` receipt (`scripts/ClaudeGatewayAddress.ps1:239-263`, removed at `:356-357`).
  The record is the developer handover (`Install-ClaudeGateway.ps1:1801-1803`).
- The guided flow's `activeRun` lives in that record and resumes only the steps after the
  installer (`Start-ClaudeGateway.ps1:293-327`, `:545-557`;
  [GUIDED-FLOW](../GUIDED-FLOW.md#resume-after-failure)). The installer phase starts over.
- ADR-0030: durable `decisions` hold applied values only.
- ADR-0032: the installer writes nothing before its summary is confirmed, and the guided flow
  treats the installer's record write as its success (`scripts/flow/Foundation.ps1:424-450`).
- P79: a checkout holds one gateway's record; a record that names another gateway is archived when
  attended or with `-ArchiveSavedRecord`, and refused otherwise (`Install-ClaudeGateway.ps1:787-831`).
- `Invoke-AzOptional` returns `$null` on any failure (`Install-ClaudeGateway.ps1:134-144`), so it
  cannot tell "absent" from "unreadable".

The facts this record relies on, with sources, are U63-U74 in [UNKNOWNS](../UNKNOWNS.md).

## Options considered

Store:

1. **`activeRun` in the decision record.** One store. Rejected: the record is the developer handover
   file; ADR-0030 keeps unapplied answers out of its durable decisions; the installer also runs
   without the flow, where no `activeRun` exists, and the bash installer writes the record only at
   its end with jq (`install-claude-gateway.sh:613-641`); and the record sits in the checkout, which
   a Cloud Shell session can lose (U63).
2. **A second file beside the record in `onboarding/`.** Per checkout, like P79. Rejected: the
   folder is the handover package, and it is lost with the checkout.
3. **A per-user state directory, one checkpoint per checkout.** Owner-only by location, outside the
   handover folder, and on Cloud Shell placed in `clouddrive`, which persists (U63). Chosen.
4. **Resource-group tags as the store or as a second marker.** Rejected; see Decision 12.

Waiting for a deployment:

- **`az deployment group wait`.** Rejected. In azure-cli 2.86.0 a `Canceled` state and a 404 keep
  `--created` polling until the time-out, and the time-out is returned rather than raised
  (`azure/cli/core/commands/command_operation.py:427-461`, U68).
- **Polling `az deployment group show`.** Chosen; the installers classify every state themselves.

Resume across installers:

- **Shared resume.** Rejected: the two installers have different steps and answers (Decision 8, 9).
- **One format, refusal that names the installer.** Chosen (Decision 13).

## Decision

### 1. Store and location

One checkpoint per checkout, in a per-user state directory. The file name carries a key: the first
16 hex digits of SHA-256 over the checkout path as the installer sees its own folder
(`$PSScriptRoot`; `install-claude-gateway.sh:24` `HERE`), lower-cased on Windows.

| Platform | Directory | Basis |
|---|---|---|
| Any, when `CLAUDE_GATEWAY_STATE_DIR` is set | that absolute directory | test and operator override |
| Azure Cloud Shell with a usable `clouddrive` | `$HOME/clouddrive/.claude-gateway` | the mounted file share persists across sessions (U63, U65) |
| Azure Cloud Shell without `clouddrive` | `$HOME/.claude-gateway`, plus the warning below | no storage persists (U63) |
| Windows | `%LOCALAPPDATA%\claude-gateway` | current, non-roaming user's application data (`Environment.SpecialFolder.LocalApplicationData`) |
| Linux and macOS | `${XDG_STATE_HOME:-$HOME/.local/state}/claude-gateway` | XDG Base Directory 0.8: state that persists between restarts |

Cloud Shell is detected by `AZUREPS_HOST_ENVIRONMENT` beginning `cloud-shell/` or a non-empty
`ACC_CLOUD` (U64). `clouddrive` is usable when `$HOME/clouddrive` is a directory and a probe file
can be created in it.

Files: `install-<key>.json` (the checkpoint) and `install-<key>.lock`.

When the checkpoint cannot persist (Cloud Shell without `clouddrive`, or a state directory that
cannot be created), the installer prints one warning line naming the reason and the exact resume
command (Decision 14) before its first change, continues, and relies on the live checks of
Decisions 7 and 10.

### 2. File mechanics

- **Owner-only.** POSIX: directory 0700 and files 0600, created under `umask 077` and set with
  `chmod`. Windows: the directory gets a protected ACL with one rule, the current user's SID with
  full control, inherited by its files. On POSIX a checkpoint or lock that is not owned by the
  current user (`test -O`) or is group- or other-writable (`find -perm -020`, `-perm -002`) is
  refused, except under `clouddrive`, where the mount sets the mode and the storage account's access
  control applies (U66); there the installer prints the measured mode once.
- **Atomic writes.** Each write goes to `install-<key>.json.tmp-<random>` in the same directory and
  replaces the checkpoint by rename: `[IO.File]::Replace` when the file exists and `[IO.File]::Move`
  when it does not (PowerShell 5.1 and 7), `mv -f` in bash. A reader sees the old file or the new
  one. Temporary files are ignored by readers and removed by the next write of the same run.
- **Corrupt checkpoint.** A file that is not JSON, has another `schema` or `schemaVersion`, lacks a
  required field, holds an unknown step id, or holds an answer that fails the installer's own
  validation (`ValidateSet`, `ValidatePattern`, `Assert-AzArgumentsSafe` at
  `Install-ClaudeGateway.ps1:267-281`) is refused on one line naming the field and the path. The file
  is not changed, moved or deleted.

### 3. Lock

- `install-<key>.lock` is created with an exclusive create: `FileMode.CreateNew` in PowerShell and a
  `set -C` (noclobber) redirection in bash. It holds one JSON line: `pid`, `processStart` (UTC, to
  the second), `host` (node name up to the first dot, lower case), `installer`, `runId`,
  `acquiredUtc`.
- Heartbeat: while the run lives, a background runspace (PowerShell 5.1 and 7) or a background
  subshell guarded by `kill -0` (bash) sets the lock's last-write time every 60 s.
- Held, on the same host: a process with that PID exists and its start time equals `processStart`.
  Start time comes from `Get-Process` on Windows and from `LC_ALL=C TZ=UTC ps -o lstart= -p <pid>` on
  Linux, macOS and Cloud Shell, for both installers (U72). When the start time cannot be read, a
  live PID counts as held.
- Held, from another host: the lock's last-write time is less than 5 minutes old.
- A lock that cannot be parsed counts as held for 5 minutes after its last write.
- A held lock refuses the run on one line naming the host, PID, process start and lock path.
- A stale lock is renamed to `install-<key>.lock.stale-<runId>` (one rename wins a race), then the
  run creates its own lock and prints a note naming the stale holder.
- The run deletes its own lock on exit (`finally` and an `EXIT` trap). `-WhatIf` and `--what-if`
  take no lock and write nothing.

### 4. Schema, version 1

```json
{
  "schema": "claude-gateway-install-checkpoint",
  "schemaVersion": 1,
  "runId": "3f2a9c0e5b1d4e7f8a6b2c4d6e8f0a1b",
  "installer": "pwsh",
  "installerFingerprint": "sha256:9c1e...",
  "installerCommit": "0fed315...",
  "checkout": "/home/<user>/claude-code-foundry-gateway",
  "createdUtc": "2026-10-01T09:12:44Z",
  "updatedUtc": "2026-10-01T09:20:11Z",
  "binding": {
    "tenantId": "00000000-0000-0000-0000-000000000000",
    "subscriptionId": "00000000-0000-0000-0000-000000000000",
    "resourceGroup": "rg-claude-gateway",
    "apimName": "apim-claudegw123456",
    "namePrefix": "claudegw123456",
    "reusedApim": false
  },
  "answers": { "Sku": "BasicV2", "StandardGroup": "claude-code-standard", "TeamBudgetBehaviour": "report" },
  "steps": [
    { "id": "resource-group", "state": "completed", "startedUtc": "...", "completedUtc": "...",
      "inputHash": "sha256:...", "receipt": { "name": "rg-claude-gateway", "location": "eastus2", "origin": "created" } },
    { "id": "gateway-deployment", "state": "started", "startedUtc": "...", "inputHash": "sha256:...",
      "receipt": { "deployments": [ { "name": "claude-gw-20261001091302", "recordedUtc": "...", "lastState": "Running" } ] } }
  ]
}
```

- `state` is `started` (written before the step changes anything), `completed` (written after the
  step and its own check succeeded) or `incomplete` (the step reported a warning and the run went
  on, as both installers do today for a group they cannot create, `Install-ClaudeGateway.ps1:1602-1605`,
  `install-claude-gateway.sh:593-596`, and bash's sync, `:604`).
- `inputHash` is SHA-256 over the canonical JSON of the answers the step uses
  (`ConvertTo-ClaudeFlowCanonical`, `scripts/flow/FlowContract.ps1:195-222`; `jq -S -c` in bash).
- `answers` holds only the non-secret answers in Decision 6; `receipt` only the fields in Decision 11.
- The first write happens after the summary is confirmed. A cancelled summary, `-WhatIf` and
  `--what-if` leave no checkpoint. After the last step the run deletes the checkpoint unless a step
  is `incomplete`; then it keeps it and prints the resume command.

### 5. Binding

| Field | Compared when | Source of the current value |
|---|---|---|
| `installer` | before sign-in | the running installer |
| `installerFingerprint` | before sign-in | SHA-256 over the sorted list of (path, SHA-256 of content with CRLF read as LF) for the installer, its checkpoint library, `infra/main.bicep`, `infra/foundry-role.bicep` and `infra/policy.xml` |
| `tenantId` | after sign-in | `az account show` |
| `subscriptionId` | after sign-in | `-SubscriptionId`/`--subscription` when passed, else the recorded value is set and read back |
| `resourceGroup` | when known | the parameter when passed, else the recorded value |
| `apimName`, `namePrefix`, `reusedApim` | when known | `-ExistingApimName`/`-NamePrefix`/`--name-prefix` when passed, else the recorded values |

A difference refuses on one line that names the field and both values, says that nothing was
changed, and ends with the `-Restart` (`--restart`) command. `installerCommit` is shown and never
compared: a checkout without git has none (`Get-ClaudeFlowReleaseInfo`,
`scripts/flow/FlowContract.ps1:346-364`).

### 6. Answers and defaults

- Recorded: the answers that decide what the run creates. These are the parameters of
  `Install-ClaudeGateway.ps1:31-118` except the run modes (`-Yes`, `-WhatIf`, `-Restart`,
  `-ChooseFinOps`, `-SkipFinOpsOffer`, `-ArchiveSavedRecord`, `-AddressApprovedPlanFingerprint`,
  `-FlipProjectionAfterCleanCompare`) and `-AddressCertificatePassword`, plus five prompt-only answers:
  `RevocationWindowSeconds` (`:987-1006`), `TeamBudgetBehaviour` (`:1021`), `UnassignedDevelopers`
  (`:1039`), `DeveloperEstimate` (`:712`) and `PendingClaudeDeployment` (`:472-475`). Bash records its
  15 flag-backed answers (`install-claude-gateway.sh:310-324`) under the PowerShell parameter names
  (`SubscriptionId`, `FoundryAccount`, ..., `PremiumGroup`), so a key means the same answer in both
  installers.
- A resumed run binds the recorded answers as if they had been passed and asks none of those
  questions again. Its summary marks them as recorded, lists the completed steps with UTC times and
  names the step where it resumes.
- A parameter passed explicitly wins over a recorded answer, except the binding fields of Decision 5.
  The summary lists each such change, and every step whose `inputHash` changes runs again.
- Attended (a console without `-Yes`): the summary question "Resume from <step>?" replaces "Create
  these resources?" (`Install-ClaudeGateway.ps1:1350`; `install-claude-gateway.sh:546`); Enter resumes,
  `n` stops with nothing changed and prints the `-Restart` command.
- `-Yes` / `--yes` (`ASSUME_YES=1`): resumes without a question when every binding field matches; a
  mismatch, a corrupt checkpoint, a held lock or another installer's checkpoint refuses. Nothing is
  discarded without `-Restart`.
- `-Restart` / `--restart`: renames the checkpoint to `install-<key>.discarded-<yyyyMMddTHHmmssZ>.json`
  and runs as a first run. A held lock refuses it.
- Precedent: the guided flow resumes a matching `activeRun` without asking
  (`Start-ClaudeGateway.ps1:293-299`, `:545-557`), and P79 asks when attended and refuses unattended
  without an explicit switch (`Install-ClaudeGateway.ps1:808-822`).

### 7. Verification before a skip

A `completed` step is skipped only when its live read returns **present**. Every read returns one of
three verdicts:

- **present**: the read succeeded and shows the step's result;
- **absent**: az failed with a not-found code on the allowlist for that read (U70);
- **inconclusive**: any other failure or output, including a code not on the allowlist.

`absent` runs the step again. `inconclusive` runs the step again when the step is idempotent and
refuses otherwise; it never skips. Steps marked "always" in Decisions 8 and 9 run on every resume. A
new reader replaces `Invoke-AzOptional` for these reads; the read-backs of
`Install-ClaudeGateway.ps1:1401-1512` are never recorded and run live before every deployment.

### 8. Steps of `Install-ClaudeGateway.ps1`

| Step id | Where | Live read when `completed` | absent | inconclusive | Receipt |
|---|---|---|---|---|---|
| sign-in, binding | `:306` | always: tenant and subscription | - | refuse | - |
| `claude-deployment` | `:1359-1363` | `az cognitiveservices account deployment show --deployment-name`: `Succeeded` is present; not found or `Failed` is absent; any other state is inconclusive | run again | refuse | account, resource group, name, origin |
| `resource-group` | `:1365-1396` | `az group show`: location | run again | run again (create is idempotent; a location conflict fails at `:1392`) | name, location, origin |
| `gateway-deployment` | `:1398-1586` | the recorded deployment `Succeeded`, `az apim show`, `az apim api show --api-id claude-foundry`, and the role assignment by id when this run created it | run again: read-backs, then a new name (Decision 10) | refuse | deployments, APIM name and origin, gateway URL, role assignment id and origin |
| `company-address` | `:1587-1591` | hostname present in `az apim show` and the record has `address` and no `pendingAddress` | run again through its own recovery (ADR-0033) | run again (the plan refuses on drift, `scripts/ClaudeGatewayAddress.ps1:247-248`) | hostname |
| `entra-groups` | `:1595-1607` | `az ad group show --group <id>` per group | pre-existing: run again; created by this run: refuse (U74) | refuse | role, display name, id, origin, UTC time |
| `sync` | `:1609-1611` | always | - | - | - |
| `projection` | `:1613-1630` | `az deployment group show` of `projection-<prefix>`, `projection-network-<prefix>` and `projection-resolver-<prefix>` (`scripts/Deploy-ClaudeProjection.ps1:107`, `:119`, `:130`): all `Succeeded` | run again with the recorded `-ProjectionResolverAppId` | refuse | resolver app id and origin |
| `business-units` | `:1641-1681` | each recorded unit id in `bu-registry` | offered again (attended) | refuse | unit id, group id, group origin |
| `onboarding-package` | `:1685-1756` | always | - | - | path |
| `verify` | `:1760-1764` | always; a caught failure is `incomplete` | - | - | - |

A Desktop sign-in through `external-idp-*` records the supplied `DesktopEntraClientId` with origin
`pre-existing`; a resume reads it with `az ad app show --id` and refuses when it is absent or
unreadable, naming `scripts/New-ClaudeDesktopEntraApp.ps1`.

### 9. Steps of `install-claude-gateway.sh`

| Step id | Where | Live read when `completed` | absent | inconclusive | Receipt |
|---|---|---|---|---|---|
| sign-in, binding | `:355` | always: tenant and subscription | - | refuse | - |
| `resource-group` | `:552-554` | `az group show` | run again; `az group create`'s exit status is checked before `completed` | run again | name, location, origin |
| `gateway-deployment` | `:556-582` | as the PowerShell row, without the role assignment | run again only when this run created the APIM; otherwise refuse | refuse | deployments, APIM name and origin, gateway URL |
| `entra-groups` | `:586-598` | `az ad group show --group <id>` | as the PowerShell row | refuse | as the PowerShell row |
| `sync` | `:600-609` | always; a reported problem is `incomplete` | - | - | - |
| `onboarding-package` | `:613-641` | always | - | - | path |

The bash installer reads nothing back before a deployment (`install-claude-gateway.sh:559-575` passes
no `*Existing` parameter, `infra/main.bicep:169-207`). Its resume therefore runs a deployment again
only against an APIM this run created, which holds no entitlement yet; against a pre-existing APIM it
refuses and names `Install-ClaudeGateway.ps1 -ExistingApimName`. The same gap on a first run is
outside P91.

### 10. Deployments

- Before `az deployment group create`, the run writes the new deployment name into the checkpoint
  (`started`) and only then creates it.
- Guard against two main.bicep deployments: before any create, the run lists the resource group's
  deployments (`az deployment group list -g`) and selects names beginning `claude-gw-` (both
  installers) or `claude-gateway-` (`deploy.ps1:154`) whose state is not terminal. Each is awaited
  under the bound below. A failed list refuses.
- States (U69): `Succeeded`, `Failed` and `Canceled` are terminal. `Deleted` and a not-found read mean
  the deployment record is gone. Every other value, including `Accepted`, `Running`, `Ready`,
  `Creating`, `Created`, `Updating`, `Deleting` and `NotSpecified`, is in flight.

| Recorded deployment on resume | Action |
|---|---|
| in flight | poll `az deployment group show` every 30 s for up to 3,600 s (az's own `wait` defaults, U68), printing the state at each change; past the bound, refuse with the resume command |
| `Succeeded` | read `properties.outputs.gatewayUrl.value`, verify the APIM and the Claude API, mark `completed` |
| `Failed`, `Canceled` | print `properties.error` and the failed operations (`az deployment operation group list`), then guard, read-backs, a new name and a create |
| not found, `Deleted` | guard, read-backs, a new name and a create (history keeps 800 per group and deletes the oldest past 700, U69) |
| read error | refuse; nothing is created |

`CLAUDE_GATEWAY_DEPLOY_POLL_SECONDS` and `CLAUDE_GATEWAY_DEPLOY_WAIT_SECONDS` override the interval
and the bound for tests. In Cloud Shell the session can end during the wait (U73); the checkpoint in
`clouddrive` and the ARM deployment outlive it.

### 11. Receipts

Receipts record what each step found or made, with `origin` `created` or `pre-existing`, and a
resume finds every object by id:

- Entra groups: id from `az ad group show --group <name> --query id` or `az ad group create ...
  --query id`, then `az ad group show --group <id>` on resume. A group found by name counts as
  pre-existing only when its `displayName` equals the requested name exactly; a prefix match counts
  as not found, and the step creates the exact group. A group this run created that Graph does not
  return by id is inconclusive, so the run refuses instead of creating a second group with the same
  name (U74). `az ad group create` without `--force` returns an existing group only when Graph's
  display-name and mail-nickname filter already sees it (`role/custom.py:1877-1888`, az 2.86.0).
- Role assignment: after a successful deployment, `az role assignment list --assignee-object-id <APIM
  principal> --scope <Foundry id> --role "Cognitive Services User"`, called only with both values
  non-empty; origin `created` when `grantFoundryRole` was true (`Install-ClaudeGateway.ps1:1522-1541`).
  On resume: `az rest --method get` on the assignment id.
- App registrations: the supplied Desktop client id (Decision 8) and the projection resolver app id,
  found by its display name after the projection step (`scripts/ClaudeProjectionChecks.ps1:163-173`)
  and passed back as `-ProjectionResolverAppId`.
- Business units: unit id, group id and origin.

### 12. No Azure-side marker

Resource-group tags are not written. A tag write needs `Microsoft.Resources/tags` write or
Contributor; a resource group holds at most 50 tags with values of at most 256 characters; built-in
policies deny a resource-group update that lacks a required tag or modify tags on update; tags are
plain text exposed through cost reports, exports and deployment history; and the group may not exist
before the run (U67). ARM already keeps the deployment record that a lost checkpoint would need: the
guard of Decision 10 reads it on every run, with or without a checkpoint. Entra and ARM ids in the
receipts cover the other steps.

### 13. Resume across installers

Both installers write the same schema. A checkpoint whose `installer` differs from the running one
is refused, naming the installer that wrote it. Their steps, answers and fingerprints differ
(Decisions 5, 8 and 9). `-Restart`/`--restart` of either installer sets it aside.

### 14. Output

- A resumed run prints the checkpoint path, the run id, its UTC start, each completed step as
  `done <UTC> <step title>`, and `resumes at: <step title>`; each skipped step prints `verified live,
  skipped`, and each step run again names its verdict.
- Refusals and the resume command are one line each. At top level the PowerShell installer writes a
  refusal or failure with `[Console]::Error.WriteLine` from a `trap` and exits 1, because PowerShell's
  error view wraps long messages at the console width; called from another script, it raises the
  exception unchanged so that `scripts/flow/Foundation.ps1:438` and the flow's trap report it. The
  top-level test is the one `Start-ClaudeGateway.ps1:24` uses (U36). Bash writes with
  `printf '%s\n' ... >&2`.
- Resume command with a persistent checkpoint: `Set-Location -LiteralPath '<checkout>';
  ./Install-ClaudeGateway.ps1` or `cd '<checkout>' && ./install-claude-gateway.sh`, plus the commit
  when git reports one. Without one (Decision 1): the same command with every recorded
  parameter-backed answer as a parameter, followed by one line naming the PowerShell prompt-only
  answers that are asked again.

### 15. No secrets

The checkpoint holds no token, key, password, certificate or connection string. Writers serialise
an allowlist of fields; `AddressCertificatePassword` (`securestring`) and the ARM token of
`Install-ClaudeGateway.ps1:1482` are never passed to them; read-back values are not recorded.

### 16. Relation to ADR-0030, ADR-0032 and P79

- ADR-0030: unchanged. The decision record keeps applied values only; in-flight answers live in the
  checkpoint.
- ADR-0032: unchanged. The first checkpoint write follows the summary confirmation, and the resume
  question is that confirmation. When the guided flow reruns its lead phase, the installer it starts
  resumes from its own checkpoint. After the address step has written the record mid-run, Setup
  checks the recorded gateway instead of running the installer; the installer then resumes through
  `-Action Change -Change foundation` (which passes `-ExistingApimName`) or when run directly.
- P79: one checkpoint per checkout matches one record per checkout. A checkout switched to another
  gateway refuses on the binding and names the field; `-Restart` sets the checkpoint aside as
  `-ArchiveSavedRecord` sets the record aside.

## Tests (RED, mapped to the owner's scenarios)

New checks: `tests/Test-InstallerCheckpoint.ps1` (PowerShell installer, in-process az stubs after
`tests/InstallerPermutationDriver.ps1`), `tests/Test-BashInstallerCheckpoint.ps1` (bash installer,
stub az, pwsh and ps on a PATH, the harness of `tests/Test-BashInstaller.ps1` moved into a shared
file), and one check in `tests/Test-FlowStart.ps1`. Each scenario runs in a fresh copy of the files
the installer reads and a fresh `CLAUDE_GATEWAY_STATE_DIR`.

| Scenario | Check | Before the code exists it fails because |
|---|---|---|
| S1 | graph 404 after group creation resumes at sync | run 2 creates a deployment and reads the groups by name |
| S2 | identity error resumes with read-backs before a new deployment name | no deployment name is recorded; run 2 asks every question |
| S3 | business-unit refusal resumes at business units | run 2 asks every question and redeploys |
| S4 | running deployment is awaited, not created again; past the bound it refuses on one line; an unrecorded running `claude-gw-` deployment is awaited | run 2 creates a second deployment |
| S5 | binding mismatch names the field: tenant, subscription, resource group, gateway, installer version, installer | there is no refusal |
| S6 | completed step missing live runs again: resource group, gateway, pre-existing group | nothing is recorded as completed |
| S7 | live read error never skips: deployment read, group read by id, resource-group read | nothing is verified |
| S8 | corrupt checkpoint refuses and keeps the file (truncated, schema version, unknown step, unsafe answer); `-Restart` sets it aside | there is no checkpoint reader |
| S9 | live lock refuses; exited holder, reused PID, and another host's lock without a heartbeat for 5 minutes are stale; another host's lock with a heartbeat refuses | there is no lock |
| S10 | no token, key, password, certificate or connection string, and every key is in the schema | there is no checkpoint |
| S11 | bash: a group created before a failure is found by id; running deployment awaited; binding mismatch per field; corrupt checkpoint kept; the library passes `bash -n` and has no bash 4 or GNU-only construct (`mapfile`, `declare -A`, `sed -i` without a suffix, `date -d`, `readlink -f`, `stat -c`) | there is no bash checkpoint |
| S12 | Cloud Shell without `clouddrive` warns and prints the resume command; with `clouddrive` the checkpoint is under it (both installers) | there is no Cloud Shell detection |
| R2, R9 | resume summary shows recorded answers, UTC step times and the resume step; `-Restart` discards; a refusal is one line at top level | there is no resume |
| R6 | owner-only permissions (Windows ACL; POSIX 0600 on the Linux and macOS jobs); an interrupted write keeps the previous checkpoint | there is no writer |
| ADR-0032 | a confirmed summary writes the checkpoint before the first change; `-WhatIf`, `--what-if` and a cancelled summary write none | no checkpoint is written after the confirmation |
| Flow | a guided-flow rerun resumes the installer from its checkpoint | the installer starts over |

Every new check gets a mutation that breaks what it guards; a mutation counts only when the suite
loads with its baseline check count and at least one check fails, and a bash mutant also passes
`bash -n`.

A prepared, unpushed workflow runs the bash checks and the POSIX permission and lock checks on
`ubuntu-latest` (bash 5.2.21) and `macos-latest` (bash 3.2.57) (U71).

## Consequences

- A rerun after any of the five field cases resumes after the last step whose result Azure still
  shows, with the same answers, and never starts a second main.bicep deployment.
- A rerun after `git pull` refuses on the installer version until `-Restart`; the restarted run then
  relies on the live checks, the deployment guard and the read-backs.
- Each platform gets a state directory that a support case needs to know about; the run prints its
  path.
- Bash keeps its missing read-back on a first run; P91 refuses only the resume case.
- New code lives in two libraries (`scripts/ClaudeInstallCheckpoint.ps1`, `scripts/install-checkpoint.sh`),
  so `Install-ClaudeGateway.ps1`, already over the 700-line budget, gains only the step hooks.
- The checkpoint is a new operator-side data store, so `docs/ARCHITECTURE.md` and a diagram spec
  change in LOG.

## How we'd know this was wrong

- Operators run `-Restart` after most `git pull`s: the fingerprint binding is too strict and a
  compatible-version rule would serve better.
- The attended Cloud Shell run shows `clouddrive` rename, exclusive create or `chmod` behaving
  otherwise than U66 assumes, or the detection variables absent (U64).
- A support case shows a second main.bicep deployment, a duplicate Entra group or a skipped step
  whose result Azure did not show.

## References

Accessed 2026-10-01.

- Cloud Shell FAQ (ms.date 2026-02-09): <https://learn.microsoft.com/azure/cloud-shell/faq-troubleshooting>
- Persist files in Cloud Shell (ms.date 2024-05-02): <https://learn.microsoft.com/azure/cloud-shell/persisting-shell-storage>
- Cloud Shell ephemeral sessions (ms.date 2024-01-22): <https://learn.microsoft.com/azure/cloud-shell/get-started/ephemeral>
- Cloud Shell image, `linux/tools.Dockerfile:101,126-127` and `linux/base.Dockerfile:60,117`, commit `b903313`: <https://github.com/Azure/CloudShell>
- azure-cli 2.86.0 `core/util.py:737-738`, `core/commands/command_operation.py:383-461`, `role/custom.py:1877-1888`, `:1898-1905`, `:1960-1968`: <https://github.com/Azure/azure-cli/tree/azure-cli-2.86.0>
- Tags, limits and access (ms.date 2025-09-15): <https://learn.microsoft.com/azure/azure-resource-manager/management/tag-resources>
- Tag policies (ms.date 2025-09-15): <https://learn.microsoft.com/azure/azure-resource-manager/management/tag-policies>
- Deployment name and concurrency (ms.date 2026-06-26): <https://learn.microsoft.com/azure/azure-resource-manager/templates/deploy-cli#deployment-name>
- Deployment history deletions (ms.date 2026-06-26): <https://learn.microsoft.com/azure/azure-resource-manager/templates/deployment-history-deletions>
- Asynchronous operations (ms.date 2026-02-27): <https://learn.microsoft.com/azure/azure-resource-manager/management/async-operations>
- Deployments - Get, `ProvisioningState`, api-version 2025-04-01: <https://learn.microsoft.com/rest/api/resources/deployments/get>
- Common deployment errors (ms.date 2025-04-28): <https://learn.microsoft.com/azure/azure-resource-manager/troubleshooting/common-deployment-errors>
- `Environment.SpecialFolder`: <https://learn.microsoft.com/dotnet/api/system.environment.specialfolder>
- XDG Base Directory Specification 0.8: <https://specifications.freedesktop.org/basedir-spec/latest/>
- GitHub-hosted runner images, commit `14d8569`: <https://github.com/actions/runner-images>
