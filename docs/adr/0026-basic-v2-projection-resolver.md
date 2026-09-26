# ADR-0026: Basic v2 uses a public Entra-authenticated resolver for the private projection

- **Status:** Accepted
- **Date:** 2026-09-26
- **Packet:** P61
- **Refines:** [ADR-0005](0005-identity-projection.md), [ADR-0011](0011-projection-platform.md),
  [ADR-0013](0013-gateway-outlives-instance.md), [ADR-0017](0017-projection-freshness-and-admission.md)

## Context

The owner asked for the Cosmos entitlement store to be available even when the gateway is
**Basic v2**, for the 100-500 developer range where API Management named values stop fitting.
The measured limits are unchanged: the business-unit membership named value holds about 93
developers and a tier allow list holds about 110 object ids. Raising the APIM SKU does not
change the 4,096-character named-value limit.

The projection's Cosmos account must stay private in this subscription. U15 found a
management-group policy that sets Cosmos public access to disabled, and the accelerator now
treats private Cosmos as the default rather than an exception.

Microsoft's current APIM v2 documentation, fetched 2026-09-26, says Standard v2 and Premium v2
support outbound virtual network integration, and the outbound integration article applies only
to Standard v2 and Premium v2:

- <https://learn.microsoft.com/en-us/azure/api-management/v2-service-tiers-overview>
- <https://learn.microsoft.com/en-us/azure/api-management/integrate-vnet-outbound>

Therefore Basic v2 cannot call a private resolver endpoint. The resolver still reaches private
Cosmos through Azure Functions Flex Consumption outbound VNet integration, which Microsoft lists
as supported for Flex Consumption, fetched 2026-09-26:

- <https://learn.microsoft.com/en-us/azure/azure-functions/functions-networking-options>
- <https://learn.microsoft.com/en-us/azure/cosmos-db/how-to-configure-private-endpoints>

App Service Authentication for App Service and Functions is the supported place to require an
authenticated request before Function code runs, fetched 2026-09-26:

- <https://learn.microsoft.com/en-us/azure/app-service/overview-authentication-authorization>
- <https://learn.microsoft.com/en-us/azure/app-service/configure-authentication-provider-aad>

## Decision

The installer offers an **entitlement store** choice:

| Choice | When it fits | What changes |
|---|---|---|
| Named values | Below the measured named-value ceiling | No Cosmos, resolver or projection network resources. |
| Projection | Around 100 developers and above, or whenever the operator chooses it | Private Cosmos entitlement store, resolver Function, population, comparison and guarded flip. |

The resolver inbound shape follows the gateway SKU:

| Gateway SKU | Resolver inbound | Reason |
|---|---|---|
| Basic v2 | Public endpoint with Microsoft Entra authentication | Basic v2 cannot reach a private resolver. |
| Standard v2 | Private endpoint | Outbound VNet integration can reach the resolver privately. |
| Premium v2 | Private endpoint | Premium v2 networking can reach the resolver privately. |

The Basic v2 public endpoint is not an anonymous API. The resolver template requires App Service
Authentication, returns 401 instead of a sign-in page, pins the token audience to the resolver app,
pins the tenant, and allows only the gateway managed identity application id and object id. The
Function's own managed identity reaches Cosmos through VNet integration, a Cosmos private endpoint
and private DNS. Cosmos local authentication stays disabled.

APIM v2 outbound IP addresses are not the primary control. They may be used as optional
defense-in-depth only when an operator accepts that IPs can change; the security boundary is the
managed-identity token.

The one-command deployer is `scripts/Deploy-ClaudeProjection.ps1`. It deploys private Cosmos and
networking, deploys the resolver using the SKU-valid inbound shape, exports the gateway named-value
decisions, populates the projection from Entra, compares the projection against the named-value
decisions, and writes only `entitlement-resolver-url`, `entitlement-resolver-audience` and
`entitlement-source` after a clean comparison and an explicit `-FlipAfterCleanCompare`.

## Cost

The cost model uses the Azure Retail Prices API documented at
<https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices>.
Rows were fetched 2026-09-26 for East US 2. The returned meters included:

- Functions Flex Consumption Always Ready Baseline: USD 0.000004 per GB-second.
- Functions Flex Consumption execution time: USD 0.000016 to 0.000026 per GB-second depending on
  always-ready versus on-demand.
- Functions Flex Consumption total executions: USD 0.000004 per 10 executions for Flex rows.
- Azure Cosmos DB serverless 1M RUs: USD 0.25 per 1M.
- Azure Cosmos DB data stored: USD 0.25 per GB-month for the Cosmos DB rows used by the model.

`scripts/Measure-ClaudeProjectionCost.ps1 -P61Scenarios` gives the operator the current scenario
view from one model. On 2026-09-26 it reported:

| Developers | SKU and resolver shape | Monthly list cost excluding APIM | At rest |
|---:|---|---:|---:|
| 100 | Basic v2, public resolver | $57.48 | $57.48 |
| 100 | Standard v2, private resolver | $65.28 | $65.28 |
| 100 | Premium v2, private resolver | $65.28 | $65.28 |
| 500 | Basic v2, public resolver | $57.48 | $57.48 |
| 500 | Standard v2, private resolver | $65.28 | $65.28 |
| 500 | Premium v2, private resolver | $65.28 | $65.28 |

The 100 and 500 developer rows are the same to cents because usage is below the free and low
variable thresholds in the default model; the bill is dominated by private endpoints, private DNS
zones and warm resolver capacity.

## Consequences

Basic v2 can now stay the low-cost gateway tier for 100-500 developers when the operator accepts
the public resolver risk. The compensating controls are identity-based, not network-location based.

Standard v2 and Premium v2 keep the stronger private-resolver topology. Operators who want no
public resolver endpoint on Basic v2 must choose Standard v2 or Premium v2.

The migration remains compare-gated. A failed population, named-value drift, projection drift or
missing resolver output leaves `entitlement-source` unchanged.

## Unknowns proposed for the lead ledger

- Whether APIM v2 outbound addresses can ever be treated as stable enough for resolver IP
  restrictions in a customer tenant. P61 treats them as optional only.
- Whether a customer tenant blocks creating the resolver app registration. The deployer accepts
  `-ResolverAppId` so a tenant administrator can pre-create it.
- Whether Basic v2 miss latency with the public resolver has the same p99 envelope as the prior
  private Premium v2 measurements; the live Basic proof must measure it.
