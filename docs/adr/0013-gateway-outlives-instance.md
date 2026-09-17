# ADR-0013: The gateway a developer is configured against must outlive the gateway

- **Status:** Accepted
- **Date:** 2026-09-17
- **Packet:** P19
- **Deciders:** claude-code-foundry-gateway maintainers, platform owner
- **Refines:** [ADR-0011](0011-projection-platform.md), [ADR-0012](0012-store-and-availability.md)

## Context

An organisation starting with 200 developers must be able to reach 200,000 without reconfiguring
the 200, and without losing the spend already recorded against them. That is the requirement. It
sounds like a scale question and it is mostly a naming and a SKU question.

ADR-0011 chose the platform for the entitlement projection and ADR-0012 separated store from
availability. Neither looked at what the gateway itself has to be for the projection to work, or at
what a developer's machine is pinned to. Both turn out to constrain the answer more than the
identity count does.

### What the tiers actually do

Read from Microsoft Learn on 2026-09-17, not inferred:

| | Basic v2 | Standard v2 | Premium v2 | Premium (classic) |
|---|---|---|---|---|
| Positioned for | development and testing, with an SLA | production | enterprise, high volume | enterprise |
| Maximum units | 10 | 10 | 30 | multiple |
| Availability zones | no | no | **yes** | **yes** |
| Multi-region | no | no | **no** | **yes** |
| Virtual network integration | **no** | **yes** | yes, plus injection | injection |

Two of those cells decide this design.

**Basic v2 has no virtual network integration.** The projection in ADR-0011 sits behind a private
endpoint, because the Cosmos account came back with public network access disabled and that is
enforced above the resource group. A gateway that cannot join a virtual network cannot reach it. So
the SKU floor for the projection is **Standard v2**, and that is true at 200 developers or 200,000 —
it has nothing to do with how many identities there are.

**Premium v2 does not do multi-region.** Only Premium classic does. An organisation that reads
"Premium" as "the resilient one" and picks Premium v2 for disaster recovery gets availability zones
and no second region.

### What can be changed in place

Learn documents upgrade and downgrade **within** two families: among the classic tiers, and between
Basic v2 and Standard v2. Premium v2 is not listed as an in-place target from either, and there is
no automated migration between the classic family and the v2 family.

An in-place tier change is otherwise as good as it gets: *"The service will not experience gateway
downtime, and API Management will continue to service API requests without interruption."*

### What a developer is pinned to

`onboarding/claude-gateway.json` carries `https://<instance>.azure-api.net/claude`, and every client
on every machine is configured from it. The instance name is in the hostname. So any move that
creates a new instance — Standard v2 to Premium v2, or v2 to classic for multi-region — changes the
URL on every developer's machine.

At 200 developers that is a bad afternoon. At 200,000 it is not a migration anyone will attempt,
which means the decision is effectively made on the first day and never revisited.

## Decision

**Three things, all of which cost nothing on day one and are expensive to retrofit.**

### 1. Developers are configured against a custom domain, never the instance hostname

The gateway endpoint takes a custom domain in every tier. Hand developers
`https://claude.<company>.com/claude` and the instance name stops being part of the contract. A
tier move that requires a new instance becomes a DNS change and a cutover, invisible to the 200 or
the 200,000.

Without this, the hostname is the migration blocker, and no amount of work on the entitlement store
helps.

### 2. The policy carries both entitlement paths from the first deployment

Moving from named-value lists to the projection must not be a policy change. The policy reads a
named value — `entitlement-source` — and takes the list path or the resolver path accordingly.
Both paths ship on day one; only one is live.

The migration is then: deploy the projection, backfill it, run the shadow comparison from
[ADR-0009](0009-shadow-migration.md) until it reports no drift, flip one named value. No policy
deployment, no gateway change, and the rollback is flipping it back.

A policy that grows the resolver path later is a policy that has to be redeployed and re-verified
against a production gateway carrying real traffic, which is exactly the day nobody wants to be
changing it.

### 3. The counter key is the object id, and it does not change

Rate limit, daily quota, business unit and organisation counters are all keyed on values that exist
identically in both paths — the object id, and the unit name resolved for it. Nothing about the
source of the entitlement enters the counter key, so switching source does not reset a counter or
start a developer's month again. ADR-0009 already required this for the migration; it is restated
here because it is also what makes a *SKU* move safe within a family.

Spend history is not in the gateway at all. It is in Log Analytics, which survives any tier change
and any instance replacement as long as the workspace is kept — so the workspace, not the gateway,
is the thing to be careful with.

### The ladder, with the traps named

| Where you are | Tier | Why | Getting there |
|---|---|---|---|
| Pilot, under ~90 developers | Basic v2 | cheapest with an SLA; no zones, no virtual network | — |
| Production, or any use of the projection | **Standard v2** | virtual network integration, which the private projection requires | **in place from Basic v2, no downtime, no URL change** |
| High volume, zone redundancy | Premium v2 | availability zones, 30 units, virtual network injection | **not an in-place upgrade** — new instance, so only painless behind a custom domain |
| Multi-region | Premium (classic) | the only tier that does it | different family, new instance, same caveat |

## Consequences

The 200-developer organisation pays nothing extra for the path: a custom domain and a policy that
carries an unused branch. The `entitlement-source` named value sits on `named-value` and the
resolver path is never taken.

The accelerator now has an opinion about the gateway SKU that is not about developer count, and it
should say so: **Basic v2 cannot run the design in ADR-0011 at any size.** Deploying the projection
against a Basic v2 gateway will fail at the first lookup, and it will fail for a networking reason
that looks nothing like an entitlement problem.

Cost is the honest objection to Standard v2 as a floor. It is a real increase over Basic v2 for an
organisation that will never need the projection. That is why the floor is stated as a condition —
*production, or any use of the projection* — rather than a blanket recommendation.

What this does not solve: an organisation that needs multi-region has to land on Premium classic,
which is a different family with no migration from v2. If that is known at the start, start there.
The custom domain makes it survivable rather than painless.

## Unknowns this leaves open

- **U14** — what the resolver path costs in added p99 latency on a cache miss, measured rather than
  reasoned. ADR-0011 records the trade; nothing has measured it.
- The staleness window is still the one input that has not been chosen, and it sets both the cache
  window and the cost. Recorded in [docs/STATUS.md](../STATUS.md).
