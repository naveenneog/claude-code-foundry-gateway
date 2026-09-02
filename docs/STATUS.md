# Status

**Active packet:** P11 - organisation-wide monthly ceiling. Shipped and verified on the live gateway. P10 and P-0 are complete.

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

## Commands that prove it

```powershell
./tests/Test-All.ps1                                    # 7 checks, offline
./tests/Test-All.ps1 -IncludeAzure                      # plus the four that call Azure
./scripts/Get-ClaudeAnalytics.ps1 -Days 30              # the usage report
./tests/Test-OrgCeilingLive.ps1 -ProveRefusal           # exhausts each budget, then restores it
node .ironclad/gate.mjs --stage packet                  # definition of done
```

## Next

P12 — programmatic cost control: read effective limits and month-to-date spend per user, and set
or clear a per-user override, without editing named values by hand. P10 supplies month-to-date
spend and P11 supplies the ceiling, so P12 is a surface over both rather than new enforcement.

U2 blocks putting a currency figure on that spend; until it closes the number stays labelled an
estimate. Open unknowns are in `docs/UNKNOWNS.md`.