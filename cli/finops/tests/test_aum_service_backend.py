import json

import httpx
import pytest

from claude_finops.backend import connect
from claude_finops.config import Config
from claude_finops.engine import Engine
from claude_finops.errors import FinOpsError

CONFIG = Config(backend="aum-service", url="https://aum.contoso.com", scope="api://example/AUM.Access")
OID = "00000000-0000-0000-0000-000000000001"


def service(responder=None, scope=None, access="admin"):
    from claude_finops.aum_service import AumServiceBackend
    calls = []
    def respond(request):
        calls.append(request)
        if responder:
            custom = responder(request)
            if custom is not None:
                return custom
        path = request.url.path
        body = {
            "/api/v1/me": dict(id=OID, email="admin@contoso.com", role="owner" if access == "admin" else "member",
                              access=access, method="entra", manager_scope=scope),
            "/api/v1/capabilities": dict(schema_version=1, backend="aum-service", limits={"page_size": 200},
                capabilities=dict(usage_read=True, budgets_read=True, budget_write=access != "viewer",
                    catalog_write=access == "admin", tiers_write=access == "admin", modes_write=access == "admin",
                    budget_requests=access != "viewer", approvals=access != "viewer", boosts=access != "viewer",
                    notifications=True, audit_read=access == "admin")),
            "/api/v1/catalog": dict(organizations=[dict(id="sales", name="Sales", parent_id=None,
                external_ref="entra-group:contoso-sales", attributes={})],
                departments=[dict(id="sales-emea", name="Sales EMEA", parent_id="sales",
                                  external_ref="entra-group:contoso-sales-emea", attributes={})], revision="revision-1"),
            "/api/v1/budgets": dict(revision="revision-1", items=[
                dict(scope_type="organization", scope_id="sales", token_limit=10000000, period="month", writable=True),
                dict(scope_type="department", scope_id="sales-emea", token_limit=5000000, period="month", writable=True),
                dict(scope_type="user", scope_id=OID, token_limit=1000, period="day", writable=True)]),
            "/api/v1/usage": dict(requests=5, prompt_tokens=20, completion_tokens=10, cache_read_tokens=100,
                                 usd=.2, unpriced_rows=0, as_of="2026-09-25T00:00:00Z"),
            "/api/v1/people": dict(items=[dict(id=OID, name="Contoso person", parent_id="sales-emea",
                organization_id="sales", department_id="sales-emea")], next_cursor="opaque-next"),
            "/api/v1/trends": dict(items=[dict(day="2026-09-24T00:00:00Z", requests=5, prompt_tokens=20,
                completion_tokens=10, cache_read_tokens=100, usd=.2, unpriced_rows=0)], next_cursor=None),
            "/api/v1/requests": dict(items=[dict(request_id="request-1", user_id=OID, timestamp="2026-09-24T00:00:00Z",
                actor="dev@contoso.com", total_tokens=30, model="claude-sonnet", client_surface="claude-code")], next_cursor="request-next"),
            "/api/v1/tiers": dict(items=[dict(id="standard", tokens_per_day=500, tokens_per_minute=100, models=[])], next_cursor=None),
        }.get(path)
        return httpx.Response(200, json=body, headers={"ETag": '"revision-1"'}) if body is not None else httpx.Response(404)
    backend = AumServiceBackend(CONFIG, token_provider=lambda: "test-only", transport=httpx.MockTransport(respond))
    return backend, calls


def test_connect_selects_independent_service_backend():
    backend = connect(CONFIG)
    assert backend.name == "AUM service"
    backend.close()


def test_service_identity_capabilities_and_totals_never_use_turnstile_routes():
    backend, calls = service()
    engine = Engine(backend, "2026-09")
    status = engine.status()
    assert status["overview"]["totals"]["total_tokens"] == 30
    assert status["budgets"]["items"][-1]["budget_period"] == "day"
    assert engine.has_feature("approvals", "approve")
    assert not engine.has_feature("notifications", "mark_read")
    assert not engine.has_feature("assistant")
    assert not any("/observability/" in str(call.url) or "/auth/me" in str(call.url) for call in calls)


def test_scoped_empty_identity_stays_scoped():
    backend, _ = service(scope={"organizations": [], "departments": [], "writable_department_ids": []}, access="manager")
    assert Engine(backend).read("whoami")["manager_scope"] is not None


def test_people_and_requests_preserve_native_cursor_and_daily_budget():
    backend, calls = service()
    result = backend.read("people", month="2026-09", department_id="sales-emea", query="Contoso", limit=50, offset=0)
    assert result["items"][0]["token_limit"] == 1000
    assert result["items"][0]["budget_period"] == "day"
    assert result["page"]["next_cursor"] == "opaque-next"
    people_call = next(call for call in calls if call.url.path == "/api/v1/people")
    assert people_call.url.params["search"] == "Contoso" and "offset" not in people_call.url.params
    assert backend.read("requests", month="2026-09", limit=50)["page"]["next_cursor"] == "request-next"


