import hashlib
import json
from datetime import timedelta
from decimal import Decimal, InvalidOperation

from .errors import ServiceError
from .service import utc
from .queries import literal
from .workflows import SYSTEM


def quantity(value):
    try:
        result = Decimal(str(value))
        if not result.is_finite() or result < 0:
            raise InvalidOperation()
        return result
    except (InvalidOperation, ValueError) as error:
        raise ServiceError(503, "analytics_incomplete", "Warning usage must be a finite nonnegative quantity") from error


def record_warnings(service):
    now = service.clock()
    start = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    end = start.replace(year=start.year + 1, month=1) if start.month == 12 else start.replace(month=start.month + 1)
    query = (f"ClaudeCost(datetime({utc(start)}), datetime({utc(now)}))"
             "\n| summarize tokens=sum(prompt_tokens)+sum(completion_tokens) by business_unit")
    rows = service.analytics.query(query)
    with service.store.lease() as lease:
        _, config, _, _ = service.context(SYSTEM)
        usage = {}
        for row in rows:
            leaf = row.get("business_unit")
            used = quantity(row.get("tokens", 0))
            usage[leaf] = usage.get(leaf, 0) + used
            parent = config.parents.get(leaf)
            if parent:
                usage[parent] = usage.get(parent, 0) + used
        targets = []
        for unit in config.units:
            key, limit = unit["Id"], unit["TokensPerMonth"]
            kind = "department" if key in config.parents else "organization"
            targets.append((kind, key, limit, usage.get(key, Decimal(0)), now.strftime("%Y-%m"),
                            start, end, "ClaudeCost"))
        if config.overrides:
            day = now.replace(hour=0, minute=0, second=0, microsecond=0)
            selected = ",".join(literal(oid) for oid in config.overrides)
            daily_query = (f"ClaudeChargeback(datetime({utc(day)}), datetime({utc(now)}))"
                           f"\n| where user_id in ({selected})"
                           "\n| summarize tokens=sum(prompt_tokens)+sum(completion_tokens) by user_id\n| take 201")
            daily = {r["user_id"]: quantity(r.get("tokens", 0)) for r in service.analytics.query(daily_query)}
            for key, limit in config.overrides.items():
                targets.append(("user", key, limit, daily.get(key, Decimal(0)), now.strftime("%Y-%m-%d"),
                                day, day + timedelta(days=1), "ClaudeChargeback"))
        for kind, key, limit, used, period, period_start, period_end, source in targets:
            metadata = service.store.get("budgets", kind + ":" + key) or {}
            threshold = metadata.get("warning_threshold_percent", 80)
            if limit <= 0 or used * 100 < limit * threshold:
                continue
            basis = "prompt_completion_only"
            version = hashlib.sha256(json.dumps([kind, key, limit, threshold, "tokens", basis],
                                               separators=(",", ":")).encode()).hexdigest()
            id_ = hashlib.sha256(json.dumps([kind, key, utc(period_start), utc(period_end), threshold, basis, version],
                                           separators=(",", ":")).encode()).hexdigest()
            if service.store.get("notifications", id_):
                continue
            record = {"schema_version": 1, "id": id_, "kind": "budget.warning",
                      "scope_type": kind, "scope_id": key, "period": period,
                      "period_start_utc": utc(period_start), "period_end_utc": utc(period_end),
                      "threshold_percent": threshold, "observed_usage": format(used, "f"),
                      "usage_unit": "tokens", "usage_basis": basis, "effective_limit_version": version,
                      "source": source, "token_limit": limit, "occurred_at": utc(now)}
            def work():
                lease()
                service.store.put("notifications", id_, record, create=True)
            service.audit_change(SYSTEM, "notification.create", "Warning threshold reached", None, record, work)
