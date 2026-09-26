"""P55 mutations: one audited intent, one revision, no write retry."""

from copy import deepcopy
from datetime import datetime, timezone, timedelta
from urllib.parse import quote

from .capabilities import require
from .errors import FinOpsError
from .rules import identifier


def write(backend, resource, body, params):
    if resource in {"budget", "budget_remove"} and params.get("month") != datetime.now(timezone.utc).strftime("%Y-%m"):
        raise FinOpsError("AUM service changes current gateway limits only. Select the current month.")
    capabilities = backend._features or backend.read("capabilities")
    body = deepcopy(body or {})
    reason = params.get("reason") or body.get("reason")
    if resource != "usd_reconcile" and (not isinstance(reason, str) or not 1 <= len(reason.strip()) <= 500):
        raise FinOpsError("AUM service changes require an audit reason of 1–500 characters. Pass --reason or fill the form.")
    method, revision = "PUT", True
    escape = lambda key: quote(identifier(key), safe="")
    if resource in {"budget", "budget_remove"}:
        require(capabilities, "native_writes", "budget")
        path = f"budgets/{params['scope_type']}/{escape(params['scope_id'])}"
        if resource == "budget_remove":
            method, body = "DELETE", {}
    elif resource in {"usd_budget", "usd_budget_remove"}:
        require(capabilities, "usd_budgets", "write")
        path = f"usd-budgets/{params['scope_type']}/{escape(params['scope_id'])}"
        if resource == "usd_budget_remove":
            method, body = "DELETE", {}
    elif resource == "usd_reconcile":
        require(capabilities, "usd_budgets", "reconcile")
        method, path, revision, body = "POST", "usd-budget-reconcile", False, {}
    elif resource == "usd_price_book":
        require(capabilities, "usd_budgets", "price_book_write")
        path = "usd-price-book"
    elif resource == "mode":
        require(capabilities, "native_writes", "mode")
        path = "modes/" + escape(params["scope_id"])
        body = dict(enforcement=body["mode"], **({"allowance_percent": body["allowance_percent"]}
                    if body.get("allowance_percent") is not None else {}))
    elif resource == "tiers":
        require(capabilities, "native_writes", "tiers")
        before = {row["id"]: row for row in backend._tiers}
        changed = [row for row in body["tiers"] if any(row.get(key) != before.get(row["id"], {}).get(key)
                   for key in ("tokens_per_day", "tokens_per_minute", "models"))]
        if not changed:
            return dict(verified=True, changed=False)
        if len(changed) != 1:
            raise FinOpsError("Save one tier per preview; the AUM service endpoint is per tier.")
        target = changed[0]
        path = "tiers/" + escape(target["id"])
        body = {key: target[key] for key in ("tokens_per_day", "tokens_per_minute", "models")}
    elif resource == "catalog":
        require(capabilities, "native_writes", "catalog")
        path, body = catalog_change(backend, body, escape)
    elif resource == "approval_create":
        require(capabilities, "approvals", "request")
        if body.get("expires_at"):
            raise FinOpsError("This AUM service budget-request contract has no request expiry; use an explicit boost instead.")
        if body.get("period") != datetime.now(timezone.utc).strftime("%Y-%m"):
            raise FinOpsError("AUM service budget requests concern current limits. Select the current month.")
        method, path, revision = "POST", "budget-requests", False
        body = {key: body[key] for key in ("scope_type", "scope_id", "token_limit")}
    elif resource in {"approval_decide", "approval_escalate"}:
        action = "escalate" if resource == "approval_escalate" else body["decision"]
        require(capabilities, "approvals", action)
        method, path, revision = "POST", f"budget-requests/{escape(params['id'])}/{action}", False
        body = dict(version=int(body["revision"]))
    elif resource == "boost_create":
        require(capabilities, "boosts", "create")
        if body.get("window") != "daily":
            raise FinOpsError("AUM service person boosts are daily. Use --window daily.")
        expiry = datetime.fromisoformat(body["expires_at"].replace("Z", "+00:00"))
        if expiry > datetime.now(timezone.utc) + timedelta(days=31):
            raise FinOpsError("AUM service boosts expire within 31 days.")
        budgets = backend._budgets
        previous = next((row["token_limit"] for row in budgets if row["scope_type"] == "user"
                         and row["scope_id"] == body["scope_id"]), None)
        if previous is None:
            previous = max((row["tokens_per_day"] for row in backend._get("tiers")["items"]), default=0)
        method, path = "POST", "boosts"
        body = dict(scope_type="user", scope_id=body["scope_id"], token_limit=previous + body["extra_tokens"],
                    expires_at=body["expires_at"])
    else:
        raise FinOpsError("This mutation is not offered by the AUM service contract.", 5)
    if resource != "usd_reconcile":
        body["reason"] = reason.strip()
    headers = {}
    if revision:
        if not backend._revision:
            raise FinOpsError("Read and preview current budgets before applying; the service requires If-Match.", 6)
        headers["If-Match"] = '"' + backend._revision.strip('"') + '"'
    result = backend._request(method, "/api/v1/" + path, body=body, extra_headers=headers)
    if result.get("revision"):
        backend._revision = result["revision"]
    return result


def catalog_change(backend, body, escape):
    before = backend._catalog or {}
    old = {row["id"]: row for name in ("organizations", "departments") for row in before.get(name, [])}
    wanted = [dict(row, parent_id=None) for row in body.get("organizations", [])] + body.get("departments", [])
    managers = [row for row in wanted if row.get("attributes", {}).get("manager_group_id") !=
                old.get(row["id"], {}).get("attributes", {}).get("manager_group_id")]
    if managers:
        def membership(row):
            return {key: row.get(key) for key in ("id", "name", "parent_id", "external_ref")}
        if len(managers) != 1 or set(old) != {row["id"] for row in wanted} or any(
                membership(row) != membership(old[row["id"]]) for row in wanted):
            raise FinOpsError("Save catalog and manager-group changes in separate previews; the service uses separate endpoints.")
        row = managers[0]
        return "manager-groups/" + escape(row["id"]), dict(manager_group_id=row.get("attributes", {}).get("manager_group_id"))
    return "catalog", dict(entities=wanted)
