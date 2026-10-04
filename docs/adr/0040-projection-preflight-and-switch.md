# ADR-0040: P84 refuses projection switching; renewal admission belongs to P86

- **Status:** P84 decision directed by the lead after council round 1; for switching, superseded by
  [ADR-0045](0045-scheduled-projection-renewal.md) (renewal admission) and
  [ADR-0050](0050-projection-switch-function.md) (the switch)
- **Date:** 2026-09-29
- **Packets:** P84; proposed P86
- **Refines:** ADR-0017 and ADR-0028

## Context and rejected contract

The customer's deployment reached Azure writes before discovering Graph and app-registration
failures. A clean comparison then permitted a switch without scheduled renewal. ADR-0017 gives
records a maximum 7,200-second lease from scan start; expiry causes developer-wide 503 responses.

Council round 1 blocked all five seats at `10ff113`. The original ARM-only admission contract
was insufficient: a digest-pinned scheduled job can carry the expected environment strings,
run `--whatif`, and have a matching succeeded execution without renewing any record.
`sync/src/apply-projection.mjs:122` prints comparison samples; `:136` permits successful dry-run
completion. Environment strings do not prove a write destination. Cron and one success cannot
prove continued schedule activity. U56 records that limitation, not an accepted safety assumption.

## P84 decision

No supported scheduled projection reconciler exists in this release. The deployer's
`-FlipAfterCleanCompare`, the installer's `-FlipProjectionAfterCleanCompare`, and guided
Entitlement's projection path all refuse unconditionally, before Azure writes. A reconciler id,
clean comparison, confirmation, WhatIf or fabricated successful ARM evidence cannot admit a
switch. There is no override. The refusal names the two-hour lease, developer-wide 503 after
expiry, and the scheduled reconciler proposed as P86 in ROADMAP.

P84 can still preflight, deploy beside the gateway, populate and compare without switching.
A declined prerequisite aborts that run rather than reusing old outputs or reporting success.
The documented manual path retains the lease and reconciliation warning; it is not described
as protected admission.

The old job-admission implementation, timestamp parsing and its positive-admission tests are
retired by this explicit contract change. Their replacement proves unconditional refusal,
including a fully matching digest-pinned dry-run. Previous receipts remain historical; they
do not qualify the revised behavior.

## Preflight and operator contract

Deployment and projection sync require PowerShell 7. Shared membership readers retain 5.1
support. Graph errors remain errors; a successful empty collection is positive absence. The
standard tier is required; a confirmed-absent premium tier passes with a note.

The app policy describes default-user rights, not effective custom/delegated roles. Explicitly
true default permission for a member user is positive evidence. Unreadable policy, disabled
default creation, guest or otherwise unproven rights produce WARN: "cannot confirm; if creation
fails, the customer's admin creates the app and you pass -ResolverAppId". P84 does not claim
to enumerate effective directory-role grants. Actual app-creation/resource denial still fails.
A supplied ResolverAppId checks that app/URI without reading Policy.Read.All-class policy data.

Checks show result, evidence, remedy and acting party at the console width. Narrow consoles use
stacked records. Every advertised wait has an estimate. Runner failure diagnostics expose
whitelisted counts and hashed samples, never raw identity-to-unit mappings, and are capped at
40 lines and 4,096 characters in total, heading and truncation marker included. Parsing failures
cannot echo a private JSON fragment.

The existing provider, naming and resource-group RBAC checks remain. Bicep evaluates the
storage name using ARM's canonical resource-group id. Regional capacity cannot be guaranteed.

## Proposed P86 admission contract

The supported reconciler has a tested image and entrypoint, a tenant-admin-granted managed
identity with Graph GroupMember.Read.All, at least hourly execution and lease alerts. Dry-run
overrides in command, arguments or environment are rejected.

Admission reads renewal evidence from Cosmos itself through the runner, bound to the exact
account resource, database, container and tenant being switched. It is not supplied as caller
claims or inferred from job environment strings. The oldest lease expiry has enough margin
for the next scheduled start, a bounded complete scan/apply and a documented safety margin.
`reconciliationGeneration` has advanced at least twice within the last two hours, and the
newest verified renewal is within 60 minutes. Observation history must distinguish real advances
from replay. The precise margin and evidence/history storage remain P86 design and test work.

ARM configuration/execution reads may supplement, but cannot replace, destination-bound renewal
observations. Those observations still cannot guarantee future health; monitored lease alerts
and the operating response remain part of P86. None of this admission machinery ships in P84.

## Architecture and sources

No deployed component, identity, network path or schedule changes in P84. Existing architecture
diagrams remain applicable. The P86 design is not an implemented component.

Microsoft documentation accessed 2026-09-29:

- [Default user role permissions](https://learn.microsoft.com/graph/api/resources/defaultuserrolepermissions?view=graph-rest-1.0).
- [Delegated app roles](https://learn.microsoft.com/entra/identity/role-based-access-control/delegate-app-roles):
  Application Developer/custom roles can grant rights when default registration is disabled.
- [Authorization policy GET](https://learn.microsoft.com/graph/api/authorizationpolicy-get?view=graph-rest-1.0):
  Policy.Read.All is required to read policy, not proof of permission to create an app.
- [Graph groups](https://learn.microsoft.com/graph/api/group-list?view=graph-rest-1.0) and
  [CAE troubleshooting](https://learn.microsoft.com/entra/identity/conditional-access/howto-continuous-access-evaluation-troubleshoot).
- [Naming rules](https://learn.microsoft.com/azure/azure-resource-manager/management/resource-name-rules),
  [Bicep parameter files](https://learn.microsoft.com/azure/azure-resource-manager/bicep/parameter-files),
  [role assignments](https://learn.microsoft.com/cli/azure/role/assignment#az-role-assignment-list).

RED/GREEN, real-caller, locale and mutation receipts are in the council correction block of
`docs/STATUS.md:5`. All correction tests are offline; the lead owns round 2 and the packet gate.
