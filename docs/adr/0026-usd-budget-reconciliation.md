# ADR-0026: Dollar budgets use a dated tariff and a reconciled gateway stop

- **Status:** Accepted
- **Date:** 2026-09-25
- **Packet:** P21/P59; U13
- **Decider:** Platform owner
- **Extends:** ADR-0010, ADR-0019 and ADR-0023

## Scope and contract

The owner assigned this isolated worktree while the shared status names P52/P55.
As in ADR-0023, this ADR records the delegated packet; the lead owns STATUS,
ROADMAP, CHANGELOG and UNKNOWNS. Proposed ledger changes and the five review
verdicts belong in the delivery report. No gate or existing check is waived.
The reference gateway is read-only. Only a separately owned Basic v2 gateway
may be changed for evidence. The terminal client is another branch's scope.

## Research and detectors, before implementation

Microsoft Learn, retrieved 2026-09-25:

| Question | Evidence | Consequence / detector |
|---|---|---|
| Nonstream response usage | [Policy expressions](https://learn.microsoft.com/azure/api-management/api-management-policy-expressions#context-variable): `IMessageBody.As<T>(preserveContent: true)` reads a copy of the body. | Parse only a successful JSON Messages response, and retain only usage counts. Compare the gateway trace against the real response. |
| Final SSE usage without buffering | [SSE guidance](https://learn.microsoft.com/azure/api-management/how-to-server-sent-events) and [forward-request](https://learn.microsoft.com/azure/api-management/forward-request-policy) require `buffer-response="false"` and avoiding body readers/logging. There is no documented policy callback for a final SSE frame. | Do not read a streaming body. Measure time to first byte with and without a body reader on the isolated gateway. |
| Response-weighted counters | [rate-limit-by-key](https://learn.microsoft.com/azure/api-management/rate-limit-by-key-policy) postpones expression increments to the end of outbound; detection occurs on a subsequent request. Its maximum window is 300 seconds, and distributed throttling is not exact. [quota-by-key](https://learn.microsoft.com/azure/api-management/quota-by-key-policy) accepts an increment expression but literal calls/window; minimum window 300 seconds, or lifetime 0. Restarts can briefly admit exhausted quotas. | Weighted counters are possible, not a durable monthly currency ledger. Isolated response-dependent increment probes must demonstrate behavior. No realtime currency counter is added without stream-safe final counts. |
| Native dollar policy | The [policy catalog](https://learn.microsoft.com/azure/api-management/api-management-policies) lists token, call and bandwidth controls, not a currency policy for Standard/Premium v2. The [AI Gateway tier](https://learn.microsoft.com/azure/api-management/ai-gateway-overview) is a different preview. | Do not depend on that tier, application keys or its unsuccessful route experiment (U16). |
| Cache fields in telemetry | [LLM log schema](https://learn.microsoft.com/azure/azure-monitor/reference/tables/apimanagementgatewayllmlog) has prompt/completion/total, not cache categories. [Token metrics](https://learn.microsoft.com/azure/api-management/llm-emit-token-metric-policy) can include provider-dependent cached tokens; an interrupted stream is inaccurate. [Trace](https://learn.microsoft.com/azure/api-management/trace-policy) logs every invocation, independent of sampling. | Recover nonstream cache writes in a counts-only trace; retain streaming incompleteness explicitly. Never imply the custom metric's cardinality limit disappeared. |
| Delay | [Ingestion latency](https://learn.microsoft.com/azure/azure-monitor/logs/data-ingestion-time) says resource logs usually take 3-10 minutes, not a maximum or SLA. | Measure ingestion plus reconcile interval, execution and APIM propagation. No finite guaranteed dollar overshoot exists without admission reservation and a bounded spend rate. |

**Open detectors:** streamed cache creation/TTL metrics, custom inference-only
RBAC, and the actual latency distribution require the isolated measurements.
The guide/report records measurements, including failures, rather than replacing
these unknowns with assumed zeros.

## Decision

Keep the token controls. Add two optional, preserved named values:

- `usd-budgets`: base64-encoded ASCII JSON, schema 1, dated price book and
  dollar amounts per organization, department and person.
- `usd-budget-state`: base64-encoded ASCII JSON, schema 1, configuration
  fingerprint, exclusive UTC windows, reconciliation/expiry time, exact decimal
  known-category subtotals, completeness flags, and per-scope decisions.

Encoding prevents JSON quotes from terminating APIM policy string literals.
Both are subject to the existing 4,096-character ceiling. Overflow refuses the
whole write; it never truncates a map. Empty objects leave old installations'
behavior unchanged. An enabled dollar budget without a matching fresh state
fails closed, not open. An obsolete configuration snapshot cannot lift a stop.

A shared Python reconciler is used by the AUM Functions timer and an on-demand
PowerShell entry point. The service retains its managed identity, narrow
named-value permissions, workspace reader, storage lease and audit. Direct
execution uses the signed-in Azure CLI identity and conditional ARM writes.
Read again immediately before applying; any governance/configuration change
defers without writes. `turnstile-integration` is an authority boundary for
scripts, APIs and scheduled reconciliation, not merely a UI warning.

The query returns categorized integer counts, not floating-point KQL dollars.
Money uses Decimal throughout, without per-request rounding. The dated book
is persisted with the budget rather than inferred later from the token quota.
Rates for all nonzero categories must exist. Unpriced models or malformed
counts produce an explicit unavailable-price decision, never zero spend.

Current membership attribution matches the existing financial reports; team
usage also charges its parent. User budgets support UTC day or month; the
existing `-DailyUsd` retains its daily period. Token-only edits do not silently
delete a dollar control. Mode comes from `bu-modes`: strict stops at the
nominal budget, allowance stops only above its effective allowance, and notify
never stops that scope. Other scopes and the original token guards still apply.
Notices are response headers; client display and email delivery are not assumed.

Stop errors have their own code and scope, nominal/effective dollars, observed
spend and reconciliation time. Raising a budget invalidates the old snapshot;
the next successful reconciliation lifts the stop. UTC rollover requires a new
window; last month's spend cannot block the new month once reconciled.

## Financial semantics and honest limits

This is a delayed stop based on a dated **internal list-price tariff**, not an
Azure invoice and not a reservation system. U2 remains open. Rates absent an
explicit historical interval are a consciously pinned tariff for the budget
period, not proof of the market price at every historic request. This clarifies
ADR-0010's intended time-versioning versus the existing single-date price book;
the API must expose the price-book date and never silently switch it.

Nonstream usage can include all five categories with a known cache TTL split.
For streaming, only measured available categories may be priced. Unknown writes,
missing cache metrics, incomplete identity joins and interrupted streams remain
visible limitations; no field called complete or invoice-accurate may be true
when those facts are absent. A known subtotal reaching the limit is sufficient
to stop; a subtotal below it does not establish total spend below it.

Thus this packet can deliver exact arithmetic and delayed gateway enforcement
on observed categories, but cannot close the stronger claim of a universally
exact streaming dollar ceiling. That would need stream-safe provider telemetry
or a separately designed metering/reservation service. It is not introduced
silently as an inference proxy here.

## Alternatives rejected

- One blended quota: already measured to omit cache and mix unlike prices.
- Parse/replace the SSE body: changes latency and breaks the client contract.
- Rounded micro-dollar increments: fractional micro-dollars lose precision;
  counters are distributed and do not supply missing usage.
- An unpriced model costs zero: fails open and makes the report look complete.
- Azure invoice budgets as synchronous enforcement: delayed billing is not
  request admission, and this subscription cannot reconcile U2.
- A second governance writer while Turnstile owns the gateway: edits would be
  overwritten and stale jobs could lift valid stops.

## Acceptance evidence

Behavioral offline tests and mutations cover serialization, precision, missing
prices, modes, scope, authority, stale snapshots, rollover and stop/lift. The
isolated live proof must show nonstream cache creation/read arithmetic, the
distinct 403, a budget raise, latency, cost and complete resource/grant removal.
The architecture source, rendered image and manifest travel with the feature.
