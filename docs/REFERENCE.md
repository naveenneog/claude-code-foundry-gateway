# Repository and command reference

Run commands from the repository root unless a procedure changes directories.
For parameter descriptions use `Get-Help .\scripts\<name>.ps1 -Full`, or read
the script's top-level `param()` block. There is no Azure portal view of local
script parameters. [Operations](OPERATIONS.md) maps tasks to portal actions.

## Repository layout

```text
Install-ClaudeGateway.ps1      interactive admin setup (Windows)
install-claude-gateway.sh      admin setup (macOS/Linux)
deploy.ps1                    non-interactive gateway deployment
DEVELOPER.md                  developer setup for the three clients
infra/
  main.bicep                  gateway, observability, API, policy and RBAC
  foundry-role.bicep          gateway's Foundry data-plane assignment
  policy.xml                 governance policy
  projection.bicep            optional entitlement store
  projection-network.bicep    private networking for the projection
  resolver.bicep              optional resolver Function
  workbook.json              usage in tokens
  workbook-chargeback.json   chargeback in money
  azuredeploy.json           compiled ARM for Deploy to Azure
analytics/
  chargeback-ledger.kql       ClaudeChargeback: request ledger
  chargeback-cost.kql         ClaudeCost: priced daily aggregates
  claude-code-daily.kql       ClaudeCodeDaily: daily analytics
scripts/
  Setup-ClaudeWorkstation.ps1 Windows developer setup
  setup-claude-workstation.sh macOS/Linux developer setup
  Setup-ClaudeFoundryDirect.ps1  direct Foundry evaluation, no gateway
  get-foundry-token.*         Desktop credential helpers
  New-OnboardingEmail.ps1     developer handover email
  Onboard-ClaudeDeveloper.ps1 preflight, configure and verify
  Test-ClaudeHealth.ps1       gateway health
  Debug-ClaudeCode.ps1        layer-by-layer client diagnostics
  Sync-ClaudeAccess.ps1       publish Entra membership
  Compare-ClaudeEntitlement.ps1  compare named values with Entra
  ClaudeGraphMembership.ps1   shared transitive membership reader
  Sync-ClaudeProjection.ps1   optional projection writer/exporter
  Show-Governance.ps1         governance verification
  Set-ClaudeDeveloper.ps1     people, tiers and units
  Set-ClaudeTier.ps1          tier limits and models
  Manage-ClaudeBusinessUnits.ps1  interactive unit management
  Set-ClaudeBusinessUnit.ps1  register a unit, team or budget
  Get-ClaudeBusinessUnit.ps1  unit spend and unassigned people
  Get-ClaudeBudget.ps1        personal quota and metric-based usage
  Set-ClaudeBudget.ps1        personal daily overrides
  Measure-ClaudeCeiling.ps1   named-value headroom
  Measure-ClaudeOvershoot.ps1 measure budget observation delay
  Measure-ClaudeProjectionCost.ps1  projection cost assumptions
  Add-ClaudeModel.ps1         deploy, allow, price or retire a model
  Get-ClaudeBypass.ps1        direct Foundry access audit
  Get-ClaudeBom.ps1           created, reused and billable resources
  Backup-ClaudeGateway.ps1    configuration backup
  Restore-ClaudeGateway.ps1   reviewed restore, dry-run by default
  Migrate-ClaudeWorkstation.ps1  first-party to gateway
  Get-FoundryValues.ps1       discover Foundry values (-Mask to share)
  Set-GatewayPolicy.ps1       publish a policy file
  Test-FoundryDirect.ps1      evaluate without the gateway
  Publish-ClaudeQueries.ps1  publish saved workspace functions
  Publish-ClaudeWorkbook.ps1 publish a workbook
  Connect-ClaudeTurnstile.ps1 optional FinOps connection
  Open-ClaudeTurnstile.ps1   CLI-assisted Turnstile sign-in
  inspect-proxy.mjs           local protocol/claim inspection
resolver/                    request-path projection reader
sync/                        in-network projection writer
docs/                        task guides and reference
  adr/                       accepted architecture decisions
  CHARTER.md ROADMAP.md STATUS.md UNKNOWNS.md
                              contract, plan and measured record
guide/
  capture.mjs                portal screenshot capture
  compose.mjs                annotated screenshot composition
  auth.mjs                   local portal sign-in
tests/                       offline and opt-in live checks
```

The [README index](../README.md#documentation) lists every guide.
`inspect-proxy.mjs` helped establish the identity model by decoding JWT claims
without printing the token; it is a historical diagnostic with a fixed upstream,
not a safe default for customer traffic. Read the
[inspection warning](DEBUGGING.md#see-exactly-what-is-on-the-wire) before adapting it.

## Contributor checks

```powershell
./tests/Test-All.ps1
./tests/Test-All.ps1 -IncludeAzure
node .ironclad/gate.mjs --stage packet
```

The first suite is offline; the second adds live Azure checks and is not a
routine production health check. The packet gate is the definition of done.
There is no portal substitute for the local test suite; use the verification
steps in each deployment guide for live resources.

`Test-DocReferences.ps1` checks case-sensitive relative Markdown links, GitHub
heading anchors (including duplicate, Unicode and explicit HTML anchors),
repository-root script paths and parameters in copyable examples. It runs
mutation cases in uniquely named project-local scratch copies. Source scope:
README, DEVELOPER, user guides in `docs/`, `guide/README.md`, and onboarding
Markdown. It does not scan historical STATUS/ROADMAP/UNKNOWNS/CHARTER or ADRs as
source guides, but checks links into them. No active user guide is excluded.

### PowerShell encoding

PowerShell scripts containing non-ASCII characters need UTF-8 **with a BOM**
for Windows PowerShell 5.1. Without one, 5.1 reads ANSI and can fail before
execution; PowerShell 7 does not expose the same problem.
`scripts/Repair-ScriptEncoding.ps1 -Check` reports; omit `-Check` to repair.
Keep a file's existing line endings. ASCII scripts need no BOM.

### Azure CLI quoting on Windows

Keep `&`, `^`, `<`, `>`, `|`, and parentheses in `--query`, out of actual Azure
CLI arguments. `az` is a `.cmd` shim; PowerShell may send a no-space argument
unquoted, and `cmd.exe` then interprets metacharacters.

```text
--query "[?contains(name,'claude')].name" -> ].name was unexpected at this time
--uri ".../members?$select=id&$top=999"   -> '$top' is not recognized as a command
```

These are examples of what **not** to run. Replace all `<placeholder>` text
before running a real command. Filter Azure CLI JSON in PowerShell, or use
`Invoke-RestMethod` for REST URLs, especially Graph `@odata.nextLink` paging.
Check exit status: error text is a nonempty string, not evidence of success.
`tests/Test-AzArguments.ps1` guards repository scripts.

## Next steps

- [Releasing](RELEASING.md) — tags, changelog and release gate.
- [Screenshot tooling](../guide/README.md) — capture, redact, review.
- [Charter](CHARTER.md) — the engineering contract.
