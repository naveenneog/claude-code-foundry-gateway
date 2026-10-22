# ADR-0068: 5-minute and 15-minute sync intervals

**Status:** Proposed
**Date:** 2026-10-22
**Packet:** P122
**Amends:** [ADR-0058](0058-scheduled-projection-sync.md) decision 1 (shortest interval 30 minutes)

## Context

ADR-0058 offered `30m` to `12h`. The customer asked for the sync job to run every
5 minutes while testing and every 15 minutes in production, with the interval
configurable. The job already runs on a Container Apps cron trigger; only the
interval table limited it. Azure Monitor accepts 30 and 45 as log search query
ranges (U167), which cover the no-success ranges of 5 minutes (25) and
15 minutes (45).

## Decision

1. `scripts/ClaudeProjectionSchedule.ps1` adds `5m` (`*/5 * * * *`) and `15m`
   (`*/15 * * * *`). The list is `5m`, `15m`, `30m`, `1h`, `2h`, `3h`, `4h`,
   `6h`, `8h`, `12h`, `manual`; anything shorter than 5 minutes is refused.
2. The installer (`-ProjectionSyncInterval`), the answers schema,
   `Deploy-ClaudeProjectionRenewal.ps1 -SyncInterval`,
   `Set-ClaudeProjectionSyncSchedule.ps1 -Interval` and the Azure CLI guide's
   `SYNC_INTERVAL` block accept both.
3. The default stays `2h`, so a re-run does not change a deployed job. A
   deployment chooses `15m` (production) or `5m` (test) explicitly.

## Consequences

- A run can take up to the job's 3,600-second replica timeout. When a run is
  longer than the interval, the next run waits up to 900 seconds for the apply
  lock and then stops with a failed-run alert (U165). `5m` suits directories
  whose full sync finishes well inside 5 minutes; `15m` is the production
  choice.
- Runs a month: 8,760 at `5m` and 2,920 at `15m` (730 hours). Each run's
  run-seconds above the free grant are billed, and each run adds console lines
  to Log Analytics (P120 membership lines included).
- No-success alert ranges: 30 minutes for `5m` and 45 for `15m`.
