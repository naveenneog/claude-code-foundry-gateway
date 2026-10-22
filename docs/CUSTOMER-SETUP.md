# Customer setup

One command sets up the gateway on the customer's existing API Management,
Foundry account, network and Entra groups, from one JSON file
([ADR-0070](adr/0070-customer-setup-from-one-sheet.md)).

## Run

```powershell
git clone --branch PRODUCTION https://github.com/naveenneog/claude-code-foundry-gateway.git
cd claude-code-foundry-gateway
az login
copy .\config\customer-sheet.example.json .\onboarding\customer-sheet.json   # fill in every <placeholder>
.\scripts\Deploy-ClaudeCustomerEnvironment.ps1 -SheetPath .\onboarding\customer-sheet.json
```

The command stops at the first failure and says why; running it again resumes.
It runs, in order: Plan, Preflight, Deploy, Catalog, Limits, Sync, Grant and
Schedule (`scripts/Deploy-ClaudeCustomerEnvironment.ps1`). `-Phase Plan` writes and
checks the files without touching Azure.

## The sheet

[`config/customer-sheet.example.json`](../config/customer-sheet.example.json):

| Section | Holds |
|---|---|
| `gateway` | Tenant, subscription, resource group and name of the existing APIM, region, publisher email; the Foundry account and resource group; `foundryAuthentication` (`client-credentials` when Foundry is in another subscription, with its subscription, endpoint, tenant, client id and the APIM named value that holds the secret; else `managed-identity`); `compatibilityGroups` (the existing standard and premium groups) |
| `network` | The existing VNet, its five subnets (`endpoints`, `runner`, `resolver`, `renewal`, `apim`) and optional private DNS zone ids. Omit the section to create a VNet |
| `projection` | Name prefix, resolver access, `syncInterval` (`5m`, `15m` and up), alert email, revocation window |
| `deployments` | Foundry deployment name per model family: `haiku`, `sonnet`, `opus`, `fable` |
| `modelSets`, `profiles` | The tiers: level, dollar credit, model set (`Ha` Haiku, `So` Sonnet, `Op` Opus, `Fa` Fable), optional `tokensPerMonth` |
| `groups` | The existing Entra groups: display name, optional object id, tier (`profile`), capabilities (`Co`, `Cw`, `Ch`, `De`), M365 |

Groups are found by exact display name when `objectId` is empty; nothing in
Entra is created or changed.

## What each tier gets

- The model families of its model set, enforced per request.
- Monthly token limits per model family from its dollar credit, priced at
  Haiku 5.5, Sonnet 5.5, Opus 5.5 and Fable 5.1 with cache reads estimated
  (`-CacheReadShare`, default 0.5; [ADR-0069](adr/0069-token-limits-per-access-plan.md)).
- A person in several groups gets the group with the highest credit.

## Rights of the signed-in account

| Phase | Right |
|---|---|
| Deploy, Catalog, Limits, Sync, Schedule | Owner on the gateway resource group; Network Contributor on the VNet; read on the DNS zones and the Foundry account |
| Grant | Privileged Role Administrator or Global Administrator in Entra ID |

## Network

| Subnet | Example | Delegation | Size |
|---|---|---|---|
| `endpoints` | `10.60.1.0/24` | none | any |
| `runner` | `10.60.2.0/24` | `Microsoft.ContainerInstance/containerGroups` | any |
| `resolver` | `10.60.3.0/26` | `Microsoft.App/environments` | /27 or larger |
| `renewal` | `10.60.3.64/27` | `Microsoft.App/environments` | /27 or larger |
| `apim` | `10.60.4.0/24` | `Microsoft.Web/serverFarms`; NSG allows outbound TCP 443 to `AzureKeyVault` | /27 or larger |

The VNet is in the APIM's subscription and region. A private DNS zone given in
the sheet must already be linked to it. Preflight checks all of this before any
write ([Secure projection](SECURE-PROJECTION.md#prerequisites)).
