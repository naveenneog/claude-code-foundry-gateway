import json
from importlib.resources import files

from claude_finops.turnstile import READ_ROUTES, WRITE_ROUTES
from claude_finops.views import TABS


def test_every_release_page_and_endpoint_has_a_face():
    parity = json.loads(files("claude_finops").joinpath("parity.json").read_text())
    assert set(parity["pages"]) == {
        "Executive Overview", "Budget Management", "People panel", "Gateway governance",
        "Usage Breakdown", "Usage Trends", "Request Trace", "Anomaly Governance findings", "Settings",
    }
    assert {page["tab"] for page in parity["pages"].values()} == {tab for tab, _ in TABS}
    assert {op for page in parity["pages"].values() for op in page["reads"]} == set(READ_ROUTES)
    assert {op for page in parity["pages"].values() for op in page["writes"]} == set(WRITE_ROUTES)
    assert set(READ_ROUTES.values()) == {
        "/api/v1/auth/me", "/api/v1/budgets", "/api/v1/budgets/users", "/api/v1/enterprise-catalog",
        "/api/v1/gateway-tiers", "/api/v1/gateway-apply",
        *{"/api/v1/observability/" + suffix for suffix in (
            "executive-overview", "distribution", "trends", "requests", "requests/{request_id}", "anomalies")},
    }
    assert set(WRITE_ROUTES.values()) == {
        ("PUT", "/api/v1/budgets/{scope_type}/{scope_id}"),
        ("DELETE", "/api/v1/budgets/{scope_type}/{scope_id}"),
        ("PUT", "/api/v1/enterprise-catalog"), ("PUT", "/api/v1/gateway-tiers"),
        ("POST", "/api/v1/gateway-apply"),
    }


def test_future_features_are_explicit_not_claimed_shipped():
    parity = json.loads(files("claude_finops").joinpath("parity.json").read_text())
    assert "Approvals" in parity["deferred"]
    assert "FinOps Assistant" in parity["deferred"]