def test_service_mutation_requires_reason_and_quoted_revision_without_retry():
    def respond(request):
        return httpx.Response(409, json={"error": {"code": "stale_revision", "message": "secret"}}) if request.method == "PUT" else None
    backend, calls = service(respond)
    backend.read("budgets", month="2026-09")
    with pytest.raises(FinOpsError):
        backend.write("budget", dict(token_limit=1000), scope_type="user", scope_id=OID, month="2026-09", reason="Approved capacity")
    writes = [call for call in calls if call.method == "PUT"]
    assert len(writes) == 1
    assert writes[0].headers["If-Match"] == '"revision-1"'
    assert json.loads(writes[0].content)["reason"] == "Approved capacity"
    assert not writes[0].url.query


def test_service_does_not_silently_drop_unsupported_filters():
    backend, _ = service()
    with pytest.raises(FinOpsError, match="model"):
        backend.read("requests", month="2026-09", model_id="claude-sonnet")


def test_service_engine_forwards_reason_and_uses_synchronous_receipt():
    def respond(request):
        if request.method == "PUT":
            return httpx.Response(200, json={"revision": "revision-2", "audit_id": "audit-1", "result": {"verified": True}})
    backend, calls = service(respond)
    engine = Engine(backend, "2026-09")
    engine.change_reason = "Approved capacity"
    result = engine.budget_change("team", "sales-emea", "4M", apply=True, confirm="sales-emea")
    assert "requested_at" not in result
    assert "no separate" in result["effect"].lower()
    assert json.loads(calls[-1].content)["reason"] == "Approved capacity"
    with pytest.raises(FinOpsError, match="no separate"):
        engine.apply(apply=True)


def test_service_request_detail_rechecks_authority_instead_of_serving_cache():
    refused = False
    def respond(request):
        if refused and request.url.path == "/api/v1/requests":
            return httpx.Response(403)
    backend, _ = service(respond)
    backend.read("requests", month="2026-09", limit=50)
    refused = True
    with pytest.raises(FinOpsError) as failure:
        backend.read("request", month="2026-09", request_id="request-1")
    assert failure.value.code == 4


@pytest.mark.parametrize("size", [(80, 24), (160, 48)])
async def test_service_terminal_hides_unoffered_views_and_opens_real_core_tabs(size):
    from claude_finops.tui import FinOpsApp
    from textual.widgets import TabbedContent
    backend, calls = service()
    app = FinOpsApp(Engine(backend, "2026-09"), CONFIG, first_run=False)
    async with app.run_test(size=size) as pilot:
        await pilot.pause(.2)
        await app.workers.wait_for_complete()
        await pilot.pause(.2)
        assert "overview" in app.data
        assert "usage" not in app.allowed_tabs and "anomalies" not in app.allowed_tabs
        assert not app.query_one(TabbedContent).get_tab("ask").display
        for tab in ("budgets", "people", "governance", "trends", "requests", "settings"):
            app.action_tab(tab)
            await pilot.pause(.2)
            await app.workers.wait_for_complete()
            assert tab in app.data
            assert app.query_one("#identity").region.width <= size[0]
        assert not any("observability" in call.url.path or "gateway-apply" in call.url.path for call in calls)


def test_service_mode_and_tier_use_native_single_object_endpoints():
    backend, calls = service(lambda request: httpx.Response(200, json={"audit_id": "audit-1", "revision": "revision-1"})
                             if request.method == "PUT" else None)
    engine = Engine(backend, "2026-09")
    engine.change_reason = "Approved adjustment"
    engine.mode_change("team", "sales-emea", "allowance", 10, apply=True)
    assert calls[-1].url.path == "/api/v1/modes/sales-emea"
    assert json.loads(calls[-1].content) == dict(enforcement="allowance", allowance_percent=10, reason="Approved adjustment")
    engine.tier_change("standard", per_minute="200", apply=True)
    assert calls[-1].url.path == "/api/v1/tiers/standard"
    assert calls[-1].headers["If-Match"] == '"revision-1"'


def test_service_request_decision_maps_native_version_and_route():
    def respond(request):
        if request.url.path == "/api/v1/budget-requests":
            return httpx.Response(200, json=dict(items=[dict(id="request-1", requester="other-person", state="pending",
                scope_type="department", scope_id="sales-emea", token_limit=6000000, version=4,
                approver_scope="sales", reason="Capacity")], next_cursor=None))
        if request.method == "POST":
            return httpx.Response(200, json={"audit_id": "audit-1", "result": {"state": "approved"}, "revision": "revision-2"})
    backend, calls = service(respond)
    result = Engine(backend, "2026-09").decide_request("request-1", "approve", "Reviewed", apply=True)
    assert result["result"]["result"]["state"] == "approved"
    assert calls[-1].url.path == "/api/v1/budget-requests/request-1/approve"
    assert json.loads(calls[-1].content) == dict(version=4, reason="Reviewed")


def test_viewer_service_advertisement_cannot_enable_native_writes():
    backend, calls = service(access="viewer")
    backend.read("budgets", month="2026-09")
    with pytest.raises(FinOpsError):
        backend.write("mode", {"mode": "notify"}, scope_id="sales-emea", reason="Forbidden change")
    assert all(call.method == "GET" for call in calls)


