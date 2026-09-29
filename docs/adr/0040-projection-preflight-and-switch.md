# ADR-0040: Projection preflight and evidence-gated switch

- **Status:** Proposed; owner acceptance pending
- **Date:** 2026-09-29
- **Packet:** P84
- **Refines:** ADR-0017 and ADR-0028

## Context

The owner's 2026-09-29 customer run reached Azure writes before discovering Graph Conditional
Access failures and missing application-registration permission. A failed lookup was interpreted
as an absent group; runner parsing hid the useful output. A clean initial comparison alone
allowed a switch despite no scheduled renewal. ADR-0017 bounds each record's lease to 7,200
seconds from scan start, after which the gateway refuses new requests with 503.

## Decision

The implementation contract below precedes production changes. Owner acceptance of this
proposed refinement remains with the lead's council and the owner.

The deployment preflight is shared by normal and preflight-only invocations. Failed or
unreadable evidence fails closed, before an Azure write. An unavailable capacity guarantee
is reported as a limitation rather than a successful capacity test.

Deployment and projection sync require PowerShell 7 or later. The shared membership reader
continues to support Windows PowerShell 5.1 and 7. Native stderr and exit status are evaluated
together; an HTTP error or an invalid collection cannot mean an empty group. Graph's filtered
group collection distinguishes absence (`value: []`) from an unsuccessful request. Duplicate
display names fail rather than selecting the first group. Both stability probes use Graph
reads with a 25-second interval; the preflight estimate is 30-90 seconds, excluding slow
customer networks.

An existing resolver app must have the expected client id and `api://<id>` identifier URI.
Without an existing app, the signed-in account must be a member user and the readable
authorization policy must explicitly allow app creation. This is a conservative sufficient
check, not a directory-role evaluator: tenants that deny the policy read, disable default
registration, or use role/custom delegation can supply an admin-created `-ResolverAppId`.
An unavailable permission read is reported as unproven, not as proof of insufficient privileges.

The provider set includes Microsoft.App, Microsoft.DocumentDB, Microsoft.Web,
Microsoft.ContainerInstance, Microsoft.Network, Microsoft.Storage, Microsoft.OperationalInsights,
Microsoft.Insights and Microsoft.Authorization. Role evidence is the built-in Owner role, or
Contributor together with User Access Administrator, inherited or direct at the target resource
group, including group memberships. Conditional assignments and custom roles are not substituted
for this sufficient proof. Azure Policy, deny assignments, regional capacity and later permission
changes can still reject a deployment.
Management-group assignments count only as ancestors returned by that resource-group-scoped
`--include-inherited` query, not by an unscoped subscription-wide role listing.

The prefix uses the intersection of the three templates' naming rules: 1-37 lowercase letters,
digits and separated hyphens, starting and ending in a letter or digit. The Cosmos name is the
tightest length bound. Availability is checked for Cosmos, Functions and storage; an unavailable
name is accepted only when the exact resource already belongs to the target resource group.
The storage hash is evaluated locally by `az bicep build-params` with literal resource-group id
and prefix. This preserves `resolver.bicep:112`, rather than reimplementing `uniqueString` or
renaming existing accounts. The Web name-availability POST is a read-only query, not a deployment.
The resource-group id comes from ARM's response, not operator casing: `uniqueString` inputs
are case-sensitive even though ARM resource-id comparisons are not.

### Switch evidence, version 1

`-ReconcilerResourceId` identifies an existing `Microsoft.App/jobs` resource in the gateway
subscription. Only ARM GETs read its definition and execution pages (API `2024-03-01`).
The job has successful provisioning, a Schedule trigger and an explicit replica timeout.
Supported UTC cron expressions have four trailing `*` fields and a minute field of `*`, a
minute number/list, or `*/n` (1-59). Other expressions are refused rather than interpreted
optimistically. This is a deliberately bounded at-least-hourly contract, not a general cron engine.

The job has one container, no init containers, an image pinned by SHA-256 digest, and these
literal non-secret environment values:

| Name | Required value |
|---|---|
| `CLAUDE_PROJECTION_CONTRACT` | `1` |
| `PROJECTION_GATEWAY_RESOURCE_ID` | The exact gateway ARM id |
| `PROJECTION_ACCOUNT_RESOURCE_ID` | The exact Cosmos account ARM id |
| `PROJECTION_TENANT_ID` | The gateway tenant |
| `PROJECTION_DATABASE` | `claude` |
| `PROJECTION_CONTAINER` | `entitlement` |
| `PROJECTION_MAX_AGE_SECONDS` | `7200` |

Environment variable names are case-sensitive, as in the Linux container. Resource-id and tenant
GUID values compare case-insensitively; the contract version, database, container and lease
values compare exactly. The installer checks the binding after resolving its actual gateway
name but before any foundation write.

