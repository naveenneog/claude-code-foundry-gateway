# ADR-0032: The guided flow starts at once and gives the foundation to the installer

## Status

Proposed for P68. Amends [ADR-0030](0030-guided-flow.md) for the `Foundation` step in a console and
for discovery; the rest of ADR-0030 stands.

## Context

The owner's manual test on 2026-09-27 reported four things about `Start-ClaudeGateway.ps1 -Action
Setup`:

1. It "takes up lot of time to load anything, no progress indicator, no upfront questions; it feels
   stuck". Measured 2026-09-27 on this workstation, against the reference subscription, with a
   new record and `-PlanOnly`: the first line of output appeared after 66 s.
2. It "takes away control of choosing and creating the installer script": the `Foundation` step
   runs `Install-ClaudeGateway.ps1 -Yes`, so the installer's own questions about the subscription,
   Foundry account, region, tiers, quotas and optional sections are answered with defaults.
3. With the Cosmos entitlement store chosen, the installer stopped at
   `Cannot choose projection unattended with -Yes unless -DeployProjection is also passed`.
4. A region choice should show what it costs, and the installer should end by offering the FinOps
   tool.

The 66 s are discovery. `Get-ClaudeFlowDiscovery` lists the signed-in account (1.2 s), every
subscription (1.2 s), every API Management instance (4.2 s), every Cognitive Services account
(12.2 s), every Log Analytics workspace (4.1 s) and then the deployments of each of the 13 Foundry
accounts in turn (2.3-4.1 s each, about 39 s), measured one call at a time on 2026-09-27. Loading
every step module takes about 1 s. No step reads those lists: the only discovery field a step uses
is `comparison`, which compares the record with the one gateway the record names.

ADR-0030 has the orchestrator ask every question before anything is written and each step apply
"without prompting". The installer's questions depend on answers the orchestrator does not have
(the subscription decides the Foundry accounts, the Foundry account decides the region and the
deployments, the region decides the price), so the orchestrator either duplicates the installer's
question logic or answers it with defaults. It did the second.

## Options

1. **Keep discovery and add a progress bar.** The wait stays 66 s and grows with the subscription.
2. **Run the listing calls in parallel.** About 15 s here, still for data nothing reads.
3. **Read only what a step uses, and say what is being read.** Discovery reads the signed-in
   account when needed and the one gateway the record names. Each call prints what it reads and an
   estimate before it starts, and how long it took after.

For the foundation:

A. **Keep `-Yes`, fix the projection flag.** The crash goes; the installer's decisions stay taken.
B. **Duplicate the installer's questions in the flow.** A second implementation of the installer's
   choices, to keep in step with the first.
C. **In a console, let the installer ask.** The flow's review says which questions the installer
   asks next; the installer's own summary, which already names every resource and its price and
   asks for confirmation, approves what it creates. Without a console the answers file supplies the
   installer's inputs and `-Yes` stays.

## Decision

Option 3 and option C.

**Discovery.** `Get-ClaudeFlowDiscovery` makes no listing call. It reads the gateway the record
names (`az apim show`), only when the record names one, and returns the same `comparison` as
before. Every Azure call the orchestrator makes before its first question prints one line naming
what it reads with an estimate, and one line with the time it took. An empty record makes no Azure
call before the first question.

**Foundation in a console.** `Invoke-ClaudeFlowStep` for `Foundation` runs `Install-ClaudeGateway.ps1`
without `-Yes`, passing only the values the record already holds, so the installer asks the rest
with its own prompts and defaults. The flow asks no foundation question itself in a console; its
review names the installer's questions instead. The installer's summary and confirmation remain the
approval for the resources it creates. **Without a console** the flow passes the record's values
with `-Yes`, as before, and adds `-DeployProjection` when the entitlement store is the Cosmos
projection, so the projection is deployed rather than refused.

**Prices at the choice.** The installer's region prompt lists the Foundry account's region and the
other regions in its geography, each with the monthly list price of the API Management v2 tiers
there; its tier prompt lists each tier's monthly list price in the chosen region. Prices come from
the Azure Retail Prices API through `scripts/AzureRetailPrice.ps1`, at 730 hours a month, and are
named as list prices with the time they were read. A price the API does not publish is shown as
not published, never as zero. The agreement's own price sheet is named as the authority: reading
it takes a billing role, not a subscription role (**U31**).

**After the installer.** In a console the installer ends by offering the FinOps tool setup
(`scripts/Select-ClaudeFinOpsTooling.ps1`); its next steps are numbered in order.

## Consequences

+ The first question appears without waiting on Azure, and every wait that remains says what it is
  waiting for and about how long.
+ The installer's decisions are the administrator's again, and each one that changes cost shows the
  cost where it is chosen.
- In a console the flow's review cannot state the region, tier or monthly total before the
  installer asks; it names the questions to come, and the installer's summary states them.
- Status and Change see drift only in the recorded gateway, which is the only drift they acted on.

## How we'd know this was wrong

A step that needs a listed resource before its first question, an installer question the flow's
review does not name, or a price shown at a choice that differs from the installer's summary for
the same region and tier would each show that the boundary is in the wrong place.

## References

- Azure Retail Prices API, filters and fields, retrieved 2026-09-27:
  <https://learn.microsoft.com/rest/api/cost-management/retail-prices/azure-retail-prices>
- View and download your organization's Azure pricing (price sheet roles), retrieved 2026-09-27:
  <https://learn.microsoft.com/azure/cost-management-billing/manage/ea-pricing>
- Price sheet APIs for EA and MCA, retrieved 2026-09-27:
  <https://learn.microsoft.com/azure/cost-management-billing/costs/migrate-cost-management-api#price-sheet-for-a-scope-by-billing-account>
