# ADR-0012: Store and availability are separate switches, not one tier ladder

- **Status:** Accepted
- **Date:** 2026-09-17
- **Packet:** P19
- **Deciders:** claude-code-foundry-gateway maintainers, platform owner
- **Refines:** [ADR-0011](0011-projection-platform.md)

## Context

The accelerator targets organisations with six-figure developer counts, but it also has to be
deployable by a team of fifty without asking them to carry enterprise infrastructure. The proposal
was a ladder: a standard tier around 100 developers on named values, an enterprise tier at 1,000 and
beyond on a database with a high-availability SKU.

The instinct is right. The rungs are not.

## What the measurements say

**There is no engineering discontinuity at 1,000.** Measured 2026-09-17 against the deployed
projection, reading records written first, last and in the middle:

| Collection size | RU per point read |
|---|---:|
| ~1 | 1 |
| 500 | 1 |
| 20,000 | 1 |
| 100,000 | 1 |

Once entitlement is a projection, 1,000 identities and 500,000 run the same code at the same cost
per lookup. What separates them is storage measured in megabytes and a cache-miss count. There is
nothing at 1,000 to hang a tier on.

**The real second break is availability, and it is not a size.** Cosmos serverless is
[single-region only](https://learn.microsoft.com/azure/cosmos-db/serverless): no multi-region
writes, no geo-replication. Availability zones are available, at 1.25x RU. Anything beyond that
needs provisioned throughput, which carries a floor — roughly 400 RU/s minimum — where serverless
bills nothing at rest.

A two-hundred-developer bank may be required to run multi-region. A five-thousand-developer startup
may not care. Tying availability to headcount puts both on the wrong rung.

## Decision

Two independent parameters rather than one ladder.

```
-EntitlementStore   named-values | projection          default: named-values
-ProjectionHa       none | zone | multi-region         default: none
```

| Combination | Holds | Bills at rest | For |
|---|---|---|---|
| `named-values` | ~90 developers, measured | nothing | every deployment until it outgrows it |
| `projection` + `none` | 500,000, serverless | private endpoint only | the common large case |
| `projection` + `zone` | 500,000, zone-redundant | endpoint, 1.25x RU | one region, datacentre-fault tolerant |
| `projection` + `multi-region` | 500,000, geo-failover | endpoint + provisioned floor | a regulated availability requirement |

`-ProjectionHa` is meaningless without `-EntitlementStore projection`, and the installer refuses the
combination rather than silently ignoring it.

### Why two switches and not one number

Size and availability are orthogonal. Collapsing them couples two decisions that are made by
different people for different reasons: how many developers you have is a fact, and whether you need
geo-failover is a policy. A single tier number forces the second to be inferred from the first,
which is how a bank ends up single-region and a startup ends up paying a provisioned floor.

### Which store, chosen for the operator rather than by them

`Measure-ClaudeCeiling.ps1` already reports headroom and fails at 80%. The installer suggests
`projection` when the existing lists are past that, the same way it already suggests an API
Management SKU from the developer count rather than asking cold. The default stays `named-values`,
because the accelerator must cost nothing extra for a deployment that does not need it.

## Consequences

+ A fifty-developer deployment is unchanged and pays nothing new.
+ A large deployment does not have to choose an availability posture it does not want in order to
  get past 90 developers.
+ The serverless single-region limit is surfaced as a choice rather than discovered during an
  incident review.
− Two parameters to explain instead of one, and one invalid combination to refuse.
− `multi-region` has a standing cost the rest of this accelerator does not, and it has to be labelled
  as such wherever it is offered.

## How we would know this was wrong

If nobody ever selects `zone` or `multi-region`, the second axis is theoretical and should collapse
back into the store parameter.

If operators routinely pick `projection` well below the named-value ceiling — for reasons this ADR
has not anticipated, such as wanting entitlement queryable from outside the gateway — then the
threshold is not the right trigger and the default should change.
