# Scale

What this gateway can hold, what runs out first, and how to establish a capacity
figure for your own deployment.

Run the measurement against your gateway rather than reading the numbers here:

```powershell
./scripts/Measure-ClaudeCeiling.ps1 -ResourceGroup <rg> -ApimName <apim>
```

It exits non-zero when a list is past 80% of its limit, so it runs as a check.

---

## What runs out first

| Ceiling | Value | How it was established |
|---|---|---|
| Characters per named value | **4,096** | Measured. 4,096 returns HTTP 201; 4,097 returns HTTP 400 `ValidationError` |
| Identities per entitlement list | **110** | Measured. 110 object ids is 4,071 characters and is accepted; 111 is 4,108 and is rejected |
| Entries in the business-unit map | **about 93** | Derived. An entry is `oid=unit,`, so it costs more than a bare object id. The script measures the real cost from your own data |
| Named values per instance | 5,000 Basic/Basic v2, 10,000 Standard/Standard v2, 18,000 Premium/Premium v2 | [Published](https://learn.microsoft.com/azure/api-management/service-limits) |

The binding limit is **110 developers per tier**. Everything else on the
instance has orders of magnitude more headroom.

A write that would exceed 4,096 characters **fails outright**. It does not
truncate, so entitlement does not silently lose its tail — but the sync has to
notice the failure, which is why `ApimNamedValue.ps1` checks the size before
writing and throws rather than discarding the exit code.

### Sharding does not rescue it

Splitting the list across several named values is the obvious escape. It gives
5,000 x 110 = 550,000 identities on Basic v2, which looks like it clears a
500,000 requirement.

It does not, for two reasons. The policy would have to scan every shard on every
request, and a policy that references thousands of named values is not something
anyone can operate or review. More directly: the problem was never the arithmetic.
Materialising 500,000 records in a **data store** is unremarkable; materialising
them in **API Management policy configuration** is what cannot work.

That is the reasoning behind [ADR-0005](adr/0005-identity-projection.md), which
replaces the list with a durable entitlement projection queried off the request
path.

---

## "500,000 employees" is not a capacity specification

It gives no rate, no concurrency and no shape. Five numbers do:

| Number | Why it decides something |
|---|---|
| **Daily active developers** | Entitlement is per identity, but load is per active identity. The gap between headcount and daily actives is usually an order of magnitude |
| **Peak requests per second** | Sizes API Management units and decides whether gateway capacity throttling will reject requests with 429 |
| **Peak token rate** | Sizes Foundry capacity. Tokens, not requests, are what the deployment meters |
| **Streaming concurrency** | A streamed completion holds a connection for its whole duration, so concurrency is not derivable from requests per second |
| **Burst shape** | A working day is not flat. The start of the day and the minutes after a build breaks are not the mean |

Only the first is a property of the organisation. The other four are properties
of how people work, and they have to be observed.

### What this repository has not measured

The reference deployment cannot supply them. Over the last 30 days its ledger
holds **111 requests across 2 days**, from a handful of developers. That is a
demonstration, not a traffic model, and extrapolating a 500,000-seat envelope
from it would produce a number with no evidence behind it.

So this page states the method and the structural ceilings, which are
traffic-independent and were measured, and stops there. **U9** and **U10** in
[UNKNOWNS.md](UNKNOWNS.md) record what remains open.

---

## What a capacity test has to prove

The obvious test - create 500,000 counter keys and see whether the service
accepts them - answers the wrong question. Accepting a key is not the same as
accounting correctly against it.

The test is whether **every identity retains its consumed allowance** across:

| Event | Why it is a risk |
|---|---|
| Sustained load | Counters are held in a distributed cache. Behaviour under memory pressure is not documented |
| Scale-out | Adding a unit changes which node serves a caller |
| Policy deployment | Applying a policy is a configuration change to the component holding the counters |
| Period rollover | A monthly quota has to roll over once, not once per node |

A counter that resets on any of those hands back allowance that was already
spent, which is indistinguishable from a budget that does not work.

`rate-limit-by-key` and `llm-token-limit` counter cardinality is not published.
Microsoft's guidance is to test for the scenario rather than rely on a stated
limit, which is **U9**.

---

## Order of work

1. Observe the five numbers on a pilot cohort, over enough days to include a bad one.
2. Load-test API Management, Foundry capacity, telemetry ingestion and quota
   composition **together**. Each is fine alone; the interaction is what fails.
3. Only then size the projection in [ADR-0005](adr/0005-identity-projection.md).

Migrating an existing deployment onto that projection without resetting anyone's
consumed allowance is a separate problem, tracked as P19b.
