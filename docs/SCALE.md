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

The projection runs on Cosmos DB serverless with a Function resolver, decided in
[ADR-0011](adr/0011-projection-platform.md). What it costs is computed rather
than quoted:

```powershell
./scripts/Measure-ClaudeProjectionCost.ps1 -Developers 500000 -DailyActive 50000
```

At the full 500,000-developer requirement that is **$11.11 a month** — the
resolver is called once per cache window per active developer, not once per
request, so the cache absorbs almost all of it. Most of that total is a private
endpoint, which bills at rest; see
[ADR-0011](adr/0011-projection-platform.md) for why private networking is
assumed rather than optional. The standing-cost objection to ADR-0005 does not
survive the arithmetic either way.

---

## The budget is a delayed kill switch, not a hard cap

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
