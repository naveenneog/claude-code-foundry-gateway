# Status

**Active packet:** P24 and P27 — the Observe half. Shipped and verified live: the client surface is
captured and separable, the queries are callable functions, and the workbook is published. Next in
M4: P28, the bill of materials diagram.

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

## P15 acceptance criteria — compliance retrieval and deletion

Claude Enterprise's Compliance API retrieves activity, chat history and file content by user and
time, and supports selective deletion. U7 established what Azure can actually honour, and the
numbers are the deliverable as much as the scripts are.

- [x] `Find-ClaudeUserData.ps1` reports what is held about one subject, per table
- [x] It reads each table's plan from the workspace, so "deletable" is measured, not assumed
- [x] `Remove-ClaudeUserData.ps1` purges per table, and does nothing without `-Execute`
- [x] Both state the limits: 50 requests an hour, 30-day SLA, Analytics plan only
- [x] Content capture stays opt-in and off by default
- [x] `node .ironclad/gate.mjs --stage packet` exits 0

### What the work found

| | |
|---|---|
| The two APIs use different table names for the same data | Purging `customMetrics` returns "'customMetrics' is not a valid table". Queries go through Application Insights, which uses the classic schema; purge goes to the workspace, which uses `AppMetrics`, `AppRequests`, `AppTraces`. Found by trying it, not by reading it |
| The workspace reports each table's plan | So `purgeable` is read from `Microsoft.OperationalInsights/workspaces/tables` rather than assumed. An unknown plan is treated as not purgeable, which is the safer direction for a compliance answer |
| Captured content has a dedicated table | `AppGenAIContent`, carrying `InputMessages`, `OutputMessages`, `SystemInstructions`, `ToolCallArguments` and `ToolCallResult`. Analytics plan, so it is purgeable. That is the table a subject request is actually about |

The live purge call could not be executed in this environment — the operation was blocked before
it reached Azure. The request shape, endpoint and workspace resolution were verified up to that
point, including by the rejection that exposed the table-name bug. The submit path itself is
therefore **verified as far as Azure's own validation, and not beyond**. It is written down here
rather than implied by a passing test.

### Council

| Seat | Verdict | Note |
|---|---|---|
| Architect | Accept | Discovery and deletion are separate scripts, and deletion invokes discovery rather than reimplementing the predicate, so the two cannot disagree about scope |
| Coder | Accept | The table map carries both names because the two APIs disagree. One name would have worked in testing and failed in production, which is what happened |
| QA | Accept | The dry run is the default and was exercised against live data. The live submit is honestly recorded as unverified rather than asserted |
| UX | Accept | The finder prints what is held and what can be removed; the purger prints what would go, the limits, and that purge is irreversible, before asking for `-Execute` |
| Security | Accept | Read-only by default. The 30-day SLA and the Basic/Auxiliary exclusion are printed by the tool, so an operator cannot promise same-day deletion without contradicting their own console output. Microsoft's preferred control — not capturing content at all — remains the default |

## P16 acceptance criteria — close the bypass

Every control in this repository governs traffic that passes through the gateway. A principal
with data-plane access directly on the Foundry account skips all of it.

- [x] `scripts/Get-ClaudeBypass.ps1` lists them, graded by what the role actually grants
- [x] Roles are classified from their `dataActions`, not from a name
- [x] Inherited assignments are included
- [x] The gateway's own identity is excluded
- [x] Exits non-zero on a finding, so it works as a check and not only a report
- [x] `node .ironclad/gate.mjs --stage packet` exits 0

### What the work found

The audit in `SETUP.md` 4.2 checked one role name by hand and reported clean. The reference
deployment had **11 assignments that could call Foundry directly**, plus four with partial
data-plane access.

| | |
|---|---|
| `Foundry User` grants `Microsoft.CognitiveServices/*` | The same as `Cognitive Services User`. Three assignments held it, and no version of this documentation mentioned the role. Matching role names would never have found it — classifying by `dataActions` did |
| Inherited assignments were invisible | Two of the three `Foundry User` grants came from subscription and resource group scope. They apply to the Foundry account and do not appear without `--include-inherited` |
| The first draft audited the wrong account | `[0].name` picked `dhwani` rather than the account the gateway calls, and reported 2 findings instead of 11. The account is now read from the gateway's own API backend |

