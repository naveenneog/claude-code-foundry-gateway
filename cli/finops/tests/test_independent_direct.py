from datetime import datetime, timezone
from pathlib import Path

import pytest

from claude_finops.config import Config, load_config
from claude_finops.direct import DirectBackend


def direct():
    return DirectBackend(Config(backend="direct", resource_group="rg-contoso", apim_name="apim-contoso"))


def test_no_http_profile_defaults_to_direct():
    missing = Path(__file__).resolve().parents[3] / ".aum-evidence" / "not-a-profile.json"
    assert Config().backend == "direct"
    assert load_config(missing).backend == "direct"
    assert load_config(missing, url="https://api.contoso.com", scope="api://example/Manage").backend == "turnstile"
    assert load_config(missing, backend="aum-service", url="https://service.contoso.com",
                       scope="api://example/AUM.Access").backend == "aum-service"


def test_hourly_trends_use_ledger_without_invented_cost():
    backend, queries = direct(), []
    backend.query = lambda query: queries.append(query) or [
        {"bucket_start": "2026-09-01T12:00:00Z", "total_tokens": 12, "total_requests": 1}]
    result = backend.read("trends", month="2026-09", interval="hour", group_by="none")
    assert "bin(timestamp,1h)" in queries[0]
    assert "ClaudeCost" not in queries[0]
    assert result["points"][0]["totals"]["estimated_cost"] is None


def test_direct_anomalies_run_documented_server_series_query():
    backend, queries = direct(), []
    backend.query = lambda query: queries.append(query) or [
        {"scope_id": "sales", "scope_kind": "organization", "day": "2026-09-04T00:00:00Z",
         "score": 4.5, "daily_cost": 15.0, "baseline_cost": 3.0, "flag": 1}]
    result = backend.read("anomalies", month="2026-09", limit=50)
    assert "series_decompose_anomalies" in queries[0]
    assert "priced_ok" in queries[0] and "scope_kind" in queries[0]
    assert "| where day < startofday(now())" in queries[0]
    assert result["items"][0]["severity"] in {"warning", "critical"}
    assert "statistical" in result["note"].lower()


def test_people_use_object_ids_daily_overrides_and_server_paging():
    backend, queries = direct(), []
    oid = "00000000-0000-0000-0000-000000000001"
    backend.query = lambda query: queries.append(query) or [
        {"person_id": oid, "actor": "dev@contoso.com", "user_id": oid, "tier": "standard",
         "used_tokens": 50, "window_tokens": 400, "last_seen": "2026-09-24T12:00:00Z"}]
    backend._bridge = lambda *_args, **_kwargs: dict(
        overrides={oid: 1000}, tiers=[dict(id="standard", tokens_per_day=500)],
        person_budgets_supported=True, authority="Gateway")
    result = backend.read("people", month="2026-09", department_id="sales-emea", query="dev", limit=50, offset=100)
    row = result["items"][0]
    assert "row_number()" in queries[0] and "take 50" in queries[0]
    assert "user_id" in queries[0] and "startofday" in queries[0]
    assert row["scope_id"] == oid and row["budget_period"] == "day"
    assert row["token_limit"] == 1000 and row["remaining_tokens"] == 950
    assert row["observed_window_tokens"] == 400


def test_current_person_override_calls_existing_direct_bridge():
    backend, calls = direct(), []
    backend._bridge = lambda action, body, **params: calls.append((action, body, params)) or {"verified": True}
    backend.write("budget", {"token_limit": 1000}, month=datetime.now(timezone.utc).strftime("%Y-%m"),
                  scope_type="user", scope_id="00000000-0000-0000-0000-000000000001")
    assert calls[0][0] == "budget" and calls[0][2]["scope_type"] == "user"


def test_daily_person_budget_does_not_compare_daily_allocation_to_monthly_parent():
    from claude_finops.engine import Engine
    from claude_finops.fake import FakeBackend
    backend = FakeBackend()
    original = backend.read
    def read(resource, **params):
        result = original(resource, **params)
        if resource == "people":
            result["department_available_tokens"] = 0
            for row in result["items"]:
                row.update(budget_period="day", writable=True)
        return result
    backend.read = read
    plan = Engine(backend, "2026-09").budget_change("person", "dev-001@contoso.com", "3M", department_id="sales-emea")
    assert plan["budget_period"] == "day" and plan["parent_headroom"] is None
    assert "daily" in plan["effect"].lower()


def test_direct_does_not_pretend_warning_thresholds_are_persisted():
    from claude_finops.engine import Engine
    from claude_finops.errors import FinOpsError
    backend = direct()
    def no_read(*_args, **_kwargs):
        raise AssertionError("Validate unsupported fields before calling Azure.")
    backend.read = no_read
    with pytest.raises(FinOpsError, match="warning threshold"):
        Engine(backend).budget_change("team", "sales-emea", "1M", warning=85)


def test_direct_cost_filter_accepts_the_observed_person_object_id():
    backend, queries = direct(), []
    backend.query = lambda query: queries.append(query) or [{}]
    backend.read("overview", month="2026-09", user_id="00000000-0000-0000-0000-000000000001")
    assert 'user_id == "00000000-0000-0000-0000-000000000001"' in queries[0]


def test_direct_request_ledger_binds_the_discovered_gateway_in_shared_workspaces():
    backend, queries = direct(), []
    backend.config.subscription = "00000000-0000-0000-0000-000000000001"
    backend.query = lambda query: queries.append(query) or []
    backend.read("requests", month="2026-09", limit=50)
    assert '| where _ResourceId =~ "/subscriptions/' in queries[0]
    assert "/resourceGroups/rg-contoso/providers/Microsoft.ApiManagement/service/apim-contoso" in queries[0]


def test_request_time_usage_does_not_reassign_a_test_request_with_stale_cost_membership():
    backend, queries = direct(), []
    backend.query = lambda query: queries.append(query) or [{"id": "aum-e2e-team-example", "total_tokens": 30, "total_requests": 1}]
    result = backend.read("distribution", month="2026-09", dimension="department", basis="ledger")
    assert "ApiManagementGatewayLlmLog" in queries[0] and "ClaudeCost(" not in queries[0]
    assert result["items"][0]["estimated_cost"] is None
    assert "request-time" in result["note"].lower()
