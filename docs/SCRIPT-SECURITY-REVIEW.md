# Script security review - P17

## Verdict

Implementation and offline checks are available for review, but **P17 is not signed
off**. No confirmed Critical-severity exploit was identified in this source review
under the trusted-administrator assumptions below. This is not a guarantee that
the scripts are vulnerability-free. Live cloud behavior, Windows PowerShell 5.1,
and the complete repository test suite remain unverified in this environment.

Scope: all 24 PowerShell and 24 shell files directly under scripts/, including the
19 new wrappers and their shared Node.js implementation. The review combined source
inspection, targeted security searches, negative boundary tests, parsing, and safe
offline execution. It was not a penetration test or an independent external audit.

## Fixed findings

| Risk | Changes and evidence |
|---|---|
| Credential forwarding or command injection through URLs and generated content | HTTPS and destination validation, encoded query values, structured subprocess argument arrays, escaped HTML/XML, quoted generated commands, and redirect rejection on hardened transport paths. Negative URL and output tests pass. Not every legacy PowerShell request shares this transport |
| Failed reads mistaken for empty access lists, no usage, or successful discovery | Selected telemetry, budget, audit and identity reads now fail closed. Both sync memberships are resolved before any write. Injected denied-read tests verify no premature sync mutation |
| Budget changes applied to an arbitrary email match | PowerShell budget resolution now requires one valid object ID; ambiguous mock lookup fails and GUID normalization passes |
| Lost budget or policy updates | Conditional ETag writes reject stale replacement. This does not make multiple resource updates atomic |
| Credential helper accepting failed or malformed CLI output | Shell rejects failed token acquisition; PowerShell accepts only a single string with valid token characters and absolute string boundaries, including rejection of trailing newline. This is format validation, not JWT signature verification |
| Documentation capture triggering real installation or login | PowerShell capture now uses help text; shell capture records executed offline plans. No interactive installer is launched by capture |
| Governance demo changing a live tier limit unexpectedly | Explicit execution guard for throttle mutation and restoration in finally. Shell detects an intervening value change; interruption limits remain below |
| Unsafe local output overwrite | Shared Node writer creates private files and rejects final-component symlinks, non-regular files and multiply linked files. Tests include a dangling symlink. Parent directories must still be trusted |
| False-success shell audit | Bypass findings produce nonzero exit status after the JSON report |

## Residual risks

These require operational controls or follow-up validation; they are not hidden by
the passing offline tests.

| Priority | Finding and affected area | Required control or next check |
|---|---|---|
| High under an untrusted-directory threat model | Legacy PowerShell file generators, encoding repair and memory import do not uniformly prevent symlink/reparse-point or hard-link overwrite. Node output checks do not protect all ancestor races; generated elevated apply helpers also trust their input tree | Never run elevated against a writable shared directory or untrusted source tree. Use administrator-owned directories and review generated payloads. Race-resistant cross-platform file handling remains unverified |
| High operational impact | Entitlement synchronization writes multiple named values, group import adds multiple members, and purge submits multiple table requests. Later failures can leave partial changes; legacy PowerShell sync lacks a transaction-wide concurrency guard | Record before/after state, serialize administration, inspect every result, reconcile partial changes. Do not assume automatic rollback or retry irreversible purge blindly |
| High operational impact | Governance restoration cannot survive force-kill, host failure, or failed restore requests. PowerShell restoration can overwrite a concurrent change; shell's comparison is not a durable recovery mechanism | Use disposable resources or an approved maintenance window; record the original limit and verify restoration externally |
| Medium | Some PowerShell resource discovery still selects the first APIM/account, and entitlement identity fallbacks swallow individual lookup failures. The shell rejects more ambiguous cases but guest-form parity is incomplete | Specify target names and verified object IDs. Validate the selected subscription/resource and complete roster before writes |
| Medium | Bypass audits inspect role dataActions, not every route to credentials or control-plane role assignment. Conditions, exclusions, inherited privileges and key access require separate assessment | A zero-finding report is not proof that direct inference is impossible. Review key access, role administration, network exposure and alternate identities independently |
| Medium | Legacy PowerShell encoding repair permissively decodes UTF-8. CSV reports can contain spreadsheet formula-like input; diagnostic outputs and backups may contain personal or sensitive data | Repair only backed-up, known UTF-8 trees; treat CSV fields as text; restrict output access and retention. Do not publish raw diagnostics or second-identity credentials |
| Medium | HTTPS validation does not establish that an administrator-supplied gateway or download host belongs to the organization. Legacy scripts do not universally reject redirects | Confirm endpoints out of band, trust only reviewed configuration, and use least-privileged tokens. Do not use these scripts as a service accepting arbitrary remote input |
| Validation gap | Full Graph/ARM behavior, MDM payload application, telemetry attribution, purge completion, Windows processes/registry, and PowerShell 5.1 remain untested here | U9 tracks supported-host and separately authorized disposable-resource validation |

