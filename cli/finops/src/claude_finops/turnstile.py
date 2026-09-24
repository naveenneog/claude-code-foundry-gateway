from urllib.parse import quote

import httpx

from .backend import Backend
from .config import token
from .errors import FinOpsError, http_error
from .rules import identifier, month_window, scope_type

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
        self._token_provider = token_provider or (lambda: token(config.scope))
        self._token = None
        self._client = httpx.Client(base_url=config.url.rstrip("/"), timeout=60,
                                    follow_redirects=False, transport=transport)

    def _request(self, method, path, params=None, body=None):
        for attempt in range(2 if method == "GET" else 1):
            if not self._token:
                self._token = self._token_provider()
            try:
                response = self._client.request(method, path, params=params, json=body,
                                                headers={"Authorization": "Bearer " + self._token})
            except httpx.HTTPError:
                raise FinOpsError("Turnstile is unreachable. Check the HTTPS URL, VPN and network; writes are not retried.", 7) from None
            if response.status_code == 401 and method == "GET" and attempt == 0:
                self._token = None
                continue
            if not 200 <= response.status_code < 300:
                raise http_error(response.status_code)
            try:
                payload = response.json()
                if not isinstance(payload, dict):
                    raise ValueError()
                return payload
            except ValueError:
                raise FinOpsError("Unexpected server response. Check the API URL and fork version.", 7) from None
        raise http_error(401)

    def read(self, resource, **params):
        if resource not in READ_ROUTES:
            raise FinOpsError("Unsupported view. Update AUM and the Turnstile fork.")
        path = READ_ROUTES[resource]
        query = {}
        if resource in {"overview", "distribution", "trends", "requests", "anomalies"}:
            start, end = month_window(params.pop("month"))
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
        if resource not in WRITE_ROUTES:
            raise FinOpsError("Unsupported change. Use a documented governance command.")
        method, path = WRITE_ROUTES[resource]
        query = {}
        if resource.startswith("budget"):
            path = path.format(scope_type=scope_type(params["scope_type"]),
                               scope_id=quote(identifier(params["scope_id"]), safe=""))
            month_window(params["month"])
            query["period"] = params["month"]
        return self._request(method, path, query, body)

    def close(self):
        self._token = None
        self._client.close()
