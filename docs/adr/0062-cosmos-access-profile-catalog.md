# ADR-0062: Resolve configurable access profiles into one Cosmos entitlement per identity

- **Status:** Proposed
- **Date:** 2026-10-14
- **Packet:** P116
- **Deciders:** claude-code-foundry-gateway maintainers

## Context

Customers require configurable commercial plans and Entra group mappings. The supplied example has nine credit plans and 47 approved access-profile combinations across Code, Cowork, Chat, Design, Haiku, Sonnet, Opus, Fable, Mythos and optional M365. Business units remain a separate chargeback dimension.

The current projection writes one document per identity and the resolver performs one Cosmos point read. The gateway policy and named-value rollback path implement only `standard` and `premium`. APIM's `llm-token-limit` does not accept an expression for `tokens-per-minute`. ADR-0004 places client capabilities and connector settings in MDM while entitlement, models and spend stay server-side.

The owner requires the Cosmos path, automatic scheduled group synchronization, live Azure proof, and no AUM or Turnstile changes in this packet.

## Options considered

1. **Make every approved combination an APIM tier.** Rejected: 47 policy branches duplicate plan data and turn every customer combination into gateway code.
2. **Read a catalog during every request.** Rejected: it changes the one-point-read latency and RU contract and couples request availability to configuration lookup.
3. **Resolve profiles during sync and denormalize the effective result into the user record.** Chosen: request-time behavior remains one point read and group complexity stays in the existing reconciliation boundary.

## Decision

1. One versioned access catalog is stored as a control document in the existing entitlement container. Its `id` and `/oid` partition value are `access-catalog::<tenantId>` and its `type` is `access-catalog`, so resolver point reads for user object IDs cannot return it.
2. The catalog supports at most 16 plans and 64 enabled access profiles in P116. Each profile has one Entra group object ID, unique priority, one plan, capabilities, model families, optional connectors and a compatibility enforcement tier of `standard` or `premium` for the existing TPM and token-quota controls.
3. Canonical capabilities are `code`, `cowork`, `chat`, `design`. Canonical model families are `haiku`, `sonnet`, `opus`, `fable`, `mythos`. `m365` is the first connector identifier.
4. A full or scheduled sync reads the catalog, resolves every enabled profile group, and selects one whole profile per identity. Highest priority wins; a tie between different profiles, an absent configured access group, an unknown model family or an invalid catalog stops before entitlement writes. Dimensions are never unioned across profiles.
5. The sync materializes `planId`, `profileId`, `capabilities`, `modelFamilies`, `connectors`, `catalogVersion`, `profileHash`, the compatibility `tier`, and the independent `businessUnit` into the existing user document. The resolver continues one point read and returns the expanded record. Existing records remain valid during migration.
6. APIM uses the expanded projection record only when `entitlement-source=projection`. Model families are enforced server-side against deployed model-family mappings. Code, Cowork, Chat, Design and connector settings remain MDM management controls under ADR-0004. The named-value path remains the two-tier rollback path.
7. The catalog writer changes no Entra membership. Once the scheduled job holds `GroupMember.Read.All`, adding or removing a user in an access-profile group is sufficient; the next successful run publishes the entitlement. The existing removal ceiling, apply lock, changed-only writes and alerts remain.
8. Existing P108 explicit organization, business-unit and user USD budgets and their caching/freshness semantics remain unchanged and must still apply to profile-backed requests. Automatic dollar defaults derived from a plan are not claimed in P116: the current reconciler emits user state only for explicit `usd-budgets` items, and implementing plan scopes would change the excluded reconciler/AUM surface.
9. AUM and Turnstile code are out of scope. P116 adds a script/JSON administration surface and records a future packet for automatic plan-dollar defaults.

## Consequences

+ Nine plans and the customer's 47 profiles fit one configuration model without 47 request-policy branches.
+ The resolver's one-point-read availability and cache contract remains intact.
+ Model access is a gateway control; client capabilities remain accurately described as management controls.
+ Existing named-value rollback, BU logic, P108 dollar controls and scheduled-job safety remain available.
− The first packet still uses `standard` or `premium` as the compatibility TPM/token enforcement bucket.
− Exact automatic per-plan dollar defaults require a later reconciler/query/state packet; catalog credit values are metadata until that packet.
− A scheduled positive live proof needs tenant-admin `GroupMember.Read.All`; without it the live proof is attended sync plus the existing fail-closed scheduled Graph denial.

## How we'd know this was wrong

Revisit the decision if 64 profiles do not cover customer deployments, the sync cannot finish inside the shortest supported interval under measured Graph throttling, one point read cannot carry the expanded record inside the resolver deadline, or customers require exact plan-dollar defaults before they accept explicit user/BU USD budgets.
