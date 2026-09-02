# Status

**Active packet:** P10 - analytics equivalent. Shipped and verified against live telemetry. P-0 (Ironclad adoption) is complete.

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

## Commands that prove it

```powershell
./tests/Test-All.ps1                          # 6 checks, offline
./tests/Test-All.ps1 -IncludeAzure            # plus the three that call Azure
./scripts/Get-ClaudeAnalytics.ps1 -Days 30    # the report itself
node .ironclad/gate.mjs --stage packet        # definition of done
```

## Next

P11 — the org-wide monthly spend ceiling. U1 is closed by measurement, so it sits in the request
path: a constant `counter-key` is a single shared counter. Two things carry into the design. The
cap is soft — the policy reference states high-concurrency requests can temporarily exceed it, so
it must not be described as a hard spend guarantee. And refusal is `403`, the same code as the
per-user daily quota, so the message has to distinguish the organisation's budget from the
developer's or it will be read as an entitlement failure.

Open unknowns are in `docs/UNKNOWNS.md`. U2 blocks putting a currency figure on the estimate; U8
blocks the four productivity fields P10 currently returns as null.
