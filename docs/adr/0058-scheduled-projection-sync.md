# ADR-0058: The projection sync job runs on a schedule the admin sets

- **Status:** Accepted. The owner asked on 2026-10-07 for an admin-set interval, 2 hours as the default and
  30 minutes as the shortest, with the job deployed by the installer whenever the projection is chosen.
- **Date:** 2026-10-08
- **Packet:** P104
- **Builds on:** [ADR-0049](0049-projection-renewal-deployment.md) (registry, image and job deployment),
  [ADR-0051](0051-persistent-sync-based-cosmos-entitlement.md) (records persist until a sync changes them; the
  job is optional), [ADR-0052](0052-cosmos-default-installer.md) (the installer deploys the projection by
  default; `-DeploySyncJob` deploys the job)

## Context

The owner's request on 2026-10-07: an admin adds or removes a developer in the tier group
(`claude-code-standard`, `claude-code-premium`) or a business-unit group in the Entra portal, and a scheduled
job applies the change. Only the added or removed developers change; existing entitlement is never wiped.

What exists, read from the code on 2026-10-08:

- `scripts/Deploy-ClaudeProjectionRenewal.ps1` deploys the job with a Manual trigger, or a schedule given as
  `-CronExpression` (five fields). `-ImageDigest` skips the image build.
- `infra/projection-renewal.bicep` creates the job (1 vCPU, 2 GiB, `replicaTimeout` 3600, `parallelism` 1),
  a failed-run alert, a Graph-denied alert and, when scheduled, a no-success alert whose query and window are
  fixed at 45 minutes (`sqr-projection-<prefix>-no-success-45m`). With a 2-hour schedule, that rule finds no
  success for about 75 minutes of every 2 hours.
- The installer deploys the job only with `-DeploySyncJob`, after the switch, with the publisher email as the
  alert address (`Install-ClaudeGateway.ps1:1630-1632`).
- `planChanges` (`sync/src/plan.mjs:78`) writes new or changed records, deletes records whose developer left
  every tier group and leaves unchanged records alone. It refuses only a resolution to nobody while records
  exist. There is no limit on how many records one run deletes.
- The resolver refuses no record by age (`resolver/src/entitlement.mjs:59-68`). The gateway caches "not
  entitled" for at most 60 seconds and an entitled answer for `entitlement-cache-seconds`
  (`infra/policy.xml:140-163`).
- The job reads Microsoft Graph with application permission `GroupMember.Read.All`, which only a Privileged
  Role Administrator or Global Administrator grants (`scripts/Grant-ClaudeProjectionRenewalGraphAccess.ps1`).
  U17 is open: the reference tenant has no grant.

Facts from research are in [UNKNOWNS](../UNKNOWNS.md) U165-U169: cron is evaluated in UTC; a scheduled
execution can start while the previous one runs; a log search alert reads at most two days; the job costs
USD 0.00003 per run-second above the subscription's monthly free grant.

## Options considered

1. **Ask for a cron expression.** Exists today. An expression does not state its period, so the no-success
   alert window cannot be derived from it.
2. **A fixed list of intervals mapped to cron (chosen).** Each interval has a known period, so the alert window
   and the cost follow from it.
