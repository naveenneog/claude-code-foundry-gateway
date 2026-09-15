# Changelog

All notable changes to this project are recorded here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
versioning follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Releases are tagged in git. `docs/ROADMAP.md` holds the forward plan and
`docs/STATUS.md` the packet currently in flight.

## [Unreleased]

Business-unit chargeback. Budgets are set and reported in dollars, but three
limits apply to every figure here and are repeated in each command's output.

The counter is blind to cached tokens: `llm-token-limit` "currently counts
prompt and completion tokens only", and on thirty days of live usage cache reads
were 6.8M tokens against 320K prompt and 152K completion — 38.7% of real cost
weight at Claude's published rates. Budgets therefore bound less spend than they
appear to, always in the direction of under-counting.

Dollar figures are list price and do not reconcile to an Azure invoice, because
Azure bills Claude as one aggregated Claude Consumption Unit meter and
private-offer discounts apply before that conversion. **U2**.

A budget is enforced as one blended token figure converted at write time,
assuming a 20% output mix. That is what P21's acceptance criterion calls
insufficient, so P21 stays open. Categorised enforcement is **U13**.

### Added

- Teams. A team is a business unit that names a parent, decided in
  [ADR-0008](docs/adr/0008-teams-and-tiers.md). A request is charged to the team
  and to the business unit above it — two monthly counters, both soft. Verified
  live: one request returned `x-bu-quota-remaining: 1666666644` for the team and
  `x-bu-parent-quota-remaining: 5555555533` for its parent, alongside the
  unchanged org ceiling.
- `-Parent` on `Set-ClaudeBusinessUnit.ps1`, with `bu-parents` as a second named
  value. Depth is capped at two and cycles are refused when written, because the
  cascade is two policy elements with fixed counter keys and no loop — a third
  level would go uncharged rather than fail. Removing a business unit promotes
  its teams to top level instead of leaving a dangling parent.
- Hierarchy in the reports. `Set-ClaudeBusinessUnit.ps1 -List` and
  `Get-ClaudeBusinessUnit.ps1` indent teams under their parent, and a parent's
  figure is the roll-up of its own members and its teams — which is what its
  counter actually enforces.
- Tier by nesting. A team gets a tier by putting the team group inside
  `claude-code-standard` or `claude-code-premium`. Nothing in the tier mechanism
  changed; entitlement was already resolved transitively.
- `tests/Test-Teams.ps1`, and eight more mutations in
  `tests/Test-BusinessUnitsNegative.ps1`, which now drives both suites.
- `guide/capture-entra.mjs` screenshots the Entra group blades that back the
  hierarchy. It exits non-zero on an expired session rather than saving the
  sign-in page.
- Business units. A business unit is an Entra security group registered with a
  monthly budget, decided in [ADR-0007](docs/adr/0007-business-unit-model.md).
  `scripts/Set-ClaudeBusinessUnit.ps1` adds, edits, lists and removes them;
  `scripts/Get-ClaudeBusinessUnit.ps1` reports budgets, members and spend;
  `docs/BUSINESS-UNITS.md` is the guide. The registry key is a stable identifier
  rather than the display name, so renaming a group in Entra does not move spend
  to a new line.
- Business-unit membership sync. `Sync-ClaudeAccess.ps1` now resolves each unit's
  group to object ids and writes the `bu-members` map alongside the entitlement
  list, under the same guard that refuses to overwrite a populated map with an
  empty one.
- Business-unit soft cap in `infra/policy.xml`. A unit with a budget gets a
  monthly `llm-token-limit` keyed on its identifier, and exhausting it returns a
  fourth distinct `403` that names the unit. A unit with no budget set is
  skipped rather than refused, so an unpriced unit behaves like the organisation
  ceiling alone. Developers in no unit are `unassigned`, allowed by default
  because no one has a unit on the deployment that first installs this.
- `tests/Test-BusinessUnits.ps1`, 66 assertions, and
  `tests/Test-BusinessUnitsNegative.ps1`, which breaks each thing those
  assertions guard and confirms the suite goes red. Both are wired into
  `tests/Test-All.ps1`.
