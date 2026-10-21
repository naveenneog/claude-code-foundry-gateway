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

1. After a successful full `--graph` run, the job prints the membership of
   every business-unit group, whether or not the member holds access: the
   mapping `Sync-ClaudeAccess.ps1` writes to `bu-members` on a named-value
   gateway. Units apply deepest first, then in registry order, and the first
   match wins. The lines are JSON with `"event":"projection-membership"`, the
   gateway resource id (lower case), the run id, `part`, `parts` and rows of
   `[oid, unit, parent]`.
2. Each line is at most 3,500 characters (U200).
3. `ClaudeCost()` reads `ContainerAppConsoleLogs` for the last three days and
   keeps lines from jobs named `caj-renew-*` whose gateway equals
   `membership_gateway`, which `Publish-ClaudeQueries.ps1` writes into the
   function. It uses the newest run, by ingestion time, whose parts are all
   present, keyed by job name and run id. A run with no unit member, or no such
   run, leaves the published `bu-members` table in use. `membership_date` names
   the source.
4. A full run that a newer targeted sync overtook (`excludedByNewerTargetedSync`
   above zero) prints no membership, because its view of those people is older
   than the projection. Snapshot, targeted, what-if and failed runs print none.
   The summary reports `membershipPrinted` and, when false, a warning with a
   remedy.
5. The summary line stays last, so the job's alerts are unchanged.

## Consequences

- Moving a person between units reaches chargeback on the next successful full
  run, without `Publish-ClaudeQueries.ps1`. Publishing is still needed after a
  price-book change, on named-value gateways, and once after this change so the
  function carries `membership_gateway`.
- The job gains no permission and no Azure resource.
- Log Analytics ingestion grows with membership: about 70 bytes per member per
  run, or about 21 MB a day for 25,000 members on the default two-hour
  schedule.
- Anyone who can read the workspace can read the object id to unit mapping.
  The same workspace already holds the gateway trace, which carries `UserId`
  and `BusinessUnit` per request.
- A line that is lost or cut makes that run incomplete; `ClaudeCost()` then
  uses the previous complete run or the published table, never a partial one.
- Trust boundary: a container job named `caj-renew-*` in any Container Apps
  environment that sends console logs to this workspace can print lines naming
  this gateway. Such lines replace the mapping until the real job's next
  complete run, at most one sync interval later, because runs are ordered by
  ingestion time. Creating or changing such a job needs write access to a
  Container Apps environment and its diagnostic setting.
- Not observed live: `ClaudeCost()` is checked by Kusto.Language for syntax and
  types and by a static contract test, not executed against a workspace. The
  P120 live check (U200, U201) executes it.
- `scripts/ClaudeChargebackQuery.ps1` records the published `membership_date`
  from the saved function text in report manifests, not the source a report
  used (roadmap follow-up).