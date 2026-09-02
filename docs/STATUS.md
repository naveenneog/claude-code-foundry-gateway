# Status

**Active packet:** P13 - per-group capability scoping. Shipped and verified on the live gateway. P-0 and P10 to P12 are complete.

## What is shipped (M0)

| | |
|---|---|
| Gateway | API Management Basic v2, `llm-token-limit` per tier keyed on Entra `oid` |
| Clients | Claude Code CLI, VS Code extension, Claude Desktop including Cowork |
| Entitlement | Entra group membership synced to APIM named values |
| Deployment | `Install-ClaudeGateway.ps1`, reuses an existing v2 instance rather than creating a second |
| Fleet | Managed settings for Claude Code and Claude Desktop, with Intune, GPO and Jamf payloads |
| Migration | Import from claude.ai, bulk entitlement from CSV or an Entra group |

## P10 acceptance criteria — analytics equivalent

Anthropic's Claude Code Analytics API does not cover Foundry: "Usage through Claude in Amazon
Bedrock, Claude in Microsoft Foundry, Claude on Google Cloud, or Claude Platform on AWS is not
included"
([reference](https://platform.claude.com/docs/en/manage-claude/claude-code-analytics-api),
retrieved 2026-09-02). So this is not an approximation of an endpoint the customer still has —
it is the only source of those numbers after a migration.

- [x] `analytics/claude-code-daily.kql` returns the 16 contracted columns
- [x] `scripts/Get-ClaudeAnalytics.ps1` emits them in the API's response envelope
- [x] Verified against live telemetry, not a fixture: 19 rows over 30 days regrouped into 13
      records, 167,713 input / 969,456 output / 106,620,084 cached tokens, 22 sessions, 2 callers
- [x] Token totals survive the reshaping — 167,713 both before and after
- [x] Unmeasurable fields are null, never zero — `lines_of_code`, tool decisions,
      `tokens.cache_creation`
- [x] `estimated_cost` carries `is_estimate` on the value itself, so it cannot be separated
      from the number downstream
- [x] Every live assertion negative-tested: breaking the prompt-token metric, the session
      dimension, the actor dimension, the date format or the numeric type each turns the suite red
- [x] `./tests/Test-All.ps1` passes offline; `-IncludeAzure` runs the live half
- [x] `node .ironclad/gate.mjs --stage packet` exits 0

### What the work found

| | |
|---|---|
| `date` is a reserved KQL keyword | `summarize ... by date =` fails to parse. The column is written `['date']`, keeping the API's name |
| `null != "none"` is true in KQL | `dcountif(sid, sid != "none")` counted one distinct null per group, reporting a session that never happened whenever the dimension was missing. Now `isnotempty(sid) and sid != "none"` |
| `ConvertFrom-Json` parses ISO strings into `DateTime` | An assertion reading the parsed object cannot tell a correct RFC 3339 date from an incorrect one, and the same applies to `3.0` versus `3`. Both are asserted against the raw JSON text |
| Anthropic excludes Foundry from the API | Recorded in ADR-0002. It changes the parity claim from "we approximate this" to "this is the only way to get it" |

### Council

| Seat | Verdict | Note |
|---|---|---|
| Architect | Accept | Two sources, joined `leftouter` so a broken OTEL export shows null beside real spend rather than a silent zero. No new always-on component; the KQL is a file, the reporter is a script |
| Coder | Accept | One query file, read by both the test and the reporter, so the thing asserted is the thing that ships. Window substitution rather than templating keeps them identical |
| QA | Accept | Every live assertion was negative-tested. Three of those breaks initially passed — the weak sum, the parsed-date check and the parsed-integer check — and each was strengthened until the break turned it red. One of them exposed a real defect in the query rather than only in the test |
| UX | Accept | `-Days` for a first look, `-Date` to match the API's one-day call, objects by default and `-AsJson` for the envelope. Errors name the fix, for example "Pass -AppInsightsName or set CLAUDE_APPINSIGHTS" |
| Security | Accept | Read-only. No content capture — these are counters, not prompts. Tokens come from `az account get-access-token` per run and are not persisted. `actor` is an Entra UPN, which is already in the telemetry |

## P11 acceptance criteria — organisation-wide monthly ceiling

Claude Enterprise exposes an org-wide monthly spend ceiling with group and member limits
cascading under it. APIM quotas are per-principal per period, and Cost Management budgets alert
without blocking inference, so neither alone is equivalent.

U1 established that a constant `counter-key` makes `llm-token-limit` a single counter shared by
every caller. That is what makes an org ceiling possible in the request path.

- [x] `quota-org` named value, monthly, on a constant counter-key
- [x] Checked before the per-tier budgets, so the organisation's state is what the developer is
      told about
- [x] Per-tier minute and daily limits still apply beneath it
- [x] The refusal names which budget ran out, in Anthropic's error shape
- [x] Successful replies carry `x-org-quota-remaining` beside `x-quota-remaining-today`
- [x] Verified on the live gateway, both branches, by `tests/Test-OrgCeilingLive.ps1 -ProveRefusal`
- [x] Documented as a soft cap in the policy, the README and ONBOARDING
- [x] `node .ironclad/gate.mjs --stage packet` exits 0

### What the work found

Both refusals are `403` with `Reason=OpenAITokenQuotaExceeded`, `Source=llm-token-limit`,
`Scope=api`. Measured on a throwaway API on 2026-09-02. Those values are identical for the org
ceiling and the per-user daily quota, so `context.LastError` cannot distinguish them — and `403`
is also what the entitlement check returns, so a developer who has simply run out of budget reads
it as losing access.

Two findings made the message possible:

| | |
|---|---|
| `<on-error>` does fire on an `llm-token-limit` refusal | So the reply can be rewritten. Its own body is `{"statusCode":403,"message":"Token quota is exceeded..."}`, which is not Anthropic's error shape, so the client would otherwise show it raw |
| Policies run in order and the failing one halts the pipeline | So a `budget` variable set before each limit names the one that refused. This is what `LastError` cannot supply |

Measured end to end:

```
org exhausted      -> 403 {"error":{"type":"rate_limit_error","budget":"organisation", ...}}
personal exhausted -> 403 {"error":{"type":"rate_limit_error","budget":"personal", ...}}
raise either       -> 200 on the next request
```

Also found: setting a quota exactly equal to what has been spent does not refuse. The quota is
exceeded when consumption passes it, not when it reaches it. The live test allows for that
rather than sitting on the boundary.

### Council

| Seat | Verdict | Note |
|---|---|---|
| Architect | Accept | One more policy in an existing pipeline. No new component, no scheduled job, no state outside APIM. The ceiling sits in the request path because U1 proved a shared counter exists there |
| Coder | Accept | The ordering requirement — org before tier — is asserted by position in the file, not by a comment asking future editors to be careful |
| QA | Accept | Shape asserted offline, behaviour asserted live, both branches proven. Negative-tested: making the org key per-caller, or removing the personal marker, each turns the suite red. The live script restores what it changes in a `finally` and prints the original values first |
| UX | Accept | The developer is told which budget ran out and that their access is intact, which is the actual question behind the support ticket. The installer warns when the monthly ceiling is below one premium developer's daily quota |
| Security | Accept | No change to authentication, entitlement or identity. The ceiling is enforced before the managed-identity swap, so an exhausted budget never reaches Foundry. The default fails safe at roughly one premium developer's month |

## P12 acceptance criteria — programmatic cost control

Claude Enterprise's Admin API reads effective limits and month-to-date spend and sets or clears
per-user overrides. P10 supplies the spend and P11 supplies the ceiling, so this adds one new
capability — a per-user daily budget that is not "move them to the other tier" — and a surface
over all three.

- [x] `quota-overrides` named value, resolved per request by the policy
- [x] `scripts/Set-ClaudeBudget.ps1` sets, clears and lists overrides by UPN or object id
- [x] `scripts/Get-ClaudeBudget.ps1` reports effective limits and month-to-date spend
- [x] Overrides survive a redeploy, the same way entitlement does
- [x] A write merges rather than replaces, and refuses if another entry would be lost
- [x] Verified live: an override changes what the gateway applies on the next request, clearing
      it restores the tier default, and a second developer's override survives both
- [x] `node .ironclad/gate.mjs --stage packet` exits 0

### What the work found

| | |
|---|---|
| `token-quota` accepts an expression, but it must return `long` | `Int32` is rejected with "Expression return type 'System.Int32' is not allowed" and `string` with "Cannot implicitly convert type 'string' to 'long'", both at deploy time. `tokens-per-minute` accepts no expression at all, so a rate change still means a tier change |
| A named value substitutes raw text into a policy expression | A JSON map would end the surrounding C# string literal on its first quote. The map is `,oid=tokens,` with sentinel commas, matching `allow-standard` |
| The daily quota no longer needs a branch per tier | Tier and override both resolve inside one expression, so the two-branch `choose` now covers only `tokens-per-minute` |
| ARM can return a pre-write value straight after a successful write | Seen once on `quota-overrides`. The live test polls rather than asserting on the first read |

### The defect this packet uncovered

`Get-ClaudeBudget.ps1` reported `0 used this month` for every developer on a gateway that had
served hundreds of requests that morning.

The gateway had moved Application Insights workspaces on 2026-08-31. P10 shipped with the old
workspace's name as a default and every one of its tests still passed, because the data from
before the move satisfied them. The non-vacuity guard was real, and it was still not enough: it
proved the numbers were not empty, not that they were current.

Fixed in ADR-0003 — the workspace is resolved from the gateway's diagnostic, and a detector
compares the newest metric against the newest request in the same workspace so that a stale
workspace fails while an idle gateway does not. Verified both ways.

### Council

| Seat | Verdict | Note |
|---|---|---|
| Architect | Accept | No new store. Overrides live beside the limits they modify, and the resolution happens where the limit is applied. The daily quota lost a branch rather than gaining one |
| Coder | Accept | `Get-ClaudeTelemetry.ps1` is one question with one answer, and three callers stopped carrying their own wrong default |
| QA | Accept | The freshness detector exists because a passing suite hid a two-day outage. Negative-tested against the stale workspace, which fails with both timestamps named |
| UX | Accept | An administrator names a person by UPN, not object id, and guest accounts resolve through the same fallback `Import-ClaudeEntitlement` needed. The reader prints what would be applied and where it came from — `tier` or `override` |
| Security | Accept | Read-mostly. The one write is a merge that refuses if another entry would disappear, which is the guard the entitlement allow list needed after a whole-value write revoked everyone. A warning, not a silent success, when an override is set for someone not entitled |

## P13 acceptance criteria — per-group capability scoping

Claude Enterprise scopes capability per role: Chat, Cowork, Claude Code, web search and
individual connectors. U4 asked whether Anthropic's self-hosted Claude apps gateway should
deliver that here. It is closed, and the answer shaped the packet.

- [x] `models-standard` and `models-premium`, enforced in the gateway policy
- [x] The check runs before the managed-identity swap, so a refused model never reaches Foundry
- [x] The refusal is in Anthropic's error shape, names the model, and says access is unaffected
- [x] `New-ClaudeCodePolicy.ps1 -Tier` generates one profile per entitlement tier
- [x] Verified live: outside the list refused, inside it served, prefix does not widen the list
- [x] Client-side controls are documented as management controls, not security boundaries
- [x] `node .ironclad/gate.mjs --stage packet` exits 0

### What the research found

The Claude apps gateway is real, documented, ships inside the `claude` binary, charges no licence
fee, supports Microsoft Foundry as a first-class upstream, and selects managed settings by IdP
group. On paper it is exactly what P13 asked for.

It was still not adopted, because it is an inference proxy: "a self-hosted service that sits
between your developers' Claude Code clients and your model provider". It holds the upstream
credential itself. Under it, Foundry sees one shared gateway credential instead of each
developer's Entra token — and that token is what P10 reports on, P11 caps and P12 overrides.
Adopting it would have quietly deleted the previous three packets. Chaining it in front of API
Management is not documented, so it was not assumed. ADR-0004 and U4 have the full reading.

Two findings from the primary sources changed the shape of the work:

| | |
|---|---|
| Anthropic's hosted server-managed settings are org-wide | "Settings apply uniformly to all users in the organization. Per-group configurations are not yet supported." Per-tier MDM profiles are therefore not a downgrade from the first-party option — for per-group scoping they are ahead of it |
| Client-delivered controls are bypassable wherever they come from | "A user who can run a modified Claude Code binary can bypass any client-side control." That applies to policy delivered by the apps gateway too, so moving tabs and permissions server-side was never among the options |

So the packet split on one line: whatever can be enforced at the gateway is enforced there, and
everything else is described honestly. Models moved server-side. Tabs, permissions, hooks and
connectors stayed client-side and are now labelled as management controls in the README,
ONBOARDING and ADR-0004 — with a test asserting that labelling stays.

### Council

| Seat | Verdict | Note |
|---|---|---|
| Architect | Accept | The alternative was better on paper and worse in fact. Rejecting it is the decision; ADR-0004 records why so it is not relitigated from the feature table |
| Coder | Accept | The allowlist reuses the sentinel-comma convention already carrying entitlement and budget overrides, so there is one string format in the policy rather than three |
| QA | Accept | Verified live in three directions, including the prefix case that a `Contains` without sentinels would have failed. An empty list allowing everything is asserted too, since that is the shipped default |
| UX | Accept | The refusal names the model, the tier, and what to do. It also says access is unaffected — the third 403 in this gateway, and all three now distinguish themselves |
| Security | Accept | The claim being made is narrow and true: models are a control, the rest is management. A packet that shipped Desktop tab toggles as though they were a security boundary would have been worse than shipping nothing |

## Commands that prove it

```powershell
./tests/Test-All.ps1                                    # 9 checks, offline
./tests/Test-All.ps1 -IncludeAzure                      # plus the six that call Azure
./scripts/Get-ClaudeTelemetry.ps1                       # where this gateway logs, and whether metrics are on
./scripts/Get-ClaudeAnalytics.ps1 -Days 30              # the usage report
./scripts/Get-ClaudeBudget.ps1                          # effective limits and spend to date
./scripts/New-ClaudeCodePolicy.ps1 -Tier premium        # one managed-settings profile per tier
./tests/Test-OrgCeilingLive.ps1 -ProveRefusal           # exhausts each budget, then restores it
node .ironclad/gate.mjs --stage packet                  # definition of done
```

## Next

P14 — the plugin marketplace. **U6** is open and blocks it: what signs a plugin, who verifies it,
and whether the same trust applies to marketplace-delivered plugins. That is a supply-chain
question, so it is researched before anything is built, not after.

P15 — compliance retrieval — is behind **U7**, whether Log Analytics can honour selective deletion
within its purge limits.

U2 still blocks putting a currency figure on spend. U8 still blocks the four productivity fields
P10 returns as null. U3 is unexamined. Open unknowns are in `docs/UNKNOWNS.md`.