# ADR-0045: Scheduled projection renewal and evidence-gated switching

- **Status:** Proposed for P86
- **Date:** 2026-10-01
- **Packet:** P86
- **Refines:** ADR-0017 and ADR-0040

## Decision

The supported Cosmos entitlement deployment has a scheduled reconciler before
any automated switch to `entitlement-source=projection`. The reconciler is an
Azure Container Apps Job in an internal workload-profiles Container Apps
environment, on its own at-least-/27 subnet delegated to
`Microsoft.App/environments`. It is separate from the resolver subnet in the
projection VNet address plan. The default cadence is every 30 minutes,
configurable by parameter.

ADR-0017 sets the lease at no more than 7,200 seconds from scan start. An hourly
run tolerates no missed run: one failure plus one late start can leave no
60-minute margin before expiry. A 30-minute schedule gives four planned starts
inside the two-hour lease, so three consecutive missed runs are tolerated before
expiry. Admission still requires current evidence; the schedule is not a
guarantee of future health.

The job runs as a user-assigned managed identity. A tenant administrator grants
Microsoft Graph `GroupMember.Read.All` once with
`scripts/Grant-ClaudeProjectionRenewalGraphAccess.ps1` or the documented
`az rest` commands. The job identity receives Cosmos SQL data-plane write access
only on `/dbs/claude/colls/entitlement`.

The sync image is built from `sync/Dockerfile` and used by digest. The default
registry SKU is ACR Basic for standing cost; Basic uses the public ACR endpoint
with Entra authentication. A private ACR endpoint requires Premium. ARM command
or args overrides are not allowed for admission, so the tested image entrypoint
and default command own the job invocation.

Status records share the `entitlement` container. They have
`type = projection-reconciliation-status`, `ttl = 21600`,
`id = projection-status::<tenantId>::<reconciliationGeneration>`, and partition
key `/oid = projection-status::<tenantId>`. That partition value is never a
GUID, so resolver point reads by developer object id cannot return a status
record. Query paths filter status records out, and orphan deletion skips them.

Admission reads two sources and both must pass:

1. Cosmos status history and oldest entitlement expiry, read through the
   existing in-VNet runner with fixed repository code.
2. The ARM Container Apps Job definition, read separately, proving the pinned
   image digest and no command/args override.

The switch is admitted only when the oldest expiry has at least 60 minutes of
margin, the reconciliation generation advanced at least twice in two hours, the
newest successful renewal is within 45 minutes, the status records are bound to
the destination account/database/container and tenant, and an email-backed
action group exists for the alerts. Otherwise the deployer, installer and guided
flow refuse with the reason and remedy. Too-little-history refusals name the
expected 60-90 minute wait on the 30-minute schedule.

Azure Monitor scheduled-query alerts cover no successful run in 45 minutes,
oldest expiry margin below 60 minutes, and Graph read denied or failed. The
action group with email receivers is a required deployment input. Without it,
the deployer warns that alerts notify no one and admission refuses the switch.

## Cost note

README.md records the existing hourly 500,000-member estimate: about
365 million writes per 730-hour month, about USD 538/month at 5.9 RU/write and
USD 0.25 per million RU. On that basis:

| Members | Hourly writes/month | Hourly write cost | 30-minute writes/month | 30-minute write cost |
|---:|---:|---:|---:|---:|
| 500 | 365,000 | USD 0.54 | 730,000 | USD 1.08 |
| 5,000 | 3,650,000 | USD 5.38 | 7,300,000 | USD 10.77 |
| 500,000 | 365,000,000 | USD 538.38 | 730,000,000 | USD 1,076.75 |

These are inferred write costs, not a measured scheduled-sync bill. They exclude
Graph reads, Container Apps execution, Log Analytics ingestion, ACR, retries and
other usage. Any price citation in operator docs uses Azure Retail Prices API
data with its access date.

## Consequences

Projection switching is no longer admitted by ARM cron, environment strings,
image digest or a single succeeded execution alone. Destination-bound Cosmos
evidence is required. A live positive Graph read still needs a tenant where an
administrator grants `GroupMember.Read.All`; the offline packet can prove the
denied path, status record shape, admission rules, templates and scripts.
