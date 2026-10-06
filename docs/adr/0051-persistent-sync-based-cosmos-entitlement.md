# ADR-0051: Cosmos entitlement persists until a sync changes it, and syncs run on demand

- **Status:** Accepted, with the owner's approval of P97's architecture decisions on 2026-10-05
- **Date:** 2026-10-05
- **Packet:** P97
- **Supersedes:** the lease of [ADR-0017](0017-projection-freshness-and-admission.md) (records expire
  7,200 seconds after the scan that wrote them), the evidence gate of
  [ADR-0045](0045-scheduled-projection-renewal.md) (three renewals before a switch), and, in
  [ADR-0005](0005-identity-projection.md), the failure-contract row "Record beyond the staleness limit:
  Deny" and the consequence "Revocation is bounded" (amendment 2, council round 2)
- **Refines:** [ADR-0049](0049-projection-renewal-deployment.md) (the job's deployment is kept and
  becomes optional) and [ADR-0050](0050-projection-switch-function.md) (one switch function, without the
  renewal receipt)

## Context

Since ADR-0017 every Cosmos entitlement record expires 7,200 seconds after the directory scan that
wrote it, and the resolver answers 503 for an expired record. That makes a scheduled job a hard
dependency of every request:

- The job must rewrite every record every run, about 730 million writes a month at 500,000 developers
  on the 30-minute schedule ([SCALE.md](../SCALE.md)).
- A job outage longer than two hours stops every developer, and at that size there is no fallback
  store, because named values hold about 93 to 110 developers.
- The job reads Microsoft Graph with an application permission that only a Privileged Role
  Administrator or Global Administrator can grant
  (`scripts/Grant-ClaudeProjectionRenewalGraphAccess.ps1:6`). Operators without that role cannot
  finish a projection deployment.
- The switch from named values waits for three job runs, 60 to 90 minutes.

The owner asked for the named-value behaviour on Cosmos: access lasts until a sync removes or moves
the person, the sync runs when someone is added or removed, and a sync for one known person does not
rescan the whole directory.

## Options

1. **Keep the lease and lengthen it.** This needs the same job and grant. It also widens the window in
   which a removed person keeps access while the job is broken.
2. **Keep the lease and trigger the job on Entra changes.** This adds a webhook or Event Grid
   subscription and its renewal to the same job and grant, and leaves the outage property in place.
3. **Persist records and keep the job as the only writer.** This removes the outage property, but
   every sync still needs the tenant-admin grant.
4. **Persist records. The operator's sign-in reads Entra, as `Sync-ClaudeAccess.ps1` does for named
   values, and the in-VNet runner writes Cosmos. The job stays optional for very large tenants.**
   Chosen.

## Decision

1. **Records persist.** A record grants its tier until a sync deletes or changes it. Writers no longer
   write `expiresAt` on entitlement records. A record that still carries a legacy `expiresAt` is served
   until that time and then answered as no record (404); the first full sync rewrites it without one.
   Amended in council round 1: ignoring a passed `expiresAt` would let records left expired by a job
   outage before this decision grant again. The resolver still
   answers 404 for a status record, 403 for another tenant and 409 for an unknown tier. It answers 503
   for a record whose generation or verification time is missing, malformed or in the future.
2. **The gateway caches answers for `entitlement-cache-seconds`.** It no longer checks expiry. A 404 is
   cached for at most 60 seconds. A resolver failure is a 503, as ADR-0005 requires.
3. **Writers write only changes.** A full sync writes added, moved and changed records and deletes the
   records of people no longer entitled. It still refuses when the groups resolve to nobody while the
   projection holds records.
4. **Snapshots keep an apply-by limit.** An exported snapshot must be applied within 7,200 seconds of
   its scan start, so an old file cannot restore old membership.
