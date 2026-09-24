import json
import logging
import re
from uuid import uuid4

from .errors import AccessDenied, ServiceError, invalid
from .queries import QueryBuilder, page_size
from .workflows import Workflows


class Api:
    def __init__(self, service, verifier):
        self.service, self.verifier = service, verifier
        self.reads = QueryBuilder(service)
        self.workflows = Workflows(service)

    def handle(self, method, path, params, raw_body, headers):
        request_id = str(uuid4())
        response_headers = {"Cache-Control": "no-store", "X-Content-Type-Options": "nosniff",
                            "X-Request-ID": request_id, "Content-Type": "application/json"}
        try:
            normalized = {k.lower(): v for k, v in headers.items()}
            header = normalized.get("authorization", "")
            scheme, _, token = header.partition(" ")
            if scheme.lower() != "bearer" or not token:
                raise AccessDenied("A bearer access token is required", status=401)
            identity = self.verifier.verify(token)
            if method not in {"GET", "POST", "PUT", "DELETE"}:
                raise ServiceError(405, "method_not_allowed", "Method is not supported")
            if len(raw_body) > 65536:
                raise ServiceError(413, "body_too_large", "Request body exceeds 64 KiB")
            try:
                body = json.loads(raw_body) if raw_body else {}
            except (ValueError, UnicodeDecodeError) as error:
                raise invalid("Body must be valid JSON") from error
            if not isinstance(body, dict):
                raise invalid("Body must be a JSON object")
            route = path.rstrip("/")
            if not route.startswith("/api/v1/"):
                raise ServiceError(404, "not_found", "Route not found")
            route = route[len("/api/v1/"):]
            result, status = self.dispatch(method, route, identity, params, body, normalized.get("if-match"))
            return status, result, response_headers
        except ServiceError as error:
            if error.status == 401:
                response_headers["WWW-Authenticate"] = "Bearer"
            return error.status, {"error": {"code": error.code, "message": str(error),
                                           "request_id": request_id}}, response_headers
        except Exception:
            logging.error("AUM dependency failure; request_id=%s", request_id)
            return 503, {"error": {"code": "dependency_unavailable",
                                  "message": "A required Azure service is unavailable. Read state before retrying a write.",
                                  "request_id": request_id}}, response_headers

    @staticmethod
    def fields(body, allowed, required=()):
        if set(body) - set(allowed) or set(required) - set(body):
            raise invalid("Request fields do not match the API contract")

    def dispatch(self, method, route, identity, params, body, revision):
        if method == "GET":
            if body:
                raise invalid("GET requests cannot have a body")
            simple = {"me": self.service.me, "auth/me": self.service.me,
                      "capabilities": self.service.capabilities,
                      "budgets": self.service.budgets, "catalog": self.service.catalog}
            if route in simple:
                if params:
                    raise invalid("This route does not accept query parameters")
                return simple[route](identity), 200
            if route in {"usage", "trends", "people", "requests"}:
                return self.reads.read(route, identity, params), 200
            if route == "tiers":
                _, config, _, _ = self.service.context(identity)
                return {"items": [config.tier(t) for t in ("standard", "premium")], "next_cursor": None}, 200
            if route in {"budget-requests", "boosts", "notifications", "audit"}:
                return self.records(identity, route, params), 200
        else:
            if params:
                raise invalid("Mutation routes do not accept query parameters")
            budget = re.fullmatch(r"budgets/(organization|department|user)/([^/]+)", route)
            if budget and method in {"PUT", "DELETE"}:
                self.fields(body, ["reason", "token_limit", "warning_threshold_percent"] if method == "PUT" else ["reason"],
                            ["reason", "token_limit"] if method == "PUT" else ["reason"])
                if method == "PUT" and body["token_limit"] is None:
                    raise invalid("Use DELETE to clear a budget")
                return self.service.set_budget(identity, *budget.groups(),
                                               {**body, **({"token_limit": None} if method == "DELETE" else {})},
                                               revision), 200
            config = re.fullmatch(r"(tiers|modes|manager-groups)/([^/]+)", route)
            if method == "PUT" and (config or route == "catalog"):
                category, key = config.groups() if config else ("catalog", "")
                kind = {"tiers": "tier", "modes": "mode", "manager-groups": "manager", "catalog": "catalog"}[category]
                fields = {"tier": ["tokens_per_day", "tokens_per_minute", "models"],
                          "mode": ["enforcement", "allowance_percent"],
                          "manager": ["manager_group_id"], "catalog": ["entities"]}[kind]
                self.fields(body, ["reason", *fields], ["reason", *[f for f in fields if f != "allowance_percent"]])
                return self.service.configure(identity, kind, key, body, revision), 200
            if route in {"budget-requests", "boosts"} and method == "POST":
                fields = ["scope_type", "scope_id", "token_limit", "reason"]
                if route == "boosts":
                    fields.append("expires_at")
                self.fields(body, fields, fields)
                return (self.workflows.request(identity, body) if route == "budget-requests"
                        else self.workflows.boost(identity, body, revision)), 201
            decision = re.fullmatch(r"budget-requests/([0-9a-f-]{36})/(approve|reject|escalate)", route)
            if decision and method == "POST":
                self.fields(body, ["reason", "version"], ["reason", "version"])
                return self.workflows.decide(identity, *decision.groups(), body), 200
        raise ServiceError(404, "not_found", "Route not found")

    def records(self, identity, route, params):
        if set(params) - {"limit", "cursor"}:
            raise invalid("Unknown query parameter")
        limit = page_size(params)
        cursor = params.get("cursor")
        if cursor and (not isinstance(cursor, str) or len(cursor) > 200 or not re.fullmatch(r"[A-Za-z0-9:._-]+", cursor)):
            raise invalid("Invalid cursor")
        _, config, mappings, scope = self.service.context(identity)
        if route == "audit":
            identity.require_admin()
        if route == "budget-requests":
            identity.require_writer()
        def visible(row):
            if route == "budget-requests":
                return identity.is_admin or row.get("requester") == identity.oid or self.workflows.can_approve(identity, row, mappings)
            if scope is None:
                return True
            if row.get("scope_type") == "user":
                leaf = self.service.members(config, [row["scope_id"]]).get(row["scope_id"])
                return scope.contains_leaf(leaf)
            return scope.contains_leaf(row.get("scope_id"))
        kind = "requests" if route == "budget-requests" else route
        rows, after = self.service.store.list(kind, limit=limit, after=cursor, filters=visible)
        return {"items": rows, "next_cursor": after}