Not remediated here. Several holders are Defender, deployment and platform service principals, and
removing them autonomously would break things that are not this repository's to break. The finding
is that the access is ungoverned, which is the operator's decision to act on.

### Council

| Seat | Verdict | Note |
|---|---|---|
| Architect | Accept | The audit belongs next to the gateway because it measures the gateway's own assumption — that traffic arrives through it |
| Coder | Accept | Deriving the role set from `dataActions` is what makes this survive Azure adding another role, and it is the only reason `Foundry User` was found |
| QA | Accept | Verified against the live account, and the wrong-account bug was caught by reading the output rather than trusting the exit code |
| UX | Accept | Findings are graded rather than flattened, the removal command is printed with the scope the grant actually came from, and the output says to check a principal before deleting it |
| Security | Accept | Read-only. It reports and refuses to remediate, which is right: several holders are legitimate platform identities, and an audit that deletes things is one nobody runs twice |

## P17 acceptance criteria — named value writes fail loudly

Every named value write in this repository was made with `az apim nv update ... -o none 2>$null` and
no exit check. Named values cap at 4,096 characters, so past about 110 object ids the write failed,
the error went to `$null`, and the caller reported success.

- [x] `scripts/ApimNamedValue.ps1`, dot-sourced by both callers
- [x] An oversized value is refused before the request, naming the limit and how many entries fit
- [x] A failed write throws, carrying what the service actually said
- [x] No script writes a named value with errors suppressed — asserted, not just replaced once
- [x] The governance demo restores `tpm-standard` in a `finally`
- [x] Verified live: a valid write lands and reads back identical
- [x] `node .ironclad/gate.mjs --stage packet` exits 0

### What the work found

The sync was the obvious victim: past ~110 members a tier stops updating while the run reports
success. The second one was worse. `Show-Governance.ps1` lowers `tpm-standard` to 100 to demonstrate
throttling, then restores it — with the same suppressed error and no `finally`. A failed or
interrupted demo left the **standard tier capped at 100 tokens per minute**, silently. That restore
now runs in a `finally`, and refuses to lower the value at all if it could not first read what to
restore.

Negative-tested end to end. A 150-entry allow list is refused with "5551 characters, which is 1455
over the limit ... roughly 107 fit", and an invalid write throws with the service's own
`ValidationError`. Neither created anything.

### Council

| Seat | Verdict | Note |
|---|---|---|
| Architect | Accept | One helper, dot-sourced, matching the existing `Show-Banner.ps1` pattern. No new dependency |
| Coder | Accept | The detector forbids the old shape repo-wide rather than fixing two call sites, so it cannot creep back. It skips comment lines, which it had to learn after flagging its own documentation |
| QA | Accept | Both failure modes negative-tested against live Azure, and the live half asserts a read-back rather than trusting the exit code |
| UX | Accept | The refusal says how far over the limit it is and roughly how many entries fit, so an operator learns the real capacity instead of a rejected request |
| Security | Accept | Entitlement failing loudly is the point: the old behaviour froze an allow list while reporting success, which is a stale-authorization bug wearing a green tick. The helper never echoes a value |

## P18 acceptance criteria — the chargeback ledger

- [x] `analytics/chargeback-ledger.kql`, one row per request with the caller attached
- [x] Built on `ApiManagementGatewayLlmLog`, a log rather than a metric, so no cardinality cap
- [x] Identity joined on `context.RequestId`, carried deliberately
- [x] Streamed requests carry correct completion tokens
- [x] Cache recorded as null with `cache_tokens_known = false`, never zero
- [x] Message capture left off; the template deploys both halves of the switch
- [x] Verified live, and both failure modes negative-tested
- [x] `node .ironclad/gate.mjs --stage packet` exits 0

### What the work found

**The quota scalar excludes cache tokens.** Two identical calls with a cacheable 10,000-token
prompt wrote and then read 10,003 cache tokens; both metered 16. Documented behaviour — "counts
prompt and completion tokens only" — but the consequence had not been drawn. Against thirty days of
live usage here, weighted at Claude's published rates, **38.7% of the real cost weight is invisible
to the per-user budget**. That is a property of the shipped P11 and P12 budgets, not of this packet,
and it is why P21 may not express a dollar budget as a token quota.

