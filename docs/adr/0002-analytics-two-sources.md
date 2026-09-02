# ADR-0002: Analytics comes from two telemetry sources, not one

- **Status:** Accepted
- **Date:** 2026-09-02
- **Packet:** P10
- **Deciders:** claude-code-foundry-gateway maintainers

## Context

Claude Enterprise exposes a Claude Code Analytics API returning one record per user per day
([reference](https://platform.claude.com/docs/en/manage-claude/claude-code-analytics-api),
retrieved 2026-09-02). Its fields:

| Group | Fields |
|---|---|
| Dimensions | `date`, `actor` (email or API key name), `organization_id`, `customer_type`, `terminal_type` |
| Core | `num_sessions`, `lines_of_code.added`, `lines_of_code.removed`, `commits_by_claude_code`, `pull_requests_by_claude_code` |
| Tool actions | `edit_tool`, `multi_edit_tool`, `write_tool`, `notebook_edit_tool`, each `accepted` / `rejected` |
| Model breakdown | `model`, `tokens.input/output/cache_read/cache_creation`, `estimated_cost.amount` |

A customer moving to Foundry loses that endpoint. This is stated by Anthropic directly, not
inferred: "This API only tracks Claude Code usage on the Claude API. Usage through Claude in
Amazon Bedrock, **Claude in Microsoft Foundry**, Claude on Google Cloud, or Claude Platform on
AWS is not included."
([reference](https://platform.claude.com/docs/en/manage-claude/claude-code-analytics-api),
retrieved 2026-09-02.)

So the endpoint does not return partial data for a Foundry deployment — it returns none. There
is no configuration that changes this, which removes the option of keeping the Anthropic API and
supplementing it.

The gateway already emits per-request telemetry to Application Insights via
`llm-emit-token-metric`, dimensioned by `User`, `UserId`, `Tier`, `Model` and `SessionId`.

## The constraint that decides this

The gateway sees requests. It cannot see anything that never becomes a request.

Lines of code, commits, pull requests, and tool accept/reject rates are **client-side events**.
They are not derivable from HTTP traffic at any level of inspection — a rejected Edit produces
no request at all. No amount of gateway policy recovers them.

Claude Code emits exactly those metrics over OpenTelemetry
([monitoring](https://code.claude.com/docs/en/monitoring-usage), retrieved 2026-09-02), and the
environment variables that turn it on are already deliverable through the managed settings this
repository generates.

## Options considered

1. **Gateway telemetry only.** Zero new components. Covers spend and attribution; silently
   omits every productivity field, which is most of the API's value.
2. **Claude Code OTEL only.** Covers productivity and token counts. Loses the gateway's tier
   attribution and its authoritative view of what was actually served, including throttles.
3. **Both, joined in Log Analytics.** Gateway telemetry is the billing record; OTEL is the
   productivity record; `UserId` is the join key.

## Decision

Option 3.

- **Gateway → Application Insights**, unchanged. Authoritative for tokens served, tier, and
  throttling.
- **Claude Code → the customer's OTLP collector → Log Analytics**, enabled through managed
  settings so it arrives with the rest of the policy and needs no per-developer action.
- **A saved KQL function** projects the union into the field names above, so a report written
  against the Claude Code Analytics API keeps working with only the transport swapped.
- **No new always-on component.** Log Analytics is already deployed by this accelerator; the
  collector is Azure Monitor's OTLP endpoint or a container the customer already runs.

Field mapping, and what does not carry over:

| API field | Source | Note |
|---|---|---|
| `date`, `actor` | either | `actor` is the Entra UPN, not an Anthropic email |
| `organization_id` | — | Replaced by tenant id |
| `customer_type` | — | Meaningless here; always the Foundry deployment |
| `terminal_type` | OTEL | Claude Code reports it |
| `num_sessions` | gateway | Distinct `SessionId` per user per day, excluding the literal `"none"` and nulls |
| `lines_of_code.*`, `commits_*`, `pull_requests_*` | OTEL only | Not visible to the gateway |
| tool `accepted` / `rejected` | OTEL only | A rejection never leaves the client. Reported as one accepted/rejected pair, not split across the four tools — Claude Code emits a single `code_edit_tool.decision` counter |
| `tokens.input`, `tokens.output`, `tokens.cache_read` | gateway | Authoritative, because it is what was served |
| `tokens.cache_creation` | — | Foundry emits no equivalent metric. Measured 2026-09-02: the gateway's Application Insights carries `Prompt Tokens`, `Completion Tokens`, `Prompt Cached Tokens` and `Total Tokens` only |
| `estimated_cost` | derived | The API reports **cents**; `analytics/claude-code-daily.kql` reports dollars in `estimated_cost_usd`. Accuracy is **U2**, open |

## Consequences

+ Productivity metrics survive the migration, which option 1 would have quietly dropped.
+ Spend stays anchored to what the gateway actually served rather than to a client's report.
+ Content capture stays off. These are counters, not prompts; the privacy decision in
  `OTEL_LOG_USER_PROMPTS` remains separate and opt-in.
− Two pipelines to keep running, and a developer whose OTEL export is broken shows productivity
  gaps while still appearing in spend. The join must make that visible rather than reporting
  zero.
− `estimated_cost` is derived, so it is only as good as the price table behind it. Until U2 is
  closed it is labelled an estimate everywhere it appears.

## How we would know this was wrong

If customers only ever look at spend, the OTEL half is overhead and should be cut to option 1.
Track which fields are actually queried once P10 ships.
