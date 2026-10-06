# Diagnostics

This guide covers deployment and workstation diagnostics with redacted results.
## Quickstart

The administrator target comes from the deployment record or [Operations discovery](OPERATIONS.md#1-select-the-gateway-and-workspace). A workstation uses the platform team's handover file. The commands below skip the real gateway request; an unskipped request can consume model capacity.

```powershell
.\scripts\Debug-ClaudeWorkstation.ps1 -RecordPath .\claude-gateway.json -NoRequest
```

```bash
./scripts/debug-claude-workstation.sh --config ./claude-gateway.json --no-request
```

**Expected result:** each check reports PASS, WARN, FAIL or SKIP with evidence and a fix. Default exit status is nonzero for a warning or failure.

## Administrator deployment checks

<details>

<summary>Diagnostic details</summary>

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

</details>
## Workstation checks

<details>

<summary>Diagnostic details</summary>

`Debug-ClaudeWorkstation.ps1` and `debug-claude-workstation.sh` check a developer
machine:

| Check | Meaning | Fix |
|---|---|---|
| Azure CLI | `az` is installed. | Install Azure CLI from the approved package channel. |
| Azure sign-in and tenant | `az account show` succeeds and matches the tenant supplied by the platform team. | `az login --tenant <tenant-id> --allow-no-subscriptions`. |
| Cognitive Services token | A token for `https://cognitiveservices.azure.com` is obtainable. The token is never printed. | Re-run `az login`; inspect Entra sign-in logs if issuance fails. |
| Claude Code | `claude --version` runs. Every Claude Code on PATH is listed, one per folder, and the first one is the one that runs. `claude doctor` runs with no input and a time limit, 45 s by default (`CLAUDE_DIAGNOSE_DOCTOR_TIMEOUT_SECONDS`), because some releases wait for a key press. | Install/update Claude Code and reopen the terminal. |
| Claude Code and the recorded models | Each alias `~/.claude/settings.json` pins is judged on what Claude Code was measured to send ([ADR-0031](adr/0031-client-keys-every-release-reads.md)). FAIL: a release that predates the pinned model, with no declaration and a model id as the pinned name, or with a declaration listing `thinking` without `adaptive_thinking`; either sends `thinking.type.enabled`, which the model refuses with `400`. WARN: the same on a custom deployment name or on a release that retries after the `400`; any other declaration that differs from the record, since a declaration turns off every capability it does not list; a model newer than the release table without its declaration; a declaration the record does not expect; an update available. | Re-run workstation setup, or `claude update`. |
| Managed settings precedence | Reports which source wins: Windows HKLM, file, HKCU; macOS/Linux managed profile or managed file over user settings. | Remove stale lower-precedence settings or deploy the intended MDM/file source. See [MDM](MDM.md). |
| User settings and environment | Reads `~/.claude/settings.json` and process environment variables that point at the gateway. | Set `CLAUDE_CODE_USE_FOUNDRY=1` and `ANTHROPIC_FOUNDRY_BASE_URL=https://<apim>.azure-api.net/claude`. |
| Conflicts | Detects mutually exclusive `ANTHROPIC_FOUNDRY_BASE_URL` and `ANTHROPIC_FOUNDRY_RESOURCE`, or mismatched base URLs. | Keep the gateway base URL and remove the resource variable. |
| VS Code and extension | `code` is present, the `anthropic.claude-code` extension is installed, and settings are discoverable. | `code --install-extension anthropic.claude-code`, then reload each window. |
| Claude Desktop | Finds third-party configuration and reports `helper-script` or `external-idp`. | Re-run workstation setup or deploy Desktop managed settings. Portal/client: Claude Desktop > Settings > Connection. |
| Claude Desktop running build (Windows) | The running Desktop build against the installed one, and shortcuts that start a versioned `app-<version>` build. | Quit Desktop including the tray icon and start it from the Start menu; repoint the shortcut. |
| Claude Desktop sign-in configuration | The sign-in keys in the policy (Windows: HKLM, then HKCU) or the local `Claude-3p` profile, checked against the release that reads them: on Windows the older of the installed and running builds, on macOS the installed app. On Linux the release is not read. A `helper-script` profile whose helper file is missing fails. | Re-run workstation setup, or regenerate the MDM profile with the spelling the fleet reads ([MDM](MDM.md)). |
| Claude Desktop recent errors (Windows) | Error lines from `%LOCALAPPDATA%\Claude-3p\logs\main.log`, such as `ENOTFOUND <host>`. | Follow the error; `ENOTFOUND` means the gateway host in the profile does not resolve. See [Troubleshooting](TROUBLESHOOTING.md#claude-desktop). |
| Network path | DNS, proxy and `NODE_EXTRA_CA_CERTS` evidence for the gateway host. | Fix DNS, proxy or custom CA; see [Network](NETWORK.md). |
| Gateway real request | Sends one real request unless skipped. | Rerun without `-NoRequest`; if the request fails, keep the redacted status, body and UTC time. |

</details>
## Support bundles

<details>

<summary>Diagnostic details</summary>

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

</details>
## Guided flow

<details>

<summary>Diagnostic details</summary>

`.\Start-ClaudeGateway.ps1 -Action Diagnose -SupportBundle` runs both scripts
with the decision record and writes their bundles to `onboarding\support\`,
which is git-ignored.

`scripts/flow/Diagnose.ps1` implements the ADR-0030 step interface. Its plan
contains only `Check` actions and writes nothing. Apply runs the same diagnostics
and returns results to the orchestrator; the decision record is not changed.

</details>
## Next

- [Debugging](DEBUGGING.md) isolates request layers manually.
- [Troubleshooting](TROUBLESHOOTING.md) maps known symptoms to fixes.
- [Developer setup](../DEVELOPER.md) covers workstation configuration.
