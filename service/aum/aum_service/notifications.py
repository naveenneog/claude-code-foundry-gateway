import hashlib

from .service import utc
from .queries import literal
from .workflows import SYSTEM


def record_warnings(service):
    now = service.clock()
    start = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    query = (f"ClaudeCost(datetime({utc(start)}), datetime({utc(now)}))"
             "\n| summarize tokens=sum(prompt_tokens)+sum(completion_tokens) by business_unit")
    rows = service.analytics.query(query)
    with service.store.lease() as lease:
        _, config, _, _ = service.context(SYSTEM)
        usage = {}
        for row in rows:
            leaf = row.get("business_unit")
            used = float(row.get("tokens", 0))
            usage[leaf] = usage.get(leaf, 0) + used
            parent = config.parents.get(leaf)
            if parent:
                usage[parent] = usage.get(parent, 0) + used
        targets = []
        for unit in config.units:
            key, limit = unit["Id"], unit["TokensPerMonth"]
            kind = "department" if key in config.parents else "organization"
            targets.append((kind, key, limit, usage.get(key, 0), now.strftime("%Y-%m")))
        if config.overrides:
            day = now.replace(hour=0, minute=0, second=0, microsecond=0)
            selected = ",".join(literal(oid) for oid in config.overrides)
            daily_query = (f"ClaudeChargeback(datetime({utc(day)}), datetime({utc(now)}))"
                           f"\n| where user_id in ({selected})"
                           "\n| summarize tokens=sum(prompt_tokens)+sum(completion_tokens) by user_id\n| take 201")
            daily = {r["user_id"]: float(r.get("tokens", 0)) for r in service.analytics.query(daily_query)}
            for key, limit in config.overrides.items():
                targets.append(("user", key, limit, daily.get(key, 0), now.strftime("%Y-%m-%d")))
        for kind, key, limit, used, period in targets:
            metadata = service.store.get("budgets", kind + ":" + key) or {}
            threshold = metadata.get("warning_threshold_percent", 80)
            if limit <= 0 or used * 100 < limit * threshold:
                continue
            id_ = hashlib.sha256(f"{kind}/{key}/{period}/{threshold}".encode()).hexdigest()
            if service.store.get("notifications", id_):
                continue
            record = {"id": id_, "kind": "budget.warning", "scope_type": kind, "scope_id": key,
                      "period": period, "threshold_percent": threshold, "observed_usage": used,
                      "token_limit": limit, "occurred_at": utc(now), "delivery_status": "pending"}
            def work():
                lease()
                service.store.put("notifications", id_, record, create=True)
            service.audit_change(SYSTEM, "notification.create", "Warning threshold reached", None, record, work)
