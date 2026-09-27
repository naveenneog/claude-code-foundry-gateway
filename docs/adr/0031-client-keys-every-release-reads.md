# ADR-0031: Client configuration uses keys the client release on the machine reads

## Status

Accepted for P67. Supersedes the rendered Desktop key names in
[ADR-0027](0027-claude-desktop-sign-in-choice.md); the recorded `desktopSignIn` shape in
`claude-gateway.json` is unchanged.

## Context

The owner's manual test on 2026-09-27 found two client failures after
`Setup-ClaudeWorkstation.ps1` ran:

1. Claude Desktop showed **Connection needs Credential kind**, with the Credential kind field
   empty, and no Entra sign-in. ADR-0027 wrote `inferenceCredentialKind: external-idp`,
   `inferenceIdpOidc` and `inferenceIdpAuthFlow`. The Anthropic configuration reference,
   retrieved 2026-09-27, lists `inferenceIdpOidc` and `inferenceIdpAuthFlow` as added in
   Desktop 2.7032.0. The Desktop release installed on this workstation, 2.2553.1.0, reads 171
   configuration keys and neither of those two; its credential kinds are `static`,
   `helper-script`, `interactive`, `vendor-profile` and `workforce`
   (`tests/fixtures/claude-desktop-schema-2.2553.1.0.json`). On the owner's workstation the
   per-user installer had installed 2.9939.2, but `app-1.44121.2\claude.exe` was still running,
   started from a shortcut to that versioned folder; 1.44121.2 read neither key, and the Sign in
   button did nothing until 2.9939.2 was started (**U27**).
2. The Claude Code CLI, version 2.1.101, returned
   `400 "thinking.type.enabled" is not supported for this model` for `claude-opus-5`. The VS Code
   extension, which bundles a newer CLI, worked. Measured 2026-09-27 against the reference gateway
   with `claude-sonnet-5`: 2.1.101 returned the same 400; with
   `ANTHROPIC_DEFAULT_SONNET_MODEL_SUPPORTED_CAPABILITIES` set it answered; 2.1.272 answered with
   the same variable at effort `high` and `max`. The Claude Code changelog adds Sonnet 5 in
   2.1.197 and Opus 5 in 2.1.219. The model configuration guide says Claude Code never recognises
   a pinned Microsoft Foundry deployment name and falls back to capability detection by model ID
   unless `_SUPPORTED_CAPABILITIES` is set (**U28**).

Both failures are the same shape: the configuration named what the newest client reads, and the
client on the machine was older. Models and Desktop releases keep arriving, so a fixed list of
either would repeat the failure.

## Decision

**Desktop Entra sign-in** (`desktopSignIn.kind: external-idp`) is written in the spelling the
Desktop release that reads the profile knows (`scripts/ClaudeDesktopSignIn.ps1`,
`New-ClaudeDesktopSettings -DesktopVersion -KeySpelling auto|original|current`):

| Release that reads the profile | Keys |
|---|---|
| 2.7032.0 or later | `inferenceCredentialKind: external-idp`, `inferenceIdpOidc`, and `inferenceIdpAuthFlow: broker` for the broker flow |
| before 2.7032.0, or unknown | `inferenceCredentialKind: interactive`, `inferenceGatewayOidc`, and `inferenceGatewayOidcAuthFlow: broker` for the broker flow |

The browser flow is the default and writes no flow key. The configuration reference reads
`interactive` with `inferenceGatewayOidc` as `external-idp`, and "the original spelling will keep
working; no end date has been set"; it is read from 1.6889.0 (`inferenceGatewayOidc`) and
1.25927.0 (`inferenceGatewayOidcAuthFlow`). The release that reads the profile is:

- Windows: the older of the installed build (MSIX package, or the newest `app-<version>` folder of
  the per-user installer) and the running build (`Get-ClaudeDesktopReadingVersion`).
  Diagnostics also report a running build older than the installed one, and shortcuts that
  start a versioned `app-<version>` folder.
- macOS: `CFBundleShortVersionString` of `/Applications/Claude.app`.
- Linux, and MDM profiles for a fleet of mixed releases: unknown, so the original spelling.
  `New-ClaudeCodePolicy.ps1 -DesktopKeySpelling current` writes the current spelling for a fleet
  on 2.7032.0 or later.

The helper-script keys are unchanged.

**Claude Code** gets a capability declaration,
`ANTHROPIC_DEFAULT_<ALIAS>_MODEL_SUPPORTED_CAPABILITIES`, for each pinned alias whose model needs
one (`scripts/ClaudeClientSupport.ps1`, mirrored in `setup-claude-workstation.sh` and
`debug-claude-workstation.sh`):

- **By rule, not by list.** Opus 4.7 and later, Sonnet 5 and later, and Fable and Mythos 5 and
  later get `effort,xhigh_effort,max_effort,thinking,adaptive_thinking,interleaved_thinking`.
  The model configuration guide says "Fable models, Sonnet 5, and Opus 4.7 and later always use
  adaptive reasoning", and the effort guide lists `xhigh` and `max` for the same families. A
  model released after this ADR in one of these families works without a script change.
