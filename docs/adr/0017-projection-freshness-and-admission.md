# ADR-0017: Projection freshness is an absolute lease; misses have a bounded admission envelope

- **Status:** Accepted
- **Date:** 2026-09-24
- **Packet:** P19 completion (explicitly requested alongside the active P45 work)
- **Refines:** [ADR-0005](0005-identity-projection.md), [ADR-0011](0011-projection-platform.md)

## Decision

An entitlement cache TTL alone cannot revoke access when the sync stops. Every
complete directory scan now produces a UUID `reconciliationGeneration`,
`lastVerifiedAt` at **scan start**, and integer UTC epoch-second `expiresAt`.
The default and maximum lease is **7,200 seconds**; operators may shorten it to
60 seconds. A snapshot preserves those values during import: replay never buys
more time. Scans must finish before publication and every member is refreshed,
including unchanged members. Kept or failed-to-delete orphans are never renewed.

The resolver refuses missing, malformed, future-dated or expired freshness with
503, not a user-not-found response. Its answer includes the absolute expiry.
APIM clips the cache duration to the remaining lease and checks that expiry on
**every** cache hit. Tenant and schema version are in the cache key. A failed
write can leave two generations in the container; each has its original lease,
not a new global freshness marker. There is no claim of an atomic cross-partition
cutover. A failed directory scan writes nothing; a partial apply exits nonzero.

Consequently a stopped sync cannot grant access beyond two hours from the
beginning of its last successful directory observation (subject to clock skew
and directory replication). This bounds admission of **new requests**, not an
already-running stream. Under healthy operation a revocation appears after the
next reconciliation plus at most the smaller of the cache window and the
remaining lease. Schedule scans often enough that scan, transfer and apply finish
before expiry; alert on failure and remaining lease, not just process exit.

Each resolver process shares concurrent reads of the same identity. It retains
no completed-result cache, so this cannot extend authorization. Distinct reads
are capped at 100, have a 3.5-second wall-clock deadline and an abort signal;
Cosmos transport timeout is 2.5 seconds with throttling retries disabled.
Unfinished aborted operations retain their slot until transport settles.

Before calling the resolver, APIM admits at most 100 concurrent misses and
200 misses/second; excess gets retryable 429. These are protective, approximate
distributed limits, not a 500,000-user throughput guarantee. Two 2-GB always-ready
instances, each explicitly set to 100 concurrent HTTP requests, provide warm
headroom without depending on scale-out for the first admitted burst. APIM has
no atomic cache lock; single flight is **per process**, not across hosts.

The enterprise Cosmos template defaults to private-only. Existing explicit
`public` and `selected-ips` callers remain supported; no public profile is
selected implicitly. Existing unleased records require a fresh reconciliation
before deploying the stricter resolver and policy.

## Evidence and trade-offs

DOCUMENTED, Microsoft Learn retrieved 2026-09-24:

- [Limit concurrency](https://learn.microsoft.com/azure/api-management/limit-concurrency-policy):
  excess is immediately 429; distributed limits are approximate.
- [HTTP concurrency](https://learn.microsoft.com/azure/azure-functions/functions-concurrency#http-trigger-concurrency):
  2-GB Flex instances default to 16; explicit values survive memory-size changes.
- [Cosmos connection policy](https://learn.microsoft.com/javascript/api/@azure/cosmos/connectionpolicy):
  `requestTimeout` is milliseconds; `retryOptions` configures retries.

Assertions and mutations are in `Test-SecureProjection.ps1`,
`Test-ProjectionNegative.ps1` and the Node tests. Live measurements, including
their envelope and limitations, belong in [SCALE.md](../SCALE.md).

Renewing all 500,000 leases costs writes on every full reconciliation, unlike
the earlier unchanged-record optimization. Capacity and recurring write cost
must include that workload. Two warm instances cost more than one. A lease
deliberately trades directory-outage tolerance for bounded stale access; an
operator cannot silently lengthen it beyond two hours to hide a failed sync.

The isolated scale loader requires the explicit container `loadtest`, refuses
an occupied container, bounds workers, confirms cardinality and measures reads
at the first, middle and last identities. It never writes the real entitlement
container. Its container and temporary grant are removed after measurement.
