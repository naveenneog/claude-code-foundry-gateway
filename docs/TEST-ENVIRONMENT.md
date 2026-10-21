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
| `Smoke` | Standard model 200 and premium model 403; moves the user to premium and unit b; after the next scheduled run, the premium model returns 200 and the membership lines place the user in unit b |
| `Teardown` | Deletes the resource group, the groups, the resolver app and an added Foundry secret, as recorded on the resource group's tags |

`-Phase All` runs every stage except `Teardown`. A stage reads earlier stages'
outputs from the resource group's deployments, so it can be rerun alone.
Rerunning `Resources` redeploys `main.bicep`, which resets the entitlement
named values; rerun `Configure` after it.

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

## Rights

| Stage | Right |
|---|---|
| `Identity` | Create groups and app registrations in the gateway tenant (a default member user can, unless the tenant restricts it) |
| `Resources` to `Populate` | Owner on the subscription or resource group: the templates create role assignments |
| `Grant` | Privileged Role Administrator or Global Administrator in the gateway tenant. Azure subscription Owner is not enough |

Without the Graph grant, every scheduled run stops at the Graph stage and the
Graph-denied alert fires. The `Grant` stage then reports the command an
administrator runs; afterwards rerun `-Phase Grant,Populate,Smoke`.

## The test cron

The test environment passes `*/<SyncMinutes> * * * *` to
`infra/projection-renewal.bicep` directly. The production intervals in
`scripts/ClaudeProjectionSchedule.ps1` start at 30 minutes (ADR-0058) and are
unchanged; `Set-ClaudeProjectionSyncSchedule.ps1` does not recognise the test
cron. A manual start and a scheduled run can overlap at 5 minutes; the later
one waits for the apply lock or stops (U165).

## Cost

The environment bills while it exists: API Management Basic v2, a 400 RU/s
Cosmos container, one always-ready resolver instance, a Basic registry, private
endpoints and DNS zones, and the job's run-seconds. Delete it with `Teardown`.
