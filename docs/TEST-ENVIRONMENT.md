# Test environment

`scripts/Deploy-ClaudeTestEnvironment.ps1` deploys a disposable gateway with the
Cosmos projection in two Bicep stages, then checks it with a live smoke test
([ADR-0067](adr/0067-staged-test-environment.md), P121).

| Stage | What it does |
|---|---|
| `Identity` | Creates the resource group (tag `claude-test-environment`), four Entra groups (standard, premium, unit a, unit b) and the resolver app registration; adds the signed-in user to standard and unit a |
| `Resources` | Deploys [`infra/test-environment/resources.bicep`](../infra/test-environment/resources.bicep): the gateway on Basic v2 with Foundry in another tenant, the private Cosmos projection, its network and the sync job registry |
| `Publish` | Builds the sync image in the registry |
| `Configure` | Deploys [`infra/test-environment/configuration.bicep`](../infra/test-environment/configuration.bicep): the resolver, the gateway's entitlement named values and the sync job every `-SyncMinutes` (5 to 30, default 5); publishes the resolver code |
| `Grant` | Grants Microsoft Graph `GroupMember.Read.All` to the job identity |
| `Populate` | Starts the job once and waits for success |
| `Smoke` | Standard model 200 and premium model 403. Then the user is in several groups at once: still in standard and unit a, and added to premium and to unit b, a team under unit a. After the next scheduled run the premium model returns 200 (premium wins over standard) and the membership lines place the user in unit b with parent unit a (the deeper unit wins). Removing premium makes the premium model return 403 again after the next run, while the standard model stays allowed. No step starts a sync by hand |
| `Teardown` | Deletes the resource group, the groups, the resolver app and an added Foundry secret, as recorded on the resource group's tags |

`-Phase All` runs every stage except `Teardown`. A stage reads earlier stages'
outputs from the resource group's deployments and tags.

| Rerun | Needs |
|---|---|
| `Identity` | Nothing; existing groups and app are reused |
| `Resources` | The Foundry parameters again. With `-CreateFoundrySecret` the earlier secret is removed and a new one added. Run `Configure` after it: redeploying `main.bicep` resets the entitlement named values |
| `Publish`, `Configure` | `Resources` has run |
| `Populate` | `Configure` and `Grant` have run |
| `Smoke` | `Populate` has run; it first puts the user back in standard and unit a |

The nested deployments are named `test-*`, so `Set-ClaudeProjectionSyncSchedule.ps1`
and the installer do not manage this job; only `Configure` does.

## Run

```powershell
./scripts/Deploy-ClaudeTestEnvironment.ps1 -SubscriptionId <subscription> -ResourceGroup rg-claude-test `
    -PublisherEmail <email> -FoundryAccountName <account> -FoundryEndpoint https://<account>.services.ai.azure.com/ `
    -FoundryTenantId <foundry tenant> -FoundryClientId <app id> `
    -FoundrySubscriptionId <subscription in the foundry tenant> -CreateFoundrySecret -UseCurrentAzLogin

./scripts/Deploy-ClaudeTestEnvironment.ps1 -SubscriptionId <subscription> -ResourceGroup rg-claude-test -Phase Teardown `
    -FoundryClientId <app id> -UseCurrentAzLogin
```

The Foundry client secret comes from one of two places:

- `-CreateFoundrySecret` adds a 7-day secret to `-FoundryClientId`'s app through
  Microsoft Graph in the Foundry tenant. It needs an owner of that app.
  Teardown removes it.
- `-FoundrySecretSourceApim <APIM resource id>` reads the
  `foundry-crosstenant-client-secret` named value of an existing gateway.

Either way the secret is held in memory and sent only in the Azure Resource
Manager deployment request body.

## Customer networking

By default `Resources` creates a VNet. To use a customer's network instead, pass
the same parameters as `Install-ClaudeGateway.ps1 -ProjectionNetworkMode existing`:

```powershell
./scripts/Deploy-ClaudeTestEnvironment.ps1 <the parameters above> `
    -ProjectionVnetId <vnet id> -ProjectionEndpointsSubnetId <id> -ProjectionRunnerSubnetId <id> `
    -ProjectionResolverSubnetId <id> -ProjectionRenewalSubnetId <id> -ProjectionApimSubnetId <id> `
    -ProjectionCosmosDnsZoneId <id> -ProjectionSitesDnsZoneId <id> -ProjectionBlobDnsZoneId <id> `
    -ProjectionQueueDnsZoneId <id> -ProjectionTableDnsZoneId <id>