- `tests/Test-FormatStrings.ps1`, a repo-wide check that every .NET format
  string parses and runs.

### Fixed

- Entitlement could have been granted to a group object. Graph
  `transitiveMembers` returns nested **group** objects as well as users, and
  `Get-GroupMemberOids` did not filter by type. Measured on
  `claude-code-standard` with one team nested inside it: seven objects returned,
  two of them `#microsoft.graph.group`. Those object ids would have been written
  into the entitlement list and the membership map, spending a 4,096-character
  budget that holds about 110 ids, and inflating the count of developers mapped.
  Now uses the typed cast `/transitiveMembers/microsoft.graph.user`, which
  filters server-side — measured five users and no groups. Filtering on
  `@odata.type` in the client would not have worked, because Graph omits that
  property under a cast. The defect predates teams and was unreachable only
  because nothing was nested.
- `Set-ClaudeBudget.ps1 -List` crashed. `{n,>14}` is not valid .NET format
  syntax — the alignment sign belongs on the number, `{n,-14}` or `{n,14}`. It
  parses at read time and throws only when the line runs, so it shipped in
  v1.4.0 and was found by the new format-string check. Two other files carried
  the same mistake.
- `tests/Test-Discovery.ps1` printed `FAIL` and then fell off the end without
  setting an exit code, so `Test-All.ps1` recorded whatever the last child
  process had left behind — including `PASS` for a failed run.
- `tests/Test-PreflightBothHosts.ps1` never checked its own result. It now
  requires each host to print `RESULT=True` or `RESULT=False`; matching the bare
  `RESULT=` label was not enough, because a failed dot-source is a
  non-terminating error and the child carried on to print an empty value.

## [1.5.0] - 2026-09-15

The foundation for business-unit chargeback. Three independent limits were
measured that together made the accelerator a roughly 100-developer system, which
is below the scale at which chargeback is a question worth asking.

### Added

- Chargeback ledger: `analytics/chargeback-ledger.kql`, one row per request with
  the caller attached. Built on the API Management LLM log rather than custom
  metrics, because Microsoft caps a metric dimension at 100 unique values and
  then, in its words, "silently discard[s]" the rest — one dimension per
  developer reaches that at about a hundred people. The log is also the only
  APIM-native source correct for streamed requests: measured 2026-09-15, a
  streamed call reported 11 tokens through the quota scalar where the completion
  was 41. Identity is joined on `context.RequestId`, carried deliberately because
  the log's `CorrelationId` is a GUID and Application Insights `operation_Id` is
  a W3C trace id. Message capture stays off. ADR-0006.
- `scripts/ApimNamedValue.ps1`: writes a named value, refuses an oversized one
  before the call, and throws on a failed one.
- ADR-0005: identity resolution becomes a durable projection synced from Graph
  off the request path, rather than a directory call on a cache miss. Reverses a
  design proposed and rejected the same day.
- ADR-0006: why the ledger is the built-in LLM log, and the four sources it was
  chosen from.
- U9 to U12 in `docs/UNKNOWNS.md`: counter-key cardinality at scale, Graph load
  on a cold cache, ledger ingestion cost against the Basic-Logs purge conflict,
  and cache accounting. U12 is closed below.

### Fixed

- Named value writes fail loudly instead of silently. Every write used
  `az apim nv update ... -o none 2>$null` with no exit check, and named values
  cap at 4,096 characters — measured: 4,096 returns HTTP 201, 8,192 returns HTTP
  400. An object id plus separator is 37 characters, so a tier holds about 110
  developers. Past that the write failed, the error was discarded, and
  `Sync-ClaudeAccess.ps1` reported a successful sync while entitlement silently
  stopped updating. `Show-Governance.ps1` was worse: it lowers `tpm-standard` to
  100 to demonstrate throttling, and a failed restore left the standard tier
  capped at 100 tokens per minute. The restore now runs in a `finally`.

### Changed

- **Behaviour change.** `Sync-ClaudeAccess.ps1` now throws where it previously
  continued. A sync that outgrows the 4,096-character limit fails instead of
  reporting success, so automation that treated a zero exit code as "entitlement
  is current" will now see the failure it was missing.

