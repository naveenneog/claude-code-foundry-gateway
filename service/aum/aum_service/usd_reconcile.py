from datetime import UTC, datetime

from .errors import Conflict, ServiceError
from .queries import literal
from .transactions import apply_values
from .usd_budgets import (
    calculate_state, check_authority, decode_document, encode_state,
    parse_budgets, source_revision, timestamp,
)
from .workflows import SYSTEM


def usage_query(gateway_base, now, chargeback="ClaudeChargeback", metrics="AppMetrics"):
    gateway = gateway_base.removeprefix("https://management.azure.com")
    if not gateway.startswith("/subscriptions/") or "/providers/Microsoft.ApiManagement/service/" not in gateway:
        raise ServiceError(503, "usd_gateway_unknown", "USD reconciliation needs a specific gateway resource id")
    start = now.astimezone(UTC).replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    if not chargeback.replace("_", "").isalnum() or not metrics.replace("_", "").isalnum():
        raise ServiceError(503, "usd_invalid_usage_query", "USD query fixture names must be identifiers")
    return f"""let _from = datetime({timestamp(start)});
let _to = datetime({timestamp(now)});
let norm = (m: string) {{ tolower(replace_regex(m, @"[^A-Za-z0-9]", "")) }};
let family_of = (m: string) {{
    let k = norm(m);
    iff(strlen(k) > 8 and substring(k, strlen(k) - 8, 8) matches regex @"^\\d{{8}}$", substring(k, 0, strlen(k) - 8), k)
}};
let ledger = {chargeback}(_from, _to)
| where timestamp >= _from and timestamp < _to
| where gateway_id =~ {literal(gateway)}
| extend deployment=iff(isempty(deployment),model,deployment),
         family=family_of(coalesce(model, deployment)),
         business_unit=coalesce(business_unit, "unassigned");
let latest_unit =
    ledger
    | where user_id != ""
    | summarize arg_max(timestamp, business_unit) by user_id
    | project user_id, latest_business_unit=business_unit;
let metered = ledger
| summarize prompt_tokens=sum(tolong(prompt_tokens)), completion_tokens=sum(tolong(completion_tokens)),
    body_reads=sum(tolong(cache_read_tokens)),
    cache_write_5m_tokens=sum(tolong(cache_write_5m_tokens)),
    cache_write_1h_tokens=sum(tolong(cache_write_1h_tokens)),
    missing_reads=countif(not(coalesce(cache_read_known,false))),
    missing_writes=countif(not(coalesce(cache_write_known,false))),
    not_body=countif(usage_source != "body"), geographies=make_set(inference_geo, 2),
    models=make_set(model, 2),
    ingestion_delay_seconds=max(datetime_diff('second', ingested_at, timestamp)),
    latest_request=max(timestamp)
    by day=startofday(timestamp), user_id, family, deployment, business_unit;
let cached = {metrics}
| where TimeGenerated >= _from and TimeGenerated < _to
| where Name == "Prompt Cached Tokens"
| where tostring(Properties["Service ID"]) == {literal(gateway.split('/')[-1])}
| extend family=family_of(tostring(Properties.Model))
| summarize metric_reads=sum(tolong(Sum)), metric_rows=count()
    by day=startofday(TimeGenerated), user_id=tostring(Properties.UserId), family, metric_model=tostring(Properties.Model);
let group_totals = metered
| summarize total_body_reads=sum(body_reads), total_missing_reads=sum(missing_reads), group_latest=max(latest_request)
    by day, user_id, family
| join kind=fullouter cached on day, user_id, family
| extend day=coalesce(day, day1), user_id=coalesce(user_id, user_id1), family=coalesce(family, family1)
| project-away day1, user_id1, family1
| extend group_cache_read_total=iff(isnotnull(total_missing_reads) and total_missing_reads == 0,
    coalesce(total_body_reads,0), max_of(coalesce(total_body_reads,0), coalesce(metric_reads,0)));
let metered_rows = metered
| join kind=leftouter group_totals on day, user_id, family
| extend remainder_reads=max_of(group_cache_read_total - total_body_reads, 0)
| project day, user_id, deployment, model=tostring(models[0]), business_unit,
    prompt_tokens=coalesce(prompt_tokens,0), completion_tokens=coalesce(completion_tokens,0),
    cache_read_tokens=coalesce(body_reads,0) + iff(latest_request == group_latest, remainder_reads, 0),
    cache_write_5m_tokens=coalesce(cache_write_5m_tokens,0),
    cache_write_1h_tokens=coalesce(cache_write_1h_tokens,0),
    cache_read_known=isnotnull(missing_reads) and (missing_reads == 0 or metric_rows > 0 or remainder_reads > 0),
    cache_write_known=isnotnull(missing_writes) and missing_writes == 0,
    inference_geo=iff(array_length(geographies) == 1,tostring(geographies[0]),'unknown'),
    usage_source=iff(isnotnull(not_body) and not_body == 0,'body','log+metric'),
    ambiguous_model=array_length(models) > 1, ingestion_delay_seconds,
    unit_unknown=false;
let metric_only_rows = group_totals
| where isnull(total_body_reads) and isnotnull(metric_reads)
| join kind=leftouter latest_unit on user_id
| project day, user_id, deployment=metric_model, model=metric_model,
    business_unit=coalesce(latest_business_unit, ""),
    prompt_tokens=0, completion_tokens=0,
    cache_read_tokens=group_cache_read_total,
    cache_write_5m_tokens=0,
    cache_write_1h_tokens=0,
    cache_read_known=true,
    cache_write_known=true,
    inference_geo="unknown",
    usage_source="metric",
    ambiguous_model=false,
    ingestion_delay_seconds=long(null),
    unit_unknown=isempty(latest_business_unit);
union metered_rows, metric_only_rows
| take 1001"""