5. **`Sync-ClaudeAccess.ps1` syncs the store the gateway uses.**
   - `-Store auto` (the default) follows `entitlement-source`.
   - On a projection gateway it exports a snapshot with the operator's sign-in, starts the in-VNet
     runner if it has stopped, and applies the snapshot.
   - `-User <name-or-object-id>` syncs one person. Their transitive membership in each configured
     group comes from Microsoft Graph `checkMemberGroups`, in batches of at most 20 group ids. For
     other users, that call needs User.ReadBasic.All and GroupMember.Read.All, as delegated or
     application permissions ([Microsoft Learn](https://learn.microsoft.com/graph/api/directoryobject-checkmembergroups),
     updated 2026-06-12). The targeted sync uses the operator's delegated sign-in. Only that
     person's record is written or deleted.
   - `-Store named-value` refreshes the named-value lists, which a rollback needs.
6. **The switch needs no job.** It needs a successful full sync of this projection in the last 24
   hours and no record the resolver would refuse. The drift check and the read-only compare against the
   gateway's named values stay, and the resolver's app must have a service principal. A gateway with no
   named-value entitlement compares the projection with a fresh full snapshot of Entra instead.
7. **The runner is started when it has stopped.** It runs `sleep 10800` with restart policy Never.
   `az container start` starts a container group whose containers terminated on their own
   ([Microsoft Learn](https://learn.microsoft.com/azure/container-instances/container-instances-stop-start),
   updated 2025-11-17).
8. **The sync job is optional.**
   - Its trigger is Manual unless a schedule is passed.
   - It runs a full sync with the same write rules.
   - It needs the Graph application permission and is meant for tenants whose directory is too large
     to send through the runner.
   - Its alerts cover failed runs and denied Graph reads. A stale-run alert exists only on a schedule.
9. **The deployer completes the resolver's sign-in path.** It creates the resolver app's service
   principal when missing, since Entra refuses tokens for an application without one. It refuses a
   region that differs from an existing `cosmos-<prefix>`. It records the prefix in the gateway named
   value `entitlement-projection-prefix`.
10. **One Cosmos writer (amendment 2, council round 2).** `sync/src/apply-projection.mjs` is the only
    writer of the entitlement container. `scripts/Sync-ClaudeProjection.ps1` resolves membership into a
    snapshot file and contacts no Cosmos endpoint; without `-ExportPath` it refuses before it signs in.
    Its direct data-plane write path is removed: that path took no apply lock, wrote no status record,
    kept legacy `expiresAt` values and read status documents as entitlement records.
11. **Applies are serialised (amendment 2, council round 2).** Every apply that writes takes a lease
    lock: the document `projection-apply-lock` in the entitlement container. The first writer creates
    it; another writer takes it over only after its lease has passed, with an `If-Match` condition on
    its ETag ([Microsoft Learn](https://learn.microsoft.com/azure/cosmos-db/database-transactions-optimistic-concurrency)).
    The lock is taken after the directory is resolved, and existing records and sync statuses are read
    inside it, so a sync that finished while another was resolving is always seen.
    - A full snapshot older than a successful full sync is refused.
    - A targeted snapshot older than a successful sync that covered the same person is refused.
    - A full apply leaves out the people whose targeted sync finished after its scan, less a 300-second
      margin for clock skew.
    - Status documents are matched by type and tenant, since they live in the container they describe.
      Every apply that writes carries the Cosmos account resource id, stored in lower case.
    - Documents with a `type` (status records and the lock) are never read as entitlement records.

## Consequences

- **Removing a person takes a sync.** A person removed from a group keeps access until a sync runs,
  then for at most the cache window (`entitlement-cache-seconds`, 15 minutes to 4 hours in the
  installer). Named values behave the same way.
  - A person whose Entra account is disabled cannot obtain new tokens. A default access token lasts
    60 to 90 minutes ([Microsoft Learn](https://learn.microsoft.com/entra/identity-platform/access-tokens),
    updated 2026-07-17).
- **A failed sync can leave part of its changes.** A sync that fails before its first write (the
  directory read, snapshot validation, the lock or a refused plan) leaves the projection as it was. A
  sync that fails during its writes can leave some of them applied: Cosmos transactions cover one
  logical partition key ([Microsoft Learn](https://learn.microsoft.com/azure/cosmos-db/transactional-batch),
  updated 2026-04-27), and records are partitioned by object id. Such a run writes no status record, so
  it never counts as switch evidence, and the next successful sync converges the records. A stopped
  sync no longer stops developers, and it no longer revokes access by itself.
- **Runner transfer limits large full syncs.** The runner receives files through `az container exec`
  in chunks under 5,000 characters, about five seconds each (`scripts/ClaudeRunner.ps1`). A full sync
  of a very large directory through the runner is slow, and the optional job reads Graph inside the
  network instead. Targeted syncs stay small at any size.
- **Write volume drops.** A full sync writes only changes, so the standing write volume follows
  directory churn rather than headcount.
- **Superseded tests change.** Tests that asserted the lease, the three-generation admission, the
  45-minute newest run and the 60-minute margin now assert these decisions. Each change is named in
  its commit.
- **The prefix is script-owned.** `entitlement-projection-prefix` is written by the projection deployer
  (and by hand in [AZ-COMMANDS](../AZ-COMMANDS.md)). `infra/main.bicep` does not declare it, so a
  gateway redeploy keeps it. The guide check in `tests/Test-AzCommandsGuide.ps1` therefore accepts a
  named-value id that an in-scope script writes, as well as those the templates and the policy declare.
- **Legacy records and retired rules.** A record that still carries an `expiresAt` from before this
  decision is not served once that time passes; the first full sync rewrites it without one. A redeploy
  of the optional job removes the expiry-margin alert rule, and, for a manual job, the no-success rule.
