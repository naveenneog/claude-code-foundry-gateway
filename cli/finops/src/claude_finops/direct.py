import json
import os
from fnmatch import fnmatchcase
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from uuid import UUID, uuid4
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from contextvars import ContextVar, copy_context
from copy import deepcopy
from threading import RLock

import httpx

from .backend import Backend
from .config import (az, resource_token, bind_resource_principal,
                     invalidate_resource_principal, validate_resource_principal, resource_principal_guard)
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
    identity_independent_reads = frozenset({
        "overview", "budgets", "catalog", "tiers", "distribution", "trends",
        "people", "requests", "request", "anomalies", "apply",
    })

    def __init__(self, config):
        self.config = config.validate()
        self._cycle = ContextVar("direct_read_cycle", default=None)
        self._prepare_lock = RLock()
        self._client = None
        self._credential_context = None
        self.root = Path(config.repository) if config.repository else Path(__file__).resolve().parents[4]
        self.bridge = self.root / "scripts" / "Invoke-ClaudeFinOps.ps1"
        if not self.bridge.exists():
            raise FinOpsError("Direct mode needs the gateway repository. Set repository in config.")
        if not config.resource_group or not config.apim_name:
            raise FinOpsError("Run aum configure to discover the Direct gateway and workspace, or set resource_group and apim_name.")

    @contextmanager
    def read_cycle(self):
        if self._cycle.get() is not None:
            yield
            if self._cycle.get().get("has_data"):
                self._check_read_cycle()
            return
        context = self._cycle.set({"lock": RLock(), "account_lock": RLock()})
        try:
            yield
            if self._cycle.get().get("has_data"):
                self._check_read_cycle()
        finally:
            self._cycle.reset(context)

    def _check_read_cycle(self):
        cycle = self._cycle.get()
        if cycle is not None:
            credential = cycle.get("credential")
            if credential is None:
                raise FinOpsError("Azure sign-in changed. Start a new read cycle for the current principal.", 3)
            self._check_credential(credential)

    def read_guard(self):
        cycle = self._cycle.get()

        @contextmanager
        def publish():
            with self._prepare_lock:
                credential = cycle.get("credential") if cycle is not None else None
                if credential is not None:
                    with resource_principal_guard(credential):
                        self._check_credential(credential)
                        yield
                elif cycle is not None and cycle.get("has_data"):
                    raise FinOpsError("Azure sign-in changed. Start a new read cycle before publishing data.", 3)
                else:
                    yield

        return publish

    def identity_update(self):
        return self._prepare_lock

    def _snapshot(self, resource="read"):
        cycle = self._cycle.get()
        if cycle is None:
            return self._bridge(resource)
        self.prepare_read(resource)
        cycle["has_data"] = True
        with cycle["lock"]:
            if "value" not in cycle:
                cycle["value"] = self._bridge("read", snapshot=True)
            state = cycle["value"]
            if resource == "read":
                result = deepcopy(state)
            else:
                result = state.get("reads", {}).get(resource)
                if not isinstance(result, dict):
                    raise FinOpsError(f"Gateway snapshot has no {resource} result. Refresh the current gateway scripts.", 7)
                if result.get("error"):
                    raise FinOpsError(result["error"], result.get("exit_code", 7))
                result = deepcopy(result)
            self._check_read_cycle()
            return result

    def _invalidate_snapshot(self):
        cycle = self._cycle.get()
        if cycle is not None:
            with cycle["lock"]:
                cycle.pop("value", None)

    def prepare_read(self, resource):
        self._account()
        if not self.config.subscription:
            raise FinOpsError("Cannot determine the selected Azure subscription. Run aum configure before querying the gateway ledger.", 3)
        if self._credential_context is None:
            raise FinOpsError("Cannot verify the Azure principal. Run az login before querying current data.", 3)

    def _account(self):
        cycle = self._cycle.get()
        with cycle["account_lock"] if cycle is not None else self._prepare_lock:
            if cycle is not None and "credential" in cycle:
                self._check_read_cycle()
                return cycle["account"]
            try:
                with self._prepare_lock:
                    account = json.loads(self._az("account", "show", "-o", "json"))
                    if not isinstance(account, dict):
                        raise ValueError()
                    if not self.config.subscription and account.get("id"):
                        self.config.subscription = str(UUID(account["id"]))
                    tenant = account.get("tenantId") or self.config.tenant_id
                    person = account.get("user", {}).get("name")
                    if tenant and person:
                        directory = Path(os.environ.get("AZURE_CONFIG_DIR", str(Path.home() / ".azure"))).resolve()
                        session = f"{directory}|{self.config.subscription}|{self.config.tenant_id}"
                        self._credential_context = bind_resource_principal((tenant, person), session)
                        if cycle is not None:
                            cycle["credential"] = self._credential_context
                            cycle["account"] = account
                    else:
                        self.invalidate_credentials()
                    return account
            except (ValueError, KeyError, TypeError, AttributeError):
                raise FinOpsError("Cannot verify the Azure account and subscription. Run aum configure before reading data.", 3) from None

    def invalidate_credentials(self):
        invalidate_resource_principal(self._credential_context)
        self._credential_context = None
        self._invalidate_snapshot()
        cycle = self._cycle.get()
        if cycle is not None:
            with cycle["account_lock"]:
                cycle.pop("account", None)

    def _check_credential(self, credential):
        validate_resource_principal(credential)
        if credential != self._credential_context:
            raise FinOpsError("Azure sign-in changed. Refresh the current principal before reading data.", 3)

    def close(self):
        self.invalidate_credentials()
        with self._prepare_lock:
            if self._client is not None:
                self._client.close()
                self._client = None

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
        self.prepare_read("query")
        cycle = self._cycle.get()
        credential = cycle["credential"] if cycle is not None else self._credential_context
        if credential is None:
            raise FinOpsError("Azure sign-in changed. Refresh the current principal before reading data.", 3)
        access = resource_token("https://api.loganalytics.io", self.config.subscription,
                                self.config.tenant_id, runner=az, credential=credential)
        try:
            self._check_credential(credential)
            with self._prepare_lock:
                if self._client is None:
                    self._client = httpx.Client(timeout=90)
                client = self._client
            response = client.post(f"https://api.loganalytics.io/v1/workspaces/{workspace}/query",
                                   headers={"Authorization": "Bearer " + access}, json={"query": kql})
            self._check_credential(credential)
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
        cycle = self._cycle.get()
        if cycle is not None and resource != "whoami":
            self.prepare_read(resource)
        result = self._read(resource, **params)
        if cycle is not None and resource != "whoami":
            cycle["has_data"] = True
            self._check_read_cycle()
        return result

    def _read(self, resource, **params):
        if resource == "capabilities":
            identity = params.get("identity") or self.read("whoami")
            result = current_capabilities(identity)
            state = self._snapshot()
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
            account = self._account()
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
            return self._snapshot(resource)
        if resource in {"catalog", "tiers", "budgets"}:
            if resource == "catalog":
                return self._snapshot()["catalog"]
            if resource == "tiers":
                return dict(items=self._snapshot()["tiers"])
            month = params["month"]
            with ThreadPoolExecutor(max_workers=1) as pool:
                pending = pool.submit(copy_context().run, self.query,
                                      self._ledger(month) + "\n| summarize used_tokens=sum(total_tokens) by business_unit")
                state = self._snapshot()
                usage = pending.result()
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
            parents = self._snapshot().get("parents", {})
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
        if resource == "usd_reconcile":
            params.setdefault("workspace_id", self.config.workspace)
            params.setdefault("subscription_id", self.config.subscription)
        self._invalidate_snapshot()
        try:
            return self._bridge(resource, body, **params)
        finally:
            self._invalidate_snapshot()
