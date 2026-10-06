# ADR-0057: One sync command for every entitlement store

Status: Accepted (2026-10-07), at the owner's request of 2026-10-06 for the same user sync command on a
named-value gateway and on the Cosmos projection.

## Context

`scripts/Sync-ClaudeAccess.ps1` publishes Entra tier-group membership to the store the gateway reads
(`entitlement-source`). With `-User` it publishes one developer's change, but only on the Cosmos projection:
on named values it refuses with "-User cannot be used with -Store named-value because named values are rewritten
whole" (`scripts/Sync-ClaudeAccess.ps1:144`). An operator therefore has to know the store before running the
command.

The tier groups come from `-StandardGroup` and `-PremiumGroup`, else the local decision record
(`scripts/Get-ClaudeGatewayTarget.ps1`), else the default names (`scripts/Sync-ClaudeAccess.ps1:48-52`). P100
records a gateway's tier groups on the gateway itself, in the named value `entitlement-groups`
(`standard=<object ID>,premium=<object ID>|none`, [ADR-0054](0054-update-flow-entitlement-migration.md)), and
nothing reads it yet. A sync run from another machine, or after the record is lost, can publish the default
groups instead of the gateway's own.

AUM's Direct publication after `aum developer add` or `remove` runs `Sync-ClaudeAccess.ps1` without `-User`
(`scripts/Invoke-ClaudeFinOps.ps1:144-151`), so on a projection gateway each developer change exports and applies
a full snapshot. U25 records that this path is not measured live.

## Options

1. Keep the refusal and document a command per store. The operator still has to know the store.
2. `-User` on named values runs the whole-list refresh, which is the only write named values support, and then
   reports the developer's resulting tier. The lists stay a complete copy of Entra.
3. `-User` on named values patches one object ID into or out of `allow-standard` and `allow-premium`. The lists
   would drift from Entra for every other developer, and two patches can race on one value.

## Decision

1. `-User` works on every store. On a named-value gateway it runs the whole refresh (option 2) and prints the
   developer's tier as written: standard, premium or none. On the projection it is the targeted sync, as today.
   `-WhatIf` writes nothing and prints the tier the refresh would give.
2. Without `-StandardGroup` and `-PremiumGroup`, the tier groups come from the gateway's `entitlement-groups`, then
   a decision record of this gateway, then the default names. A group that `entitlement-groups` names and Microsoft
   Graph does not find stops the sync before any write; the record and default names are not used in its place.
   `premium=none` means the gateway has no premium group.
3. A gateway without `entitlement-groups` gets it after its first successful sync, not with `-WhatIf`. When
   `-StandardGroup` or `-PremiumGroup` resolve to other groups than the gateway records, the sync refuses before
   any write and names `-RecordGroups`; with `-RecordGroups` it syncs and then records the new groups.
4. AUM's Direct publication passes the developer's object ID as `-User`, so a projection gateway runs a targeted
   sync and a named-value gateway the whole refresh.
5. `entitlement-groups` is read and written through one module, `scripts/ClaudeEntitlementGroups.ps1`, which
   the update flow's migration 0004 also uses.

## Consequences

- One command, `scripts/Sync-ClaudeAccess.ps1 -ResourceGroup <rg> -ApimName <apim> -User <upn or object ID>`,
  publishes one developer's change on every gateway.
- On named values, `-User` costs a whole refresh: a Microsoft Graph read of both groups, and up to three
  named-value writes. Named values hold about 110 developers per tier list, so the refresh stays small.
- A sync can write one more named value, `entitlement-groups`, the first time it runs on a gateway that lacks it.
- A changed tier group is an explicit act (`-RecordGroups`), as P100 made it in the update flow.
- Microsoft Graph can report a membership change late; a `-User` report taken right after a change can show the
  previous tier (U157).
