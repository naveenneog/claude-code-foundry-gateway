# ADR-0063: Cross-tenant Foundry and customer private-network reuse

**Status:** Proposed  
**Date:** 2026-10-15  
**Packet:** P117

## Context

The customer gateway estate and the Claude Foundry account are in different
Entra tenants. The customer APIM already proves a client-credential path whose
secret is stored as the secret named value
`foundry-crosstenant-client-secret`. The P116 installer assumes that Foundry is
readable inside the deployment subscription and that the APIM managed identity
receives Cognitive Services User on that account.

The customer VNet already owns private DNS zones and links for Cosmos and
storage. P116's customer-VNet mode still creates those zones and links, and
refuses a conflicting namespace link. The customer VNet also lacks the three
dedicated projection subnets for the ACI runner, resolver environment and
renewal environment.

## Decision

1. Cross-tenant Foundry is an explicit opt-in mode. It takes the Foundry HTTPS
   endpoint, FDPO tenant ID and application client ID as configuration. It does
   not use an ARM resource reference and does not attempt a managed-identity
   role assignment in the other tenant.
2. The opt-in policy references the pre-existing APIM secret named value
   `foundry-crosstenant-client-secret`. The installer verifies that the named
   value exists and is secret, but never reads, copies, prints or records its
   value.
3. APIM obtains a client-credential token for
   `https://cognitiveservices.azure.com/.default`, caches it for less than its
   expiry and sends it only to the configured Foundry endpoint. Default
   deployments retain the existing managed-identity policy path.
4. Existing private-DNS reuse is explicit. Every reused zone is supplied by
   resource ID. The network deployment creates no zone or VNet link for a
   supplied zone; private endpoint zone groups reference it directly.
5. The existing VNet remains customer-owned. P117 may create only the three
   named, previously absent subnets approved for the pilot. The installer then
   receives all five subnet IDs and does not alter them.
6. The existing `claude-messages` API is not changed. The accelerator deploys
   its own `claude-foundry` API and `/claude` path on the reused APIM instance.
7. Access profiles and business units remain independent. The live detector
   requires nine plans, 47 access-profile groups and 48 business-unit groups.

## Consequences

+ The existing cross-tenant credential is reused without secret disclosure.
+ The customer network and central private-DNS ownership remain intact.
+ The same-tenant managed-identity deployment remains the default.
+ The new API can be removed independently without changing the existing API.
- Cross-tenant mode depends on the lifetime and rotation of an application
  credential held outside this repository.
- The FDPO application remains a direct Foundry principal and must stay
  restricted to the selected account.
- Customer-DNS reuse needs more explicit configuration than projection-owned
  DNS.

## Alternatives considered

**Grant the customer APIM managed identity in FDPO.** A managed identity is
tenant-bound and is not the existing proven cross-tenant path.

**Copy the existing secret into a new APIM instance.** This requires reading or
reissuing a secret and creates another APIM cost. Reusing the existing instance
keeps the secret in place and isolates P117 by API ID and path.

**Create another VNet and DNS zones.** This ignores the customer's required
precreated network and duplicates private connectivity.

**Overwrite the existing `claude-messages` API.** This would place the working
customer path at risk and makes rollback dependent on restoring another
project's revision.
