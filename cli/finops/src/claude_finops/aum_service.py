"""Optional independent authority, normalized from P55 OpenAPI 1.0.3."""

from datetime import datetime, timezone, timedelta
from urllib.parse import quote

from .capabilities import enabled, require
from .errors import FinOpsError
from .http_backend import HttpBackend
from .rules import identifier, month_window, can_budget_write
from . import service_models as models


class AumServiceBackend(HttpBackend):
    name = "AUM service"
    immediate_writes = True
    native_modes = True
    requires_reason = True
    person_budget_period = "day"
    unit_direct_departments = False
    native_user_budget_records = True
    maximum_boost_days = 31

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._identity = None
        self._revision = None
        self._catalog = None
        self._budgets = []
        self._tiers = []
        self._requests = {}

    def _get(self, path, params=None):
        result = self._request("GET", "/api/v1/" + path, params)
        if result.get("revision"):
            self._revision = result["revision"]
        return result

    def people_filter(self, scope_id):
        if not scope_id or scope_id == "__authorized__":
            return {}
        catalog = self._catalog or self.read("catalog")
        return {"organization_id" if scope_id in {row["id"] for row in catalog["organizations"]}
                else "department_id": scope_id}

    def _window(self, params):
        start, end = month_window(params["month"])
        now = datetime.now(timezone.utc)
        if datetime.fromisoformat(start.replace("Z", "+00:00")) >= now:
            raise FinOpsError("AUM service queries must not be in the future.")
        values = {"from": params.get("from") or start}
        explicit_end = params.get("to") or params.get("before")
        if explicit_end:
            values["to"] = explicit_end
        elif datetime.fromisoformat(end.replace("Z", "+00:00")) <= now:
            values["to"] = end
        # Omit current-month 'to': the server fixes it inside its cursor, while
        # preserving the same query fingerprint on subsequent client pages.
        for key in ("organization_id", "department_id", "user_id", "limit", "cursor"):
            if params.get(key) is not None and params[key] != "":
                values[key] = params[key]
        for key in ("model_id", "runtime", "tier", "project_id"):
            if params.get(key):
                raise FinOpsError(f"The connected AUM service contract does not support the {key} filter.", 5)
        return values

    def read(self, resource, **params):
        if resource == "whoami":
            current = self._get("me")
            if self._identity and any(current.get(key) != self._identity.get(key) for key in ("id", "role", "manager_scope")):
                self._requests.clear()
                self._catalog = self._revision = self._features = None
                self._budgets, self._tiers = [], []
            self._identity = current
            return self._identity
        if resource == "capabilities":
            self._features = models.capabilities(self._get("capabilities"))
            return self._features
        if resource == "catalog":
            self._catalog = self._get("catalog")
            return dict(self._catalog, default_department_id=None)
        if resource == "tiers":
            self._get("budgets")
            result = self._get("tiers")
            self._tiers = result["items"]
            return dict(items=[dict(row, name=row["id"], entra_group="") for row in self._tiers])
        if resource == "budgets":
            catalog = self.read("catalog")
            result = self._get("budgets")
            if catalog.get("revision") and catalog["revision"] != result["revision"]:
                raise FinOpsError("Gateway configuration changed during the read. Refresh budgets.", 6)
            entities = {row["id"]: row for kind in ("organizations", "departments") for row in catalog[kind]}
            rows = []
            for row in result["items"]:
                entity = entities.get(row["scope_id"], {})
                rows.append(dict(row, scope_name=entity.get("name", row["scope_id"]),
                    parent_scope_id=entity.get("parent_id"), budget_period=row.get("period", "month"),
                    used_tokens=None, remaining_tokens=None, status="unknown",
                    warning_threshold_percent=row.get("warning_threshold_percent", 80)))
            self._budgets = rows
            return dict(items=rows, revision=result["revision"], period=params.get("month"),
                note="Current gateway limits: units/teams monthly, people daily. This service response has no per-budget usage/risk totals.")
        if resource == "usd_budgets":
            return self._get("usd-budgets")
        if resource == "usd_status":
            return self._get("usd-budget-status")
        if resource == "usd_price_book":
            return self._get("usd-price-book")
        if resource == "apply":
            return dict(configured=False, direct=True, executions=[],
                note="AUM service writes and verifies gateway state synchronously. Audit/revision is the receipt; no Turnstile apply job.")
        if resource == "overview":
            result = self._get("usage", self._window(params))
            return dict(totals=models.totals(result), generated_at=result.get("as_of"),
                        note="Saved ClaudeCost, prompt/completion token basis. Unpriced cost is unknown; not an invoice.")
        if resource == "trends":
            if params.get("interval", "day") != "day" or params.get("group_by", "none") != "none":
                raise FinOpsError("This AUM service contract offers ungrouped daily trends only.", 5)
            result = self._get("trends", self._window(params))
            return dict(points=[dict(bucket_start=row["day"], label="All", totals=models.totals(row)) for row in result["items"]],
                        note="Server-scoped daily ClaudeCost facts.")
        if resource == "people":
            if params.get("offset", 0):
                raise FinOpsError("AUM service uses opaque people cursors. Start at offset 0, then pass --cursor.", 5)
            query = self._window(params)
            if len(params.get("query", "")) > 100:
                raise FinOpsError("AUM service people search is at most 100 characters.")
            query["search"] = params.get("query", "")
            records = self._get("people", query)
            budgets = self.read("budgets", month=params["month"])
            limits = {row["scope_id"]: row for row in budgets["items"] if row["scope_type"] == "user"}
            items = []
            for row in records["items"]:
                budget = limits.get(row["id"], {})
                identity = self._identity or self.read("whoami")
                items.append(dict(scope_type="user", scope_id=row["id"], scope_name=row["name"],
                    parent_scope_id=row.get("parent_id"), unit=row.get("organization_id"),
                    token_limit=budget.get("token_limit"), used_tokens=None, remaining_tokens=None,
                    status="unknown", budget_period="day",
                    writable=bool(row.get("parent_id")) and can_budget_write(identity, "user", row["id"], row["parent_id"]),
                    warning_threshold_percent=budget.get("warning_threshold_percent", 80)))
            return dict(models.page(records, items), offset=0, limit=params.get("limit", 50), total=None,
                        note="Server-scoped observed people; daily overrides. Usage, last-seen and effective tier defaults are not included in this API.")
        if resource == "requests":
            result = self._get("requests", self._window(params))
            rows = [dict(row, user_name=row.get("actor"), model_name=row.get("model"),
                         runtime=row.get("client_surface"), estimated_cost=None) for row in result["items"]]
            self._requests = {row["request_id"]: row for row in rows}
            return dict(models.page(result, rows), note="Server-scoped, stable cursor; per-request cache/cost remain unknown.")
        if resource == "request":
            key = identifier(params["request_id"])
            query = dict(month=params["month"], limit=200)
            cached = self._requests.get(key)
            if cached and cached.get("timestamp"):
                stamp = datetime.fromisoformat(cached["timestamp"].replace("Z", "+00:00")).replace(microsecond=0)
                query.update({"from": stamp.isoformat(), "to": (stamp + timedelta(seconds=1)).isoformat()})
            seen = set()
            while True:
                fresh = self.read("requests", **query)
                result = next((row for row in fresh["items"] if row["request_id"] == key), None)
                if result is not None:
                    return result
                cursor = fresh["page"]["next_cursor"]
                if not cached or not cursor or cursor in seen:
                    raise FinOpsError("Request is outside the current page. Select it from paged Requests; this service has no indexed detail endpoint.", 5)
                seen.add(cursor)
                query["cursor"] = cursor
        if resource in {"approval_requests", "approval_request"}:
            return self._approval_read(resource, params)
        if resource in {"boosts", "notifications", "audit"}:
            result = self._get(resource, {key: params[key] for key in ("limit", "cursor") if params.get(key)})
            if resource == "notifications":
                result["items"] = [dict(row, title="Budget threshold reached", body="Server warning fact",
                    severity="warning", created_at=row.get("occurred_at")) for row in result["items"]]
            return dict(models.page(result), note="Server-authorized records. Notifications are immutable facts, not delivery receipts.")
        raise FinOpsError(f"AUM service does not offer {resource} in the connected contract; no Turnstile fallback is used.", 5)

    def _approval_read(self, resource, params):
        identity = self._identity or self.read("whoami")
        cursor, seen = params.get("cursor"), set()
        while True:
            query = {key: value for key, value in dict(limit=params.get("limit", 50), cursor=cursor).items() if value is not None}
            result = self._get("budget-requests", query)
            rows = [models.request_record(row, identity) for row in result["items"]]
            if resource == "approval_request":
                found = next((row for row in rows if row["id"] == params["id"]), None)
                if found:
                    return found
                cursor = result.get("next_cursor")
                if not cursor:
                    raise FinOpsError("Request not found in the server-authorized queue.", 5)
                if cursor in seen:
                    raise FinOpsError("Service repeated a cursor; stop and refresh the request queue.", 7)
                seen.add(cursor)
                continue
            view = params.get("view", "mine")
            if view == "mine":
                rows = [row for row in rows if row["requester_id"] == identity["id"]]
            elif view == "waiting":
                rows = [row for row in rows if "approve" in row["allowed_actions"]]
            elif view == "history":
                rows = [row for row in rows if row["state"] != "pending"]
            else:
                raise FinOpsError("Choose mine, waiting or history.")
            return dict(models.page(result, rows), note="Queue filter applies within this server page; use Next even if no matching rows are shown.")

    def write(self, resource, body=None, **params):
        from .service_writes import write
        return write(self, resource, body, params)