def reconcile_snapshot(arm, analytics, now, lease=lambda: None):
    snapshot = arm.read()
    values = {k: v["value"] for k, v in snapshot.items()}
    check_authority(values)
    doc = parse_budgets(values.get("usd-budgets"))
    if not doc or not doc["items"]:
        return {"enabled": False}, None, snapshot
    if "usd-budget-state" not in snapshot:
        raise Conflict("Install the USD gateway named values and policy before enabling budgets", "usd_not_installed")
    rows = analytics.query(usage_query(arm.base, now))
    if len(rows) > 1000:
        raise ServiceError(503, "usd_usage_capacity", "USD query exceeded 1,000 groups; no partial spend was applied")
    state = calculate_state(values, rows, now)
    previous = decode_document(values["usd-budget-state"])
    if previous.get("reconciled_at", "") > state["reconciled_at"]:
        raise Conflict("A newer USD reconciliation already exists", "usd_stale_run")
    lease()
    current = {k: v["value"] for k, v in arm.read().items()}
    check_authority(current)
    if source_revision(current) != source_revision(values):
        raise Conflict("Governance changed during reconciliation; no state applied", "usd_stale_run")
    encoded = encode_state(state)
    return state, None if encoded == values["usd-budget-state"] else encoded, snapshot


def reconcile(service):
    with service.store.lease() as lease:
        state, encoded, snapshot = reconcile_snapshot(service.arm, service.analytics, service.clock(), lease)
        if encoded is not None:
            service.audit_change(
                SYSTEM, "usd.reconcile", "Scheduled or administrator-requested USD reconciliation",
                snapshot["usd-budget-state"]["value"], encoded,
                lambda: apply_values(service.arm, snapshot, {"usd-budget-state": encoded}, lease),
            )
    return state


def reconcile_direct(arm, analytics):
    state, encoded, snapshot = reconcile_snapshot(arm, analytics, datetime.now(UTC))
    if encoded is not None:
        apply_values(arm, snapshot, {"usd-budget-state": encoded}, lambda: None)
    return state