def test_unit_manager_direct_members_are_authorized_without_context_parent_widening():
    from claude_finops.rules import can_budget_write
    identity = dict(role="member", manager_scope=dict(organizations=[dict(id="sales")],
        departments=[dict(id="sales-emea", parent_id="sales")], writable_department_ids=["sales-emea"]))
    assert can_budget_write(identity, "user", OID, "sales")
    identity["manager_scope"]["organizations"] = []
    assert not can_budget_write(identity, "user", OID, "sales")


def test_service_refuses_historical_budget_write_and_overlong_reason_before_mutating():
    backend, calls = service()
    backend.read("budgets", month="2001-01")
    with pytest.raises(FinOpsError, match="current month"):
        backend.write("budget", {"token_limit": 1000}, scope_type="user", scope_id=OID,
                      month="2001-01", reason="Approved")
    with pytest.raises(FinOpsError, match="500"):
        Engine(backend).request_budget("team", "sales-emea", "6M", "x" * 501)
    assert all(call.method == "GET" for call in calls)


def test_service_managed_unit_export_includes_direct_members_without_double_counting_teams():
    scope = dict(organizations=[dict(id="sales", parent_id=None)],
                 departments=[dict(id="sales-emea", parent_id="sales")], writable_department_ids=["sales-emea"])
    backend, calls = service(scope=scope, access="manager")
    result = Engine(backend, "2026-09").chargeback()
    usage = [call for call in calls if call.url.path == "/api/v1/usage"]
    assert len(usage) == 1 and usage[0].url.params.get("organization_id") == "sales"
    assert len(result["items"]) == 1 and result["items"][0]["id"] == "sales"


def test_selected_request_detail_follows_timestamp_ties_after_reauthorization():
    selected = dict(request_id="selected", timestamp="2026-09-24T00:00:00Z", total_tokens=30)
    seeded = False
    def respond(request):
        if request.url.path != "/api/v1/requests":
            return None
        if not seeded or request.url.params.get("cursor") == "ties-next":
            return httpx.Response(200, json=dict(items=[selected], next_cursor=None))
        return httpx.Response(200, json=dict(items=[dict(selected, request_id="earlier")], next_cursor="ties-next"))
    backend, calls = service(respond)
    backend.read("requests", month="2026-09", limit=50)
    seeded = True
    assert backend.read("request", month="2026-09", request_id="selected")["request_id"] == "selected"
    assert calls[-1].url.params["cursor"] == "ties-next"


def test_service_request_cache_retains_only_the_current_page():
    def respond(request):
        if request.url.path == "/api/v1/requests":
            key = request.url.params.get("cursor", "first")
            return httpx.Response(200, json=dict(items=[dict(request_id=key, total_tokens=1)], next_cursor="next"))
    backend, _ = service(respond)
    backend.read("requests", month="2026-09", limit=50)
    backend.read("requests", month="2026-09", limit=50, cursor="next")
    assert set(backend._requests) == {"next"}


@pytest.mark.parametrize("access", ["admin", "manager"])
def test_existing_native_person_budget_uses_server_writable_record_without_directory_lookup(access):
    scope = dict(organizations=[], departments=[dict(id="sales-emea", parent_id="sales")],
                 writable_department_ids=[]) if access == "manager" else None
    backend, calls = service(access=access, scope=scope)
    engine = Engine(backend, "2026-09")
    engine.change_reason = "Reviewed daily override"
    result = engine.budget_change("person", OID, "900")
    assert result["budget_period"] == "day" and result["before"] == 1000
    assert not any(call.url.path == "/api/v1/people" for call in calls)


def test_service_boost_expiry_is_refused_during_preview_not_only_apply():
    backend, calls = service()
    with pytest.raises(FinOpsError, match="31 days"):
        Engine(backend).boost(OID, "sales-emea", "100", "2099-01-01", "Reviewed", window="daily")
    assert all(call.method == "GET" for call in calls)


async def test_service_people_do_not_require_catalog_rows_for_observed_search():
    from claude_finops.tui import FinOpsApp
    backend, calls = service(lambda request: httpx.Response(200, json=dict(organizations=[], departments=[],
        revision="revision-1")) if request.url.path == "/api/v1/catalog" else None)
    app = FinOpsApp(Engine(backend, "2026-09"), CONFIG, first_run=False)
    async with app.run_test(size=(100, 32)) as pilot:
        await pilot.pause(.2)
        await app.workers.wait_for_complete()
        app.action_tab("people")
        await pilot.pause(.2)
        await app.workers.wait_for_complete()
        assert app.data["people"]["items"][0]["scope_id"] == OID
        query = next(call.url.params for call in calls if call.url.path == "/api/v1/people")
        assert "department_id" not in query and "organization_id" not in query
        assert sum(call.url.path == "/api/v1/people" for call in calls) == 1


@pytest.mark.parametrize("status", [401, 405])
def test_shared_http_errors_do_not_require_turnstile_for_independent_service(status):
    from claude_finops.errors import http_error
    assert "Turnstile" not in str(http_error(status))