## Coverage inventory

The [complete script mapping](SHELL-SCRIPTS.md#command-mapping) is the per-file
inventory. The following groups describe what was inspected, not a claim that every
file has an individual behavioral test.

| Script families, both PowerShell and shell | Review focus |
|---|---|
| Capture-Transcripts; Show-Banner | Offline execution, generated output, static display |
| Debug-ClaudeCode; Test-FoundryDirect; Test-Prerequisites | Credential destinations, inference side effects, error reporting, platform-specific probes |
| Get-ClaudeAnalytics; Get-ClaudeBudget; Get-ClaudeTelemetry; Get-FoundryValues | Query construction, discovery, failure handling, output sensitivity |
| Get-ClaudeBypass; Show-Governance | Role scope, false-clean results, mutation guard and restoration |
| Find-ClaudeUserData; Remove-ClaudeUserData | Subject identity, workspace scope, pagination, deletion guard and polling |
| Import-ClaudeEntitlement; Sync-ClaudeAccess; Set-ClaudeBudget | Identity ambiguity, roster parsing, preflight ordering, conditional updates and partial failures |
| Import-ClaudeMemory; Repair-ScriptEncoding | Input encoding, preservation, backups and filesystem trust |
| New-ClaudeCodePolicy; New-OnboardingEmail; Set-GatewayPolicy | Generated content escaping, output handling, email/header input, policy replacement |
| Setup-ClaudeWorkstation; get-foundry-token; Invoke-ShellTests | Setup preview, token failure/format handling, command invocation, safe test harness behavior |

## Verification evidence

- Node suite: 22 tests, including all 19 new commands' help and offline dry runs,
  negative URL/identity inputs, transport failures, private file output, entitlement
  ordering, analytics shaping, generated policy, memory replacement and capture.
- Isolated PowerShell: all scripts parse; mocked fail-closed, sync ordering, budget
  identity and credential-format regressions pass. No system PowerShell was installed.
- Existing shell harness: 13 passed, zero failed, using mocks and pure transforms.
- Bash syntax and shared Node module syntax checks pass. Script UTF-8 BOM check
  reports no repairs required. Editor diagnostics report no errors in scripts/tests.
- Packet gate was executed: Bicep build passes, but tests.run fails because `pwsh`
  is not on PATH. WIP and open unknowns are warnings, not waived checks.
- Test-All retains all existing checks and now invokes the new suites. The complete
  runner was not forced through the temporary PowerShell: its existing Windows and
  setup probes require a suitable host and can have real side effects.

Safe focused commands:

```text
npm run test:scripts
pwsh -NoProfile -File tests/Test-ScriptSecurity.ps1
bash scripts/test-setup-workstation.sh
bash scripts/repair-script-encoding.sh --root scripts --check
node .ironclad/gate.mjs --stage packet
```

The PowerShell check here used the isolated runtime under the session temporary
directory, not the unresolved `pwsh` executable shown in the reproducible command.
The gate performs its configured build; it is not a fully offline command.
No deployment, inference, entitlement mutation, purge, email send, interactive
login, or workstation setup was executed for P17 validation. No commits were made.

## Required before sign-off

Run the unchanged packet gate on a host with its Windows and PowerShell prerequisites
and approved setup-test conditions. Separately approve live comparisons on disposable
resources, including failed reads, ambiguous identities, stale ETags and partial
mutation recovery. Resolve or explicitly accept the residual risks above in the
deployment's threat model. Until then, neither production readiness nor complete
cross-platform behavioral equivalence is established.