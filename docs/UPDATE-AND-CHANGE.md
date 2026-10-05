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
- every `{{named-value}}` reference in the current policy, derived from the policy rather than a
  hardcoded list, including later values such as `usd-budgets`, `usd-budget-state`,
  `external-idp-extra-audience` and `entitlement-source`;
- optional job definitions with older repository commit pins, when discovery reports them.

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
missing named values shown by `{{...}}` references in the policy with the defaults from
`infra\main.bicep`, deploy the policy, then update `claude-gateway.json` with the current release
commit and a history row. Prefer the script because it fingerprints the whole plan and refuses an
unknown named-value default.

## 2. Change the API Management tier

The guided `Tier` step plans only from the discovered SKU and region. Prices are read from the
Azure Retail Prices API at plan time; unknown price data is shown as unknown, never as zero. Before
its write, the step exports the gateway with `scripts\Backup-ClaudeGateway.ps1` to
`backups\before-tier-<apim>-<UTC time>.json`.

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

Named values are the default and hold roughly 100 developers. The projection is the scale path.
Records expire at most **two hours after scan start**; without renewal **every developer gets 503
after expiry**. `scripts/Deploy-ClaudeProjectionRenewal.ps1` deploys the job that renews them every
30 minutes ([ADR-0049](adr/0049-projection-renewal-deployment.md)). A switch is admitted after
three successful runs, with an action group that has an enabled email receiver; a clean comparison
or an ARM job execution alone is not renewal evidence ([ADR-0050](adr/0050-projection-switch-function.md)).

The `Entitlement` step uses `scripts\Measure-ClaudeProjectionCost.ps1` for the operator's
scenarios and switches through the same function as the deployer when a renewal receipt names the
gateway. The standalone deployer can still deploy
beside, populate and compare while named values remain authoritative. Deployment and
projection sync require PowerShell 7. `-PreflightOnly` runs the same read-only checks without
Azure writes (normally 30-90 seconds, including the 25-second Graph probe interval).

SKU rules from P61:

- Basic v2 uses a public resolver endpoint protected by Microsoft Entra and pinned to the gateway
  managed identity; Cosmos stays private.
- Standard v2 and Premium v2 use a private resolver reachable from the gateway's VNet integration.

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

`-FlipAfterCleanCompare` deploys, publishes and applies nothing. It reads
`onboarding/projection-renewal-<prefix>.json`, checks the receipt's values and that the gateway
calls the resolver deployed with it, runs `scripts/Compare-ClaudeEntitlement.ps1 -FailOnDrift`, the
read-only compare in the runner and admission, writes the entitlement named values to
`onboarding/projection-switch-<apim>-<UTC time>-<8 hex digits>.json`, and sets `entitlement-source`
to `projection`; `-WhatIf` stops before the backup ([ADR-0050](adr/0050-projection-switch-function.md)).

Reverse path: `entitlement-source` returns to `named-value` after the lists are refreshed with
`scripts/Sync-ClaudeAccess.ps1` and checked with `scripts/Compare-ClaudeEntitlement.ps1
-FailOnDrift`. Lists not kept current while the projection served traffic can regrant stale
members or deny new ones; the switch's backup holds the values from before it.

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