**The quota scalar is also wrong for streaming**, reporting 11 tokens for a 41-token completion. The
built-in log gets the same request right. Since streaming is most of Claude Code, that alone
justifies the move.

**Neither APIM source carries the cache categories.** They are in the response body, but reading it
in `outbound` buffers the response and ends streaming. The gap is recorded rather than closed.

**Two switches, not one.** `GatewayLlmLogs` on the resource decides where rows land;
`largeLanguageModel.logs` on the API diagnostic decides whether they are produced. Enabling only the
first found an empty table with a full schema.

### The test that measured nothing

The first version asserted that the `actor` column was populated. The query fills it with
`coalesce(actor, "unattributed")`, so it was always populated and the assertion passed while every
row was in fact unattributed — the join had not worked at all. It was caught by reading the output
rather than the exit code. The assertion now requires a real caller, and breaking the join key turns
it red.

### Council

| Seat | Verdict | Note |
|---|---|---|
| Architect | Accept | The ledger is a built-in log, so the scale fix costs no new component. The one thing written is the identity the log lacks |
| Coder | Accept | The join key is carried rather than inferred, because the two candidate ids look similar and are not |
| QA | Accept | Both failure modes negative-tested: a broken join gives 0 attributed, and a zero in place of null fails. The first version of this test was vacuous and is recorded above rather than quietly fixed |
| UX | Accept | A row says whether it was streamed and where its numbers came from, so a report can state what it does not know instead of implying zero |
| Security | Accept | `RequestMessages` and `ResponseMessages` are left unset and asserted off. Enabling LLM logs without that check would have turned on prompt capture, which P15 keeps opt-in |

## P20–P22 acceptance criteria — business units

A business unit is an Entra security group registered with a monthly budget.
[ADR-0007](adr/0007-business-unit-model.md) records why: a group already exists, is already
governed, and already has joiner/mover/leaver handling, so membership needs no second roster.

- [x] **P20** A stable identifier separate from the display name. The registry key is the
      identifier; renaming the Entra group does not move spend to a new line
- [x] **P20** Transfer is group membership, deletion returns members to `unassigned`, and a
      developer in two business-unit groups takes the first in registry order
- [x] **P22** A unit that exhausts its budget gets a fourth, distinct `403` naming the unit;
      other units are unaffected; an unpriced unit is skipped rather than walled off
- [x] Unassigned developers are allowed by default, because nobody has a unit on the deployment
      that first installs this. `bu-unassigned=deny` is the target state once the report reads zero
- [x] Verified live: add, list, edit and remove all work; sync mapped 3 developers to `platform`;
      the report showed 544 tokens and 1 unassigned; `x-bu-quota-remaining: 2222222195` came back
      on a real request
- [x] No regression: an unassigned developer still received HTTP 200
- [x] 66 assertions in `tests/Test-BusinessUnits.ps1`, and every one of the 11 things they guard
      negative-tested by `tests/Test-BusinessUnitsNegative.ps1`
- [x] `./tests/Test-All.ps1` passes offline and with `-IncludeAzure`
- [x] `node .ironclad/gate.mjs --stage packet` exits 0
- [ ] **P21** remains open. The admin surface takes dollars and the report is categorised, but
      enforcement converts to one blended token figure at write time. "One counter cannot represent
      money" was P21's acceptance criterion and it is not met — see **U13**

### What the work found

| | |
|---|---|
| Five of ten mutations survived the first negative run | The colon-in-group-name case was never exercised, so `LastIndexOf` versus `IndexOf` made no difference to any assertion — the entire reason the split is on the last colon was untested |
| `'38\.7|cache'` is an alternation | The word "cache" alone satisfied it while the measured figure was wrong. Split into two assertions |
| A caveat in a `<# #>` help block is not a caveat | `-match` over raw file text cannot tell a comment from output. Comments are now stripped, and the terminal and JSON surfaces asserted separately — matching either one passed while the other had been deleted |
| A refusal check scoped to the whole file tail | `$policy.Substring(IndexOf(...))` matched `businessUnit` 200 lines above the message. Now scoped to the branch that builds it |
| `Test-Discovery.ps1` printed FAIL and exited 0 | It fell off the end without an exit code, so `Test-All` read whatever the last child process left. `Test-PreflightBothHosts.ps1` never checked its result at all — both were in a suite whose PASS was partly vacuous |
| `RESULT=` is printed even when nothing ran | A failed dot-source is non-terminating, so the child carried on and printed an empty value. The check now requires `True` or `False` |

