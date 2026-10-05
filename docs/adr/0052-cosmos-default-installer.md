# ADR-0052: The installer recommends and deploys the Cosmos projection by default

- **Status:** Accepted, with the owner's approval of P98's decisions on 2026-10-05
- **Date:** 2026-10-06
- **Packet:** P98
- **Supersedes:** the default store of [ADR-0012](0012-store-and-availability.md) (named values unless
  `-EntitlementStore projection` is passed)
- **Builds on:** [ADR-0051](0051-persistent-sync-based-cosmos-entitlement.md) (records persist until a
  sync changes them; the switch admits a gateway on a recent full sync)

## Context

A named value holds 4,096 characters. Business-unit membership fills first, at about 93 developers
with six-character unit IDs; a tier list holds about 110 object IDs ([SCALE](../SCALE.md)). Raising the
API Management SKU does not change that limit.

Before this decision, the installer's projection choice changed only the recorded store. The
deployment ran only with `-DeployProjection`, which no prompt set, and the switch needed a renewal
receipt that the installer never produced. A customer who chose the projection got a gateway still
serving named values.

The owner's direction, 2026-10-05: the Cosmos-based installer is the recommended and default path,
named values only for small organisations, and choosing Cosmos deploys it.

## Options

1. Keep named values as the default and document the projection as a migration. Every installation
   above about 93 developers then repeats the migration by hand.
2. Choose the store from the declared developer count. A team that grows past the limit migrates
   later, and two paths stay in daily use.
3. Make the projection the default for every size, keep named values selectable for small teams, and
   have the installer deploy and switch it.

## Decision

Option 3.

- **Default store.** The installer offers the Cosmos projection first, as recommended, for every
  developer count. `-Yes` without `-EntitlementStore` chooses it. Named values stay selectable for
  teams within their capacity; above it, the installer refuses them with the reason.
- **Choosing the projection deploys it.** The installer checks the projection prerequisites
  (PowerShell 7, Azure CLI, Node.js, npm, tar) before any Azure write. It runs
  `scripts/Deploy-ClaudeProjection.ps1` to deploy, populate and compare. It then runs the same script
  with `-FlipAfterCleanCompare`, which switches only after the resolver checks, the compare and switch
  evidence (ADR-0051). A failed deployment or a refused switch leaves named values serving and prints
  the rerun command. A new gateway gets no named-value lists. Both the deployer's compare and the
  switch then compare the projection with a fresh Entra snapshot.
- **Resolver access.** The resolver is public by default on every SKU. Microsoft Entra authentication
  accepts only the gateway's managed identity ([ADR-0028](0028-basic-v2-projection-resolver.md)), and Cosmos
  DB stays private. A private resolver needs the gateway's outbound virtual network integration into
  the projection network, which the installer does not configure. That integration exists on
  Standard v2 and Premium v2 only ([Microsoft Learn, updated 2025-12-04](https://learn.microsoft.com/azure/api-management/integrate-vnet-outbound)).
  `-ResolverInboundAccess private` stays available on those tiers, and the installer then states the
  prerequisite.
- **The optional sync job.** `-DeploySyncJob` deploys it after the switch, with the publisher email as
  the alert address; a failure there does not end the installation.
- **The approval summary lists the projection steps**, so `-WhatIf` shows them.
- **SKU guidance** keeps the included-request arithmetic and adds the facts that decide a tier with
  the projection (Microsoft Learn: [features](https://learn.microsoft.com/azure/api-management/api-management-features),
  updated 2026-06-05; [outbound VNet integration](https://learn.microsoft.com/azure/api-management/integrate-vnet-outbound),
  2025-12-04; [VNet injection](https://learn.microsoft.com/azure/api-management/inject-vnet-v2), 2025-10-08;
  [availability zones](https://learn.microsoft.com/azure/reliability/reliability-api-management), 2026-09-09;
  [Cosmos DB serverless](https://learn.microsoft.com/azure/cosmos-db/serverless), 2026-04-27):
  - **Basic v2:** 250 MB built-in cache, up to 10 units, no virtual network integration and no
    availability zones.
  - **Standard v2:** 1 GB cache, up to 10 units, outbound virtual network integration and zones.
  - **Premium v2:** 5 GB cache, up to 30 units, virtual network injection and zones.
  - Microsoft publishes no requests-per-second planning figure.
  - Cosmos DB serverless is single-region.
- **Documentation opens with a quickstart.** README, Setup and the projection guide start with the
  first command and the next commands in order; explanations follow.

## Consequences

- A default installation needs PowerShell 7, Node.js, npm and tar on the operator's machine. The
  macOS and Linux installer (`install-claude-gateway.sh`) still deploys named values; the projection
  runs from PowerShell 7.
- The projection adds a standing cost. `scripts/Measure-ClaudeProjectionCost.ps1` prices it; the
  installer shows the figure before approval.
- A default installation takes longer: the projection's Cosmos account, network, runner and resolver
  deploy after the gateway.
- `tests/Test-Scale.ps1` asserted that the README calls the projection "not the default"; it now
  asserts the README states the installer deploys it by default, and the business-unit negative suite's
  mutant reverses that sentence.
