import json
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from uuid import uuid4

import httpx

from .backend import Backend
from .config import az
from .errors import FinOpsError, http_error
from .rules import identifier, month_window

DIMENSIONS = {"organization": "business_unit", "department": "business_unit", "user": "actor",
              "model": "model", "runtime": "client_surface"}


class DirectBackend(Backend):
    name = "Direct"

    def __init__(self, config):
        self.config = config.validate()
        self.root = Path(config.repository) if config.repository else Path(__file__).resolve().parents[4]
        self.bridge = self.root / "scripts" / "Invoke-ClaudeFinOps.ps1"
        if not self.bridge.exists():
            raise FinOpsError("Direct mode needs the gateway repository. Set repository in config.")
        if not config.resource_group or not config.apim_name:
            raise FinOpsError("Direct mode needs resource_group and apim_name in config.")

    def _bridge(self, action, body=None, **params):
        folder = self.root / ".finops-evidence"
        folder.mkdir(exist_ok=True)
        path = folder / f"bridge-{uuid4().hex}.json"
        try:
            path.write_text(json.dumps(dict(action=action, body=body, parameters=params)), encoding="utf-8")
            result = subprocess.run(["pwsh", "-NoProfile", "-File", str(self.bridge), "-InputFile", str(path),
                                     "-ResourceGroup", self.config.resource_group, "-ApimName", self.config.apim_name],
                                    capture_output=True, text=True, encoding="utf-8", timeout=300)
            if result.returncode:
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
        access = az("account", "get-access-token", "--resource", "https://api.loganalytics.io",
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

    def _ledger(self, month):
        start, end = month_window(month)
        source = (self.root / "analytics" / "chargeback-ledger.kql").read_text(encoding="utf-8-sig")
        return source.replace("let _from = ago(1d);", f"let _from = datetime({start});").replace(
            "let _to = now();", f"let _to = datetime({end});")

    @staticmethod
    def _quote(value):
        return json.dumps(str(value), ensure_ascii=True)

    def read(self, resource, **params):
        if resource == "whoami":
            account = json.loads(az("account", "show", "-o", "json"))
            return dict(email=account.get("user", {}).get("name", "Azure caller"), role="owner",
                        method="azure-rbac", tenant=account.get("tenantId"),
                        scope="Gateway administrator mode; Azure RBAC checks every operation")
        if resource == "apply":
            return dict(configured=False, direct=True, note="Direct writes verify named values, not a Turnstile job.", executions=[])
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
        ledger = self._ledger(params.get("month", datetime.now(timezone.utc).strftime("%Y-%m")))
        for key, column in (("department_id", "business_unit"), ("organization_id", "business_unit"),
                            ("model_id", "model"), ("user_id", "actor")):
            if params.get(key):
                ledger += f"\n| where {column} == {self._quote(params[key])}"
        if resource == "people":
            if not params.get("department_id"):
                raise FinOpsError("Choose a team for server-side people search.")
            query = str(params.get("query", ""))[:200]
            offset, limit = max(0, int(params.get("offset", 0))), min(200, max(1, int(params.get("limit", 50))))
            rows = self.query(ledger + f"\n| where actor contains {self._quote(query)}"
                              "\n| summarize used_tokens=sum(total_tokens), last_seen=max(timestamp) by actor"
                              f"\n| sort by actor asc | serialize row=row_number() | where row > {offset} | take {limit}")
            return dict(items=[dict(scope_type="user", scope_id=r["actor"], scope_name=r["actor"],
                                    parent_scope_id=params["department_id"], used_tokens=r["used_tokens"],
                                    token_limit=None, remaining_tokens=None, status="unallocated", last_seen=r["last_seen"])
                               for r in rows], offset=offset, limit=limit, total=None,
                        note="Observed people only; monthly person budgets require Turnstile.")
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
        totals = "total_tokens=sum(total_tokens), total_requests=count(), cache_read_tokens=real(null), estimated_cost=real(null)"
        if resource == "overview":
            rows = self.query(ledger + "\n| summarize " + totals)
            return dict(totals=rows[0] if rows else {}, note="Ledger tokens only. Cost and cache are not zero: they are unknown.")
        if resource == "distribution":
            dimension = params.get("dimension", "organization")
            if dimension not in DIMENSIONS:
                raise FinOpsError("Direct usage dimensions: organization, department, user, model, runtime.")
            rows = self.query(ledger + f"\n| summarize {totals} by id={DIMENSIONS[dimension]}"
                              "\n| order by total_tokens desc | take 100")
            return dict(items=[dict(row, name=row["id"]) for row in rows], dimension=dimension,
                        note="Estimated cost unavailable; use repository chargeback scripts for priced reports.")
        if resource == "trends":
            interval = params.get("interval", "day")
            if interval not in {"day", "hour", "week"}:
                raise FinOpsError("Interval must be hour, day or week.")
            step = {"hour": "1h", "day": "1d", "week": "7d"}[interval]
            rows = self.query(ledger + f"\n| summarize {totals} by bucket_start=bin(timestamp,{step}) | order by bucket_start asc")
            return dict(points=[dict(bucket_start=row.pop("bucket_start"), label="All", totals=row) for row in rows])
        if resource == "anomalies":
            return dict(items=[], note="Direct mode has no Turnstile anomaly-rule engine. Use Azure Monitor alerts; this is not an all-clear.")
        raise FinOpsError("This view requires Turnstile.")

    def write(self, resource, body=None, **params):
        if resource.startswith("budget"):
            if params.get("month") != datetime.now(timezone.utc).strftime("%Y-%m"):
                raise FinOpsError("Direct mode changes only the current month. Use Turnstile for historical budgets.")
            if params.get("scope_type") == "user":
                raise FinOpsError("Monthly person budgets require Turnstile. Daily overrides use Set-ClaudeBudget.ps1.")
        if resource == "apply":
            raise FinOpsError("Direct writes use the repository scripts immediately; there is no separate apply job.")
        return self._bridge(resource, body, **params)
