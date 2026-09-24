"""Deterministic Contoso data only; no production identities or tokens."""

from copy import deepcopy
from datetime import datetime, timezone

from .backend import Backend
from .errors import FinOpsError

STAMP = "2026-09-24T12:00:00Z"


def budget(kind, key, name, parent, limit, used):
    return dict(scope_type=kind, scope_id=key, scope_name=name, parent_scope_id=parent,
                token_limit=limit, warning_threshold_percent=80, used_tokens=used,
                remaining_tokens=None if limit is None else limit - used,
                usage_percent=round(used * 100 / limit, 1) if limit else None,
                forecast_tokens=round(used * 30 / 24), status="warning" if limit and used >= limit * .8 else "healthy",
                forecast_percent=round(used * 125 / limit, 1) if limit else None,
                updated_at=STAMP, updated_by="admin@contoso.com")


class FakeBackend(Backend):
    name = "Example"

    def __init__(self, role="owner"):
        self.role = role
        self.reads = []
        self.writes = []
        self.rows = [
            budget("organization", "sales", "Sales", None, 20000000, 11000000),
            budget("department", "sales-emea", "Sales EMEA", "sales", 8000000, 6100000),
            budget("department", "sales-apac", "Sales APAC", "sales", 9500000, 4900000),
            budget("organization", "engineering", "Engineering", None, 30000000, 4500000),
        ]
        self.people = [budget("user", f"dev-{i:03}@contoso.com", f"Developer {i:03}", "sales-emea", 100000, i * 1000)
                       for i in range(1, 76)]
        self.catalog = dict(source="configured", updated_at=STAMP, updated_by="admin@contoso.com",
                            default_department_id="sales-emea",
                            organizations=[dict(id=r["scope_id"], name=r["scope_name"], attributes={},
                                                external_ref=f"entra-group:contoso-{r['scope_id']}")
                                           for r in self.rows if r["scope_type"] == "organization"],
                            departments=[dict(id=r["scope_id"], name=r["scope_name"], parent_id=r["parent_scope_id"],
                                             external_ref=f"entra-group:contoso-{r['scope_id']}",
                                             attributes={"kind": "team", "manager_group": f"contoso-{r['scope_id']}-managers"})
                                         for r in self.rows if r["scope_type"] == "department"])
        self.tiers = [dict(id="standard", name="Standard", entra_group="contoso-standard", tokens_per_minute=20000,
                           tokens_per_day=500000, models=["claude-sonnet-5"]),
                      dict(id="premium", name="Premium", entra_group="contoso-premium", tokens_per_minute=80000,
                           tokens_per_day=2000000, models=["claude-sonnet-5", "claude-opus-5"])]
        self.requested_at = STAMP

    def read(self, resource, **params):
        self.reads.append((resource, deepcopy(params)))
        if resource == "whoami":
            return dict(id="contoso-admin", email="admin@contoso.com", name="Contoso administrator",
                        role=self.role, method="entra", managed_units=[] if self.role == "owner" else ["sales"])
        if resource == "budgets":
            return deepcopy(dict(period=params.get("month", "2026-09"), generated_at=STAMP, items=self.rows,
                                 risk_count=1, risk_items=[], history=[], enforcement=[]))
        if resource == "people":
            matched = [p for p in self.people if p["parent_scope_id"] == params["department_id"]
                       and params.get("query", "").lower() in (p["scope_name"] + p["scope_id"]).lower()]
            offset, limit = params.get("offset", 0), params.get("limit", 50)
            return deepcopy(dict(items=matched[offset:offset + limit], total=len(matched), offset=offset, limit=limit,
                                 department_token_limit=8000000, department_allocated_tokens=7500000,
                                 department_available_tokens=500000, generated_at=STAMP))
        if resource == "catalog":
            return deepcopy(self.catalog)
        if resource == "tiers":
            return dict(items=deepcopy(self.tiers), updated_at=STAMP)
        if resource == "apply":
            return dict(configured=True, last_request=dict(requested_at=self.requested_at, started=True,
                                                           execution="example-apply", reason="Example save", error=None),
                        executions=[dict(name="example-apply", status="Succeeded",
                                         started_at=self.requested_at, ended_at=self.requested_at)])
        if resource == "overview":
            return dict(generated_at=STAMP, totals=dict(total_tokens=15500000, total_requests=12500,
                        estimated_cost=112.50, cache_read_tokens=7200000, average_latency_ms=740,
                        p95_latency_ms=1800, error_rate=.2), changes_percent={"total_tokens": 12.4})
        if resource == "distribution":
            dimension = params.get("dimension", "organization")
            values = {"organization": ["sales", "engineering"], "department": ["sales-emea", "sales-apac"],
                      "model": ["claude-sonnet-5", "claude-opus-5"], "runtime": ["sdk-cli", "vscode"],
                      "user": ["dev-001@contoso.com", "dev-002@contoso.com"]}
            return dict(dimension=dimension, items=[dict(id=name, name=name, total_tokens=11000000 - i * 6500000,
                        total_requests=9000 - i * 5500, cache_read_tokens=4000000, estimated_cost=80 - i * 47.5,
                        share_percent=70.9 if not i else 29.1) for i, name in enumerate(values.get(dimension, ["unknown"]))])
        if resource == "trends":
            return dict(interval=params.get("interval", "day"), points=[dict(bucket_start=f"2026-09-{i:02}T00:00:00Z",
                        key="all", label="All", totals=dict(total_tokens=100000 + i * 25000, calls=100 + i * 13,
                        estimated_cost=1 + i * .12, cached_tokens=i * 1000)) for i in range(1, 25)])
        if resource in {"requests", "request"}:
            rows = [dict(request_id=f"contoso-request-{i:03}", timestamp=f"2026-09-24T11:{59 - i % 60:02}:00Z",
                         user_id="dev-001@contoso.com", user_name="Developer 001",
                         organization_id="sales", department_id="sales-emea", model_name="claude-sonnet-5",
                         model_id="claude-sonnet-5", total_tokens=1500 + i * 100, prompt_tokens=1000,
                         completion_tokens=500, runtime="sdk-cli", status_code=200, estimated_cost=.012,
                         latency_ms=740, cache_write_tokens=0, estimated=True) for i in range(120)]
            if resource == "request":
                result = next((row for row in rows if row["request_id"] == params["request_id"]), None)
                if not result:
                    raise FinOpsError("Request not found. Check its identifier.", 5)
                return result
            return dict(items=rows[:params.get("limit", 50)], page={"next_cursor": None})
        if resource == "anomalies":
            return dict(items=[dict(id="contoso-finding-1", severity="warning", title="Token burn above baseline",
                                   dimension="department", dimension_name="Sales APAC", detected_at=STAMP,
                                   actual_value=4900000, threshold_value=4500000,
                                   description="Review the team's usage before changing its budget.")])
        raise FinOpsError(f"Unknown example view: {resource}")

    def write(self, resource, body=None, **params):
        if self.role != "owner":
            raise FinOpsError("Read-only role.", 4)
        self.writes.append((resource, deepcopy(params), deepcopy(body)))
        self.requested_at = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
        if resource.startswith("budget"):
            rows = self.people if params["scope_type"] == "user" else self.rows
            row = next(item for item in rows if item["scope_id"] == params["scope_id"])
            row["token_limit"] = None if resource == "budget_remove" else body["token_limit"]
            limit, used = row["token_limit"], row["used_tokens"]
            row["remaining_tokens"] = None if limit is None else limit - used
            row["usage_percent"] = None if limit is None else used * 100 / limit
            row["status"] = ("unallocated" if limit is None else "exceeded" if used >= limit
                             else "warning" if used >= limit * .8 else "healthy")
            if body:
                row["warning_threshold_percent"] = body["warning_threshold_percent"]
            return self.read("budgets", month=params["month"])
        if resource == "catalog":
            self.catalog.update(deepcopy(body))
            return self.read("catalog")
        if resource == "tiers":
            self.tiers = deepcopy(body["tiers"])
            return self.read("tiers")
        return dict(started=True, requested_at=self.requested_at, execution="example-apply")