3. **Microsoft Graph change notifications** start a run when a group changes. They need an HTTPS notification
   endpoint and a subscription renewed before it expires: at most 41,760 minutes (under 29 days) for groups
   ([Learn: subscription resource type](https://learn.microsoft.com/graph/api/resources/subscription), updated
   2026-09-17). This adds components for a delay the owner accepts at 30 minutes to 2 hours. Not chosen; a
   possible later packet.

## Decision

1. **Intervals.** `30m`, `1h`, `2h` (default), `3h`, `4h`, `6h`, `8h`, `12h` or `manual`, mapped to
   `*/30 * * * *`, `0 * * * *`, `0 */2 * * *`, `0 */3 * * *`, `0 */4 * * *`, `0 */6 * * *`, `0 */8 * * *` and
   `0 */12 * * *` (UTC). Anything shorter than 30 minutes is refused. `-CronExpression` is replaced by
   `-SyncInterval` in the deploy script; it is refused before any Azure call with the interval it maps to.
2. **The installer deploys the job with the projection.** `-ProjectionSyncInterval` (default `2h`) replaces the
   opt-in `-DeploySyncJob`, which is still accepted and changes nothing. `none` skips the job. Without the
   parameter, a re-run keeps the interval of the deployed job, found by its `claude-projection-prefix` tag
   (`scripts/ClaudeProjectionSyncJob.ps1`); a deployed cron outside the list stops the run before any write until
   the parameter names an interval. With `none`, a deployed job is left as it is, and the review and the next
   steps name its schedule. A re-run that redeploys the job keeps its alert addresses, registry SKU, workspace
   and subnet (`Get-ClaudeProjectionSyncJobSettings`), read before the review; a registry closed to public access
   or with a SKU the template does not deploy stops the run, and a failed renewal deployment is deployed again.
   The review lists the interval, runs per month and cost.
3. **The Graph grant stays with a tenant administrator.** The installer reads the job identity's app role
   assignments and prints whether it holds `GroupMember.Read.All`, and if not, the grant command. It writes
   nothing in Microsoft Graph. Until the grant, scheduled runs stop at the Graph stage, write nothing and fire
   the Graph-denied alert.
4. **Alerts follow the interval.** The no-success rule reads 2 x interval + 15 minutes (75 minutes for `30m`,
   24 hours 15 minutes for `12h`) through `overrideQueryTimeRange`, with a 5-minute window and evaluation, and
   has one name for every interval. The deploy script removes the earlier `-no-success-45m` rule. P97's rule
   query held the literal text `${renewalLogs}`, because Bicep does not interpolate `'''` strings; the rule
   joins its query in a one-line string, and `tests/Test-ProjectionRenewal.ps1` refuses `${` in any compiled
   rule query.
5. **A removal ceiling for unattended runs.** In job mode (`--graph`), a plan that deletes more than
   max(10, 10% of the existing entitlement records) writes nothing and ends with `projection-renewal-failed`,
   stage `removal-ceiling`, and both counts; the failed-run alert fires. Additions, tier changes and
   business-unit changes are not limited. An attended `Sync-ClaudeAccess.ps1` run applies such a plan.
6. **Changing the interval later.** `scripts/Set-ClaudeProjectionSyncSchedule.ps1 -Interval <value>` reads the
   deployed job and its action group and redeploys `infra/projection-renewal.bicep` with the same image
   digest, so the trigger and the alert change together. It passes `-KeepRegistry`, so the registry and the job
   identity are read from their deployment rather than deployed again, and it changes only the job that the
   `projection-renewal-<prefix>` deployment created, with that deployment's workspace, subnet and tier groups; a
   job whose groups differ from the recorded ones is refused. At the same interval it writes nothing unless the
   alert rules or the recorded schedule differ from the template. The Azure CLI guide's renewal block takes
   `SYNC_INTERVAL` with the same table, checked against `scripts/ClaudeProjectionSchedule.ps1` by
   `tests/Test-AzCommandsRenewal.ps1`. In the Azure portal, the script runs in Azure Cloud Shell; editing only
   the job's cron expression would leave the no-success alert on the old range.

## Consequences

- Adding a developer to a tier or business-unit group takes effect at the next run plus at most 60 seconds;
  removal at the next run plus at most `entitlement-cache-seconds`.
- A run that takes longer than the interval overlaps the next execution. The later run waits up to 900 seconds
  for the apply lock; if the earlier run still holds it, the later run stops before any write and the failed-run
  alert fires (U165).
- Cost: 1,460 runs a month at `30m` and 365 at `2h`, at 730 hours a month (`scripts/AzureRetailPrice.ps1:281-295`). The first 180,000 run-seconds a month are inside the
  subscription's free grant when nothing else uses it (U168).
- U17 stays open: the positive scheduled path is proven offline and in a tenant where the grant can be given.