### Council

| Seat | Verdict | Note |
|---|---|---|
| Architect | Accept | Membership comes from the group that already governs joiner/mover/leaver, so there is no second roster to reconcile. No new always-on component: three named values and a policy branch |
| Coder | Accept | The registry format has one owner, `ClaudeBusinessUnit.ps1`, read by the writer, the reader, the sync and the test. Splitting on the last colon is now covered by a case that fails on the first |
| QA | Accept | Eleven mutations, all caught — but only after five survived the first run and three assertions were found to measure nothing. That is recorded above rather than quietly fixed. Two unrelated suites that could not fail were repaired as a result |
| UX | Accept | Every command states list price and the cache gap in its own output, so a figure cannot be read without them. An edit reports the previous value alongside the new one |
| Security | Accept | No new identity path: membership is the same Graph read entitlement already does, under the same guard that refuses to empty a populated map. The refusal names the unit but not its members |

## P20c acceptance criteria — teams and tiers

[ADR-0008](adr/0008-teams-and-tiers.md) sets the model. A team is a business unit that names a
parent; tier is a separate axis attached by nesting the team group inside the tier group.

- [x] A request is charged to its team **and** to the unit above it. Verified live: one call
      returned `x-bu-quota-remaining: 1666666644` (ITES 1) and
      `x-bu-parent-quota-remaining: 5555555533` (MCAPS), with the org ceiling unchanged
- [x] Depth is capped at two and cycles are refused when written, not discovered when a budget
      stops cascading. Verified live: a third level was refused and **nothing was written** —
      the registry still held four units and no partial entry
- [x] Membership resolves to the most specific unit. Verified live: MCAPS transitively contains
      four people, all four were claimed by their teams first, and MCAPS itself took none
- [x] Tier resolves through nesting with no change to the tier mechanism. Verified live:
      `claude-code-premium` resolved to 2 members via the nested team, `claude-code-standard` to 5
- [x] Removing a business unit promotes its teams rather than leaving a dangling parent
- [x] A parent's reported figure is the roll-up of its own members and its teams, matching what
      its counter enforces
- [x] `./tests/Test-All.ps1` passes; 19 of 19 mutations caught
- [x] `node .ironclad/gate.mjs --stage packet` exits 0

### What the work found

| | |
|---|---|
| `transitiveMembers` returns nested **groups**, not only users | Measured on `claude-code-standard` with one team nested inside: 7 objects, 2 of them `#microsoft.graph.group`. `Get-GroupMemberOids` did not filter by type, so a group's object id would have been entitled and would have eaten a 4,096-character budget that holds about 110 ids. The defect predates teams and was unreachable only because nothing was nested |
| A client-side `@odata.type` filter would have been worse | Under the typed cast Graph omits that property, so the filter would have discarded every user. The cast `/transitiveMembers/microsoft.graph.user` filters server-side — measured 5 users, 0 groups |
| A test can assert the comment instead of the behaviour | The ordering check matched the prose explaining "most specific" and passed while the sort had been replaced with a constant. Fixed by extracting `Sort-ClaudeBuByDepth` and asserting against real data |
| A parent reads zero from the ledger | Members map to their team, so the roll-up has to be computed or the parent's percentage would contradict its own counter |

### Council

| Seat | Verdict | Note |
|---|---|---|
| Architect | Accept | A team is not a new object — it is a unit with a parent, so the ledger, the reports and the refusal path were unchanged. Tier stays orthogonal, so re-organising one axis does not disturb the other |
| Coder | Accept | The parent map is a second named value rather than a fourth registry field, because the group name may contain a colon and the budget is already found by splitting on the last one. A variable field count is where the previous defect in this area came from |
| QA | Accept | 19 mutations, all caught. One assertion was found matching a comment rather than behaviour, which is the same failure mode recorded in P20–P22 and was fixed by making the ordering a function with a data-driven test |
| UX | Accept | Teams are indented under their parent in both the writer and the reader, and the depth cap explains itself at the point of refusal rather than in documentation |
| Security | Accept | The typed cast closes a path where a group object could have been written into an entitlement list. No new identity surface: the same delegated Graph read as before |

