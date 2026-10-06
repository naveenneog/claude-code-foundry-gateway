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
    value, the decision record when it describes the same gateway (resource group and API Management name), the
    default names `claude-code-standard` and `claude-code-premium`. A group counts only when Microsoft Graph finds
    it. A group named by a parameter, `entitlement-groups` or the decision record that Graph cannot find blocks the
    plan and is named in it; only the default names are a fallback. Its transitive members are compared with
    `allow-standard` or `allow-premium`, and the difference is shown. A record of another gateway is named in the
    plan and its groups are not used.
  - Business units: `bu-registry` and `bu-parents`, which the writer already reads from the gateway.
  - Name prefix: `entitlement-projection-prefix` when it is a valid prefix (the deployer writes it before the
    switch, so projection resources may exist under it), else `-NamePrefix`, else the API Management name without
    `apim-` (the installer's rule, `Install-ClaudeGateway.ps1:585`). A `-NamePrefix` that differs from a valid
    recorded prefix blocks the plan; a recorded value that is not a valid prefix gives way to `-NamePrefix`.
  - Region and SKU: the gateway's; a region that `az apim show` gives as a display name (`East US 2`) is used as
    its ARM name (`eastus2`), as the installer does (`Install-ClaudeGateway.ps1:580`). Resolver access: public,
    as ADR-0052 decided, unless `-ResolverInboundAccess private`.
  - Developers: the distinct transitive members of the two tier groups in Entra, the population the refresh and
    the snapshot carry; the transfer time and the cost use this count. The object IDs in `allow-standard` and
    `allow-premium` are counted apart, for the drift.
  - No premium group: `-PremiumGroup none`, `premium=none` in `entitlement-groups` or the record, or no premium
    group found while `allow-premium` is empty. The apply then passes `none`, the convention of the switch and the
    sync job (`scripts/ClaudeProjectionSwitch.ps1:10`, `scripts/Deploy-ClaudeProjectionRenewal.ps1:160`), never a
    default group name, and `scripts/ClaudeGraphMembership.ps1` treats the group name `none` as no group without a
    Graph lookup, because any user can create a Microsoft 365 group of that name.
- **Readiness checks in the plan.** Read-only; a FAIL blocks `-Apply` and names the remedy; nothing is written.
  - The projection preflight, unchanged.
  - Region availability: Cosmos DB accounts, container groups and private endpoints from the resource
    providers' location lists, and the Flex Consumption locations.
  - Usage against limits: container groups and cores in the region, storage accounts in the region, virtual
    networks in the region, Cosmos DB accounts in the subscription, private DNS zones in the subscription.
  - The effective right to create role assignments in the resource group, from the permissions API.
  - Template validation of the projection and network templates; a policy denial is a FAIL.
  - The snapshot transfer through the runner: more than 110 minutes is a FAIL, because a snapshot's apply-by time
    is 2 hours after its export; the estimate uses the measured 6.3 seconds per 4,900-character part and about 127
    bytes per developer (2026-10-06).
- **What the plan shows.** The previous values and their sources; the drift between named values and Entra;
  each resource to be created (name, type, SKU, region) from an inventory that a test compares with the compiled
  templates; the network (address space, subnets, private endpoint, DNS zones, resolver access, runner); the
  identities and role assignments; the monthly cost from `scripts/Measure-ClaudeProjectionCost.ps1`; the time
  estimate; the switch and the rollback.
- **What the fingerprint covers.** Every fact the plan shows and every value the apply uses: the groups' object
  IDs, member, gained and lost counts; the business-unit IDs and a SHA-256 of `bu-registry` and of `bu-parents`; the
  prefix, region,
  tier and access; the resolver app the preflight found, which the apply passes to the deployment; each check's
  name, result and remedy. Evidence that changes between runs (times, usage numbers) is printed beside the plan
  and left out, so that `-Apply`, which plans again, matches.
- **Apply.** Backup; then the tier groups are recorded in `entitlement-groups` (`standard=<object ID>,premium=
  <object ID>|none`: object IDs only, so the value passes `az.cmd` and `cmd.exe` unchanged; names are read back
  from Graph); then the installer's functions in their order: the named-value refresh
  (`Invoke-ClaudeInstallerEntitlementSync`), then deploy, populate, compare and switch
  (`Invoke-ClaudeInstallerProjectionDeployment`). The groups come first, so a later step that fails leaves them
  on the gateway and the switch never happens without them. The migration is verified (`entitlement-source` is
  `projection`, `entitlement-projection-prefix` is the planned prefix, `entitlement-groups` holds the planned
  groups), and the decision record gets a history row. A failed step leaves named values serving and names the
  update command that resumes: the decision record when it is not the default, the resolved groups as object
  IDs, the prefix and the resolver access. A tier whose group has no members (no group, or an empty one) lets the
  refresh empty that tier's list (`-AllowEmptyStandard`, `-AllowEmptyPremium`), because the approved plan counted
  its listed developers as leaving it. The decision record gets the groups the move used and the history row only
  when it describes the moved gateway.
- **Without a decision record.** `-ResourceGroup` and `-ApimName` are enough to plan; the plan uses a record of
  those two values, and the apply writes it with the release and a history row. A record that names another
  gateway is not a source of tier groups; the plan says so and prints no apply command, and `-Apply` refuses it
  before any write, naming `-RecordPath` for this gateway's record.

## Consequences

- An existing named-value gateway moves to the projection with two commands, the plan and the apply. The
  apply command is printed with its fingerprint, and no value is typed again.
- Quota, region, permission and policy failures appear in the plan, before any write. Cosmos DB regional
  capacity remains a deployment-time failure, before the switch (U136).
- A plan takes longer: two Graph probes 25 seconds apart, usage reads and template validation.
- `entitlement-groups` is a new named value, written only by this update in P100. Gateways installed or moved by
  the installer do not have it; P101 makes `Sync-ClaudeAccess.ps1` read it, falling back to the decision record
  and the default names as this plan does, and record it.
- The group name `none` is reserved: a tier group that has this display name is passed by object ID.
- The installer's re-run keeps its own migration; the update documentation names the update flow for existing
  gateways.

## How we'd know this was wrong

- A live migration fails after a plan that passed, on a cause the readiness checks name (a quota, a region, a
  permission or a policy).
- An operator has to pass a previous value by hand that the gateway or its record held.
- The inventory test passes while a compiled template creates a resource type the plan does not show.