```

- The VNet and all five subnet ids are required; the VNet must be in `-SubscriptionId` and `-Location`.
- DNS zone ids are optional. A given zone must be that `privatelink.*` namespace and already linked to the VNet; an omitted zone is created and linked by the test.
- Before the Foundry secret is read or anything is deployed, the installer's preflight
  (`Invoke-ClaudeProjectionNetworkPreflight`, `scripts/ClaudeProjectionNetwork.psm1`) checks five distinct
  subnets of the VNet, their delegations (resolver and renewal `Microsoft.App/environments`, runner
  `Microsoft.ContainerInstance/containerGroups`, apim `Microsoft.Web/serverFarms`, endpoints none), `/27` or
  larger, the apim subnet NSG rule to `AzureKeyVault` on 443, and the DNS links. Nothing in the customer VNet or
  its subnets is changed; private endpoints are added to the endpoints subnet.
- Extra right: read the VNet, subnets, NSG and DNS zones, and join the endpoints subnet (`Microsoft.Network/virtualNetworks/subnets/join/action`), for example Network Contributor on the VNet.
- Basic v2 API Management does not join the VNet, so the apim subnet is validated but unused in the test.
## Rights

| Stage | Gateway tenant and subscription | Foundry tenant |
|---|---|---|
| `Identity` | Create a resource group; create groups and app registrations (a default member can, unless the tenant restricts it) | none |
| `Resources` | Owner on the subscription (the templates create role assignments); with `-FoundrySecretSourceApim`, read the source gateway's secret named value | with `-CreateFoundrySecret`: owner of the Foundry app |
| `Publish` | Run ACR builds on the registry (Owner covers it) | none |
| `Configure` | Owner; read the gateway identity's service principal | none |
| `Grant` | Privileged Role Administrator or Global Administrator. Azure subscription Owner is not enough | none |
| `Populate` | Start and read Container Apps job executions; query the workspace | none |
| `Smoke` | Change the four groups' membership (their creator owns them); call the gateway; query the workspace | none |
| `Teardown` | Delete the resource group, groups and app | owner of the Foundry app, when a key was added |

## When the Graph grant is refused

`Grant` records the refusal, disables the job's three alert rules (otherwise
a failure email arrives every run), and stops. Then:

1. A Privileged Role Administrator or Global Administrator runs
   `./scripts/Grant-ClaudeProjectionRenewalGraphAccess.ps1 -PrincipalId <job identity>`,
   the command `Grant` printed.
2. Run `-Phase Configure,Populate,Smoke`. `Configure` redeploys the job and
   re-enables its alert rules.
3. A grant can take hours to reach the job identity's tokens. When
   `Populate` reports a Graph refusal after a grant, run
   `-Phase Populate,Smoke` later.

## The test cron

The test environment passes `*/<SyncMinutes> * * * *` to
`infra/projection-renewal.bicep` directly. The production intervals in
`scripts/ClaudeProjectionSchedule.ps1` start at 30 minutes (ADR-0058) and are
unchanged; `Set-ClaudeProjectionSyncSchedule.ps1` does not recognise the test
cron. A manual start and a scheduled run can overlap at 5 minutes; the later
one waits for the apply lock or stops (U165).

## Cost

The environment bills while it exists. Fixed charges: API Management Basic v2
and the always-ready resolver instance are the largest, then the 400 RU/s
Cosmos container, the Basic registry, and the private endpoints and DNS zones.
Usage charges: Log Analytics ingestion (each 5-minute run adds console lines),
the job's run-seconds, Functions storage and executions, and the alert rule
evaluations. Price the deployed SKUs in the
[Azure pricing calculator](https://azure.microsoft.com/pricing/calculator/), and
delete the environment with `Teardown` when the check is done.
