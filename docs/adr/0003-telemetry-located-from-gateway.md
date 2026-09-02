# ADR-0003: Telemetry is located from the gateway, not from a name

- **Status:** Accepted
- **Date:** 2026-09-02
- **Packet:** P12 (correcting P10)
- **Deciders:** claude-code-foundry-gateway maintainers

## Context

`infra/main.bicep` names the Application Insights workspace `appi-${namePrefix}`, and
`namePrefix` defaults to `claudegw${uniqueString(resourceGroup().id)}`. The installer also lets
the operator pick a name, and reusing an existing API Management instance can produce a
different prefix from the original deployment.

The result is that one resource group can hold several Application Insights workspaces that all
look like the right one. The reference deployment has three: `appi-claude-gateway`,
`appi-claudegw933092` and `appi-claude-gw-fzgql9`.

`scripts/Get-ClaudeAnalytics.ps1` and `tests/Test-Analytics.ps1` shipped in P10 with
`appi-claude-gateway` as a default, taken from `scripts/Show-Governance.ps1`.

## What went wrong

On 2026-08-31 the gateway stopped writing metrics to `appi-claude-gateway` and started writing
them to `appi-claude-gw-fzgql9`. The API-level diagnostic points at a logger named `appinsights`,
which resolves to the latter; the service-level diagnostic points at a different logger, which
resolves to the former.

Every P10 test still passed. The query returned all sixteen columns, and the non-vacuity guard
was satisfied by data from before the switch, so it reported 19 rows and a million tokens. What
it did not report was that none of that data was newer than two days old.

The same defect made `Get-ClaudeBudget.ps1` report `0 used this month` for every developer on a
gateway that had served hundreds of requests that morning. A zero is indistinguishable from
"nobody used it" and does not look like an error.

## Decision

Locate the workspace from the gateway's own diagnostic configuration, in this order:

1. `apis/{api}/diagnostics/applicationinsights` → `loggerId` → logger → `resourceId`
2. the service-level diagnostic, the same way
3. an explicitly supplied name

`scripts/Get-ClaudeTelemetry.ps1` does this and nothing else. `Get-ClaudeAnalytics.ps1`,
`Get-ClaudeBudget.ps1` and `tests/Test-Analytics.ps1` call it instead of holding a default name.
It also returns whether `metrics` is enabled on that diagnostic, because
`llm-emit-token-metric` emits nothing when it is off — a second way to get a silent zero.

A detector goes with it. `tests/Test-Analytics.ps1` compares the newest `customMetrics`
timestamp with the newest `requests` timestamp in the same workspace:

| Requests | Metrics | Meaning |
|---|---|---|
| recent | recent | healthy |
| stale | stale | idle gateway, not a fault |
| recent | stale | reading the wrong workspace, or metrics are off |

Comparing the two is what makes this a detector rather than an alarm clock: an absolute
freshness threshold would fail on any quiet gateway.

## Consequences

+ A report reads the workspace the gateway is writing to now, rather than the one it was writing
  to when the script was written.
+ Metrics being disabled on the diagnostic is surfaced as a warning instead of as zeros.
+ The failure mode that hid for two days now fails a test. Verified both ways: the detector
  passes against the live workspace and fails against the stale one, naming both timestamps.
− One more ARM round trip per report, and a script that the others depend on.
− A deployment with no diagnostic configured at all still needs `-AppInsightsName`.

## How we would know this was wrong

If the diagnostic and the logger ever disagree about where data actually lands, this resolves
confidently to the wrong place — worse than a name, which is at least obviously a guess. The
freshness detector is what would catch that, which is why it is not optional.
