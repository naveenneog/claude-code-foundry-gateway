# ADR-0032: The guided flow starts at once and gives the foundation to the installer

## Status

Accepted for P68, 2026-09-27. Amends [ADR-0030](0030-guided-flow.md) for the `Foundation` step in
a console and for discovery; the rest of ADR-0030 stands. Implemented in `f48d545` and `f955295`;
tests in `tests/Test-FlowStart.ps1`.

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

Reading `Foundation.ps1` for this decision found that its plan says `Check` when the record
names a gateway, while its apply runs the installer anyway. Under `-Yes` without a name prefix
the installer's reuse menu defaults to creating a new gateway, so an unattended second Setup, or
any Guide apply, would create a second API Management instance. This was found by reading the
code, not by a run.

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
what it reads with an estimate, and one line with the time it took. With an empty record the flow
makes no Azure call before its first question or, in an attended run, before the installer starts,
and its first line of output says so. Discovery also returns Region: the gateway's region from
that read, or the record's location when nothing was read.

**Foundation in a console.** An attended run is one in a console without `-PlanOnly`,
`-ApprovedPlanFingerprint` or `-WhatIf`. When the record names no gateway, or the action is
`-Change foundation`, an attended run has two phases:

1. The flow prints the Foundation review, which names the installer's questions, and runs
   `Install-ClaudeGateway.ps1` without `-Yes`, passing only the values the record's foundation
   decision holds. The installer asks the rest with its own prompts and defaults, and its summary
   and confirmation are the approval for the resources it creates; the flow asks for no
   fingerprint in this phase. The installer therefore writes nothing before that confirmation: the
   Claude deployment it creates in a subscription that has none is listed in the summary and
   created after it. An installer that returns without writing its record (cancelled at the
   summary) stops the flow before any other step.
2. The flow reads the new gateway (one `az apim show`), then asks the remaining steps' questions
   (FinOps first, priced in the gateway's region), prints their review and asks for the typed
   fingerprint, as ADR-0030 describes.

The flow asks no foundation question itself in an attended run. In every run, when the record
already names a gateway, Setup and Guide check that gateway instead of running the installer
again, as the Foundation plan already said; the review names `-Action Change -Change foundation`,
which runs the installer with `-ExistingApimName` and `-ResourceGroup` set to the recorded gateway.
That is the installer's own reuse path: it adopts the gateway's region, tier, name and publisher
from Azure, so the flow passes none of them, and in a console the flow passes nothing else and the
installer asks its other questions. **Without a console**, and
with `-PlanOnly`, `-ApprovedPlanFingerprint` or `-WhatIf`, the flow plans every step in one
review as before and passes the record's values with `-Yes`, adding `-DeployProjection` when the
entitlement store is the Cosmos projection, so the projection is deployed rather than refused.

The orchestrator adds `action` and `attended` to the discovery object it passes to each step,
and the FinOps step prices its choices in discovery's `Region`. The installer
writes the choices the flow records (`sku`, `location`, `foundryAccount`,
`foundryResourceGroup`) into `onboarding/claude-gateway.json`. `CLAUDE_INTERACTIVE=1` makes
`Test-ClaudeInteractive` treat a process whose input is redirected as a console, so a test can
drive an attended run through standard input.

**One subscription, and values `cmd.exe` cannot re-read.** Discovery and the installer take the
subscription from one resolver (the record's `subscriptionId`, then the foundation decision's), and
the installer receives it as `-SubscriptionId`, which the fingerprint binds; a subscription that is
not an id is refused. On Windows `az` is `az.cmd`, and `cmd.exe` re-reads `& | < > ^ ( ) " %` in
an argument, so a value holding one can end the argument early or run a second command. The flow
refuses such a record value before the installer runs, discovery passes a recorded name to `az`
only when it is letters, digits and `. _ -`, and the installer checks the values it passes to `az`
before its summary.

**Resume.** An attended run records its phases in `activeRun` (`lead`, then `after-lead` with the
names of the steps). A retry of a failed second phase plans those same steps, without the
foundation check that the now-recorded gateway would add, so its fingerprint can match ADR-0030's
resume rule and the completed steps are skipped. A mistyped fingerprint in the second phase applies
nothing and says that the gateway foundation is set up.

**Prices at the choice.** The installer's region prompt lists the Foundry account's region and
the other regions in its geography (from `az account list-locations`), each with the monthly
list price of the three API Management v2 tiers there, read in one Azure Retail Prices API call
for the three unit meters in every region; its tier prompt lists each tier's monthly list price
in the chosen region. Prices are per unit at 730 hours a month through
`scripts/AzureRetailPrice.ps1`, named as list prices with the time they were read. A price the
API does not publish is shown as not published, never as zero. The agreement's own price sheet
is named as the authority: reading it takes a billing role, not a subscription role (**U31**).

**After the installer.** Run on its own in a console, the installer ends by offering the FinOps
tool setup (`scripts/Select-ClaudeFinOpsTooling.ps1`); the flow passes `-SkipFinOpsOffer`
because its FinOps step follows. The installer's next steps are numbered in order.

## Consequences

+ The first question appears without waiting on Azure, and every wait that remains says what it is
  waiting for and about how long.
+ The installer's decisions are the administrator's again, and each one that changes cost shows the
  cost where it is chosen.
+ Change foundation updates the recorded gateway by name, and its review prices that live gateway.
- In an attended run the Foundation review cannot state the region, tier or monthly total before
  the installer asks; it names the questions to come, and the installer's summary states them.
- An attended run asks for the fingerprint only for the steps after the installer, because their
  plans depend on what the installer created.
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
