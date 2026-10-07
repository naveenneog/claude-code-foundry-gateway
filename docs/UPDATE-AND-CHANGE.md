# Update and change a guided-flow gateway

Use this runbook when a gateway was deployed by an older accelerator release, or when an
administrator wants to change one recorded decision after setup.

## 1. Update an older deployment

`scripts\Update-ClaudeGateway.ps1` reads `onboarding\claude-gateway.json`, discovers the live
gateway, compares it with the current repository, and prints a fingerprinted plan. A plan never
writes. It detects:

- the record schema (`schemaVersion` 1 or 2), preserving unknown fields while adding `release` and
  `history`;
- the live API policy hash versus `infra\policy.xml`;
- every `{{named-value}}` reference in the current policy and in included policy fragments, derived
  from XML rather than a hardcoded list, including later values such as `usd-budgets`,
  `usd-budget-state`, `external-idp-extra-audience`, `entitlement-source` and the
  `content-safety-*` named values;
- APIM policy fragments included by `infra\policy.xml`, created before the API policy is written;
- optional job definitions with older repository commit pins, when discovery reports them;
- the entitlement store: a gateway that serves from named values gets the move to the Cosmos projection
  ([section 3](#move-a-named-value-gateway-with-the-update)).

Without the decision record, `-ResourceGroup` and `-ApimName` name the gateway, and the apply writes the record.

```powershell
$plan = .\scripts\Update-ClaudeGateway.ps1 `
  -RecordPath .\onboarding\claude-gateway.json `
  -ResourceGroup <rg> -ApimName <apim>

.\scripts\Update-ClaudeGateway.ps1 `
  -RecordPath .\onboarding\claude-gateway.json `
  -ResourceGroup <rg> -ApimName <apim> `
  -Apply -ApprovedPlanFingerprint <fingerprint-shown-above>
```

Before any Azure write, the updater runs `scripts\Backup-ClaudeGateway.ps1` and records the backup
path in the plan. Roll back with:

```powershell
.\scripts\Restore-ClaudeGateway.ps1 -Path <snapshot.json> -Apply
```

Manual equivalent: take a backup, compare the live API policy with `infra\policy.xml`, create any
missing named values shown by `{{...}}` references in the policy and included fragments with the
defaults from `infra\main.bicep`, create any included policy fragments, deploy the policy, then
update `claude-gateway.json` with the current release
commit and a history row. Prefer the script because it fingerprints the whole plan and refuses an
unknown named-value default.

## 2. Change the API Management tier

The guided `Tier` step plans only from the discovered SKU and region. Prices are read from the
Azure Retail Prices API at plan time; unknown price data is shown as unknown, never as zero. Before
its write, the step exports the gateway with `scripts\Backup-ClaudeGateway.ps1` to
`backups\before-tier-<apim>-<UTC time>.json`. A choice that needs a new instance also takes this export,
then stops before any Azure write; the export is the backup that the move below restores.

Research fetched 2026-09-26:

- Microsoft Learn, API Management upgrade and scale:
  <https://learn.microsoft.com/en-us/azure/api-management/upgrade-and-scale>
- Microsoft Learn, v2 tiers overview:
  <https://learn.microsoft.com/en-us/azure/api-management/v2-service-tiers-overview>
- Microsoft Learn, feature comparison:
  <https://learn.microsoft.com/en-us/azure/api-management/api-management-features>
- Azure API Management pricing:
  <https://azure.microsoft.com/pricing/details/api-management/>

The documented in-place v2 tier change path is Basic v2 ↔ Standard v2. Microsoft states these
service infrastructure changes can take 15 minutes or longer, but the gateway continues serving
requests without interruption except for Developer tier changes. Premium v2 full virtual network
injection is a topology change in this flow: create a new Premium v2 instance, restore the gateway
configuration, verify, then cut clients over. That move keeps the old gateway serving until the
new one passes verification.

Manual equivalent for an in-place Basic v2 ↔ Standard v2 change:

```powershell
.\scripts\Backup-ClaudeGateway.ps1 -ResourceGroup <rg> -ApimName <apim> -Path .\backups\before-tier.json
az apim update -g <rg> -n <apim> --set sku.name=StandardV2 --enable-managed-identity true
.\scripts\Test-ClaudeHealth.ps1 -ResourceGroup <rg> -ApimName <apim>
```

`--enable-managed-identity true` preserves the gateway identity during the SKU update; Azure CLI `apim_update` clears `instance.identity` when `enable_managed_identity` is false. Source: https://github.com/Azure/azure-cli/blob/dev/src/azure-cli/azure/cli/command_modules/apim/custom.py.

For Premium v2/injection, use the move path: deploy a new gateway with the desired SKU/network
shape, restore the backup with `-Force`, verify health and a real request, then update clients or
DNS. Do not delete the old gateway until rollback is no longer needed.

## 3. Move entitlement between named values and the projection

The Cosmos projection is the installer's default store ([ADR-0052](adr/0052-cosmos-default-installer.md)). Named values hold about
93 developers in business-unit membership and about 110 per tier list, and serve small organisations.
Projection records persist until a sync removes or changes the person. A sync-job outage does not
stop developers. Add or remove a developer in the Entra group, then run
`scripts/Sync-ClaudeAccess.ps1 -ResourceGroup <rg> -ApimName <apim> -User <name-or-object-id>` for one
person, or omit `-User` for everyone. Removal takes effect after the sync plus at most
`entitlement-cache-seconds`; disabled Entra accounts lose access when their current token expires,
60 to 90 minutes by default (Microsoft Learn access tokens, updated 2026-07-17:
https://learn.microsoft.com/entra/identity-platform/access-tokens).

### Move a named-value gateway with the update

`Update-ClaudeGateway.ps1` plans the move from named values to the projection as migration
`0004-entitlement-projection` ([ADR-0054](adr/0054-update-flow-entitlement-migration.md)). The plan reads the
live gateway, so it works with or without the decision record `onboarding\claude-gateway.json`:

```powershell
.\Update-ClaudeGateway.ps1 -ResourceGroup <rg> -ApimName <apim>
.\Update-ClaudeGateway.ps1 -ResourceGroup <rg> -ApimName <apim> -Apply -ApprovedPlanFingerprint <fingerprint>
```

The plan prints the second command with its fingerprint, followed by any option given to the first. It shows:

| Item | Where the value comes from |
|---|---|
| Tier groups | `-StandardGroup` and `-PremiumGroup`; else the gateway's `entitlement-groups` named value; else `standardGroup` and `premiumGroup` in the decision record, when the record names the same gateway; else `claude-code-standard` and `claude-code-premium`. Each group is read from Microsoft Graph, and the plan counts the developers who would gain or lose access compared with `allow-standard` and `allow-premium`. A group named by a parameter, `entitlement-groups` or the decision record that Graph cannot find blocks the plan; only the default names are a fallback. `-PremiumGroup none` means no premium group; the name `none` is reserved for this, so a group with that display name is passed by object ID. |
| Developers | the distinct members of the two tier groups in Entra, which the move deploys and the cost and time count; the named-value lists are counted beside them |
| Business units | the IDs in `bu-registry` and the hierarchy in `bu-parents`; the fingerprint covers both, with a SHA-256 of each |
| Name prefix | the gateway's `entitlement-projection-prefix` when it is a valid prefix; else `-NamePrefix`; else the API Management name without `apim-` (the installer's rule). A `-NamePrefix` that differs from a valid recorded prefix blocks the plan, because projection resources may exist under the recorded one. |
| Region and tier | the gateway; a v2 tier is required |
| Resolver access | `-ResolverInboundAccess`; else `public` ([ADR-0052](adr/0052-cosmos-default-installer.md)) |
| Resolver app registration | the existing `claude-projection-resolver-<prefix>` app that the preflight finds, which the apply uses; else the deployment creates it |
| Readiness | the projection preflight (`scripts/ClaudeProjectionChecks.ps1`) and `scripts/ClaudeProjectionReadiness.ps1`: region availability, usage against limits, the right to create role assignments and template validation |
| Resources, network and identities | `scripts/ClaudeProjectionInventory.ps1`; `tests/Test-ProjectionInventory.ps1` compares it with the compiled templates |
| Monthly cost | `scripts/Measure-ClaudeProjectionCost.ps1`, from Azure Retail Prices API list prices |
| Time | about 35 minutes for the apply, plus the snapshot transfer through the runner, compressed and sent in parts 16 at a time: a snapshot of 500,000 developers took 41 minutes on 2026-10-06 ([P99 status](status/P99.md#live-run)). On 2026-10-06 the plan of a Basic v2 gateway with one developer took 3 minutes and its apply 36 minutes ([P100 status](status/P100.md#live-run)). |

The plan is BLOCKED, prints no apply command, and `-Apply` refuses it before the backup when:

- a readiness check is FAIL;
- a tier group is not found;
- the tier is not v2;
- a private resolver is asked for on Basic v2;
- the snapshot transfer would take more than 110 minutes, since a snapshot's apply-by time is 2 hours after
  its export; at the measured rate that is about 1.4 million developers.

A decision record that names another gateway, by resource group, API Management name or the subscription it
names, gets the same treatment: the plan names both gateways and prints no apply command, and `-Apply` refuses
before any write. `-RecordPath` names this gateway's record, or a new path that the apply writes. With a record,
the update reads the gateway in the subscription the record names; without one, in the Azure CLI's current
subscription.

The update writes in the Azure CLI's current subscription. When the record names another subscription than the
current one, the plan prints `az account set --subscription <id>` instead of the apply command, and `-Apply`
refuses before any write. The deployer's switch run, `Deploy-ClaudeProjection.ps1 -FlipAfterCleanCompare
-SubscriptionId <id>`, which the installer's projection step prints as its rerun command after a refused switch,
refuses the same way.

The readiness evidence, such as usage counts and times, is printed after the plan and is not part of the
fingerprint. The check results are, with every value the apply uses, so a change between the plan and the
apply makes `-Apply` refuse the fingerprint.

The apply takes the backup and records the tier groups in `entitlement-groups`
(`standard=<object id>,premium=<object id>|none`). It then runs the installer's steps from
`scripts/ClaudeInstallProjection.ps1`:

1. Refresh the named values from Entra.
2. Deploy the projection.
3. Populate it.
4. Compare it with the named values.
5. Switch `entitlement-source`.

It verifies that `entitlement-source` is `projection`, `entitlement-projection-prefix` is the planned prefix
and `entitlement-groups` holds the planned groups. A failed step leaves named values serving, with the groups
recorded. The error ends with the update command that resumes, naming the decision record when it is not the
default, the resolved groups, the prefix and the access. A gateway already on the projection plans no move,
and `-KeepNamedValues` plans none. A blocked move blocks the whole update; with `-KeepNamedValues` the other
migrations apply. In Windows PowerShell 5.1 the update plans no move, because the deployment needs PowerShell 7
(`pwsh`), and its other migrations apply.

A gateway that served from the projection before
[ADR-0051](adr/0051-persistent-sync-based-cosmos-entitlement.md) upgrades in this order.
`scripts/Deploy-ClaudeProjection.ps1`, run again with the parameters it was deployed with, publishes the
current resolver, records `entitlement-projection-prefix` and applies a full snapshot, which rewrites
every record that still carries an `expiresAt`. `scripts/Sync-ClaudeAccess.ps1` and
`scripts/Deploy-ClaudeProjectionRenewal.ps1` refuse until that named value exists. A sync job deployed
before then keeps its older image, which writes `expiresAt` and takes no apply lock, until
`scripts/Deploy-ClaudeProjectionRenewal.ps1` runs again.

The `Entitlement` step uses `scripts\Measure-ClaudeProjectionCost.ps1` for the operator's
scenarios and switches through the same function as the deployer using the gateway's `entitlement-projection-prefix` named value. The standalone deployer can still deploy
beside, populate and compare while named values remain authoritative. Deployment and
projection sync require PowerShell 7. `-PreflightOnly` runs the same read-only checks without
Azure writes (normally 30-90 seconds, including the 25-second Graph probe interval).

SKU rules from P61:

- Basic v2 uses a public resolver endpoint protected by Microsoft Entra and pinned to the gateway
  managed identity; Cosmos stays private.
- The installer deploys that public resolver on Standard v2 and Premium v2 too, by default
  ([ADR-0052](adr/0052-cosmos-default-installer.md)); `-ResolverInboundAccess private` gives them a private
  resolver reachable from the gateway's VNet integration, the default of `Deploy-ClaudeProjection.ps1`
  run on its own.

Manual equivalent:

```powershell
.\scripts\Measure-ClaudeProjectionCost.ps1 -P61Scenarios
.\scripts\Deploy-ClaudeProjection.ps1 `
  -ResourceGroup <rg> -ApimName <apim> -NamePrefix <prefix> `
  -SubscriptionId <subscription-id> -Sku BasicV2 -ResolverInboundAccess public `
  -ResolverAppId <resolver-app-id> -PreflightOnly

.\scripts\Deploy-ClaudeProjection.ps1 `
  -ResourceGroup <rg> -ApimName <apim> -NamePrefix <prefix> `
  -SubscriptionId <subscription-id> -Sku BasicV2 -ResolverInboundAccess public `
  -ResolverAppId <resolver-app-id>
```

`-FlipAfterCleanCompare` deploys, publishes and applies nothing. It calls
`Invoke-ClaudeProjectionSwitch -ResourceGroup <rg> -ApimName <apim> -NamePrefix <prefix>`, checks the
resolver deployment and service principal, runs `scripts/Compare-ClaudeEntitlement.ps1 -FailOnDrift`,
the read-only compare in the runner and switch evidence, writes the entitlement named values to a
projection-switch backup, and sets `entitlement-source` to `projection`; `-WhatIf` stops before the
backup ([ADR-0051](adr/0051-persistent-sync-based-cosmos-entitlement.md)).

Reverse path: `entitlement-source` returns to `named-value` after the lists are refreshed with
`scripts/Sync-ClaudeAccess.ps1 -Store named-value` and checked with `scripts/Compare-ClaudeEntitlement.ps1
-FailOnDrift`. Lists not kept current while the projection served traffic can regrant stale
members or deny new ones; the switch's backup holds the values from before it. A rollback to named
values holds only a population within their capacity, about 93 developers in business-unit membership
and about 110 per tier list ([Scale](SCALE.md#what-runs-out-first)); above it, the projection is the only
store that holds everyone.

## 4. Change the enterprise network edge

The `Network` step wraps `scripts\New-ClaudeNetworkEdge.ps1`. It does not replace that script's
review: the network review's own fingerprint, impact acknowledgement and unknown-cost
acknowledgements are still required.

Manual equivalent:

```powershell
# Prepare priced review with the network tooling, then:
.\scripts\New-ClaudeNetworkEdge.ps1 `
  -ReviewPath <review.json> `
  -ApprovedPlanFingerprint <network-review-fingerprint> `
  -NonInteractive
```

## 5. Change Claude Desktop sign-in

The `DesktopSignIn` step updates the decision record, writes the
`external-idp-extra-audience` named value, and flags device profiles for regeneration. Before its
write, the step exports the gateway with `scripts\Backup-ClaudeGateway.ps1` to
`backups\before-desktop-sign-in-<apim>-<UTC time>.json`.

- `helper-script` keeps the existing Azure CLI credential helper path and writes an empty extra
  audience.
- `external-idp-browser` and `external-idp-broker` require the Desktop public-client app audience
  to be accepted by the gateway.

Manual equivalent:

```powershell
.\scripts\Backup-ClaudeGateway.ps1 -ResourceGroup <rg> -ApimName <apim> -Path .\backups\before-desktop.json
.\scripts\ApimNamedValue.ps1  # dot-source, then:
Set-ApimNamedValue -ResourceGroup <rg> -ApimName <apim> `
  -Id external-idp-extra-audience -Value <desktop-app-client-id-or-api-audience>
.\scripts\New-ClaudeCodePolicy.ps1 -ConfigPath .\onboarding\claude-gateway.json -OutputPath .\onboarding\profiles
```

After any Desktop sign-in change, redistribute the regenerated Intune/Jamf/GPO profiles or rerun
the workstation setup scripts.
