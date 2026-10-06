# ADR-0054: The update flow moves a named-value gateway to the Cosmos projection, with its previous values and a readiness check

- **Status:** Accepted. The owner asked on 2026-10-06 for this path ahead of the P99 merge, and approved
  merges, live testing and architecture decisions on 2026-10-05.
- **Date:** 2026-10-06
- **Packet:** P100
- **Builds on:** [ADR-0052](0052-cosmos-default-installer.md) (the projection is the default store; the
  installer deploys, populates, compares and switches), [ADR-0051](0051-persistent-sync-based-cosmos-entitlement.md)
  (records persist until a sync changes them; the switch admits on a full sync within 24 hours)

## Context

The owner's direction on 2026-10-06: an existing gateway that serves entitlement from named values moves to the
Cosmos projection through the update flow, with few commands. The flow reuses the gateway's previous tier groups,
business units and entitlement, checks quotas and prerequisites, and shows the resources, networking and cost
before anything is written.

What exists, read from the code on 2026-10-06:

- `scripts/Update-ClaudeGateway.ps1` plans ordered migrations from `scripts/flow/migrations/`, prints a plan
  fingerprint, and writes only with `-Apply -ApprovedPlanFingerprint`, after a backup
  (`scripts/Update-ClaudeGateway.ps1:24-70`). It stops when the decision record
  `onboarding\claude-gateway.json` is missing (`:21-24`). None of its migrations touches the projection.
- The installer's re-run migrates a named-value gateway (ADR-0052). It calls `Invoke-ClaudeInstallerEntitlementSync`
  and `Invoke-ClaudeInstallerProjectionDeployment` (`scripts/ClaudeInstallProjection.ps1:168-286`). It prompts again
  for the tier groups (`Install-ClaudeGateway.ps1:1264-1267`).
- The gateway does not store its tier groups: `allow-standard` and `allow-premium` hold developers' object IDs
  (`infra/policy.xml:229-236`). The decision record holds `standardGroup` and `premiumGroup` when it exists
  (`Install-ClaudeGateway.ps1:1698-1717`); it is ignored by git and stays on the machine that ran setup.
- The projection preflight checks tools, sign-in, the gateway, Microsoft Graph, the tier groups, the resolver
  registration, resource providers, role assignments on the resource group by enumeration, and names
  (`scripts/ClaudeProjectionChecks.ps1:203-375`). It does not check quotas, region availability or the effective
  right to create role assignments. Cosmos DB regional capacity cannot be checked in advance
  ([SECURE-PROJECTION](../SECURE-PROJECTION.md)).
- Limits and the read-only ways to check them are in [UNKNOWNS](../UNKNOWNS.md) U135-U139.

## Options considered

1. **Extend the installer's re-run.** `Install-ClaudeGateway.ps1` has 1,832 lines against a budget of 700, and
   its re-run redeploys `infra/main.bicep` with the live named values as arguments, which a migration does not
   need (ROADMAP, P95 council follow-ups). Not taken.
2. **A new migration script.** A second plan, approval and backup mechanism next to the update flow's. Not
   taken.
3. **A migration in the update flow.** It reuses the update flow's fingerprinted plan, backup, ordered
   verification and decision record, and the installer's tested deploy-and-switch functions. Taken.

## Decision

Migration `0004-entitlement-projection` in `scripts/flow/migrations/`:

- **When it runs.** When the gateway's `entitlement-source` is not `projection`. `-KeepNamedValues` on
  `Update-ClaudeGateway.ps1` keeps named values; the plan says so.
- **Previous values, each with its source.**
  - Tier groups, first found of: `-StandardGroup` and `-PremiumGroup`, the gateway's `entitlement-groups` named
    value, the decision record, the default names `claude-code-standard` and `claude-code-premium`. A group
    counts only when Microsoft Graph finds it. Its transitive members are compared with `allow-standard` or
    `allow-premium`, and the difference is shown.
  - Business units: `bu-registry` and `bu-parents`, which the writer already reads from the gateway.
  - Name prefix: `entitlement-projection-prefix`, else the API Management name without `apim-` (the
    installer's rule, `Install-ClaudeGateway.ps1:585`), else `-NamePrefix`.
  - Region and SKU: the gateway's. Resolver access: public, as ADR-0052 decided, unless `-ResolverInboundAccess
    private`.
  - Developers: the object IDs in `allow-standard` and `allow-premium`, for the cost and the time estimate.
- **Readiness checks in the plan.** Read-only; a FAIL blocks `-Apply` and names the remedy; nothing is written.
  - The projection preflight, unchanged.
  - Region availability: Cosmos DB accounts, container groups and private endpoints from the resource
    providers' location lists, and the Flex Consumption locations.
  - Usage against limits: container groups and cores in the region, storage accounts in the region, virtual
    networks in the region, Cosmos DB accounts in the subscription, private DNS zones in the subscription.
  - The effective right to create role assignments in the resource group, from the permissions API.
  - Template validation of the projection and network templates; a policy denial is a FAIL.
- **What the plan shows.** The previous values and their sources; the drift between named values and Entra;
  each resource to be created (name, type, SKU, region) from an inventory that a test compares with the compiled
  templates; the network (address space, subnets, private endpoint, DNS zones, resolver access, runner); the
  identities and role assignments; the monthly cost from `scripts/Measure-ClaudeProjectionCost.ps1`; the time
  estimate; the switch and the rollback.
- **Apply.** Backup, then the installer's functions in their order: the named-value refresh
  (`Invoke-ClaudeInstallerEntitlementSync`), then deploy, populate, compare and switch
  (`Invoke-ClaudeInstallerProjectionDeployment`). Then the tier groups are recorded in `entitlement-groups`
  (object IDs and names, not secret), the migration is verified, and the decision record gets a history row.
  A failed step leaves named values serving and names the same update command to resume.
- **Without a decision record.** `-ResourceGroup` and `-ApimName` are enough to plan; apply writes the record.

## Consequences

- An existing named-value gateway moves to the projection with two commands, the plan and the apply. The
  apply command is printed with its fingerprint, and no value is typed again.
- Quota, region, permission and policy failures appear in the plan, before any write. Cosmos DB regional
  capacity remains a deployment-time failure, before the switch (U136).
- A plan takes longer: two Graph probes 25 seconds apart, usage reads and template validation.
- `entitlement-groups` is a new named value. P101 makes `Sync-ClaudeAccess.ps1` read it.
- The installer's re-run keeps its own migration; the update documentation names the update flow for existing
  gateways.

## How we'd know this was wrong

- A live migration fails after a plan that passed, on a cause the readiness checks name (a quota, a region, a
  permission or a policy).
- An operator has to pass a previous value by hand that the gateway or its record held.
- The inventory test passes while a compiled template creates a resource type the plan does not show.
