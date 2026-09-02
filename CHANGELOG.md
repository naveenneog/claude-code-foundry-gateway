# Changelog

All notable changes to this project are recorded here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Ironclad engineering discipline: `.ironclad/charter.json`, a vendored `gate.mjs`, and the
  `docs/` ledger. See ADR-0001.
- `docs/ROADMAP.md` with a parity matrix against Claude Enterprise and the M1–M3 packet queue.
- `docs/UNKNOWNS.md` with six open questions, each with what it blocks and how to close it.
- ADR-0002: analytics comes from gateway telemetry and Claude Code OpenTelemetry, joined in Log
  Analytics, because tool accept/reject and lines-of-code are client-side and never reach the
  gateway.
- `DEVELOPER.md`: the developer's setup on one page, and a router at the top of the README.
- Client screenshots for the CLI, VS Code and Claude Desktop, and the installer run, all
  redacted by `guide/redact-clients.mjs` and `guide/redact-terminal.mjs`.
- `Import-ClaudeEntitlement.ps1`: bulk entitlement from a CSV or an Entra group, resolving
  identifiers four ways because a directory holds a person under several addresses.
- `Import-ClaudeMemory.ps1`: lands memory exported from claude.ai into `CLAUDE.md`.
- `New-ClaudeCodePolicy.ps1`: managed settings for Claude Code as JSON, `.reg`, Intune OMA-URI
  and `.mobileconfig`.
- `tests/Test-AzArguments.ps1`: fails on any `az` argument that `cmd.exe` would re-parse.

### Changed

- Tests moved from `scripts/` to `tests/`. `Test-Prerequisites.ps1` and `Test-FoundryDirect.ps1`
  stayed, because they are runtime tooling rather than tests. See ADR-0001.
- The installer reuses an existing v2 API Management instance instead of always creating one.
- Documentation states what is true and cites a source, rather than telling the reader what
  matters.

### Fixed

- `RoleAssignmentExists` when reusing a gateway that already held the Foundry role.
- Entitlement sync failing on Windows because `&` in a Graph URL reached `cmd.exe`.
- A redeploy resetting the entitlement allowlists to empty, revoking every user.
- Reuse resetting API Management TLS settings, NAT gateway and developer portals to defaults.
