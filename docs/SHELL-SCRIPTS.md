# Shell administrative commands

The nineteen new Bash entry points use shared Node.js modules in
[scripts/lib](../scripts/lib). They do not invoke PowerShell. Existing shell
equivalents remain in place. Use a supported Node.js runtime with built-in
`fetch`, `util.parseArgs`, and the Node test runner. Live administrative commands
also require Azure CLI, an authenticated account, and the appropriate permissions.

## Command mapping

| PowerShell | Shell | Status |
|---|---|---|
| [Capture-Transcripts.ps1](../scripts/Capture-Transcripts.ps1) | [capture-transcripts.sh](../scripts/capture-transcripts.sh) | New, offline capture |
| [Debug-ClaudeCode.ps1](../scripts/Debug-ClaudeCode.ps1) | [debug-claude-code.sh](../scripts/debug-claude-code.sh) | New, Unix client checks |
| [Find-ClaudeUserData.ps1](../scripts/Find-ClaudeUserData.ps1) | [find-claude-user-data.sh](../scripts/find-claude-user-data.sh) | New |
| [Get-ClaudeAnalytics.ps1](../scripts/Get-ClaudeAnalytics.ps1) | [get-claude-analytics.sh](../scripts/get-claude-analytics.sh) | New |
| [Get-ClaudeBudget.ps1](../scripts/Get-ClaudeBudget.ps1) | [get-claude-budget.sh](../scripts/get-claude-budget.sh) | New |
| [Get-ClaudeBypass.ps1](../scripts/Get-ClaudeBypass.ps1) | [get-claude-bypass.sh](../scripts/get-claude-bypass.sh) | New |
| [Get-ClaudeTelemetry.ps1](../scripts/Get-ClaudeTelemetry.ps1) | [get-claude-telemetry.sh](../scripts/get-claude-telemetry.sh) | New |
| [Get-FoundryValues.ps1](../scripts/Get-FoundryValues.ps1) | [get-foundry-values.sh](../scripts/get-foundry-values.sh) | New |
| [Import-ClaudeEntitlement.ps1](../scripts/Import-ClaudeEntitlement.ps1) | [import-claude-entitlement.sh](../scripts/import-claude-entitlement.sh) | New |
| [Import-ClaudeMemory.ps1](../scripts/Import-ClaudeMemory.ps1) | [import-claude-memory.sh](../scripts/import-claude-memory.sh) | New |
| [Invoke-ShellTests.ps1](../scripts/Invoke-ShellTests.ps1) | [test-setup-workstation.sh](../scripts/test-setup-workstation.sh) | Existing |
| [New-ClaudeCodePolicy.ps1](../scripts/New-ClaudeCodePolicy.ps1) | [new-claude-code-policy.sh](../scripts/new-claude-code-policy.sh) | New |
| [New-OnboardingEmail.ps1](../scripts/New-OnboardingEmail.ps1) | [new-onboarding-email.sh](../scripts/new-onboarding-email.sh) | New |
| [Remove-ClaudeUserData.ps1](../scripts/Remove-ClaudeUserData.ps1) | [remove-claude-user-data.sh](../scripts/remove-claude-user-data.sh) | New |
| [Repair-ScriptEncoding.ps1](../scripts/Repair-ScriptEncoding.ps1) | [repair-script-encoding.sh](../scripts/repair-script-encoding.sh) | New |
| [Set-ClaudeBudget.ps1](../scripts/Set-ClaudeBudget.ps1) | [set-claude-budget.sh](../scripts/set-claude-budget.sh) | New |
| [Set-GatewayPolicy.ps1](../scripts/Set-GatewayPolicy.ps1) | [set-gateway-policy.sh](../scripts/set-gateway-policy.sh) | New |
| [Setup-ClaudeWorkstation.ps1](../scripts/Setup-ClaudeWorkstation.ps1) | [setup-claude-workstation.sh](../scripts/setup-claude-workstation.sh) | Existing |
| [Show-Banner.ps1](../scripts/Show-Banner.ps1) | [banner.sh](../scripts/banner.sh) | Existing |
| [Show-Governance.ps1](../scripts/Show-Governance.ps1) | [show-governance.sh](../scripts/show-governance.sh) | New |
| [Sync-ClaudeAccess.ps1](../scripts/Sync-ClaudeAccess.ps1) | [sync-claude-access.sh](../scripts/sync-claude-access.sh) | New |
| [Test-FoundryDirect.ps1](../scripts/Test-FoundryDirect.ps1) | [test-foundry-direct.sh](../scripts/test-foundry-direct.sh) | New |
| [Test-Prerequisites.ps1](../scripts/Test-Prerequisites.ps1) | [preflight.sh](../scripts/preflight.sh) | Existing |
| [get-foundry-token.ps1](../scripts/get-foundry-token.ps1) | [get-foundry-token.sh](../scripts/get-foundry-token.sh) | Existing |

