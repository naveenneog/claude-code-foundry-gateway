# ADR-0011: The entitlement projection runs on Cosmos DB serverless with a Function resolver

- **Status:** Accepted
- **Date:** 2026-09-17
- **Packet:** P19
- **Deciders:** claude-code-foundry-gateway maintainers, platform owner
- **Refines:** [ADR-0005](0005-identity-projection.md), which decided *what* entitlement becomes and
  deliberately did not name a platform

## Context

[ADR-0005](0005-identity-projection.md) replaced the named-value entitlement list with a durable
projection queried by a small resolver off the request path. It left two things open: what stores
the projection, what runs the resolver, and what that costs to keep running.

The objection to the whole design has always been the standing bill. This settles it with a number.

## Decision

**Azure Cosmos DB serverless** for the projection, **Azure Functions on the Consumption plan** for
the resolver.

Both are pay-per-use with no minimum. Cosmos serverless "bills only for resources used per database
operation and consumed storage with no minimum"; Functions Consumption carries a free grant per
subscription per month.

### What it costs

`scripts/Measure-ClaudeProjectionCost.ps1` computes it. At the requirement that motivated ADR-0005 —
500,000 developers, 50,000 of them active on a working day, a 60-minute cache window:

| | Per month |
|---|---:|
| Azure Function | $1.56 |
| Cosmos DB request units | $2.20 |
| Cosmos DB storage (0.19 GB) | $0.05 |
| Private endpoint | $7.30 |
| **Total** | **$11.11** |

Rates are published US list, read 2026-09-17, and are regional.

### The private endpoint is not optional, and that was found by deploying

This ADR first said **$3.81** on Functions Consumption with no private networking. Deploying the
template to the reference subscription proved that wrong.

The account came back with `publicNetworkAccess: Disabled`, enforced above the resource group —
`az cosmosdb update --public-network-access ENABLED` reported success and changed nothing. Nothing
in `infra/projection.bicep` asks for that; the governance baseline imposes it.

An accelerator aimed at organisations with six-figure developer counts must assume that baseline
rather than its absence. Two consequences:

1. **Cosmos needs a private endpoint** — $7.30 a month, billed whether anyone calls the gateway or
   not. It is the first line in this accelerator that bills at rest, and at a small deployment it is
   the entire bill.
2. **The resolver cannot run on Consumption.** The Y1 Consumption plan has no VNet integration.
   [Flex Consumption](https://learn.microsoft.com/azure/azure-functions/flex-consumption-plan) does,
   and keeps per-execution billing, so the cost line is unchanged — but the plan this ADR originally
   named could not have reached the database at all.

Neither was visible from a pricing page. Both came from deploying the thing.

### Deployed privately, 2026-09-23

The whole path was deployed and migrated to on that date
([SECURE-PROJECTION.md](../SECURE-PROJECTION.md)), and the deployment added three
lines that bill at rest which the table above does not have:

| At rest | Per month |
|---|---:|
| Private endpoints: Cosmos, the resolver itself, and its storage account's blob, queue and table | 5 × $7.30 = $36.50 |
| Private DNS zones for them | 5 × $0.50 = $2.50 |
| One warm resolver instance (2 GB at the always-ready baseline rate) | $26.28 |

The storage endpoints were not optional either: a management-group policy set
the resolver's storage account private at creation, as it did the Cosmos
account, and the Functions host needs blob, queue and table. The warm instance
is a choice. Without it the first lookup after idle pays a cold start against
the gateway's 5-second timeout.

`Measure-ClaudeProjectionCost.ps1` now prices all of it: **$69.09 a month** at
the requirement above, $65.28 of it at rest. The conclusion stands. The usage
lines are still under $4, because the cache, not the request rate, sets them.

**The cost is small because the resolver is called per cache miss, not per request.** A developer
misses once per cache window while they are active, so someone making 500 calls an hour and someone
making 5 cost the same. At a 60-minute window over an 8-hour day that is 8 lookups per active
developer per day: 8.8M misses a month, which is 8.8M request units and 8.8M invocations against a
1M free grant.

Storage is negligible by construction — one small record per identity, 500,000 of them is under a
fifth of a gigabyte.

### The dial that matters is the cache window, and it is not a cost dial

Halving the window to 30 minutes doubles the bill and halves how long a revoked developer keeps
working. That is the staleness trade-off ADR-0005 made explicit, and this is where it is actually
priced. Computed, not estimated:

| Cache window | Misses per month | Per month | Revoked developer keeps working for up to |
|---|---:|---:|---|
| 240 minutes | 2,200,000 | **$8.14** | 4 hours |
| 60 minutes | 8,800,000 | **$11.11** | 1 hour |
| 15 minutes | 35,200,000 | **$22.99** | 15 minutes |

Note how little of that moves. Most of the bill is the private endpoint, which is fixed, so
quartering the staleness window does not even triple the total.

Every row is affordable. **So choose the window on the revocation requirement, not the invoice** —
the money is not the constraint at any setting anyone would pick, and pretending otherwise would be
optimising the wrong number.

## Consequences

+ The standing-cost objection to ADR-0005 does not survive contact with the arithmetic. Single-digit
  dollars a month at the full 500,000-developer requirement.
+ No minimum charge, so a pilot with eight developers costs nothing measurable — the same code runs
  at both ends without a tier decision.
+ Storage scales with headcount and headcount is small data; throughput scales with *active*
  developers and the cache absorbs almost all of it.

− **Serverless offers no guaranteed throughput or latency.** Microsoft states this plainly, and caps
  a serverless container at 5,000 RU/s per physical partition. At 500,000 developers the average is
  under 15 RU/s, so headroom is not the worry; the absence of a latency guarantee is. This is
  survivable only because the resolver sits behind the APIM cache rather than on every request, and
  it is the reason ADR-0005 put it there.
− Functions Consumption has cold starts, which land in p99 on a cache miss. A miss is already the
  slow path; if measurement shows it is too slow, the escape is a Premium plan with a warm instance,
  and that *does* carry a standing bill.
− Two more resources in the bill of materials, where today the gateway has one component with a
  standing cost.

## What this does not decide

**The staleness window itself.** ADR-0005 requires a number; this shows every plausible number is
affordable. Choosing it is the operator's call and remains open.

**When to build it.** Measured 2026-09-17, the reference deployment holds 8 identities against a
binding ceiling of about 93 — business-unit membership, not the 110 a tier list holds. See
[SCALE.md](../SCALE.md). `Test-ClaudeHealth.ps1` reports headroom and flags at 80%, which is the
trigger to start.

## How we would know this was wrong

If cache-miss latency on Consumption turns out to dominate p99 for real users, the platform choice
was wrong even though the cost was right, and the answer is a warm Premium instance rather than a
different database.

If the miss rate is far higher than one per window per active developer — because the cache evicts
under memory pressure rather than on TTL — the cost model understates, and the signal is the
resolver's invocation count exceeding `daily_active x misses_per_active_day x working_days`.
