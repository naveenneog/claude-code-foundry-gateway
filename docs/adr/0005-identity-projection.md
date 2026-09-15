# ADR-0005: Identity resolution is a durable projection, not a directory call

- **Status:** Accepted
- **Date:** 2026-09-15
- **Packet:** P19 (planned), recorded now because it reverses an earlier design
- **Deciders:** claude-code-foundry-gateway maintainers
- **Supersedes:** the cache-plus-Graph design proposed on 2026-09-15 and rejected the same day

## Context

Entitlement and tier are resolved today by testing a caller's object id against a comma-delimited
API Management named value, synced from Entra groups on a schedule.

Named values cap at **4,096 characters**. Measured 2026-09-15: a 4,096-character value returns HTTP
201 and 8,192 returns HTTP 400. An object id plus its separator is 37 characters, so a tier holds
about **110 developers**. The requirement is 500,000.

## The design that was proposed, and why it was wrong

The first proposal was to stop materialising the list and instead resolve per request:
`cache-lookup-value` keyed on the object id, Microsoft Graph on a miss, `cache-store-value` with a
TTL. The reasoning was that 500,000 employees is not 500,000 concurrent, so the cache only ever
holds daily-active users.

That reasoning is true and insufficient. The built-in cache is documented as **"volatile and shared
by all units in the same region"**. A flush makes every active developer a miss simultaneously,
which converts Graph from an occasional dependency into a critical one with no warning. A miss also
puts directory latency directly into the request path, so even a small miss rate lands in p99.

The error underneath it was conflating two different things. Materialising 500,000 records in a
**data store** is unremarkable. Materialising them in **API Management policy configuration** is
what cannot work. Rejecting the second does not require accepting a live directory call.

## Decision

A durable entitlement projection, synced from Graph **off** the request path.

| | |
|---|---|
| Projection | `tenantId`, `oid`, `tier`, `businessUnit`, `authorized`, `mappingVersion`, `effectiveFrom`, `lastVerifiedAt` |
| Sync | Incremental where supported, plus periodic full reconciliation. An incomplete or failed scan must never replace a good snapshot |
| Request path | One `cache-lookup-value` for a single composite record, because the policy "can only be used once in a policy section". On a miss, a small resolver backed by the projection — not Graph |
| Auth | The gateway reaches the resolver with its managed identity |
| Protection | `rate-limit` after the lookup, per Microsoft's guidance for cache unavailability, plus request coalescing and bounded timeouts in the resolver |

### The failure contract

No design gives fresh revocation, unlimited outage tolerance and zero false denial at once. This one
chooses explicitly:

| Situation | Behaviour |
|---|---|
| Known identity, record within the staleness limit | Enforce the recorded tier and business unit |
| Record beyond the staleness limit | Deny |
| Unknown identity, or ambiguous business unit | Deny. Never silently grant a default tier with no chargeback owner |
| Authoritative revocation | Deny, and invalidate the cached record |
| Lookup failure | Never interpreted as "no such user", and never overwrites a good record |

Bounded stale authorization is a deliberate security trade-off rather than an avoidance of the
fail-open and fail-closed question. Revocation propagation is measured separately from availability.

Identity is keyed on **tenant plus object id**. Audience validation alone is not an authorization
model.

## Consequences

+ Graph outages and throttling stop being able to take the gateway down.
+ A cache flush costs a resolver round trip rather than a directory storm.
+ The projection is the natural place for the effective-dated mapping history that chargeback needs,
  so a mid-month transfer does not move last month's spend.
+ Revocation is bounded and stated rather than incidental.
− A component that did not exist before. The charter requires that to be justified, and the
  justification is that the alternative — 4,096 characters — cannot hold the data at all.
− Migration has to run in shadow mode, because entitlement is live.

## How we would know this was wrong

If the projection's staleness window turns out to be the thing operators fight, the answer was
closer to the directory than this assumes. The signal is how often a support request is "I was added
to the group and still cannot use it" versus "the gateway was down".