## P26 acceptance criteria — the installer finds or creates a model

- [x] Claude deployments are listed with SKU and capacity, not just a name — a name alone does not
      say whether the deployment can carry the traffic
- [x] The operator chooses which models each tier may call, and the choice reaches the template.
      `modelsStandard` and `modelsPremium` were previously never passed at all
- [x] When no account has a Claude deployment, the installer offers to create one rather than
      stopping. Verified live: `foundry-plus-resource` has no Claude deployment and returned 12
      deployable Claude models, one row per model at its newest version
- [x] Selection matches on the model and publisher format, never the deployment name. Verified live
      on an account with **27 deployments**, of which 2 are Claude — OpenAI, OpenAI-OSS, Mistral and
      DeepSeek were all excluded
- [x] Quota is a distinct failure with its own advice, tested against both a quota error and an
      authorisation error
- [x] `./tests/Test-All.ps1` passes; 25 of 25 mutations caught
- [x] `node .ironclad/gate.mjs --stage packet` exits 0

### What the work found

**A redeploy would have wiped every business unit, team and membership.** The installer preserves
`allow-standard`, `allow-premium` and `quota-overrides` by reading them off the gateway and handing
them back. `bu-registry`, `bu-members` and `bu-parents` were never added to that list, and their
template parameters default to `,,` — so omitting them clears them.

Confirmed with `what-if` against the live gateway:

| Parameters | Planned `bu-registry` |
|---|---|
| Omitted, as the installer did | `,,` — four units and two teams gone |
| Supplied, as it now does | `,mcaps=…,gbb=…,ites-1=…,ites-2=…` unchanged |

Every existing "a redeploy preserves X" assertion checked only the Bicep expression, never that the
caller supplied the value. The template was willing to preserve and nothing proved anyone asked it
to. Both ends are now asserted.

| | |
|---|---|
| Azure lists a model once per version | `claude-sonnet-5` came back as v1 and v2. Offering the same model twice is a choice nobody wants; newest wins |
| `$args` is an automatic variable | Assigning to it inside a function is at best confusing. Renamed |
| A `quota` match on the installer proves nothing | The installer contains `quotaStandard`, `quotaOrg` and more, so the assertion passed on unrelated text. The classification moved into `Get-DeploymentFailureReason` and is tested against both error kinds |

### Council

| Seat | Verdict | Note |
|---|---|---|
| Architect | Accept | The installer already holds the subscription context needed to create a deployment. Sending the operator elsewhere to do it by hand was a gap in the installer, not a property of the gateway |
| Coder | Accept | Deployable models are read from the account rather than hard-coded, because what is offerable depends on region and entitlement, and a hard-coded list goes stale and then offers something that cannot be created |
| QA | Accept | 25 mutations, all caught. The quota assertion was found matching unrelated text in the installer and was replaced with a function tested against a quota error and an authorisation error |
| UX | Accept | SKU and capacity are shown because they are what an operator changes when a deployment cannot carry the load. Opus is excluded from standard by default with the reason given at the prompt |
| Security | Accept | No new permission: creating a deployment needs the Cognitive Services contributor rights the operator already needs to stand up the gateway, and failure states which right was missing |

## P24/P27 acceptance criteria — the Observe half

- [x] The client that made the call is recorded. Nothing in API Management carried it — measured
      2026-09-16, `AppRequests.Properties` held only API and service metadata, `ClientType` read
      `PC`, `ClientBrowser` was empty
- [x] The surface is **parsed** from the agent string, not matched against a list. Verified live
      with the real Claude Code CLI plus Desktop-, VS Code- and SDK-shaped agents, all five
      distinguishable in one query
- [x] The queries are callable functions. Verified the window parameter is honoured rather than
      pinned: `ClaudeChargeback()` 44 rows, `(ago(2h), now())` 5, `(ago(30d), now())` 44,
      `(ago(1m), now())` 0
- [x] The publisher refuses when a window line has moved, rather than shipping a function that
      ignores its arguments
- [x] A workbook exists, bound to one workspace, updating in place on re-run
- [x] It refuses to publish against a workspace without the functions. Verified: pointed at a
      second workspace it named the missing function and the script to run first
