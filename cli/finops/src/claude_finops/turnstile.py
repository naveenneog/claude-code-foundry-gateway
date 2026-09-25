from urllib.parse import quote

import httpx

from .backend import Backend
from .config import token
from .errors import FinOpsError, http_error
from .rules import identifier, month_window, scope_type, query_window
from .feature_routes import READ_ROUTES as FEATURE_READS, WRITE_ROUTES as FEATURE_WRITES
from .capabilities import current_capabilities, enabled, redact_credentials

READ_ROUTES = {
    "whoami": "/api/v1/auth/me",
    "overview": "/api/v1/observability/executive-overview",
    "distribution": "/api/v1/observability/distribution",
    "trends": "/api/v1/observability/trends",
    "requests": "/api/v1/observability/requests",
    "request": "/api/v1/observability/requests/{request_id}",
    "anomalies": "/api/v1/observability/anomalies",
    "budgets": "/api/v1/budgets",
    "people": "/api/v1/budgets/users",
    "catalog": "/api/v1/enterprise-catalog",
    "tiers": "/api/v1/gateway-tiers",
    "apply": "/api/v1/gateway-apply",
}
WRITE_ROUTES = {
    "budget": ("PUT", "/api/v1/budgets/{scope_type}/{scope_id}"),
    "budget_remove": ("DELETE", "/api/v1/budgets/{scope_type}/{scope_id}"),
    "catalog": ("PUT", "/api/v1/enterprise-catalog"),
    "tiers": ("PUT", "/api/v1/gateway-tiers"),
    "apply": ("POST", "/api/v1/gateway-apply"),
}


class TurnstileBackend(Backend):
    name = "Turnstile"

    def __init__(self, config, token_provider=None, transport=None):
        config.validate()
        self.config = config
        self._token_provider = token_provider or (lambda: token(config.scope, config.subscription))
        self._token = None
        self._features = None
        self._etags = {}
        self._client = httpx.Client(base_url=config.url.rstrip("/"), timeout=60,
                                    follow_redirects=False, transport=transport)

    def _request(self, method, path, params=None, body=None, extra_headers=None, optional=False):
        for attempt in range(2 if method == "GET" else 1):
            if not self._token:
                self._token = self._token_provider()
            try:
                response = self._client.request(method, path, params=params, json=body,
                                                headers={"Authorization": "Bearer " + self._token, **(extra_headers or {})})
            except httpx.HTTPError:
                raise FinOpsError("Turnstile is unreachable. Check the HTTPS URL, VPN and network; writes are not retried.", 7) from None
            if response.status_code == 401 and method == "GET" and attempt == 0:
                self._token = None
                continue
            if not 200 <= response.status_code < 300:
                if optional and response.status_code in {403, 404, 405}:
                    return None
                raise http_error(response.status_code)
            if response.status_code == 204:
                return {"deleted": True}
            if response.headers.get("ETag"):
                self._etags[path] = response.headers["ETag"]
            try:
                payload = response.json()
                if not isinstance(payload, dict):
                    raise ValueError()
                return payload
            except ValueError:
                if optional and "text/html" in response.headers.get("content-type", ""):
                    return None
                raise FinOpsError("Unexpected server response. Check the API URL and fork version.", 7) from None
        raise http_error(401)

    def read(self, resource, **params):
        if resource == "capabilities":
            identity = params.get("identity") or self.read("whoami")
            document = current_capabilities(identity)
            advertised = self._request("GET", "/api/v1/finops/capabilities", optional=True)
            if advertised and advertised.get("schema_version") == 1 and isinstance(advertised.get("features"), dict):
                document["features"].update(advertised["features"])
                document["advertised"] = True
            if identity.get("manager_scope") is None:
                settings = self._request("GET", FEATURE_READS["assistant_settings"], optional=True)
                if settings and "model_available" in settings:
                    actions = ["read", "ask", "pin", "manage"]
                    if identity.get("role") == "owner":
                        actions.append("configure")
                    document["features"]["assistant"] = dict(enabled=True, actions=actions, model_available=settings["model_available"])
                registry = self._request("GET", FEATURE_READS["registry"], optional=True)
                if registry and registry.get("gateways") and registry.get("models"):
                    document["features"]["advanced"] = dict(enabled=True, actions=["read"])
            self._features = document
            return document
        if resource in FEATURE_READS:
            path = FEATURE_READS[resource]
            if resource == "boosts":
                params["period"] = params["month"]
            params.pop("month", None)
            if "{id}" in path:
                path = path.format(id=quote(identifier(params.pop("id")), safe=""))
            return redact_credentials(self._request("GET", path, {k: v for k, v in params.items() if v is not None}))
        if resource not in READ_ROUTES:
            raise FinOpsError("Unsupported view. Update AUM and the Turnstile fork.")
        path = READ_ROUTES[resource]
        query = {}
        tier = params.pop("tier", None)
        if tier:
            params["project_id"] = tier if tier.startswith("tier-") else "tier-" + tier
        if params.get("dimension") == "tier":
            params["dimension"] = "project"
        if resource in {"overview", "distribution", "trends", "requests", "anomalies"}:
            start, end = query_window(params.pop("month"), params.pop("from", None), params.pop("to", None))
            query.update({"from": start, "to": end})
            if params.get("before"):
                query["to"] = params.pop("before")
        elif resource in {"budgets", "people"}:
            query["period"] = params.pop("month")
            month_window(query["period"])
        if resource == "request":
            path = path.format(request_id=quote(identifier(params.pop("request_id")), safe=""))
        params.pop("month", None)
        query.update({k: v for k, v in params.items() if v is not None and v != ""})
        return self._request("GET", path, query)

    def write(self, resource, body=None, **params):
        if resource in FEATURE_WRITES:
            method, path = FEATURE_WRITES[resource]
            if "{id}" in path:
                path = path.format(id=quote(identifier(params.pop("id")), safe=""))
            query = {"period": params["month"]} if resource == "bulk_budget" else {}
            headers = {"Idempotency-Key": params["idempotency_key"]} if params.get("idempotency_key") else {}
            return redact_credentials(self._request(method, path, query, body, headers))
        if resource not in WRITE_ROUTES:
            raise FinOpsError("Unsupported change. Use a documented governance command.")
        method, path = WRITE_ROUTES[resource]
        if resource in {"catalog", "tiers"} and self._features is None:
            self.read("capabilities")
        query = {}
        if resource.startswith("budget"):
            path = path.format(scope_type=scope_type(params["scope_type"]),
                               scope_id=quote(identifier(params["scope_id"]), safe=""))
            month_window(params["month"])
            query["period"] = params["month"]
        headers = {}
        if resource in {"catalog", "tiers"} and enabled(self._features or {}, "conditional_writes", "write"):
            if path not in self._etags:
                raise FinOpsError("Refresh the collection before applying: its ETag is required.", 6)
            headers["If-Match"] = self._etags[path]
        return self._request(method, path, query, body, headers)

    def close(self):
        self._token = None
        self._client.close()
