# ADR-0022: A discovered, separately owned enterprise network edge

**Status:** Accepted for P54 implementation; measurements and limits are in
[NETWORK-ENTERPRISE](../NETWORK-ENTERPRISE.md).

## Context

P54 was explicitly assigned on 2026-09-24 while the common worktree status page
still tracked P46. The lead owns the shared ledgers and architecture renderer.
This packet supplies their proposed updates rather than editing those files.
The scope includes P49's network profiles, but a profile must not silently
reconfigure unrelated workloads in a shared subscription.

The public Basic v2 baseline cannot reach private backends. The owner holds
subscription Owner and owns the relevant applications and groups, but cannot
obtain tenant administrator consent. Network controls must not require new
Graph application permissions, a new OAuth audience or a developer API key.

## Decision

Keep APIM as the identity, entitlement and budget boundary. Add an optional
Application Gateway WAF v2 edge with end-to-end TLS, a Key Vault certificate
read by a user-assigned managed identity, private-origin connectivity where
supported, and a service-level source-IP restriction before authentication.
Overwrite the client-address header at the edge; never trust a caller's
`X-Forwarded-For` for the ledger. The developer's Entra token passes unchanged
through the edge and is replaced with APIM's identity only at the backend hop.

Use Standard v2 inbound Private Link and outbound VNet integration as the
cost-conscious private-origin design. Basic v2 is a public-origin alternative,
not a private-network SKU. Premium v2 injection is a private, creation-time
configuration, not the same feature as outbound integration. Classic tiers are
network-capable but unsuitable for this repository's Anthropic token metering.

Offer internal, internet-facing and hybrid listeners explicitly. Discovery
lists actual subscriptions, supported region/SKU data, resource groups, VNets,
subnets, peerings, firewalls, routes, private DNS, certificates, public IPs,
gateways, WAF policies, Foundry and workspaces. A recommendation is not a
deployment target. Unattended ambiguity fails closed; existing shared
resources are not overwritten. Free address suggestions require IPAM approval.

Use a separate Messages-path WAF policy for measured, rule-scoped exclusions.
Keep request inspection and size enforcement enabled. Do not solve false
positives with a custom Allow rule or by disabling all body inspection.
Roll out in Detection, inspect the logs, and prove both legitimate traffic and
attack-pattern refusal in Prevention. Disable response buffering and configure
a 600-second backend timeout; the measurement harness distinguishes first SSE
event, first text delta and complete response.

The live Detection log exposed prompt/system/tool text, so log scrubbing is
part of the default policy, independently of inspection. The measured example
has six field selectors and 71 individual rule/field pairs; it is not a
universal waiver for future clients. Actual code traffic passed Prevention and
a query-string attack and oversized body still blocked.

The evaluation certificate must be a real CA/server chain: Key Vault's
self-signed end-entity certificate worked with Node's explicit trust but not
with the tested native client's CA configuration. The private verifier now
generates a two-day CA and leaf, imports the leaf PFX over Private Link, deletes
the working keys, and returns only the public CA. Production uses the selected
enterprise/public issuer.

Persist a local ownership manifest before each write. Re-runs read live
ownership, and removal checks it again and restores APIM before deleting only
owned resources. Private DNS can live in another subscription. The script
does not delete shared resource groups, purge a vault, register a tenant app,
change Entra consent, or modify the reference gateway.

## Consequences and limits

WAF is complementary to Entra and budgets, not a replacement. Prompt text
contains legitimate code that resembles web attacks; exclude only the
measured rule/field on the Messages URI and keep other surfaces inspected.
Private Link is not by itself "only the edge": corporate clients can otherwise
reach the private origin directly. An authenticated bypass test is mandatory.

The edge brings hourly cost, DNS operations and certificate lifecycle work.
Private-only operators need an actual routed client and DNS resolver, not a
successful control-plane deployment. Corporate IPAM, VPN/ExpressRoute,
firewall policy and optional application/monitoring network changes remain
explicit administrator decisions. Front Door Premium is an alternative
reference topology, not silently substituted for a regional Application Gateway.

## Owner addition: decisions, cost deltas and impact, 2026-09-25

Every planned network change must be an explicit administrator decision.
Topology, region, edge type (Application Gateway, Front Door Premium or none),
WAF mode/rules, each component's public/private state, reuse/create choices,
firewall/DNS and certificate source must carry a dated regional list-price
comparison and concrete security, availability, operational, reversibility
and dependency implications. A configuration-only choice is identified as
such, not given a fictitious service charge. Shared resources are not free:
show their current allocated cost separately from incremental deployment cost.
Unpriced variable consumption and unavailable tariffs remain unknown.

Before any Azure write, show one complete create/change/remove plan and its
cost delta. WhatIf performs the same read-only discovery and impact queries
and prints the same summary. Non-interactive execution requires an explicit
approval, not merely a default ShouldProcess result. Access-reducing changes
also require acknowledgement of the exact historical-impact report.

Impact comes from the selected gateway's actual diagnostic destinations, not
a workspace name. Query a bounded, administrator-selected UTC window; scope
every row to that gateway; distinguish Entra identity, APIM portal user IDs,
gateway peer IPs and trusted original-client IPs. Unknown or privacy-masked
IPs, missing tables, sampling, truncation and consumers bypassing the gateway
must not be counted as safe. A private backend alone does not require an
otherwise public gateway's developers to join a VNet.

The reference gateway is used only for read-only impact validation. Its
GatewayLogs category is not enabled and its Insights destinations differ, so
coverage must be measured rather than assumed. No logging, network, policy
or permission change on that reference is part of this addition.

## Sources

Verified 2026-09-24:

- [APIM landing zone architecture](https://learn.microsoft.com/azure/architecture/example-scenario/integration/app-gateway-internal-api-management-function).
- [APIM network capabilities](https://learn.microsoft.com/azure/api-management/virtual-network-concepts)
  and [Premium v2 injection](https://learn.microsoft.com/azure/api-management/inject-vnet-v2).
- [Application Gateway SSE](https://learn.microsoft.com/azure/application-gateway/use-server-sent-events).
- [WAF limits](https://learn.microsoft.com/azure/web-application-firewall/ag/application-gateway-waf-request-size-limits)
  and [rule-scoped exclusions](https://learn.microsoft.com/azure/web-application-firewall/ag/application-gateway-waf-configuration).
- [Private Application Gateway](https://learn.microsoft.com/azure/application-gateway/application-gateway-private-deployment)
  and [Key Vault certificates](https://learn.microsoft.com/azure/application-gateway/key-vault-certs).
