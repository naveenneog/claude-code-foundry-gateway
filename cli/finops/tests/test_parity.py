import json
from importlib.resources import files
from pathlib import Path

from claude_finops.views import TABS
from claude_finops.ui_features import EXTRA_TABS
from claude_finops.turnstile import READ_ROUTES, WRITE_ROUTES

ROWS = {"Executive Overview", "Budget Management", "People panel", "Gateway governance",
        "Usage Breakdown", "Usage Trends", "Request Trace", "Anomaly Governance",
        "Approvals", "FinOps Assistant", "Settings", "Advanced model gateway"}


def test_every_revision_four_row_is_implemented_or_waits_on_named_contract():
    parity = json.loads(files("claude_finops").joinpath("parity.json").read_text())
    contracts = json.loads(files("claude_finops").joinpath("contracts.json").read_text())
    assert set(parity["pages"]) == ROWS
    assert {page["tab"] for page in parity["pages"].values()} == {tab for tab, _ in TABS + EXTRA_TABS}
    for page in parity["pages"].values():
        assert page["status"] in {"implemented", "waiting"}
        if page["status"] == "waiting":
            assert page["endpoint"] in contracts["endpoints"]
        for endpoint in page.get("waiting", {}).values():
            assert endpoint in contracts["endpoints"]
        assert page["features"] and page["tests"]
        for test in page["tests"]:
            assert (Path(__file__).parent / test).exists()


def test_original_release_endpoints_cannot_be_dropped():
    assert set(READ_ROUTES.values()) == {
        "/api/v1/auth/me", "/api/v1/budgets", "/api/v1/budgets/users", "/api/v1/enterprise-catalog",
        "/api/v1/gateway-tiers", "/api/v1/gateway-apply",
        *{"/api/v1/observability/" + suffix for suffix in (
            "executive-overview", "distribution", "trends", "requests", "requests/{request_id}", "anomalies")},
    }
    assert set(WRITE_ROUTES.values()) == {
        ("PUT", "/api/v1/budgets/{scope_type}/{scope_id}"), ("DELETE", "/api/v1/budgets/{scope_type}/{scope_id}"),
        ("PUT", "/api/v1/enterprise-catalog"), ("PUT", "/api/v1/gateway-tiers"), ("POST", "/api/v1/gateway-apply"),
    }


def test_no_generic_deferred_bucket_hides_revision_four_gaps():
    parity = json.loads(files("claude_finops").joinpath("parity.json").read_text())
    assert "deferred" not in parity
    required = {"lookup_palette", "breadcrumbs", "exact_focus", "preview_apply_confirmation",
                "scope_hidden_actions", "plain_screen_reader", "local_time_offsets"}
    assert required <= set(parity["cross_cutting"]["features"])


def test_independent_backends_and_native_server_gaps_are_explicit():
    parity = json.loads(files("claude_finops").joinpath("parity.json").read_text())
    backends = parity["backends"]
    assert set(backends) == {"direct", "aum-service", "turnstile"}
    assert backends["direct"]["default_when_no_http_profile"]
    assert backends["turnstile"]["optional"]
    assert "daily_person_overrides" in backends["direct"]["implemented"]
    assert "reason_and_if_match" in backends["aum-service"]["implemented"]
    assert all(value.startswith(("GET ", "POST ", "DELETE ", "interval=", "assistant API"))
               for value in backends["aum-service"]["unavailable_in_contract_1_0_3"].values())
