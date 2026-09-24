# Scale

What this gateway can hold, what runs out first, and how to establish a capacity
figure for your own deployment.

Run the measurement against your gateway rather than reading the numbers here:

```powershell
./scripts/Measure-ClaudeCeiling.ps1 -ResourceGroup <rg> -ApimName <apim>
```

It exits non-zero when a list is past 80% of its limit, so it runs as a check.

**Prerequisites:** Reader access to the selected gateway for headroom; write,
network and directory roles for migration as listed in
[Private projection](SECURE-PROJECTION.md#prerequisites). Run from the
repository root using explicit resource groups; Foundry, APIM and the
projection may be in different groups.

**Portal/manual:** APIM > APIs > Named values shows list contents and lengths;
Overview shows the tier. Measure the actual encoded membership size against the
table below. This checks configuration capacity, not traffic throughput.
[Architecture](ARCHITECTURE.md) shows how the optional store fits.

---

## What runs out first

| Ceiling | Value | How it was established |
|---|---|---|
| Characters per named value | **4,096** | Measured. 4,096 returns HTTP 201; 4,097 returns HTTP 400 `ValidationError` |
| Identities per entitlement list | **110** | Measured. 110 object ids is 4,071 characters and is accepted; 111 is 4,108 and is rejected |
| Entries in the business-unit map | **about 93** | Derived. An entry is `oid=unit,`, so it costs more than a bare object id. The script measures the real cost from your own data |
| Named values per instance | 5,000 Basic/Basic v2, 10,000 Standard/Standard v2, 18,000 Premium/Premium v2 | [Published](https://learn.microsoft.com/azure/api-management/service-limits) |

The binding limit is **business-unit membership, at about 93 developers** — not
the 110 a tier list holds. A `bu-members` entry is `oid=unit,`: 38 characters
plus the business-unit name, against 37 for a bare object id. With a
six-character unit id that is 44 characters and the map holds 93; a **longer unit
name** costs more and holds fewer.

So business-unit membership runs out first, and planning against 110 over-plans
by roughly a fifth. Everything else on the instance has orders of magnitude more
headroom.

`Measure-ClaudeCeiling.ps1` derives this from your own data rather than assuming
either figure, because the cost per entry depends on names you choose.

A write that would exceed 4,096 characters **fails outright**. It does not
truncate, so entitlement does not silently lose its tail — but the sync has to
notice the failure, which is why `ApimNamedValue.ps1` checks the size before
writing and throws rather than discarding the exit code.

### Why not put the tier in the token

The obvious alternative is to stop looking entitlement up at all: put the tier in
an Entra **app role** or a **groups** claim, and let the gateway read it straight
off the validated token. No projection, no resolver, no standing cost, and it
scales to any number of developers.

It cannot work here, and the reason is worth keeping written down because it is
the first thing a reviewer proposes.

Claude Code acquires a token for the **Foundry data plane**, so the gateway
validates the audience `https://cognitiveservices.azure.com` (and
`https://ai.azure.com`). Those are first-party Microsoft resources. App roles and
the `groups` claim are configured on the *application registration* that the
token is issued for — `optionalClaims` and `appRoles` in its manifest — and you
**do not own that registration**. There is nowhere to put the claim.

Changing the audience to an application you do own would mean Claude Code
requesting a token for it, which is not configurable: the client asks for the
Foundry data plane because that is what it is calling.

That is why entitlement is a lookup rather than a claim, and why
[ADR-0005](adr/0005-identity-projection.md) is about *where the lookup reads
from* rather than whether there is one.

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
replaces the list with a durable entitlement projection. Graph reconciliation
runs off the request path; a cache miss reads the projection **on** the request
path through the resolver.

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

### What one unit of Foundry capacity buys

Measured 2026-09-23: a Global Standard `claude-haiku-4-5` deployment at capacity
10 reported its `rateLimits` as `request` 10 and `token` 10,000 per 60 seconds.
One unit of capacity is therefore **1 request and 1,000 tokens per minute**, and
the installer's "capacity in thousands of tokens per minute" is half of it.

Claude Code makes many small requests, so the request limit binds first. As an
illustration only: 50,000 daily actives at 500 requests a day over an 8-hour day
average about 52,000 requests a minute, which is 52,000 units of capacity before
any peak. The subscription this was built in had a quota of 80 units for that
model in that region, and quota is per subscription, region and model, so a
second deployment adds none. At this scale Foundry quota, requested from
Microsoft, is the limit to plan first. The gateway and the projection are not.

### What this repository has not measured

The reference deployment cannot supply them. Over the last 30 days its ledger
holds **730 requests across 6 days**, busiest day 250, from a handful of
developers — measured 2026-09-23. That is a demonstration, not a traffic model,
and extrapolating a 500,000-seat envelope from it would produce a number with no
evidence behind it.

So this page states the method and the structural ceilings, which are
traffic-independent and were measured, and stops there. **U9** and **U10** in
[UNKNOWNS.md](UNKNOWNS.md) record what remains open.

---

## What a capacity test has to prove

The obvious test - create 500,000 counter keys and see whether the service
accepts them - answers the wrong question. Accepting a key is not the same as
accounting correctly against it.

### The projection, measured 2026-09-17

`guide/loadtest-projection.mjs`, run from a container inside the VNet because the
data plane is not reachable from outside it:

| Collection size | RU per point read | Latency |
|---|---:|---|
| ~1, near-empty | 1 | 24.5 ms |
| 500 | 1 | 25–54 ms |
| 20,000 | 1 | 23–25 ms |
| **100,000** | **1** | 24–47 ms |

Flat across a hundred-thousand-fold growth, reading records written first, last
and in the middle. That is the claim the whole design rests on: a lookup is a
point read whose cost does not follow the size of the collection, and it holds
because every identity is its own logical partition.

Had the container been partitioned on `/tenantId`, all 100,000 would have shared
one partition and this table would not be flat.

**Writes are a different story, and the migration plan needs it.** Bulk loading
managed about **190 records a second**, so backfilling 500,000 identities takes
roughly 45 minutes. Pushing concurrency up did not help: 6,400 in-flight
requests produced `TimeoutError` rather than more throughput. That is a
backfill-window number, not a request-path one — nothing in the gateway waits on
it — but ADR-0009's phase 1 has to budget for it.

### 500,000 measured, 2026-09-24

**MEASURED, 13:05:37–13:14:45 UTC:** the revised
`guide/loadtest-projection.mjs` loaded a separate, initially empty `loadtest`
container through the private endpoint, with 32 workers and `/oid` partitioning.
The runner was in Canada Central and Cosmos in East US 2. It used the current
record shape, including a reconciliation generation and an absolute expiry.
The real `entitlement` container was not the load target.

| Measurement | Result |
|---|---:|
| Confirmed cardinality (`COUNT(1)`) | **500,000** |
| Load time | **524.26 seconds** |
| Sustained write throughput | **953.73 records/second** |
| Write charge | **2,950,000 RU**, 5.9 RU per create |
| Near-empty point read | 1 RU, 51.99 ms |
| Full-container reads | 500 reads, **1 RU each** |
| Full-container latency, p50 / p95 / p99 / maximum | **47.53 / 49.15 / 51.00 / 72.09 ms** |

| Record written | Samples | p50 | p99 |
|---|---:|---:|---:|
| First, 0 | 100 | 47.55 ms | 50.33 ms |
| 1 | 100 | 47.64 ms | 49.95 ms |
| Middle, 250,000 | 100 | 47.60 ms | 55.14 ms |
| 499,998 | 100 | 47.28 ms | 50.79 ms |
| Last, 499,999 | 100 | 47.53 ms | 49.15 ms |

Percentiles use nearest rank. The test container and its temporary scoped role
assignment were deleted afterwards. The tool now refuses any container other
than explicitly named `loadtest`, refuses a nonempty container and bounds
concurrency; the older loader always targeted `entitlement` and must not be used.

**INFERRED:** this establishes the storage cardinality and point-read shape,
not 500,000 simultaneously active developers. It does not measure a 500,000-user
Graph scan, full reconciliation upsert throughput, APIM counter exactness,
Foundry capacity or streaming concurrency. The earlier 190/s and this 954/s
are measurements of different loaders, not competing guarantees.

### The lookup through the gateway, measured 2026-09-23

What a cache miss adds to a request, end to end. The client was inside the
gateway's VNet and signed in as a managed identity entitled only through the
projection. It asked for a model its tier may not call, so the gateway resolved
entitlement and refused **without calling the model**. Response time was
therefore the gateway plus the lookup and nothing else. The gateway was Premium
v2 in Canada Central; the Cosmos account was in East US 2, behind a private
endpoint in the same VNet; the resolver had one always-ready instance.

| 150 requests each | min | p50 | p95 | p99 | max |
|---|---:|---:|---:|---:|---:|
| Cache hit (60-second window, back to back) | 4 ms | 5 ms | 10 ms | 172 ms | 336 ms |
| Cache miss (1-second window, 1.2 s apart) | 67 ms | **91 ms** | **149 ms** | **301 ms** | 389 ms |

The resolver's own metrics counted exactly 150 executions in the miss window,
all on the warm instance, so every miss was a real lookup. A miss adds about
86 ms at the median and 139 ms at p95. The slowest, 389 ms, is a small fraction
of the 5-second limit the gateway gives the resolver.

Measured again on 2026-09-24 from outside the VNet, 220 misses against 220 hits on
the same gateway: a miss added 78 ms at the median and 134 ms at p99.

### After idle, and under a burst, measured 2026-09-24

The same gateway and resolver, one identity, asking for a model its tier may not
call, so each answer is the gateway plus the lookup:

| Condition | Requests | Refused with 503 | Slowest |
|---|---:|---:|---:|
| First request after at least 15 minutes idle, no always-ready instance | 3 | **2** | 5,880 ms |
| The same, with one always-ready instance | 1 | 0 | 1,809 ms |
| 20 concurrent misses for one identity, one always-ready instance, the first burst | 20 | **4** | 5,378 ms |
| Later bursts of 20, 50 and 100, with the resolver already scaled out | 490 | 0 | 1,458 ms |

Every concurrent miss reached the resolver: nothing coalesced them. The four
failures in the first burst ran on two hosts that started during it and waited
out the gateway's 5-second limit, and the 503 told the developer the entitlement
service could not be reached. A 2,048 MB Flex Consumption instance takes 16
concurrent requests by default
([HTTP trigger concurrency](https://learn.microsoft.com/azure/azure-functions/functions-concurrency#http-trigger-concurrency)),
so a burst larger than the warm instances waits for new ones. One always-ready
instance does not keep a first burst inside the limit, and a resolver with none
fails outright. Setting it back to one did not help at once: the next request
still met a new host. That is **U18**. The fixes are the miss-path backpressure
and coalescing the P19 review asked for, more always-ready instances, or both.
Three cold trials do not give a cold-start p99.

The P19 completion changes that path: per-process single flight in the resolver,
a 3.5-second lookup deadline, a 2.5-second Cosmos transport timeout, and APIM
backpressure **before** the resolver (100 concurrent misses, 200 misses/second).
Two always-ready 2-GB instances each accept 100 concurrent HTTP requests, rather
than relying on new hosts above the default of 16.

**MEASURED, 13:27:47–13:27:49 UTC:** the first 20-request burst after deploying
that configuration, with no probe warmup, had **zero 503s**; every response was
the expected model-refusal 403, p99/maximum **2,334 ms**. The requests did not
call Foundry. This is a measured burst envelope, not a latency SLA.

**MEASURED, 13:44:43–13:44:44 UTC:** after **16 minutes with no probe traffic**,
another first burst of 20 returned 20 expected 403s, **zero 503s**, and
p99/maximum **1,105 ms**. The two always-ready instances and HTTP concurrency
100 were left in place deliberately; the cache setting remained 60 seconds.

**MEASURED, 13:48–13:52 UTC:** miss bursts used a one-second cache. The primed
overload test ran after restoring 60 seconds, with the previous answer expired:

| Condition | Requests | Result | Maximum |
|---|---:|---|---:|
| First burst of 100 | 100 | 100 expected 403, no 503 | 1,682 ms |
| Three bursts of 50 | 150 | 150 expected 403, no 503 | 960 ms |
| Three bursts of 100 | 300 | 300 expected 403, no 503 | 1,326 ms |
| 500 already-connected callers, cache empty | 500 | 279 expected 403, **221 retryable 429**, no 503 | 1,377 ms |

The 429 body said “Entitlement lookup is busy” with `Retry-After: 1`.
Priming used an absent route (404), not the entitlement endpoint. An earlier
500-request run with cold client connections got all 403s, but took up to
5,084 ms and did not exercise overload: TLS setup staggered arrival and the
cache absorbed calls. That is why those two tests are not interchangeable.

Warm sequential comparison: 100 misses at p50/p95/p99
**256/292/384 ms**, against 99 hits after a separate warmup at
**175/180/191 ms**. Added p50 was 81 ms, added p99 192 ms. The cache was restored
to **60 seconds**. These are same-identity tests; distinct-identity throughput
and a larger cold envelope remain deployment-specific capacity work.

**DOCUMENTED:** APIM's built-in cache has no atomic lock for this use.
Coalescing is per resolver process, not across instances; APIM's distributed
rate and concurrency limits are approximate. A cache flush above the admitted
envelope can still return retryable 429. See
[ADR-0017](adr/0017-projection-freshness-and-admission.md).

### What a counter test still has to prove

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

### Counters at 500,000 keys, measured 2026-09-24

A throwaway Premium v2 instance in Canada Central, one unit and then two, with a
mock Messages API behind `llm-token-limit` policies keyed on a synthetic
identity: tokens per minute and a daily quota, as this gateway's tiers use, an
hourly quota to see a rollover within the run, and a request-rate limit. Every
response reported 15 tokens used. The instance was deleted and purged afterwards.

| Check | Result |
|---|---|
| 500,000 distinct identities, one request each | All charged: 1,639 requests a second on one unit, p99 574 ms, 8 HTTP 500 |
| Three more sweeps, 1,500,000 requests | 1,599 requests a second, p99 579 ms, no capacity 429 |
| The remaining allowance reported to a random 2,048 of them | Did not match what they had used, before any scale-out or policy change |
| One identity, one request at a time | Served 540 tokens against a 300-token hourly quota before it was refused |
| 1,000 identities refused for 40 rounds in a row | All accepted and charged again later in the same hour |
| Scale-out from one unit to two | 389 s; afterwards 11,042 requests were answered 503 over 16 s |
| A policy change | In effect on every request 15 s after it was saved |

So the counters take 500,000 identities, and they are soft at any scale. Microsoft
documents the remaining-quota figure as an estimate, and the limit as one that
concurrent requests can exceed
([llm-token-limit](https://learn.microsoft.com/azure/api-management/llm-token-limit-policy)).
That is the conclusion of [The budget is a delayed kill switch, not a hard
cap](#the-budget-is-a-delayed-kill-switch-not-a-hard-cap), now measured at the
cardinality. What the run did not establish is how far over a production-sized
quota a developer can go, or why exhausted identities were admitted again, so
**U9** stays open.

---

## Order of work

1. Observe the five numbers on a pilot cohort, over enough days to include a bad one.
2. Load-test API Management, Foundry capacity, telemetry ingestion and quota
   composition **together**. Each is fine alone; the interaction is what fails.
3. Size and test reconciliation, miss admission and the projection alongside the
   request path; storage cardinality alone does not size the full service.

The projection runs on Cosmos DB serverless with a Function resolver, decided in
[ADR-0011](adr/0011-projection-platform.md). What it costs is computed rather
than quoted:

```powershell
./scripts/Measure-ClaudeProjectionCost.ps1 -Developers 500000 -DailyActive 50000 -AlwaysReadyInstances 2
```

**Manual:** the [cost table](SECURE-PROJECTION.md#cost) exposes the inputs;
Azure Cost Management > Cost analysis shows actual billing after deployment.
The script is a local calculation, not a portal budget or a measured invoice.

The historical one-warm-instance, read-path estimate was **$69.09 a month**, of which
$65.28 bills at rest: five private endpoints, five private DNS zones and one warm
resolver instance, as deployed on 2026-09-23. The usage lines are under $4,
because the resolver is called once per cache window per active developer, not
once per request, so the cache absorbs almost all of it. See
[ADR-0011](adr/0011-projection-platform.md) for why private networking is
assumed rather than optional. The standing-cost objection to ADR-0005 does not
survive the arithmetic either way.

That estimate is **not the operating total for leased reconciliations**.
The current two-warm-instance profile bills $91.56/month at rest at the same
published rates. It also refreshes every member's lease on every reconciliation,
including unchanged members. At 500,000 records, hourly renewal means about
365 million writes per 730-hour month. Using the measured **create** charge of
5.9 RU as an illustrative input gives $538.38/month for writes alone at
$0.25/million RU. **INFERRED, not a renewal quote:** existing-record upserts,
Graph scanning, runner execution, telemetry and retries were not priced by that
load. The cost script still models the read path; use `-AlwaysReadyInstances 2`
and budget reconciliation separately, rather than presenting its total as complete.

---

## The budget is a delayed kill switch, not a hard cap

The delay calculation below describes a **ledger-driven external watcher**,
not APIM's admission-time token counter. The repository's token quotas are
also soft and cache-blind. Do not assume a financial watcher is installed by
the default gateway deployment.

A budget enforced outside the request path cannot stop spending at the moment a
threshold is crossed. Four things elapse first:

```powershell
./scripts/Measure-ClaudeOvershoot.ps1 -ResourceGroup <rg> -ApimName <apim> `
    -WorkspaceName <workspace>
```

Measured on the reference deployment, 2026-09-16:

| Term | Measured | How |
|---|---|---|
| Telemetry lag | **193s worst**, 87s median over 102 requests | `ingestion_time() - TimeGenerated` on the ledger |
| Job interval | 300s | Your choice. Whatever watches the ledger runs on a timer |
| Propagation | **17s** | Write an override, poll the gateway until the policy serves the new number |
| In-flight requests | not measured | A property of your traffic. This deployment has no traffic model |
| **Window** | **511s** | |

So spending continues for **roughly eight and a half minutes** after the
threshold is crossed, plus whatever was already admitted and is still streaming.
Multiply by your peak token rate for the overshoot in tokens.

Two details worth keeping:

**The worst case is the bound, not the median.** Telemetry lag ranged 56s to
193s across the sample. A bound built on the median would be wrong about half
the time, in the direction that matters.

**Propagation is measured through the gateway, not the ARM API.** Reading a named
value back returns the new value immediately, which says nothing about when the
policy sees it. The measurement polls a response header instead.

A genuine hard cap needs admission-time budget reservation: the decision has to
be made before the request is served, against state the gateway already holds.
API Management's quota policies do not offer that, so this is not called one.

**Portal/manual measurement:** Log Analytics > Logs can compare ingestion time
with request time; the scheduler's execution history gives its interval.
Observe changed response headers through an entitled test client after editing
APIM > Named values to measure propagation. A portal value readback alone does
not establish the delay or in-flight overshoot.

---

## Deploying today, and scaling later

### Two things to get right on the first day

Both cost nothing now and are expensive to retrofit. Reasoning and the sources
are in [ADR-0013](adr/0013-gateway-outlives-instance.md).

**Give developers a custom domain, not the instance hostname.** The onboarding
file carries `https://<instance>.azure-api.net/claude`, which puts the instance
name into the configuration on every machine. Any later move that creates a new
instance — Standard v2 to Premium v2, or v2 to classic for multi-region — then
changes the URL for every developer. Behind `https://claude.<company>.com/claude`
the same move is a DNS change nobody notices. At 200 developers retrofitting
this is a bad afternoon; at 200,000 it is a migration nobody attempts, which
means the first day's choice is the permanent one.

**Know which SKU the design needs, which is not a developer-count question.**
Read from Microsoft Learn on 2026-09-17:

| | Basic v2 | Standard v2 | Premium v2 | Premium (classic) |
|---|---|---|---|---|
| Maximum units | 10 | 10 | 30 | multiple |
| Availability zones | no | no | **yes** | **yes** |
| Multi-region | no | no | **no** | **yes** |
| Virtual network integration | **no** | **yes** | yes, plus injection | injection |
| In-place move | ↔ Standard v2 | ↔ Basic v2 | not documented | classic family only |

Do **not** deploy classic Premium as the multi-region version of this
accelerator: it lacks the required Anthropic token parsing. The table describes
platform offerings, not equivalent supported gateway configurations. Multi-
region governance and allowance retention still need a separate verified design.

Two of those cells matter more than the rest:

- **Basic v2 has no virtual network integration**, and the projection sits
  behind a private endpoint because the Cosmos account comes back with public
  access disabled. So **Basic v2 cannot run the ADR-0011 design at any size** —
  not at 200,000 developers and not at 20. The floor for the projection is
  Standard v2, and the failure on Basic v2 looks like a networking error rather
  than an entitlement one.
- **Premium v2 does not do multi-region.** Only Premium classic does. Reading
  "Premium" as "the resilient one" and picking v2 for disaster recovery gets
  availability zones and a single region.

Basic v2 to Standard v2 is an in-place change with no gateway downtime and no
URL change. Everything else means a new instance — survivable only behind the
custom domain above.

### Standing up the projection

The projection is **not wired into the installer**. Running
`Install-ClaudeGateway.ps1` today deploys the gateway and nothing else, which is
deliberate: private subnets, Graph access and a reconciliation schedule need
explicit operator decisions. The projection and resolver exist, but their
deployment and the migration are still explicit rather than one installer step.

To stand one up on its own:

```powershell
az deployment group create -g <rg> `
  --template-file infra/projection.bicep `
  --parameters namePrefix=<your-prefix>
```

### What happens when you outgrow the named values

Nothing silent. `ApimNamedValue.ps1` checks the size before writing, so the sync
**refuses and says so** rather than truncating:

```
Named value 'allow-standard' is 4441 characters, which is 345 over the API
Management limit of 4096. It holds 120 entries of about 38 characters; roughly
107 fit. Nothing was written. A list this large needs a different store - see
docs/ROADMAP.md P19.
```

Entitlement stays exactly as it was. Nobody loses access; the next developer
just cannot be added until the store changes.

`Test-ClaudeHealth.ps1` reports headroom and fails at 80%, so the warning
arrives around 74 developers rather than at the wall.

### Why growing later is not a rebuild

The thing that would be painful to migrate is not in the layer being replaced.
| | Lives in | Touched by the migration |
|---|---|---|
| Who is entitled, and their tier | Entra groups | **no** — groups stay the source of truth |
| Business units and budgets | `bu-registry`, named values | **no** — one entry per unit, not per developer |
| Consumed budget this period | API Management quota counters | **no** — [ADR-0009](adr/0009-shadow-migration.md) preserves the keys |
| Spend history and chargeback | Log Analytics ledger | **no** |
| The oid → tier, oid → unit maps | `allow-*`, `bu-members` | **yes** — these three, and only these |

The named values are a *projection* of Entra, rebuilt from it on every sync. So
moving to Cosmos changes where the gateway reads, not what is true.
`Sync-ClaudeAccess.ps1` writes named values; `Sync-ClaudeProjection.ps1` and
the in-network Node writer publish the projection. Reuse the directory model,
not the assumption that the two commands are interchangeable.

A rollback restores authorization without restoring consumption, which is the
rule that makes the move safe to reverse mid-flight.
[ADR-0009](adr/0009-shadow-migration.md) has the five phases; phase 2, the
comparison that proves both paths agree before either is trusted, ships today as
`Compare-ClaudeEntitlement.ps1`.

---

## Getting there without resetting anyone's allowance

Entitlement is live, and budgets are consumed state rather than configuration. A
developer who has spent 80% of a monthly allowance is carrying a number that
exists only in the gateway's counters, so a migration that re-keys or resets
those counters hands the allowance back — and a budget that has stopped binding
looks like a budget that is working.

[ADR-0009](adr/0009-shadow-migration.md) sets out the five phases. Authorization
does not change until phase 4, and a rollback restores authorization without
restoring consumption.

Phase 2 is the part that cannot be skipped, and it exists now:

```powershell
./scripts/Compare-ClaudeEntitlement.ps1 -ResourceGroup <rg> -ApimName <apim>
```

It resolves every identity twice — once from what the gateway is enforcing, once
from the directory — and exits non-zero when the two disagree. Premium is tested
before standard, the same order the policy uses, so it does not report drift the
gateway does not have.

| It reports | Meaning |
|---|---|
| `missing` | In the directory, not on the gateway. Gets 403 until the sync runs |
| `stale` | On the gateway, not in the directory. Still entitled after removal |
| `tier-drift` | Entitled on both sides, at different tiers |

It is useful before any of that migration is built, because it answers a live
support question: *is the sync current?* Entitlement is not live, and this
measures the gap.

---

## The move itself, step by step

What a pilot customer runs to get from the named-value lists to the projection.
The measured small migration kept serving; this is not a zero-downtime
guarantee. A rollback is safe only while refreshed lists fit and agree with
current directory membership. Confirm backup, schedule, lease alerts and a
test cohort before changing the source.

**Before you start**, settle the two decisions that cannot be retrofitted —
a custom domain and whether you need a second region. See
[DECISIONS.md](DECISIONS.md). Doing this migration first and those afterwards
means doing it twice.

### 0. Check you are on a tier that can run it

```powershell
az apim show -g <rg> -n <apim> --query sku.name -o tsv
```

Basic v2 cannot join a virtual network, so it cannot reach a resolver that has
no public endpoint. Two ways forward: deploy the resolver with
`inboundAccess=public`, where the Entra token check is then the only control, or
move to Standard v2 or Premium v2 and keep everything private.
[Deploy the projection privately](SECURE-PROJECTION.md) covers both.

**Portal:** APIM > Overview / Pricing tier. For this private runbook choose a
VNet-capable v2 tier; a public resolver is an explicitly reviewed alternative.

**Rollback:** none needed. Nothing has changed yet.

### 1. Confirm the switch is present

```powershell
az apim nv show -g <rg> --service-name <apim> --named-value-id entitlement-source --query value -o tsv
```

Expect `named-value`. If the named value is absent, the gateway is running a
policy from before the switch existed — redeploy with
`Install-ClaudeGateway.ps1`, which preserves everything else.

**Portal:** APIM > Named values > `entitlement-source`. A policy/template
upgrade is a separate change; back up and follow Setup rather than assuming a
bare template redeploy preserves live state.

**Rollback:** none. This step only reads.

### 2. Stand up the projection

The store, its private network, the resolver and its identity. Steps 1 to 7 of
[Deploy the projection privately](SECURE-PROJECTION.md) do this, starting with:

```powershell
az deployment group create -g <rg> `
  --template-file infra/projection.bicep `
  --parameters namePrefix=<your-prefix> networkAccess=private-only
```

Then point the gateway at the resolver, which still changes nobody's access:

```powershell
. ./scripts/ApimNamedValue.ps1
Set-ApimNamedValue -ResourceGroup <rg> -ApimName <apim> -Id entitlement-resolver-url -Value 'https://func-resolver-<prefix>.azurewebsites.net/api'
Set-ApimNamedValue -ResourceGroup <rg> -ApimName <apim> -Id entitlement-resolver-audience -Value 'api://<resolver-app-id>'
```

**Portal:** APIM > Named values > edit URL/audience from the resolver
deployment's Outputs. Creating these values does not switch authorization.

**Rollback:** delete the resources. Nothing reads them yet.

### 3. Populate it, and leave the lists alone

The lists keep serving every request while the projection fills. The account
has no public endpoint, so the write runs inside the network: resolve the
groups with your own sign-in, then apply the snapshot from the runner with its
own identity, which can write only this container.

```powershell
./scripts/Sync-ClaudeProjection.ps1 -Account cosmos-<prefix> -ApimName <apim> -ResourceGroup <rg> -ExportPath snapshot.json
# then, in the runner:
node /work/sync/src/apply-projection.mjs --cosmos https://cosmos-<prefix>.documents.azure.com:443/ --tenant <tenant-id> --snapshot /work/snapshot.json
```

`-ApimName` and `-ResourceGroup` make the projection assign business units from
the gateway's own registry, deepest first and first match winning, which is how
the named-value path does it. Before 2026-09-23 the projection sync let the last
match win, so anyone in a team and its parent would have been charged to a
different unit after the flip. The isolated 500,000-record loader measured
954 creates/second on 2026-09-24; that is not a measurement of the full directory
scan and apply job. Use the in-network Node bulk writer for this population,
not the PowerShell writer's serial HTTP loop.

**Freshness is now part of the migration.** A complete scan stamps a generation,
its start time and an absolute expiry, two hours by default and never longer.
The snapshot must be applied before that expiry; copying or replaying it does
not renew it. Schedule a fresh scan at least hourly, allowing scan, transfer
and apply time to fit inside the lease. Every retained member is rewritten.
Before upgrading an existing projection, populate leased records first, then
deploy the strict resolver and policy. Old unleased records correctly return
503 after that deployment.

**Rollback:** delete and repopulate. No developer is affected either way.

**Portal/manual:** Container instance > Containers > Connect runs the prepared
writer from inside the VNet; Cosmos > Data Explorer inspects records. Do not
hand-author freshness timestamps as a substitute for a directory scan.

### 4. Run the comparison until it reports nothing

Two comparisons, and both must be clean:

```powershell
# The lists against the directory: are the lists current?
./scripts/Compare-ClaudeEntitlement.ps1 -ResourceGroup <rg> -ApimName <apim> -ExportGatewayPath gateway-decisions.json

# The projection against the lists: would anyone gain or lose access at the flip?
# In the runner, with the exported file copied in:
node /work/sync/src/apply-projection.mjs --cosmos https://cosmos-<prefix>.documents.azure.com:443/ --tenant <tenant-id> --compare /work/gateway-decisions.json
```

This is the step that must not be rushed. The first comparison on its own says
only whether the lists are current; the second is the one that reads the
records the resolver would serve. It names every difference as
`would-lose-access`, `would-gain-access`, `tier-drift` or `unit-drift` and exits
non-zero while there are any. Expired records now count as losing access, so an
expired snapshot cannot approve a flip. Measured on 2026-09-23: 8 identities compared,
0 differences.

**Portal:** Entra All members, APIM Named values and Cosmos Data Explorer can
spot-check a test identity. They are not a replacement for comparing every
effective identity before a bulk flip.

**Rollback:** not applicable — nothing has changed. Fix the drift and run again.

### 5. Flip one value

```powershell
az apim nv update -g <rg> --service-name <apim> `
  --named-value-id entitlement-source --value projection
```

**Portal:** APIM > Named values > `entitlement-source` > `projection` > Save.
Repeat the same action with `named-value` only under the rollback conditions
below. Check real caller responses after propagation.

Propagation to the running policy was measured at 9–18 seconds on Basic v2. On
Premium v2 the write itself took 38 to 41 seconds, and the flip took effect
within 44 seconds of starting it.

What each developer then experiences, measured on 2026-09-23:

| Situation | Response |
|---|---|
| Unexpired record present | Served; cached for the smaller of `entitlement-cache-seconds` and its remaining lease, and expiry checked on every hit |
| No record | `403 permission_error`, cached for at most 60 seconds |
| Resolver down, answer still cached | Served until the window ends |
| Resolver down, window ended | `503` with `Retry-After: 5`, and a message saying it is not the developer's access |
| Reconciliation stopped and record expired | `503` explaining that the projection expired or could not supply an unexpired answer; never stale authorization |
| Miss-path capacity exhausted | Retryable `429`, before the resolver |

Before 2026-09-23 the policy answered a missing record with that 503, so every
unentitled attempt read as an outage and invited a retry. Redeploy the current
policy before flipping.

**Rollback:** set it back to `named-value` **only after refreshing and comparing
the lists**. A saved list is not a revocation-safe rollback: it can regrant a
leaver. Keep both destinations current during the bounded rollback window, and
do not roll back to lists once the population no longer fits them.

### 6. Watch, then stop maintaining the lists

Observe a representative working period. Request counter keys and existing log
history stay in place; that is not a promise that counters survive an instance
replacement or failover. Current admin reports still read named-value rosters:
`Get-ClaudeBudget.ps1`, `Get-ClaudeBusinessUnit.ps1`, the health comparison and
`ClaudeCost`'s published membership map must be reviewed for projection-scale
coverage. Do not interpret an old/empty list as the current projected population.
The request ledger's stamped unit remains available for an audit.

Only once you are satisfied should the sync stop writing the named-value lists.
Until then they are your rollback. A rollback is only as good as the lists:
measured, rolling back after the lists had stopped being maintained refused an
entitled developer with 403 until `Sync-ClaudeAccess.ps1` ran again.

### What does not change

| | |
|---|---|
| The gateway address | unchanged, so no developer reconfigures anything |
| Per-developer counters | keyed on the object id in both paths — allowances do not reset |
| Spend history | in Log Analytics, untouched by any of this |
| The policy | source flip is configuration-only after the prerequisite policy upgrade and fresh-store comparison |
