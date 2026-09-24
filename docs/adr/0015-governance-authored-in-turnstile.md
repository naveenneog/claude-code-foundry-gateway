# ADR-0015: Governance can be authored in Turnstile and applied to the gateway on save

- **Status:** Accepted
- **Date:** 2026-09-24
- **Packet:** P44
- **Deciders:** claude-code-foundry-gateway maintainers, platform owner

## Context

[ADR-0014](0014-turnstile-beside-the-gateway.md) put Turnstile beside the gateway and let one kind
of change come back from it: a budget, pulled by `Sync-ClaudeTurnstileGovernance.ps1 -Direction
FromTurnstile -Apply`. Business units, teams, their Entra groups and tiers stayed in this
repository's scripts. An organization that runs Turnstile as its FinOps console wants to manage
all of them there, without scripts for the Turnstile administrator, and wants a save to take
effect without waiting for a scheduled pass.

Verified this session:

- A Container Apps job with a manual trigger is started with `POST {jobId}/start?api-version=2024-03-01`
  by a principal holding Container Apps Jobs Operator on that job. Turnstile's API, as its managed
  identity, started the job in 1.9 s.
- An API Management named value takes effect on the next request, with no redeploy. A tier limit
  saved on Turnstile's page was read on the gateway 112 s later; a budget saved in Turnstile
  refused the next request 123 s after the save.
- Turnstile's budgets are monthly. A month inherits the previous month's from a timer that runs
  every five minutes, exactly once, and a month that already has a budget row is left alone.
  Until the timer has run, the month has no budgets (Turnstile, `roll_forward_budgets`).
- Reading a group and its members as a managed identity needs the Microsoft Graph application
  permission `GroupMember.Read.All`, which only a tenant administrator can grant. It was not
  available in the reference tenant ([UNKNOWNS.md](../UNKNOWNS.md), U17).

## Options considered

1. **Turnstile writes the gateway's named values itself.** Turnstile would hold write access to
   the gateway, and a second implementation of the registry format would have to agree with this
   repository's. Rejected.
2. **The hourly job only.** No new permission, but a save takes up to an hour, and the
   administrator cannot see when it has. Kept as the backstop, not the path.
3. **Turnstile starts an apply job on save.** Turnstile gains one power: starting a job whose code
   is this repository at a pinned commit and whose identity can write named values and nothing
   else.
4. **An event from Turnstile to a queue the job listens on.** Another resource to run, and
   Turnstile publishes no events; starting the job is one call.

## Decision

Option 3. The single reason: the only new thing Turnstile can do is start a job whose code and
permissions this repository fixes.

- The connection's `governanceAuthority` says where governance is authored: `Gateway`, the
  default, or `Turnstile`, which implies budgets are authored there too.
- Moving governance to Turnstile seeds it from the gateway once, on the change. Seeding again
  would overwrite what was saved in Turnstile, so a later registration does not.
- The apply reads Turnstile's catalog, the budgets of the month Turnstile names after rolling
  the previous month's in, and the tiers; writes only named values that differ; and reads each
  back.
- It applies no group it cannot confirm exists, except, when the directory cannot be read, a
  group the gateway already uses. Tier limits always apply. Membership is refreshed only when
  every group can be read. A catalog with no business unit at all is refused.
- The hourly job applies the same way, so a start that failed is caught up within the hour.

This amends ADR-0014's "What Turnstile changes reaches developers one way only: a budget" for a
connection whose governance is authored in Turnstile. Its first decision stands: no Claude request
passes through Turnstile, and the gateway is the one enforcer.

## Consequences

+ The Turnstile administrator edits units, teams, groups, budgets and tier limits on Turnstile's
  pages, and the gateway enforces a save about two minutes later.
+ Enforcement stays in one place, the gateway's policy, and the registry format keeps one tested
  implementation.
+ Turnstile's API is granted Container Apps Jobs Operator on one job; the job's identity a custom
  role with four actions on one API Management instance.
− A third tier needs a policy change. Turnstile's page edits the two the policy enforces, and a
  save of another is reported, not applied.
− Without `GroupMember.Read.All`, a unit with a group new to the gateway is not applied and
  membership is not refreshed by the job (U17). Budgets, tier limits and units with known groups
  are.
− Most of the two minutes is the job starting: 33 s for the container, 55 s to add PowerShell,
  sign in and fetch the commit. A prebuilt image would shorten it; ADR-0014 chose not to run one.
− Two role assignments and one app setting to keep in step. `Connect-ClaudeTurnstile.ps1` makes
  and removes all three.

## How we'd know this was wrong

- A save routinely taking longer to apply than administrators will wait. At about two minutes it
  is shorter than the hourly pass it replaces; at ten it would not be worth the permission.
- A registry written by the apply that Turnstile's pages do not show. The round-trip test in
  `Test-TurnstileGovernance.ps1` exists to catch the two formats drifting apart.
- Administrators needing a third tier often enough that tiers belong in data, not in the policy.
