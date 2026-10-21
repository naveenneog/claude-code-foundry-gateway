# ADR-0066: Chargeback membership from the projection sync job

**Status:** Proposed
**Date:** 2026-10-21
**Packet:** P120

## Context

`ClaudeCost()` attributes spend to the business unit a developer belongs to
today, and keeps the unit stamped at request time as `business_unit_at_time`
(`analytics/chargeback-cost.kql`). Today's mapping is a `datatable` that
`scripts/Publish-ClaudeQueries.ps1` builds from the gateway's `bu-members` and
`bu-parents` named values when an operator runs it. Log Analytics cannot read
APIM named values, so the mapping is only as current as the last publish.

On a gateway that serves entitlement from the Cosmos projection, the sync job
(`sync/src/apply-projection.mjs --graph`, deployed by
`infra/projection-renewal.bicep`) resolves every member's unit from Entra on
each run and writes it into the projection records. It does not write
`bu-members`, and neither does `scripts/Sync-ClaudeAccess.ps1` on a projection
gateway, so the published mapping there can be empty or stale.

The job already sends its console output to the gateway's Log Analytics
workspace through a diagnostic setting, in `ContainerAppConsoleLogs` with a
`JobName` column (U107), and the job's alerts read that table.

Options considered:

1. **Job republishes the saved function** through
   `Microsoft.OperationalInsights/workspaces/savedSearches`. Needs a write role
   on the workspace for the job identity, the price book inside the image, and
   a function body that grows with every member.
2. **Job sends membership to a custom table** through the Logs Ingestion API.
   Needs a data collection endpoint, a data collection rule, a custom table and
   a role assignment.
3. **Job prints membership lines to its console log**, and `ClaudeCost()` reads
   the newest complete set from `ContainerAppConsoleLogs`.

## Decision

Option 3.

1. After a successful full `--graph` run, the job prints its resolved
   membership before the final summary line, as JSON lines with
   `"event":"projection-membership"`, the run id, the run time, `part`,
   `parts` and `rows` of `[oid, unit, parent]`. Members without a unit are
   omitted. A run that resolves no unit prints one line with no rows, so "no
   units today" is also current.
2. Each line is at most 3,500 characters (U200).
3. `ClaudeCost()` reads `ContainerAppConsoleLogs` for the last three days, keeps
   lines from jobs whose name starts with `caj-renew-`, and uses the newest run
   whose parts are all present. When there is none, it uses the published
   `bu-members` table as before. `membership_date` names the source.
4. Snapshot, targeted (`--user`), what-if and failed runs print no membership.
5. The summary line stays last, so the job's alerts are unchanged.

## Consequences

- Moving a person between units reaches chargeback on the next sync run,
  without `Publish-ClaudeQueries.ps1`. Publishing is still needed after a price
  book change and on named-value gateways.
- The job gains no permission and no Azure resource.
- Log Analytics ingestion grows with membership: about 70 bytes per member per
  run, or about 21 MB a day for 25,000 members on the default two-hour
  schedule.
- Anyone who can read the workspace can read the object id to unit mapping.
  The same workspace already holds the gateway trace, which carries `UserId`
  and `BusinessUnit` per request.
- A line that is lost or cut makes that run incomplete; `ClaudeCost()` then
  uses the previous complete run or the published table, never a partial one.
- A job in another Container Apps environment that logs to the same workspace
  with a `caj-renew-` name could supply membership. Creating one needs write
  access to the subscription.
