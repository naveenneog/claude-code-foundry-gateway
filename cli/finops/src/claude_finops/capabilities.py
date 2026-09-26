"""Versioned, role-aware capability gates. Unknown versions and actions fail closed."""

from .errors import FinOpsError

FUTURE_ENDPOINTS = {
    "approvals": "/api/v1/budget-requests",
    "boosts": "/api/v1/budget-boosts",
    "notifications": "/api/v1/notifications",
    "request_cursor": "/api/v1/observability/requests (cursor contract)",
    "conditional_writes": "ETag / If-Match on catalog and tiers",
    "anomaly_dispositions": "/api/v1/observability/anomalies/{id}/disposition",
    "global_search": "/api/v1/search",
    "usd_budgets": "/api/v1/usd-budgets and /api/v1/usd-budget-status",
}
READ_FEATURES = {
    "approval_requests": "approvals", "approval_request": "approvals", "global_search": "global_search",
    "boosts": "boosts", "notifications": "notifications",
    "assistant_settings": "assistant", "conversations": "assistant", "conversation": "assistant",
    "pinned_charts": "assistant", "pinned_chart": "assistant",
    "registry": "advanced", "backend_pool": "advanced", "releases": "advanced",
    "release": "advanced", "release_diff": "advanced", "applications": "advanced",
    "application": "advanced",
    "audit": "audit_read",
    "usd_budgets": "usd_budgets", "usd_status": "usd_budgets", "usd_price_book": "usd_budgets",
}
WRITE_FEATURES = {
    "approval_create": ("approvals", "request"), "approval_decide": ("approvals", "approve"),
    "approval_escalate": ("approvals", "escalate"), "boost_create": ("boosts", "create"),
    "boost_revoke": ("boosts", "revoke"), "notification_read": ("notifications", "mark_read"),
    "disposition": ("anomaly_dispositions", "acknowledge"), "assistant_ask": ("assistant", "ask"),
    "pin_chart": ("assistant", "pin"), "assistant_settings": ("assistant", "configure"),
    "conversation_rename": ("assistant", "manage"), "conversation_delete": ("assistant", "manage"),
    "pin_remove": ("assistant", "pin"), "bulk_budget": ("bulk_budget", "write"),
    "usd_budget": ("usd_budgets", "write"), "usd_budget_remove": ("usd_budgets", "write"),
    "usd_reconcile": ("usd_budgets", "reconcile"), "usd_price_book": ("usd_budgets", "price_book_write"),
}


def enabled(document, feature, action="read"):
    if not isinstance(document, dict) or document.get("schema_version") != 1:
        return False
    features = document.get("features")
    if not isinstance(features, dict):
        return False
    value = features.get(feature, {})
    return (isinstance(value, dict) and value.get("enabled") is True
            and isinstance(value.get("actions"), list) and action in value["actions"])


def require(document, feature, action="read"):
    if not enabled(document, feature, action):
        endpoint = FUTURE_ENDPOINTS.get(feature, feature)
        raise FinOpsError(f"Not available for this sign-in: {feature}. Waiting on advertised endpoint {endpoint}.", 5)


def current_capabilities(identity):
    owner = identity.get("role") == "owner" and identity.get("manager_scope") is None
    return {"schema_version": 1, "advertised": False, "features": {
        "budget_modes": {"enabled": True, "actions": ["read", "write"] if owner else ["read"]},
        "bulk_budget": {"enabled": owner, "actions": ["write"] if owner else []},
    }}


def redact_credentials(value):
    secret_keys = {"api_key", "apikey", "access_token", "refresh_token", "client_secret", "password",
                   "primary_key", "secondary_key", "authorization", "encrypted_credentials", "secret"}
    if isinstance(value, dict):
        return {k: "[credential omitted]" if k.lower() in secret_keys else redact_credentials(v)
                for k, v in value.items()}
    if isinstance(value, list):
        return [redact_credentials(v) for v in value]
    return value
