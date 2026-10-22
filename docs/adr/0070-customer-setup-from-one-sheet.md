# ADR-0070: Customer setup from one sheet

**Status:** Proposed
**Date:** 2026-10-22
**Packet:** P124

## Context

The customer keeps its tiers and 47 Entra groups in one JSON sheet and asked
for a client-run setup on its existing API Management, Foundry account and
network, as one command rather than a list of steps. The installer
(`Install-ClaudeGateway.ps1`) takes an answers file; the catalog, token limits,
first sync, Graph grant and schedule are separate scripts.

## Decision

1. The sheet gains `gateway` Foundry sign-in fields, `compatibilityGroups` and a
   `network` section (`config/customer-sheet.example.json`).
2. `scripts/Deploy-ClaudeCustomerEnvironment.ps1 -SheetPath <sheet>` runs Plan,
   Preflight, Deploy, Catalog, Limits, Sync, Grant and Schedule in order and stops
   at the first failure. Plan derives the answers file
   (`scripts/ClaudeCustomerSheet.ps1`) and checks it with the installer's own
   validator, and converts the sheet into the access catalog.
3. The installer deploys the sync job without a schedule; Schedule starts it
   once, waits for success, then sets the sheet's `syncInterval`.
4. A sheet with any missing value or `<placeholder>` stops before Azure is read.

## Consequences

- One command for the operator; existing scripts do the work, so their checks
  and rollback stay as they are.
- Grant needs a Privileged Role Administrator or Global Administrator. A run by
  anyone else stops at Grant; that person runs the same command again.
- Managed identity reaches Foundry only in the gateway subscription; a sheet
  that names another subscription with managed identity is refused.
