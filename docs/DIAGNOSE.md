# Diagnostics

P66 adds two read-only diagnostics entry points and one guided-flow module:

```powershell
# Administrator deployment
./scripts/Debug-ClaudeSetup.ps1 -ResourceGroup <rg> -ApimName <apim>

# Developer workstation
./scripts/Debug-ClaudeWorkstation.ps1 `
  -GatewayUrl https://<apim>.azure-api.net/claude `
  -TenantId <tenant-id>

# macOS/Linux workstation
./scripts/debug-claude-workstation.sh \
  --gateway-url https://<apim>.azure-api.net/claude \
  --tenant-id <tenant-id>
```

Every check prints `PASS`, `WARN`, `FAIL` or `SKIP`, the evidence used, the exact
fix command and the portal path. By default the scripts return non-zero for a
warning or failure. Add `-FailOn fail` if scheduled monitoring should only fail
on hard failures. Add `-NoRequest` / `--no-request` to skip the single real
gateway request.

## Administrator deployment checks

`Debug-ClaudeSetup.ps1` checks the deployment without writing to Azure:

| Check | Meaning | Fix |
|---|---|---|
| Decision record | `onboarding/claude-gateway.json` exists and can be parsed. | Restore the record or rerun `Start-ClaudeGateway.ps1 -Action Setup`. |
| Decision record matches live state | The recorded APIM name, URL and SKU match the live gateway. | `Start-ClaudeGateway.ps1 -Action Update` after `Backup-ClaudeGateway.ps1`. Portal: API Management > Overview. |
| Gateway real request | DNS, Entra token and the gateway request path work. | Rerun without `-NoRequest`; if it fails, inspect APIM > APIs > Claude API > Test and run `Test-ClaudeHealth.ps1`. |
| API Management SKU | The gateway is Basic v2, Standard v2 or Premium v2. | Migrate to a v2 SKU; classic tiers can meter Claude calls as zero tokens. Portal: API Management > Scale and pricing. |
| Managed identity and Foundry role | The APIM managed identity has a Foundry data-plane role such as `Cognitive Services User`. | `az role assignment create --assignee <principal-id> --role "Cognitive Services User" --scope <foundry-resource-id>`. Portal: Foundry account > Access control (IAM). |
| Deployed policy | The live Claude API policy contains the repository governance controls from `infra/policy.xml`. | `./scripts/Set-GatewayPolicy.ps1 -ResourceGroup <rg> -ApimName <apim>`. Portal: APIM > APIs > Claude API > Design. |
| Named values and ceilings | Named values exist, are under 4,096 characters, and list counts are compared with the 110 tier-list and 93 business-unit ceilings. | `./scripts/Measure-ClaudeCeiling.ps1 -ResourceGroup <rg> -ApimName <apim>`. Portal: APIM > Named values. |
| Entitlement source | The script reports named values or projection. Projection runs also need resolver health and authentication checks. | `./scripts/Deploy-ClaudeProjection.ps1 -ResourceGroup <rg> -ApimName <apim> -NamePrefix <prefix> -WhatIf`. Portal: resolver App Service > Authentication. |
| Tier groups | The health path checks whether tier decisions can resolve. | `./scripts/Compare-ClaudeEntitlement.ps1 -ResourceGroup <rg> -ApimName <apim>`. Portal: Entra admin center > Groups. |
| Business units and budgets | Reuses `Test-ClaudeHealth.ps1` for unassigned users and org ceiling versus unit budgets. | `./scripts/Test-ClaudeHealth.ps1 -ResourceGroup <rg> -ApimName <apim> -Detailed`. |
| FinOps tool | Reports Turnstile/AUM evidence available from named values and endpoints. | `Select-ClaudeFinOpsTooling.ps1`, `Connect-ClaudeTurnstile.ps1`, `Install-ClaudeAum.ps1`. |
| Dollar budgets | Reports whether a price book and fresh reconciled state can be proven. | `./scripts/Sync-ClaudeUsdBudgets.ps1 -ResourceGroup <rg> -ApimName <apim>`. |
| Workbooks | Confirms or points to workbook deployment. | `./scripts/Publish-ClaudeWorkbook.ps1 -ResourceGroup <rg>`. Portal: Monitor > Workbooks. |
| Chargeback jobs | Looks for report job evidence and last run metadata when available. | `./scripts/Invoke-ClaudeChargebackSchedule.ps1 -ResourceGroup <rg> -ApimName <apim>`. |
| Foundry bypass principals | Reuses `Test-ClaudeHealth.ps1` / `Get-ClaudeBypass.ps1` to identify principals that can bypass the gateway. | Remove unintended direct Foundry data-plane role assignments. Portal: Foundry account > Access control (IAM). |

## Workstation checks

`Debug-ClaudeWorkstation.ps1` and `debug-claude-workstation.sh` check a developer
machine:

| Check | Meaning | Fix |
|---|---|---|
| Azure CLI | `az` is installed. | Install Azure CLI from the approved package channel. |
| Azure sign-in and tenant | `az account show` succeeds and matches the tenant supplied by the platform team. | `az login --tenant <tenant-id> --allow-no-subscriptions`. |
| Cognitive Services token | A token for `https://cognitiveservices.azure.com` is obtainable. The token is never printed. | Re-run `az login`; inspect Entra sign-in logs if issuance fails. |
| Claude Code | `claude --version` runs and `claude doctor` output is captured where available. | Install/update Claude Code and reopen the terminal. |
| Managed settings precedence | Reports which source wins: Windows HKLM, file, HKCU; macOS/Linux managed profile or managed file over user settings. | Remove stale lower-precedence settings or deploy the intended MDM/file source. See [MDM](MDM.md). |
| User settings and environment | Reads `~/.claude/settings.json` and process environment variables that point at the gateway. | Set `CLAUDE_CODE_USE_FOUNDRY=1` and `ANTHROPIC_FOUNDRY_BASE_URL=https://<apim>.azure-api.net/claude`. |
| Conflicts | Detects mutually exclusive `ANTHROPIC_FOUNDRY_BASE_URL` and `ANTHROPIC_FOUNDRY_RESOURCE`, or mismatched base URLs. | Keep the gateway base URL and remove the resource variable. |
| VS Code and extension | `code` is present, the `anthropic.claude-code` extension is installed, and settings are discoverable. | `code --install-extension anthropic.claude-code`, then reload each window. |
| Claude Desktop | Finds third-party configuration and reports `helper-script` or `external-idp`. | Re-run workstation setup or deploy Desktop managed settings. Portal/client: Claude Desktop > Settings > Connection. |
| Network path | DNS, proxy and `NODE_EXTRA_CA_CERTS` evidence for the gateway host. | Fix DNS, proxy or custom CA; see [Network](NETWORK.md). |
| Gateway real request | Sends one real request unless skipped. | Rerun without `-NoRequest`; if the request fails, keep the redacted status, body and UTC time. |

## Support bundles

Add `-SupportBundle <path>` or `--support-bundle <path>`:

```powershell
./scripts/Debug-ClaudeSetup.ps1 -ResourceGroup <rg> -ApimName <apim> `
  -SupportBundle .\setup-support.zip

./scripts/Debug-ClaudeWorkstation.ps1 -GatewayUrl https://<apim>.azure-api.net/claude `
  -TenantId <tenant-id> -SupportBundle .\workstation-support.zip
```

The zip contains `manifest.json`, `results.json` and non-secret configuration
that explains what was checked. The bundle redacts emails, object IDs,
subscription IDs, JWTs and token-like strings before writing files. Do not add
raw terminal transcripts or bearer tokens to a support ticket.

## Guided flow

`.\Start-ClaudeGateway.ps1 -Action Diagnose -SupportBundle` runs both scripts
with the decision record and writes their bundles to `onboarding\support\`,
which is git-ignored.

`scripts/flow/Diagnose.ps1` implements the ADR-0030 step interface. Its plan
contains only `Check` actions and writes nothing. Apply runs the same diagnostics
and returns results to the orchestrator; the decision record is not changed.
