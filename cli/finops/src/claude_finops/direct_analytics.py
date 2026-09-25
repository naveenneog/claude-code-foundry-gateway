"""Direct analytics stay bounded in KQL; no directory scan or client-side time-series model."""

from datetime import datetime, timezone
from hashlib import sha256

from .errors import FinOpsError
from .rules import query_window

DIMENSIONS = {"department": "business_unit", "user": "actor", "model": "model",
              "runtime": "client_surface", "tier": "tier"}


def people(backend, ledger, params):
    team = params.get("department_id")
    if not team:
        raise FinOpsError("Choose a team for server-side observed-people search.")
    query = str(params.get("query", ""))[:200]
    offset = max(0, int(params.get("offset", 0)))
    limit = min(200, max(1, int(params.get("limit", 50))))
    kql = (ledger + f"\n| where actor contains {backend._quote(query)} or user_id startswith {backend._quote(query)}"
           "\n| extend person_id=iff(isempty(user_id), actor, user_id)"
           "\n| summarize window_tokens=sum(total_tokens), used_tokens=sumif(total_tokens, timestamp >= startofday(now())),"
           " arg_max(timestamp, actor, user_id, tier) by person_id"
           "\n| project person_id, actor, user_id, tier, used_tokens, window_tokens, last_seen=timestamp"
           f"\n| sort by person_id asc | serialize row=row_number() | where row > {offset} | take {limit}")
    rows = backend.query(kql)
    state = backend._bridge("read") if rows else {}
    defaults = {tier["id"]: tier["tokens_per_day"] for tier in state.get("tiers", [])}
    current = params["month"] == datetime.now(timezone.utc).strftime("%Y-%m")
    result = []
    for row in rows:
        key = row.get("person_id", row.get("user_id") or row["actor"])
        override = state.get("overrides", {}).get(key)
        budget = override if override is not None else defaults.get(row.get("tier"))
        used = row.get("used_tokens") if current else None
        result.append(dict(scope_type="user", scope_id=key, scope_name=row["actor"],
            parent_scope_id=team, used_tokens=used, token_limit=budget,
            remaining_tokens=budget - used if budget is not None and used is not None else None,
            status="unknown" if used is None else "exceeded" if budget is not None and used >= budget else "healthy",
            last_seen=row.get("last_seen"), tier=row.get("tier"), observed_window_tokens=row.get("window_tokens"),
            unit=state.get("parents", {}).get(team, team),
            budget_period="day", has_override=override is not None, warning_threshold_percent=80,
            writable=bool(row.get("user_id")) and bool(state.get("person_budgets_supported"))))
    return dict(items=result, offset=offset, limit=limit, total=None, budget_period="day",
        note="Observed people, server-paged. Used/limit: current UTC day; detail includes selected-month tokens. "
             "Daily override or tier default, not a monthly allocation or an exact gateway counter.")


def hourly(backend, ledger, params):
    group = params.get("group_by", "none")
    if group not in {"none", *DIMENSIONS}:
        raise FinOpsError("Hourly grouping supports department, user, model, runtime or tier; filter a unit explicitly.")
    split = f", label={DIMENSIONS[group]}" if group != "none" else ""
    query = (ledger + "\n| summarize total_tokens=sum(total_tokens), total_requests=count()"
             f" by bucket_start=bin(timestamp,1h){split}\n| order by bucket_start asc")
    rows = backend.query(query)
    points = []
    for row in rows:
        values = dict(row)
        stamp, label = values.pop("bucket_start"), values.pop("label", "All")
        values.update(estimated_cost=None, cache_read_tokens=None, cache_write_tokens=None)
        points.append(dict(bucket_start=stamp, label=label, totals=values))
    return dict(points=points, note="Hourly request-ledger facts. Per-hour cost/cache are unknown; "
                "daily ClaudeCost is not spread across hours. Ingestion can lag.")


def anomalies(backend, cost, params):
    start, end = query_window(params["month"], params.get("from"), params.get("to"))
    limit = min(200, max(1, int(params.get("limit", 50))))
    query = f"""let aum_facts=materialize({cost});
let aum_scopes=union
(aum_facts | extend scope_kind="organization", scope_id=iff(isempty(business_unit_parent), business_unit, business_unit_parent)),
(aum_facts | where isnotempty(business_unit_parent) | extend scope_kind="department", scope_id=business_unit);
let aum_eligible=aum_scopes | summarize unknown_prices=countif(not(priced_ok)), active_days=dcount(day) by scope_kind, scope_id
| where unknown_prices == 0 and active_days >= 14;
aum_scopes | join kind=inner aum_eligible on scope_kind, scope_id
| make-series daily_cost=sum(usd) default=0 on day from datetime({start}) to min_of(datetime({end}), startofday(now())) step 1d by scope_kind, scope_id
| where array_length(daily_cost) >= 14
| extend (flag, score, baseline_cost)=series_decompose_anomalies(daily_cost,3.0,7,'linefit')
| mv-expand day to typeof(datetime), daily_cost to typeof(real), flag to typeof(int), score to typeof(real), baseline_cost to typeof(real)
| where flag != 0
| extend strength=abs(score)
| order by strength desc | take {limit}"""
    rows = backend.query(query)
    findings = []
    for row in rows:
        identity = f"{row['scope_kind']}|{row['scope_id']}|{row['day']}"
        findings.append(dict(id="stat-" + sha256(identity.encode()).hexdigest()[:24],
            severity="critical" if abs(row["score"]) >= 6 else "warning",
            title="Daily estimated cost above baseline" if row["flag"] > 0 else "Daily estimated cost below baseline",
            dimension=row["scope_kind"], dimension_id=row["scope_id"], dimension_name=row["scope_id"],
            detected_at=row["day"], **row))
    return dict(items=findings, note="Statistical candidates, not incidents: KQL decomposition, threshold 3, weekly seasonality, "
                "linear trend; >=14 active priced days, completed UTC days only. Unpriced/sparse series excluded. "
                "Missing days treated as no observed cost; ingestion gaps can trigger findings. No rows is not an all-clear.")