### Known limitation

- The per-user token budget does not count cache tokens. Measured 2026-09-15:
  two identical calls with a cacheable 10,000-token prompt wrote and then read
  10,003 cache tokens, and both metered 16. This is documented API Management
  behaviour — the `llm-token-limit` policy "currently counts prompt and
  completion tokens only" — but against thirty days of live usage, weighted at
  Claude's published rates where output is 5x base input and a cache read is
  0.1x, **38.7% of the real cost weight is invisible to the budget**. The ledger
  records what the budget cannot see. Correcting the budget itself is M4 work.

## [1.4.0] - 2026-09-03

Claude Enterprise parity: analytics, spend control, capability scoping and
compliance retrieval.

### Added

- `analytics/claude-code-daily.kql` and `scripts/Get-ClaudeAnalytics.ps1`: Claude
  Code usage in the shape of the Claude Code Analytics API, built from the
  gateway's own telemetry. Anthropic's API does not cover Foundry — "Usage
  through ... Claude in Microsoft Foundry ... is not included"
  ([reference](https://platform.claude.com/docs/en/manage-claude/claude-code-analytics-api),
  retrieved 2026-09-02) — so after a migration this is the only source of those
  numbers.
- Organisation-wide monthly spend ceiling: `quota-org`, enforced in the request
  path on a constant counter-key and checked before the per-tier budgets. A soft
  cap; the policy reference states high-concurrency requests can temporarily
  exceed the configured limit.
- The gateway says which budget ran out. Both refusals are `403` with the same
  `LastError.Reason`, and `403` is also what the entitlement check returns, so a
  developer out of budget previously read it as losing access. The reply carries
  `"budget": "organisation"` or `"budget": "personal"`.
- Per-developer daily budget overrides: `scripts/Set-ClaudeBudget.ps1` sets and
  clears them, `scripts/Get-ClaudeBudget.ps1` reports effective limits and spend
  to date. Measured: `token-quota` accepts a policy expression but it must return
  `long`; `Int32` and `string` are both rejected at deploy time.
- Model allowlist per tier: `models-standard` and `models-premium`, enforced
  before the request reaches Foundry. Sentinel commas make the match exact, so
  `claude-opus-5` does not admit `claude-opus-5-mini`.
- `New-ClaudeCodePolicy.ps1 -Tier standard|premium` generates one managed-settings
  profile per entitlement tier.
- Data subject request tooling: `scripts/Find-ClaudeUserData.ps1` reports what the
  telemetry holds about one person and what is actually deletable;
  `scripts/Remove-ClaudeUserData.ps1` purges it and does nothing without
  `-Execute`. Both print the limits — 50 purge requests an hour, a 30-day
  completion SLA with no expedite, Analytics-plan tables only.
- `scripts/Get-ClaudeBypass.ps1`: who can reach Foundry without passing through
  the gateway. It derives the roles granting data-plane access from their
  `dataActions` rather than matching a name, and includes inherited assignments.
  On the reference deployment the documented one-role hand check reported clean
  while 11 assignments could call Foundry directly — three through `Foundry
  User`, which grants the same `Microsoft.CognitiveServices/*` as `Cognitive
  Services User`.
- `scripts/Get-ClaudeTelemetry.ps1`: which Application Insights the gateway is
  actually writing to, resolved from its diagnostic rather than a name.
- ADR-0002 (analytics from two sources), ADR-0003 (telemetry located from the
  gateway), ADR-0004 (policy delivered out of band).

### Fixed

- Usage reports read the Application Insights the gateway is currently writing
  to, instead of a workspace named by convention. The reference deployment moved
  workspaces on 2026-08-31 and nothing noticed: every analytics assertion still
  passed on data that had stopped two days earlier, and `Get-ClaudeBudget.ps1`
  reported `0 used this month` on a gateway that had served hundreds of requests
  that morning. ADR-0003.

## [1.3.0] - 2026-09-02

### Added

- Ironclad engineering discipline: `.ironclad/charter.json`, a vendored
  `gate.mjs`, and the `docs/` ledger — CHARTER, ROADMAP, STATUS, UNKNOWNS and
  ADRs. See ADR-0001.
- `docs/ROADMAP.md` with a parity matrix against Claude Enterprise.
- `docs/UNKNOWNS.md`, so what is not known is written down before it is built on.
- `DEVELOPER.md`: the developer's setup on one page, with a router at the top of
  the README.
- Client screenshots for the CLI, VS Code and Claude Desktop, redacted by
  `guide/redact-clients.mjs` and `guide/redact-terminal.mjs`.

### Changed

- Tests moved from `scripts/` to `tests/`. `Test-Prerequisites.ps1` and
  `Test-FoundryDirect.ps1` stayed, being runtime tooling rather than tests.
  See ADR-0001.
- Documentation states what is true and cites a source, rather than telling the
  reader what matters.

## [1.2.0] - 2026-08-31

Robustness on Windows, and the first migration tooling.

### Added

- `Import-ClaudeEntitlement.ps1`: bulk entitlement from a CSV or an Entra group,
  resolving identifiers four ways because a directory holds a person under
  several addresses.
- `Import-ClaudeMemory.ps1`: lands memory exported from claude.ai into
  `CLAUDE.md`.
- `New-ClaudeCodePolicy.ps1`: managed settings for Claude Code as JSON, `.reg`,
  Intune OMA-URI and `.mobileconfig`.
- `docs/MIGRATION.md`, covering what transfers from Claude Enterprise and what
  does not.
- `tests/Test-AzArguments.ps1`: fails on any `az` argument `cmd.exe` would
  re-parse.
- A project banner, and `.gitattributes` pinning line endings so shell scripts
  survive a Windows contributor.

### Changed

- The installer reuses an existing v2 API Management instance instead of always
  creating one.

### Fixed

- `az --query` mangled on Windows, because `az` is a `.cmd` shim and PowerShell
  only quotes a native argument containing a space.
- Entitlement sync failing on Windows because `&` in a Graph URL reached
  `cmd.exe`; the sync also never paged, silently truncating at 999 members.
- A redeploy resetting the entitlement allow lists to empty, revoking every user.
- Reuse resetting API Management TLS settings, NAT gateway and developer portals
  to defaults.
- `RoleAssignmentExists` when reusing a gateway that already held the Foundry
  role.
- The migration guide's claim that Desktop and Cowork sessions do not transfer.
  An import wizard exists.

## [1.1.0] - 2026-08-28

### Added

- Interactive admin setup, one-command developer setup, and an onboarding email
  template.
- macOS and Linux versions of the admin and workstation scripts.
- An end-to-end health check, `scripts/Debug-ClaudeCode.ps1`.
- A preflight so setup fails early rather than midway.

### Fixed

- The health check detecting the main VS Code process rather than the extension
  host.

## [1.0.0] - 2026-08-19

Initial release.

### Added

- Governed gateway for Claude Code on Microsoft Foundry: API Management Basic v2,
  per-developer token budgets keyed on the Entra object id, tiering from Entra
  group membership, and chargeback telemetry. The gateway holds the only Foundry
  credential; developers authenticate with their own Entra token.
- `Install-ClaudeGateway.ps1` and the Bicep template behind it.
- `Sync-ClaudeAccess.ps1`, syncing Entra group membership into API Management
  named values.
- Task-shaped documentation, an annotated click-by-click UI guide, and the
  Playwright tooling that generates its screenshots.

[Unreleased]: https://github.com/naveenneog/claude-code-foundry-gateway/compare/v1.5.0...HEAD
[1.5.0]: https://github.com/naveenneog/claude-code-foundry-gateway/compare/v1.4.0...v1.5.0
[1.4.0]: https://github.com/naveenneog/claude-code-foundry-gateway/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/naveenneog/claude-code-foundry-gateway/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/naveenneog/claude-code-foundry-gateway/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/naveenneog/claude-code-foundry-gateway/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/naveenneog/claude-code-foundry-gateway/releases/tag/v1.0.0
