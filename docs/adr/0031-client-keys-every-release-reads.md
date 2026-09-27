# ADR-0031: Client configuration uses keys every supported client release reads

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
   (`tests/fixtures/claude-desktop-schema-2.2553.1.0.json`). A release older than 2.7032.0
   therefore sees no valid credential kind and no identity provider.
2. The Claude Code CLI, version 2.1.101, returned
   `400 "thinking.type.enabled" is not supported for this model` for `claude-opus-5`. The VS Code
   extension, which bundles a newer CLI, worked. Measured 2026-09-27 against the reference gateway
   with `claude-sonnet-5`: 2.1.101 returned the same 400; with
   `ANTHROPIC_DEFAULT_SONNET_MODEL_SUPPORTED_CAPABILITIES` set it answered; 2.1.272 answered with
   the same variable at effort `high` and `max`. The Claude Code changelog adds Sonnet 5 in
   2.1.197 and Opus 5 in 2.1.219. The model configuration guide says Claude Code never recognises
   a pinned Microsoft Foundry deployment name and falls back to capability detection by model ID
   unless `_SUPPORTED_CAPABILITIES` is set.

## Decision

**Desktop Entra sign-in** (`desktopSignIn.kind: external-idp`) renders the original spelling:

- `inferenceCredentialKind: interactive`
- `inferenceGatewayOidc` with `issuer`, `clientId`, `bearerTokenType`, and `scopes` and `resource`
  when recorded
- `inferenceGatewayOidcAuthFlow: broker` when the recorded flow is `broker`; the browser flow is
  the default and writes no flow key

The configuration reference states that `interactive` with `inferenceGatewayOidc` is read as
`external-idp` and that the original spelling keeps working with no end date. It is read from
Desktop 1.6889.0 (`inferenceGatewayOidc`) and 1.25927.0 (`inferenceGatewayOidcAuthFlow`), so one
profile serves a fleet on mixed releases. The helper-script keys are unchanged.

**Claude Code** gets a capability declaration for each pinned model whose Anthropic model is
known, from `scripts/ClaudeClientSupport.ps1`:

| Model | Capabilities | Claude Code that knows the model |
|---|---|---|
| `claude-sonnet-5` | `effort,xhigh_effort,max_effort,thinking,adaptive_thinking,interleaved_thinking` | 2.1.197 |
| `claude-opus-5` | the same | 2.1.219 |
| `claude-opus-5-5` | the same | 2.1.280 |

The capability values come from the model configuration guide; `xhigh` and `max` effort for
Opus 5, Opus 5.5 and Sonnet 5 come from the effort guide. The model is read from the deployment
recorded by the installer (`deployments` in `claude-gateway.json`), and from the deployment name
only when no record exists. An unknown model gets no declaration, so Claude Code keeps its own
detection.

The workstation setup and diagnostics also compare the installed versions with these tables:
Claude Code below the version that knows a recorded model is updated with `claude update`
(skipped with `-SkipInstall`), and Claude Desktop below the release that reads the rendered keys
is reported with the release it needs.

## Consequences

Desktop releases older than 2.7032.0 read the Entra sign-in configuration, and newer ones read it
as `external-idp`. If Anthropic sets an end date for the original spelling, the renderer changes
in one place, `scripts/ClaudeDesktopSignIn.ps1`, and the fixture test names every key it writes.

Claude Code 2.1.101 works with the recorded models without an update, because capability
detection no longer depends on the CLI knowing the model ID. A declaration also disables any
capability it does not list, so the table must change when a model's capabilities change.

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