## Safe preview

```bash
bash scripts/get-claude-budget.sh --help
bash scripts/get-claude-budget.sh --resource-group example --apim-name example --dry-run
bash scripts/set-claude-budget.sh --user 00000000-0000-0000-0000-000000000001 --tokens 1000 --what-if
npm run test:scripts
```

Every new command supports `--help`, `--dry-run`, and `--what-if`. Dry runs print
an offline operation plan: they do not acquire credentials, discover resources,
validate live permissions, run child processes, or write files. They validate option
names and argument shape, not all live inputs. Do not treat a successful plan as
proof that the requested operation can succeed. The existing workstation shell
also supports `--dry-run`; other existing scripts do not share the new common CLI.

Options use kebab-case, such as `--resource-group`; lists are comma-separated.
Results are JSON by default (`--as-json` is accepted). Errors exit nonzero, and
the bypass command also exits nonzero when it reports a non-read-only finding.
Use explicit resource names and verified object IDs for privileged operations.

## Effects without dry run

| Commands | Effects |
|---|---|
| Get/find reports | Authenticated reads; reports can contain personal data |
| `sync-claude-access`, `set-gateway-policy`, `set-claude-budget` | Write immediately when invoked with valid mutation arguments; no `--execute` guard. Budget `--list` is read-only |
| `import-claude-entitlement`, `remove-claude-user-data` | Live preview by default; `--execute` adds members or submits irreversible purge |
| `show-governance` | Inference and telemetry reads by default; `--execute` permits temporary throttle mutation unless `--skip-throttle-test` |
| `debug-claude-code`, `test-foundry-direct` | Inference unless `--skip-live-call`; this flag is not a fully offline mode |
| Policy, email, memory, capture, encoding commands | Local writes; encoding `--check` avoids repair; email `--send` additionally sends through Graph |

Generated policy apply helpers are separate: Bash defaults to `--dry-run` and
requires `--execute`; PowerShell supports `-WhatIf`. Installation may require an
elevated shell. Inspect payloads and use administrator-owned directories first.

## Compatibility boundaries

- These are functional counterparts, not identical CLI or console-output replicas.
  Windows registry/CIM and interactive desktop probes do not apply to Unix. Direct
  shell diagnostics use HTTP probes rather than an interactive Claude conversation.
- Transcript capture intentionally records offline shell plans or PowerShell help,
  not live wizard sessions. This prevents documentation capture from changing a workstation.
- Shell CSV imports discover common column names, use the existing group defaults,
  and reject unknown tiers or unresolved identities before writes. PowerShell retains
  its guest-form fallback and per-row reporting behavior; not every fallback is ported.
- Shell bypass JSON includes read findings regardless of `--include-read`. Neither
  audit establishes the absence of control-plane, key-based, or network bypass paths.
- Shell memory imports use the PowerShell block markers. Backups have unique names;
  managed paths are platform-specific. Shell encoding repair rejects invalid UTF-8.
- MDM payload delivery, live Graph queries, purge completion, cloud authorization,
  and Windows PowerShell 5.1 have not been validated in this packet.

See [security review](SCRIPT-SECURITY-REVIEW.md) and [status](STATUS.md) before rollout.