A succeeded execution has valid start and end times, started less than 7,200 seconds ago, and
ran the current container image, command, arguments and environment. An unrelated or old
template's success does not count. A newer failed execution refuses the switch. Each page stays
under the same ARM job path. Execution lists may omit the optional `id` (as the documented
2024-03-01 example does); a safe execution name then identifies it under that verified job's
list URL. A supplied id must match that name and job exactly. A null `secretRef` or final Graph
`nextLink` is not a secret reference or another page. The contract assumes the customer-controlled pinned image implements
the declared renewal operation: ARM status proves successful process termination, not application
semantics. P86 must define and test that image, identity grant and monitoring.

The guard runs during preflight when a switch is requested, and again immediately before the
first of the three named-value writes. The second guard uses the actual exported snapshot's
absolute expiry, with sufficient remaining lease for a schedule interval plus the job's replica
timeout. The first guard states the expiry of a scan starting now as an estimate. Both describe
the developer-wide 503 consequence after expiry. The installer passes
`-ProjectionReconcilerResourceId`; the guided-flow decision records `reconcilerResourceId`.
The deployer remains the final shared enforcement point. No override or acknowledgement bypass
exists. No schedule is provisioned here.
An explicitly supplied zero snapshot expiry is invalid, not an invitation to estimate a new
lease. Each of the three switch writes pins the subscription verified during preflight.

## Options

A clean comparison alone retains the observed outage risk. A typed acknowledgement still
permits switching with no renewal and is not selected. A verified existing scheduled job gives
read-only evidence while keeping schedule provisioning in P86.

## Architecture

No deployed component, identity, network path or schedule is added or changed. P84 changes
operator-side validation and switch admission. The existing diagrams remain applicable.

## Evidence

Microsoft documentation accessed 2026-09-29:

- [Authorization policy GET](https://learn.microsoft.com/graph/api/authorizationpolicy-get?view=graph-rest-1.0):
  `Policy.Read.All`, one object and `defaultUserRolePermissions.allowedToCreateApps`.
- [Default user permissions](https://learn.microsoft.com/graph/api/resources/defaultuserrolepermissions?view=graph-rest-1.0)
  and [application registration](https://learn.microsoft.com/entra/identity-platform/quickstart-register-app).
- [Graph group collection](https://learn.microsoft.com/graph/api/group-list?view=graph-rest-1.0).
- [CAE troubleshooting, IP address configuration](https://learn.microsoft.com/entra/identity/conditional-access/howto-continuous-access-evaluation-troubleshoot):
  split tunneling, IPv4/IPv6 variation and trusted named locations.
- [Resource naming](https://learn.microsoft.com/azure/azure-resource-manager/management/resource-name-rules),
  [Cosmos CLI](https://learn.microsoft.com/cli/azure/cosmosdb#az-cosmosdb-check-name-exists),
  [storage CLI](https://learn.microsoft.com/cli/azure/storage/account#az-storage-account-check-name),
  [Web availability API](https://learn.microsoft.com/rest/api/appservice/check-name-availability/check-name-availability?view=rest-appservice-2024-04-01).
- [Bicep parameters](https://learn.microsoft.com/azure/azure-resource-manager/bicep/parameter-files)
  and [build-params](https://learn.microsoft.com/azure/azure-resource-manager/bicep/bicep-cli#build-params).
  Local offline evaluation on 2026-09-29 produced `stres52p2c4jfs43ig` for the fixture's
  resource-group id and `p84fixture`. Compilation returned `parametersJson`; no Azure request ran.
- [Role assignment CLI](https://learn.microsoft.com/cli/azure/role/assignment#az-role-assignment-list)
  and [privileged built-in role ids](https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/privileged).
- [Job GET](https://learn.microsoft.com/rest/api/resource-manager/containerapps/jobs/get?view=rest-resource-manager-containerapps-2024-03-01)
  and [execution list](https://learn.microsoft.com/rest/api/resource-manager/containerapps/jobs-executions/list?view=rest-resource-manager-containerapps-2024-03-01):
  `properties.configuration`, `properties.template`, execution `status`, `startTime`, `endTime`,
  `template` and collection `nextLink`.

The prior lease decision is `docs/adr/0017-projection-freshness-and-admission.md:10`.
Provider/name inputs are `infra/projection.bicep:70`, `infra/projection-network.bicep:51` and
`infra/resolver.bicep:110`. The offline native-fixture pattern is `tests/TestAzureFixture.ps1:2`.
All P84 tests use offline Azure fixtures; no live availability or permissions claim follows
from those tests. Successful preflight evidence is a point-in-time check, not a capacity or
future availability guarantee.

Offline measurement on 2026-09-29 at `4083c8b`: the complete 240-assertion suite passed, all
111 valid-syntax mutations failed assertions without losing the baseline count, and the restored
240 passed (`tests/Test-ProjectionPreflight.ps1:1`, `tests/Test-ProjectionPreflightNegative.ps1:1`).
The first 99/108 proof and the detector corrections are retained in `docs/STATUS.md:5`.
The lead's council/gate and owner acceptance remain pending; no live Azure proof was performed.