- **The first Claude Code release that knows a model** comes from the changelog: Opus 4.7
  2.1.111, Fable 5 2.1.170, Sonnet 5 2.1.197, Opus 5 2.1.219, Fable 5.1 2.1.257, Opus 5.5
  2.1.280. A model the table does not name has no required release; its declaration is what
  lets an older Claude Code use it.
- **Per-deployment overrides.** A `deployments` entry in `claude-gateway.json` can carry
  `capabilities` (a list, or `none`) and `claudeCode` (a release) for a model the rule does not
  describe, or to correct it.
- **Pinning by model.** The installer records `deployments` with each deployment's name, model
  and version. Each alias is pinned to the newest recorded model in its family, whatever the
  deployment is called; the haiku alias falls back to the Sonnet deployment when no Haiku
  deployment is recorded. The deployment name stands in for the model only when no record
  exists.

The workstation setups compare the installed versions with these rules. Claude Code older than
the release a recorded model needs is updated with `claude update` (skipped with `-SkipInstall`
or `--skip-install`), within 5 minutes. The setups then ask Claude Code itself for one reply
through the gateway (`claude -p ping --model <sonnet deployment>`, within 2 minutes), which is
what catches the next client and model mismatch. Every Claude Code on PATH is listed, one per
folder in PATH order, and on Windows only a file Windows can start is chosen (`.exe`, `.cmd`,
`.bat`, `.ps1`): npm also writes an extensionless POSIX script beside `claude.cmd`. Client
commands run with standard input closed, UTF-8 decoding and a time limit
(`Invoke-ClaudeClientCommand`, and `run_bounded_` in bash, which runs the command in its own
process group from perl, `setsid` or GNU `timeout`; once the time is up it sends TERM and then
KILL 5 s later to the whole group, and once the command has exited it ends anything the command
left running in the group, signalling only the group so that no reused PID is hit); a command
that cannot start is a result, not an exception.

**What each release sends.** Measured 2026-09-27 by pointing Claude Code at a local listener
that recorded each request body, for the alias pinned to `claude-sonnet-5` and to a custom name
`prod-fast`:

| Declaration | 2.1.101 | 2.1.272 |
|---|---|---|
| none | `thinking.type.enabled` for `claude-sonnet-5`; `adaptive` for `prod-fast` | `adaptive` for both |
| `thinking` only | `enabled` | `enabled`; after the model's 400 it retried with `adaptive` |
| all six | `adaptive` | `adaptive` |

The diagnostics grade each pinned alias on these measurements (`Get-ClaudeCodeAliasCheck`, and
`alias_check_` in `scripts/claude-client-support.sh`): FAIL for no declaration on a release that
predates the model when the pinned name is a model id, and for `thinking` without
`adaptive_thinking` on such a release; WARN for the same cases on a custom name or a release that
retries, for any other declaration that differs from the record (a declaration turns off every
capability it does not list), for a model newer than the release table, and for a declaration the
record does not expect. The bash rules live in that one library, which both bash scripts source.

## Consequences

Desktop releases older than 2.7032.0 read the Entra sign-in configuration, and newer ones get the
current spelling. If Anthropic sets an end date for the original spelling, the renderer changes
in one place, `scripts/ClaudeDesktopSignIn.ps1`, and the fixture test names every key it writes.

Claude Code 2.1.101 works with the recorded models without an update. Measured 2026-09-27 through
the reference gateway with the settings `Set-ClaudeCodeGatewaySettings` writes: the default model,
`--model opus`, `--model sonnet`, `--model claude-sonnet-5`, `--model claude-opus-5` and
`--effort max` answered; the same settings without the declarations returned the 400. A
declaration also disables any capability it does not list, so the rule must change when a
family's capabilities change. Two copies of the rule exist, `scripts/ClaudeClientSupport.ps1` and
`scripts/claude-client-support.sh`, and `tests/Test-WorkstationClients.ps1` fails when they
disagree, including a word-for-word comparison of both alias checks over fifteen cases.

`Setup-ClaudeWorkstation.ps1` now needs `ClaudeClientSupport.ps1` and `ClaudeDesktopSignIn.ps1`
beside it, and stops at once, naming them, when they are missing. The onboarding email's download
command fetches every file the setup reads from its own folder, taken from the script itself.

Tenant consent is not changed by this decision. Desktop's own Entra sign-in still needs consent
for the Desktop public-client app, which the reference tenant does not grant (**U23**); the
helper-script path needs none.

## References

- Anthropic, "Configuration reference", retrieved 2026-09-27:
  <https://claude.com/docs/third-party/claude-desktop/configuration>
- Anthropic, "Claude Code changelog", retrieved 2026-09-27:
  <https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md>
- Anthropic, "Model configuration", retrieved 2026-09-27:
  <https://code.claude.com/docs/en/model-config>
- Anthropic, "Effort", retrieved 2026-09-27:
  <https://platform.claude.com/docs/en/build-with-claude/effort>