- [x] Every currency figure on the pane says list price and states the 38.7% cache gap
- [x] No always-on component added — a saved search and a workbook both store and run nothing
- [x] `./tests/Test-All.ps1` passes; 39 of 39 mutations caught
- [x] `node .ironclad/gate.mjs --stage packet` exits 0

### What the work found

| | |
|---|---|
| The obvious guess at the CLI's agent string was wrong | Claude Code 2.1.241 sends `claude-cli/2.1.241 (external, sdk-cli)` — `sdk-cli`, not `cli`. A classifier written from the guess would have bucketed the real CLI as "other" and looked correct doing it. The surface is now extracted from whatever follows `external,` |
| A classifier in policy is a redeploy; in KQL it is a query edit | The policy captures the fact and the query interprets it, so a client that changes its agent string costs nothing to accommodate |
| A portal link built from the management endpoint opens nothing | `https://management.azure.com/subscriptions/...` concatenated after `#@/resource` produced a link that looked plausible and went nowhere. The ARM path is now kept separate from the base URL |
| A workbook bound to the wrong workspace reads as no usage | It renders empty rather than erroring, so both publishers refuse to guess when a resource group holds more than one |

### Council

| Seat | Verdict | Note |
|---|---|---|
| Architect | Accept | Observe was the last box in the flow with nothing behind it. It is filled with metadata only — a saved search and a workbook — so the constraint of not adding an always-on bill of materials held |
| Coder | Accept | The `.kql` files stay the single source; the publisher rewrites only the window lines and refuses if it cannot find them. A copy of the query inside the publisher would have been a second thing to keep current |
| QA | Accept | 39 mutations, all caught. The parameter check was made non-vacuous by proving four different windows return four different counts — a pinned function returns the same number every time and passes a weaker test |
| UX | Accept | Both publishers list, publish and remove, and refuse with the name of the script to run first rather than an Azure error. The caveats sit on the pane, not in a footnote |
| Security | Accept | The agent string is a request header the caller already sends, truncated and stored beside data already held. No prompt content is captured and no new permission is needed |

## Commands that prove it```powershell./tests/Test-All.ps1                                    # 17 checks, offline
./tests/Test-All.ps1 -IncludeAzure                      # plus the seven that call Azure
./scripts/Get-ClaudeTelemetry.ps1                       # where this gateway logs, and whether metrics are on
./scripts/Get-ClaudeAnalytics.ps1 -Days 30              # the usage report
./scripts/Get-ClaudeBudget.ps1                          # effective limits and spend to date
./scripts/Get-ClaudeBusinessUnit.ps1                    # budgets, members and spend by business unit
./scripts/Publish-ClaudeQueries.ps1 -List               # the callable KQL functions
./scripts/Publish-ClaudeWorkbook.ps1 -List              # the Observe pane, and where it opens
./scripts/New-ClaudeCodePolicy.ps1 -Tier premium        # one managed-settings profile per tier
./scripts/Find-ClaudeUserData.ps1 -User <upn>           # what is held about one person
./scripts/Get-ClaudeBypass.ps1                          # who can skip the gateway entirely
./tests/Test-OrgCeilingLive.ps1 -ProveRefusal           # exhausts each budget, then restores it
./tests/Test-BusinessUnitsNegative.ps1                  # breaks each business-unit check and confirms it goes red
node .ironclad/gate.mjs --stage packet                  # definition of done
```

## Next

P14 — the plugin marketplace — is the only packet left, and U6 rewrote its acceptance criterion.
Claude Code has no plugin signing scheme, so "signed accepted, unsigned refused" cannot be tested.
What can be tested is immutable approved content: a plugin pinned to a commit sha or archive
hash, a modified one refused on hash mismatch, marketplaces outside `strictKnownMarketplaces`
rejected, and `isDesktopExtensionSignatureRequired` enforcing publisher signing for `.mcpb`
bundles only. `docs/UNKNOWNS.md` U6 has the keys and the blast radius.

Three unknowns remain open. **U2** blocks putting a currency figure on spend. **U8** blocks the
four productivity fields P10 returns as null. **U3** — whether Claude in Chrome applies under a
third-party provider — is unexamined and affects only a parity-matrix row.

One thing outside the packet queue and worth doing: seven principals hold `Cognitive Services
User` directly on the Foundry account, which bypasses every budget in this repository.
`SETUP.md` section 4.2 has the audit commands.