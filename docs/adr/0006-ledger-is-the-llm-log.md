# ADR-0006: The chargeback ledger is the built-in LLM log, joined to identity

- **Status:** Accepted
- **Date:** 2026-09-15
- **Packet:** P18
- **Deciders:** claude-code-foundry-gateway maintainers
- **Closes:** U12

## Context

Per-user chargeback currently rides on `llm-emit-token-metric`. Microsoft documents that custom
metrics cap each dimension at 100 unique values and each namespace at 1,000 active time series, and
that beyond either limit "any new dimension values or time series are not tracked, and the
corresponding metric data is silently discarded". `UserId` is one dimension per developer and
`SessionId` is unbounded, so the ledger stops recording somewhere around a hundred developers, and
says nothing when it does.

Four candidate sources were measured on the live gateway on 2026-09-15.

| | Streaming | Output tokens | Cache categories | Per-request id | Cardinality |
|---|---|---|---|---|---|
| `x-tokens-consumed` (the quota scalar) | wrong | missing | **excluded** | no | n/a |
| `llm-emit-token-metric` | ok | ok | `Prompt Cached Tokens` | no | **capped at 100** |
| `ApiManagementGatewayLlmLog` | **correct** | **correct** | **absent** | `RequestId` | unbounded |
| Anthropic response body | not parseable | ok | **full detail** | `id` | n/a |

No single source carries everything.

## What the measurements showed

**The quota scalar excludes cache tokens.** Two identical calls with a cacheable 10,000-token
system prompt: the first wrote 10,003 cache tokens, the second read 10,003. Both were metered as
16. This is documented behaviour — the reference says the policy "currently counts prompt and
completion tokens only" — but its consequence had not been drawn. Against thirty days of live usage
on this gateway, cache reads are 6.8 million tokens against 320 thousand prompt and 152 thousand
completion. Weighted at Claude's published rates, where output is 5x base input and a cache read is
0.1x, **38.7% of the real cost weight is invisible to the quota**.

**The quota scalar is also wrong for streaming.** A streamed request reported 11 through
`x-tokens-consumed` where the completion was 41. The built-in LLM log recorded 11 prompt and 30
completion for the same request, correctly.

**Streaming cannot be parsed in policy.** The usage is present in the stream — `message_start`
carries the cache breakdown and `message_delta` the final output and thinking tokens — but reading
the response body in `outbound` buffers it, which would end streaming for Claude Code. That is not
an acceptable trade for a billing field.

**The built-in log has no cache fields.** Its schema is `PromptTokens`, `CompletionTokens`,
`TotalTokens`, and the cached request recorded 9 and 30 while 10,003 cache reads went unrecorded.
APIM is evidently parsing the stream, since it gets streamed output tokens right; it simply does not
project the cache categories into the table.

## Decision

The ledger is `ApiManagementGatewayLlmLog`, joined to identity by a `trace` the gateway emits.

- **Spine:** the built-in log, enabled through `GatewayLlmLogs` on the APIM resource and
  `largeLanguageModel.logs` on the API diagnostic. It is a log, so it has no cardinality cap; it is
  correct for streaming; and it carries a per-request id.
- **Identity:** a `<trace severity="information">` in `outbound` carrying the caller's object id,
  UPN, tier and requested model, keyed on `context.RequestId`. The trace policy is documented as
  "not affected by Application Insights sampling", which is what a billing record needs.
- **Join:** `ApiManagementGatewayLlmLog.CorrelationId` to the trace's request id. Application
  Insights `operation_Id` is a W3C trace id and does not match the log's GUID, so the join key is
  carried deliberately rather than inferred.
- **Message capture stays off.** `largeLanguageModel.requests` and `.responses` are left unset. The
  table has `RequestMessages` and `ResponseMessages` columns, and filling them would be content
  capture through the back door, which P15 keeps opt-in.

### Cache tokens are recorded as unknown, not zero

For a non-streamed request the categories can be read from the response body. For a streamed one
they cannot, and no APIM-native source exposes them per request. The ledger therefore carries a
`usage_source` of `body` or `log`, and a report may not present a cached figure as zero when the
source is `log`. Aggregate cache volume remains available from `Prompt Cached Tokens`, which is
bounded but not per-user.

## Consequences

+ The ledger stops silently discarding data at a hundred developers.
+ Streamed requests, which is most of Claude Code, are counted correctly for the first time.
+ Identity is attached without buffering a response or adding a component.
+ Content capture stays opt-in.
− Per-request cache attribution is unavailable for streamed requests, which is a gap in the
  platform rather than in this design. It is recorded as unknown and stated in the report.
− Two tables to join, and a join key that has to be carried rather than inferred.

## How we would know this was wrong

If Microsoft adds the cache categories to `ApiManagementGatewayLlmLog`, the trace is only needed for
identity and this gets simpler. If instead the join key proves unstable across APIM upgrades, the
answer moves to emitting the whole record ourselves and accepting the streaming limitation.
