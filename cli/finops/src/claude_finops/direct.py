import json
from fnmatch import fnmatchcase
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from uuid import uuid4

import httpx

from .backend import Backend
from .config import az
from .errors import FinOpsError, http_error
from .rules import identifier, month_window, query_window
from .capabilities import current_capabilities
from . import direct_analytics

DIMENSIONS = {"organization": "business_unit", "department": "business_unit", "user": "actor",
              "model": "model", "runtime": "client_surface", "tier": "tier"}


class DirectBackend(Backend):
    name = "Direct"
    immediate_writes = True
    native_modes = True
    person_budget_period = "day"
    budget_warning_threshold = False

    def __init__(self, config):
        self.config = config.validate()
        self.root = Path(config.repository) if config.repository else Path(__file__).resolve().parents[4]
        self.bridge = self.root / "scripts" / "Invoke-ClaudeFinOps.ps1"
        if not self.bridge.exists():
            raise FinOpsError("Direct mode needs the gateway repository. Set repository in config.")
        if not config.resource_group or not config.apim_name:
            raise FinOpsError("Run aum configure to discover the Direct gateway and workspace, or set resource_group and apim_name.")

    def _bridge(self, action, body=None, **params):
        folder = self.root / ".finops-evidence"
        folder.mkdir(exist_ok=True)
        path = folder / f"bridge-{uuid4().hex}.json"
        try:
            path.write_text(json.dumps(dict(action=action, body=body, parameters=params)), encoding="utf-8")
            result = subprocess.run(["pwsh", "-NoProfile", "-File", str(self.bridge), "-InputFile", str(path),
                                     "-ResourceGroup", self.config.resource_group, "-ApimName", self.config.apim_name,
                                     *(["-Subscription", self.config.subscription] if self.config.subscription else [])],
                                    capture_output=True, text=True, encoding="utf-8", timeout=300)
            if result.returncode:
                try:
                    detail = json.loads(result.stdout).get("error")
                except ValueError:
                    detail = None
                if detail:
                    from .redaction import mask_identifiers
                    raise FinOpsError("Gateway script: " + mask_identifiers(detail), 7 if "manual recovery" in detail else 6)
                if "manual recovery required" in result.stderr:
                    raise FinOpsError("Gateway change failed and rollback was incomplete or conflicted. Inspect named values; manual recovery is required. Do not repeat the save.", 7)
                if "previous values restored and verified" in result.stderr:
                    raise FinOpsError("Gateway change failed; previous values were restored and read-back verified. Refresh before retrying.", 6)
                raise FinOpsError("Gateway script refused the change. Check Azure roles, governance authority, parent budget and Entra groups; refresh before retrying.", 6)
            return json.loads(result.stdout)
        except (OSError, subprocess.TimeoutExpired, ValueError):
            raise FinOpsError("Cannot run gateway scripts. Install PowerShell 7 and verify the repository and Azure sign-in.", 7) from None
        finally:
            path.unlink(missing_ok=True)

    def query(self, kql):
        if not self.config.workspace:
            raise FinOpsError("Usage requires workspace in config: the Log Analytics workspace customer id. Find it in Azure Portal > Log Analytics > Overview.")
        workspace = identifier(self.config.workspace)
        access = self._az("account", "get-access-token", "--resource", "https://api.loganalytics.io",
                         "--query", "accessToken", "-o", "tsv")
        try:
            with httpx.Client(timeout=90) as client:
                response = client.post(f"https://api.loganalytics.io/v1/workspaces/{workspace}/query",
                                       headers={"Authorization": "Bearer " + access}, json={"query": kql})
            if not response.is_success:
                raise http_error(response.status_code)
            payload = response.json()
            if payload.get("error"):
                raise FinOpsError("Log Analytics returned a partial result. Narrow the time window and retry.", 7)
            table = payload["tables"][0]
            return [dict(zip([col["name"] for col in table["columns"]], row)) for row in table["rows"]]
        except (httpx.HTTPError, ValueError, KeyError, IndexError):
            raise FinOpsError("Ledger query failed. Check workspace id, network and Log Analytics Reader access.", 7) from None
        finally:
            access = ""

    def _ledger(self, month, start=None, end=None):
        start, end = query_window(month, start, end)
        source = (self.root / "analytics" / "chargeback-ledger.kql").read_text(encoding="utf-8-sig")
        if self.config.subscription:
            resource = (f"/subscriptions/{self.config.subscription}/resourceGroups/{self.config.resource_group}"
                        f"/providers/Microsoft.ApiManagement/service/{self.config.apim_name}")
            source = source.replace("\nApiManagementGatewayLlmLog\n",
                                    "\nApiManagementGatewayLlmLog\n| where _ResourceId =~ " + self._quote(resource) + "\n")
        return source.replace("let _from = ago(1d);", f"let _from = datetime({start});").replace(
            "let _to = now();", f"let _to = datetime({end});")

    @staticmethod
    def _quote(value):
        return json.dumps(str(value), ensure_ascii=True)

    def _az(self, *args):
        return az(*args, *(("--subscription", self.config.subscription) if self.config.subscription else ()))

    def read(self, resource, **params):
        if resource == "capabilities":
            identity = params.get("identity") or self.read("whoami")
            result = current_capabilities(identity)
            state = self._bridge("read")
            writer = identity.get("role") == "owner" and state.get("authority") == "Gateway"
            result["authority"] = state.get("authority", "unknown")
            result["features"]["bulk_budget"] = {"enabled": False, "actions": []}
            result["features"]["native_writes"] = {"enabled": writer, "actions": ["budget", "catalog", "tiers"] if writer else []}
            result["features"]["budget_modes"] = {"enabled": True, "actions": ["read"] + (["write"] if writer and state.get("modes_supported") else [])}
            result["features"]["person_daily_budget"] = {"enabled": True, "actions": ["read"] + (["write"] if writer and state.get("person_budgets_supported") else [])}
            usd_actions = ["read"] if state.get("usd_supported") else []
            if writer and state.get("usd_supported"):
                usd_actions += ["write", "reconcile", "price_book_write"]
            result["features"]["usd_budgets"] = {"enabled": bool(usd_actions), "actions": usd_actions}
            return result
        if resource == "whoami":
            account = json.loads(self._az("account", "show", "-o", "json"))
            if not self.config.subscription and account.get("id"):
                self.config.subscription = account["id"]
            can_write = False
            if account.get("id"):
                resource_id = (f"/subscriptions/{account['id']}/resourceGroups/{self.config.resource_group}"
                               f"/providers/Microsoft.ApiManagement/service/{self.config.apim_name}")
                url = f"https://management.azure.com{resource_id}/providers/Microsoft.Authorization/permissions?api-version=2022-04-01"
                try:
                    permissions = json.loads(self._az("rest", "--method", "get", "--url", url, "-o", "json"))
                    action = "microsoft.apimanagement/service/namedvalues/write"
                    can_write = any(any(fnmatchcase(action, p.lower()) for p in row.get("actions", []))
                                    and not any(fnmatchcase(action, p.lower()) for p in row.get("notActions", []))
                                    for row in permissions.get("value", []))
                except FinOpsError:
                    can_write = False
            return dict(email=account.get("user", {}).get("name", "Azure caller"), role="owner" if can_write else "member",
                        method="azure-rbac", tenant=account.get("tenantId"),
                        scope="Admin-only Direct through Azure RBAC, not unit-scoped authorization. "
                              "For scoped managers/viewers choose the optional AUM service or Turnstile.")
        if resource == "apply":
            return dict(configured=False, direct=True, note="Direct writes verify named values and compensate on failure; no server apply job.", executions=[])
        if resource in {"usd_budgets", "usd_status", "usd_price_book"}:
            return self._bridge(resource)
        if resource in {"catalog", "tiers", "budgets"}:
            state = self._bridge("read")
            if resource == "catalog":
                return state["catalog"]
            if resource == "tiers":
                return dict(items=state["tiers"])
            month = params["month"]
            usage = self.query(self._ledger(month) + "\n| summarize used_tokens=sum(total_tokens) by business_unit")
            used = {r["business_unit"]: r["used_tokens"] for r in usage}
            rows = []
            for item in state["registry"]:
                key = item["Id"]
                parent = state["parents"].get(key)
                total = used.get(key, 0)
                if not parent:
                    total += sum(used.get(k, 0) for k, value in state["parents"].items() if value == key)
                limit = item["TokensPerMonth"] or None
                rows.append(dict(scope_type="department" if parent else "organization", scope_id=key,
                                 scope_name=key, parent_scope_id=parent, token_limit=limit, used_tokens=total,
                                 remaining_tokens=limit - total if limit is not None else None,
                                 status="exceeded" if limit and total >= limit else "healthy",
                                 warning_threshold_percent=80, historical_limit=False))
            return dict(items=rows, period=month, note="Current gateway limits; historical budget versions are unavailable.",
                        quota_org=state["quota_org"])
        ledger = self._ledger(params.get("month", datetime.now(timezone.utc).strftime("%Y-%m")),
                              params.get("from"), params.get("to"))
        for key, column in (("department_id", "business_unit"), ("model_id", "model"),
                            ("runtime", "client_surface"), ("tier", "tier")):
            if params.get(key):
                ledger += f"\n| where {column} == {self._quote(params[key])}"
        if params.get("user_id"):
            value = self._quote(params["user_id"])
            ledger += f"\n| where user_id == {value} or actor == {value}"
        needs_ledger = resource in {"people", "requests", "request"} or (resource == "trends" and params.get("interval") == "hour")
        if params.get("organization_id") and needs_ledger:
            parents = self._bridge("read").get("parents", {})
            unit = params["organization_id"]
            leaves = [unit] + [key for key, parent in parents.items() if parent == unit]
            ledger += "\n| where business_unit in (" + ",".join(self._quote(key) for key in leaves) + ")"
        if resource == "people":
            return direct_analytics.people(self, ledger, params)
        if resource == "distribution" and params.get("basis") == "ledger":
            dimension = params.get("dimension", "department")
            if dimension not in DIMENSIONS or dimension == "organization":
                raise FinOpsError("Request-time usage supports team, person, model, surface or tier. Parent-unit history is not stamped in this ledger.")
            column = DIMENSIONS[dimension]
            rows = self.query(ledger + f"\n| summarize total_tokens=sum(total_tokens), total_requests=count() by id={column}"
                              "\n| order by total_tokens desc | take 100")
            return dict(items=[dict(row, name=row["id"], cache_read_tokens=None, estimated_cost=None) for row in rows],
                        dimension=dimension, note="Request-time attribution from the selected gateway ledger; current membership is not substituted. Cache/cost unknown.")
        if resource == "trends" and params.get("interval") == "hour":
            return direct_analytics.hourly(self, ledger, params)
        if resource in {"requests", "request"}:
            if resource == "request":
                ledger += "\n| where request_id == " + self._quote(identifier(params["request_id"]))
            elif params.get("before"):
                ledger += "\n| where timestamp < todatetime(" + self._quote(params["before"]) + ")"
            limit = min(200, max(1, int(params.get("limit", 50))))
            rows = self.query(ledger + f"\n| take {limit}")
            for row in rows:
                row.update(user_name=row.get("actor"), model_name=row.get("model"), runtime=row.get("client_surface"),
                           estimated_cost=None, status_code=None)
            if resource == "request":
                if not rows:
                    raise FinOpsError("Request not found in this month's ledger.", 5)
                return rows[0]
            return dict(items=rows, page={"next_cursor": None}, note="Ledger lower bound: per-request cache and cost are unknown.")
        start, end = query_window(params["month"], params.get("from"), params.get("to"))
        cost = f"ClaudeCost(datetime({start}), datetime({end}))"
        for key, column in (("department_id", "business_unit"), ("model_id", "model"),
                            ("runtime", "client_surface"), ("tier", "tier")):
            if params.get(key):
                cost += f"\n| where {column} == {self._quote(params[key])}"
        if params.get("user_id"):
            value = self._quote(params["user_id"])
            cost += f"\n| where user_id == {value} or actor == {value}"
        if params.get("organization_id"):
            unit = self._quote(params["organization_id"])
            cost += f"\n| where business_unit == {unit} or business_unit_parent == {unit}"
        totals = ("total_tokens=sum(prompt_tokens + completion_tokens), total_requests=sum(requests), "
                  "cache_read_tokens=sum(cache_read_tokens), estimated_cost=sum(usd), unknown_prices=countif(not(priced_ok))")
        unknown = "\n| extend estimated_cost=iff(unknown_prices > 0, real(null), estimated_cost)"
        caveat = "Published workspace ClaudeCost: list-price lower bound, current published membership, cache writes unknown. "
        caveat += "In shared workspaces this is not automatically one gateway's cost; validate the published function source. Not an invoice."
        if resource == "overview":
            rows = self.query(cost + "\n| summarize " + totals + unknown)
            return dict(totals=rows[0] if rows else {}, note=caveat, accounting_scope="published-workspace-function")
        if resource == "distribution":
            dimension = params.get("dimension", "organization")
            if dimension not in DIMENSIONS:
                raise FinOpsError("Direct usage dimensions: organization, department, user, model, runtime.")
            column = ("iff(isempty(business_unit_parent), business_unit, business_unit_parent)"
                      if dimension == "organization" else DIMENSIONS[dimension])
            rows = self.query(cost + f"\n| summarize {totals} by id={column}" + unknown +
                              "\n| order by total_tokens desc | take 100")
            return dict(items=[dict(row, name=row["id"]) for row in rows], dimension=dimension,
                        note=caveat)
        if resource == "trends":
            interval = params.get("interval", "day")
            if interval not in {"day", "hour", "week"}:
                raise FinOpsError("Interval must be hour, day or week.")
            step = {"hour": "1h", "day": "1d", "week": "7d"}[interval]
            rows = self.query(cost + f"\n| summarize {totals} by bucket_start=bin(day,{step})" + unknown +
                              "\n| order by bucket_start asc")
            return dict(points=[dict(bucket_start=row.pop("bucket_start"), label="All", totals=row) for row in rows], note=caveat)
        if resource == "anomalies":
            return direct_analytics.anomalies(self, cost, params)
        raise FinOpsError("This view requires an optional AUM service or Turnstile capability.")

    def write(self, resource, body=None, **params):
        if resource.startswith("budget"):
            if params.get("month") != datetime.now(timezone.utc).strftime("%Y-%m"):
                raise FinOpsError("Direct mode changes only the current month. Use Turnstile for historical budgets.")
        if resource == "apply":
            raise FinOpsError("Direct writes use the repository scripts immediately; there is no separate apply job.")
        if resource in {"usd_budget", "usd_budget_remove", "usd_reconcile", "usd_price_book"}:
            if resource == "usd_reconcile":
                params.setdefault("workspace_id", self.config.workspace)
                params.setdefault("subscription_id", self.config.subscription)
            return self._bridge(resource, body, **params)
        return self._bridge(resource, body, **params)
