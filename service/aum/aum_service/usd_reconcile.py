from datetime import UTC, datetime

from .errors import Conflict, ServiceError
from .queries import literal
from .transactions import apply_values
from .usd_budgets import (
    calculate_state, check_authority, decode_document, encode_state,
    parse_budgets, source_revision, timestamp,
)
from .workflows import SYSTEM


def usage_query(gateway_base, now):
    gateway = gateway_base.removeprefix("https://management.azure.com")
    if not gateway.startswith("/subscriptions/") or "/providers/Microsoft.ApiManagement/service/" not in gateway:
        raise ServiceError(503, "usd_gateway_unknown", "USD reconciliation needs a specific gateway resource id")
    start = now.astimezone(UTC).replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    return f"""let _from = datetime({timestamp(start)});
let _to = datetime({timestamp(now)});
let metered = ClaudeChargeback(_from, _to)
| where timestamp >= _from and timestamp < _to
| where gateway_id =~ {literal(gateway)}
| extend deployment=iff(isempty(deployment),model,deployment)
| summarize prompt_tokens=sum(tolong(prompt_tokens)), completion_tokens=sum(tolong(completion_tokens)),
    body_reads=sum(tolong(cache_read_tokens)),
    cache_write_5m_tokens=sum(tolong(cache_write_5m_tokens)),
    cache_write_1h_tokens=sum(tolong(cache_write_1h_tokens)),
    missing_reads=countif(not(coalesce(cache_read_known,false))),
    missing_writes=countif(not(coalesce(cache_write_known,false))),
    not_body=countif(usage_source != "body"), geographies=make_set(inference_geo, 2),
    units=make_set(business_unit, 2), models=make_set(model, 2),
    ingestion_delay_seconds=max(datetime_diff('second', ingested_at, timestamp))
    by day=startofday(timestamp), user_id, deployment;
let cached = AppMetrics
| where TimeGenerated >= _from and TimeGenerated < _to
| where Name == "Prompt Cached Tokens"
| where tostring(Properties["Service ID"]) == {literal(gateway.split('/')[-1])}
| summarize metric_reads=sum(tolong(Sum)), metric_rows=count()
    by day=startofday(TimeGenerated), user_id=tostring(Properties.UserId), deployment=tostring(Properties.Model);
metered | join kind=fullouter cached on day, user_id, deployment
| project day=coalesce(day,day1), user_id=coalesce(user_id,user_id1),
    deployment=coalesce(deployment,deployment1), model=tostring(models[0]),
    business_unit=iff(array_length(units) == 1,tostring(units[0]),''),
    prompt_tokens=coalesce(prompt_tokens,0), completion_tokens=coalesce(completion_tokens,0),
    cache_read_tokens=iff(isnotnull(missing_reads) and missing_reads == 0,
        coalesce(body_reads,0),max_of(coalesce(body_reads,0),coalesce(metric_reads,0))),
    cache_write_5m_tokens=coalesce(cache_write_5m_tokens,0),
    cache_write_1h_tokens=coalesce(cache_write_1h_tokens,0),
    cache_read_known=isnotnull(missing_reads) and (missing_reads == 0 or metric_rows > 0),
    cache_write_known=isnotnull(missing_writes) and missing_writes == 0,
    inference_geo=iff(array_length(geographies) == 1,tostring(geographies[0]),'unknown'),
    usage_source=iff(isnotnull(not_body) and not_body == 0,'body','log+metric'),
    ambiguous_model=array_length(models) > 1, ingestion_delay_seconds
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
