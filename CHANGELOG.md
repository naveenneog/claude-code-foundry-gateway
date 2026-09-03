# Changelog

All notable changes to this project are recorded here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Data subject request tooling. `scripts/Find-ClaudeUserData.ps1` reports what the gateway's
  telemetry holds about one person, per table, reading each table's plan from the workspace so it
  states what is actually deletable. `scripts/Remove-ClaudeUserData.ps1` purges it with Azure
  Monitor's GDPR Purge operation, one request per table, and does nothing without `-Execute`.
  Both print the limits U7 established — 50 purge requests an hour, a 30-day completion SLA with
  no expedite, and Analytics-plan tables only.
- Model allowlist per tier: `models-standard` and `models-premium`, enforced at the gateway before
  the request reaches Foundry. Sentinel commas make the match exact, so `claude-opus-5` does not
  admit `claude-opus-5-mini`; an empty value allows every deployed model. Verified live in all
  three directions.
- `New-ClaudeCodePolicy.ps1 -Tier standard|premium` generates one managed-settings profile per
  entitlement tier, including `availableModels` and the Claude Desktop tab keys.
- ADR-0004 and the closure of U4: the Claude apps gateway supports a Foundry upstream, but it is
  an inference proxy holding a shared upstream credential, so adopting it would remove the
  per-developer Entra identity that P10, P11 and P12 depend on. Policy stays out of band.
- Per-developer daily budget overrides. `scripts/Set-ClaudeBudget.ps1` sets and clears them,
  `scripts/Get-ClaudeBudget.ps1` reports what the gateway would actually apply to each developer
  and what they have spent this month. Overrides apply on the next request — the policy resolves
  them per call. Measured 2026-09-02: `token-quota` accepts a policy expression but it must
  return `long`; `Int32` and `string` are both rejected at deploy time.
- `scripts/Get-ClaudeTelemetry.ps1`: which Application Insights this gateway is actually writing
  to, resolved from its diagnostic rather than from a name, and whether metrics are enabled on
  it. See ADR-0003.
- Organisation-wide monthly spend ceiling: `quota-org`, enforced in the request path by an
  `llm-token-limit` on a constant counter-key, checked before the per-tier budgets. Tier limits
  still apply beneath it, so a developer can be inside their own budget and still be refused
  because the organisation's is spent. It is a soft cap — the
  [policy reference](https://learn.microsoft.com/en-us/azure/api-management/llm-token-limit-policy)
  states high-concurrency requests can temporarily exceed the configured limit.
- The gateway now says which budget ran out. Both refusals are `403` with the same
  `LastError.Reason`, and `403` is also what the entitlement check returns, so a developer out of
  budget previously read it as losing access. The reply is rewritten in Anthropic's error shape
  carrying `"budget": "organisation"` or `"budget": "personal"`.
- `tests/Test-OrgCeiling.ps1` and `tests/Test-OrgCeilingLive.ps1`. The second verifies a running
  gateway; with `-ProveRefusal` it exhausts each budget, reads the message and restores the quota.
- `analytics/claude-code-daily.kql` and `scripts/Get-ClaudeAnalytics.ps1`: Claude Code usage in
  the shape of the Claude Code Analytics API, built from the gateway's own telemetry. Anthropic's
  API does not cover Foundry — "Usage through ... Claude in Microsoft Foundry ... is not
  included" ([reference](https://platform.claude.com/docs/en/manage-claude/claude-code-analytics-api),
  retrieved 2026-09-02) — so after a migration this is the only source of those numbers.
  Verified against live telemetry: 19 rows over 30 days regrouped into 13 records, 167,713 input
  tokens, 22 sessions, 2 callers.
- `tests/Test-Analytics.ps1`: asserts the query's contract offline, and with `-IncludeAzure`
  submits it to Application Insights and checks each column carries data independently. Every
  live assertion was negative-tested by breaking the query and confirming the suite turns red.
- U8 in `docs/UNKNOWNS.md`: the OpenTelemetry attributes that split lines-of-code and tool
  decisions are unverified, so those four fields return null rather than a guessed zero.
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

### Fixed

- Usage reports read the Application Insights the gateway is currently writing to, instead of a
  workspace named by convention. The reference deployment moved workspaces on 2026-08-31 and
  nothing noticed: every P10 assertion still passed on data that had stopped two days earlier,
  and `Get-ClaudeBudget.ps1` reported `0 used this month` on a gateway that had served hundreds
  of requests that morning. `tests/Test-Analytics.ps1` now compares the newest metric against the
  newest request in the same workspace, so a stale workspace fails while an idle gateway does
  not. ADR-0003.

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
