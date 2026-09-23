# ADR-0014: Turnstile beside the gateway, fed by a scheduled job with no secret

- **Status:** Accepted
- **Date:** 2026-09-23
- **Packet:** P39, P40
- **Deciders:** claude-code-foundry-gateway maintainers, platform owner

## Context

Turnstile ([TURNSTILE.md](../TURNSTILE.md)) can enforce budgets itself, for traffic routed through
its own API Management policy. The gateway already enforces access, tier quotas and business-unit
and team budgets on every request. Two enforcers give two answers to "is this person over budget",
and only one of them knows about tiers and access.

Usage has to reach Turnstile continuously, from the gateway's ledger, as something that can read
the ledger and write to Turnstile's hub and API. Whatever does that holds those permissions for as
long as it runs.

## Decision

**Turnstile sits beside the gateway, never in front of it.** No Claude request passes through
Turnstile. What Turnstile changes reaches developers one way only: a budget written back into the
gateway's registry by `Sync-ClaudeTurnstileGovernance.ps1 -Direction FromTurnstile -Apply`.

**The export and sync run as an Azure Container Apps job** (`infra/turnstile-schedule.bicep`),
started by a cron schedule, signed in as its own user-assigned managed identity, running this
repository's scripts at a pinned commit id. The identity's grants are made by
`Connect-ClaudeTurnstile.ps1 -ExporterPrincipalId`, which is the one place that decides what an
exporter may do: send to one hub, read the gateway's named values, its Application Insights
resource and workspace, and hold Turnstile's admin app role.

Options considered:

| Option | Why not |
|---|---|
| GitHub Actions with OIDC | The job would run outside the tenant, and a public repository's run logs are public |
| Azure Automation or Functions | The scripts use the Azure CLI throughout; neither host carries it |
| Container Instances | No scheduler of its own; something else would have to start it, holding a permission to do so |
| A custom container image | A registry to run and an image to rebuild whenever a script changes. PowerShell is added at start from its published release instead |
| Turnstile's own API Management policy on Claude traffic | Puts Turnstile in the request path, which the first decision rules out |

## Consequences

- No secret exists anywhere: not in the template, the job, the repository or a key vault.
- What runs cannot change without a redeploy, because the job fetches a commit id, and
  `Register-ClaudeTurnstileSchedule.ps1` refuses one that is not on the remote.
- A failed run is not retried. The next run's window overlaps it, and Turnstile keeps one copy of
  each row, so the next run recovers it.
- The job depends on GitHub and the PowerShell release being reachable at start. An enterprise
  that cannot allow that mirrors the repository and passes `-RepositoryUrl`.
- Upgrading the scripts the job runs is `Register-ClaudeTurnstileSchedule.ps1` again, from a newer
  commit.
