from copy import deepcopy
import json

import httpx
import pytest
from textual.widgets import Button, Static

from claude_finops.engine import Engine
from claude_finops.palette import FinOpsCommands
from claude_finops.tui import FinOpsApp
from p85_fixtures import USER, choose_record, fill, management_app, settle
from test_aum_service_backend import service
from test_usd_budgets import UsdFake


@pytest.mark.parametrize("kind", ["direct", "turnstile"])
@pytest.mark.parametrize("scope,key,amount,tokens", [
    ("organization", "sales", "21M", 21000000),
    ("department", "sales-emea", "9M", 9000000),
    ("user", USER, "150k", 150000),
])
async def test_token_budget_preview_apply_receipt(monkeypatch, tmp_path, kind, scope, key, amount, tokens):
    app, state = management_app(monkeypatch, tmp_path, kind)
    async with app.run_test(size=(100, 36)) as pilot:
        await settle(app, pilot)
        await choose_record(app, pilot, "people" if scope == "user" else "budgets", key)
        await pilot.press("e")
        await pilot.pause()
        await fill(app, pilot, "#amount", amount)
        await pilot.click("#preview")
        await settle(app, pilot)
        plan = app.screen.preview_plan
        assert (plan["scope_type"], plan["scope_id"], plan["after"]) == (scope, key, tokens)
        assert plan["budget_period"] == ("day" if kind == "direct" and scope == "user" else "month")
        assert not state.calls and not state.fake.writes
        await pilot.click("#apply-change")
        await settle(app, pilot)
        assert app.screen.saved
        params = dict(scope_type=scope, scope_id=key, month=app.engine.month)
        message = str(app.screen.query_one("#form-status", Static).render())
        if kind == "direct":
            assert state.calls == [("budget", {"token_limit": tokens}, params)]
            assert "Gateway" in message and "Turnstile" not in message
        else:
            body = dict(token_limit=tokens, warning_threshold_percent=80)
            assert state.fake.writes == [("budget", params, body)]
            writes = [call for call in state.http_calls if call.method != "GET"]
            assert len(writes) == 1 and writes[0].method == "PUT"
            assert writes[0].url.path == f"/api/v1/budgets/{scope}/{key}"
            assert json.loads(writes[0].content) == body
            assert "Turnstile" in message if scope == "user" else "Apply succeeded" in message


async def test_direct_usd_budget_complete_flow_keeps_decimal_and_reconciliation(monkeypatch, tmp_path):
    app, state = management_app(monkeypatch, tmp_path)
    async with app.run_test(size=(100, 36)) as pilot:
        await settle(app, pilot)
        await choose_record(app, pilot, "budgets", "sales")
        await pilot.press("u")
        await pilot.pause()
        await fill(app, pilot, "#amount", "1.230000001")
        await pilot.click("#preview")
        await settle(app, pilot)
        assert app.screen.preview_plan["before"] == "1"
        assert app.screen.preview_plan["after"] == "1.230000001"
        assert not state.calls
        await pilot.click("#apply-change")
        await settle(app, pilot)
        assert state.calls == [("usd_budget", {
            "amount_usd": "1.230000001", "period": "month", "price_book_date": "2026-09-16",
        }, {"scope_type": "organization", "scope_id": "sales", "month": app.engine.month})]
        assert app.screen.saved
        assert "Saved; awaiting reconciliation." in str(app.screen.query_one("#form-status", Static).render())
        await pilot.click("#cancel-change")
        await settle(app, pilot)
        assert app.engine.read("usd_budgets")["items"][0]["amount_usd"] == "1.230000001"


def usd_service():
    definitions = deepcopy(UsdFake().usd)

    def respond(request):
        path = request.url.path
        if path == "/api/v1/capabilities":
            return httpx.Response(200, json={"schema_version": 1, "capabilities": {
                "usage_read": True, "budgets_read": True, "usd_budgets_read": True,
                "usd_budget_write": True, "budget_write": True,
            }})
        if path == "/api/v1/usd-budgets":
            return httpx.Response(200, json=definitions, headers={"ETag": '"revision-1"'})
        if path == "/api/v1/usd-budget-status":
            return httpx.Response(200, json={"enabled": True, "fresh": True, "items": {}})
        if request.method == "PUT":
            assert path in {"/api/v1/usd-budgets/organization/sales", "/api/v1/budgets/organization/sales"}
            body = json.loads(request.content)
            if "amount_usd" in body:
                definitions["items"][0]["amount_usd"] = body["amount_usd"]
            return httpx.Response(200, json={"revision": "revision-2", "audit_id": "audit-1",
                                           "result": {"verified": True}})
        return None

    backend, calls = service(respond)
    return FinOpsApp(Engine(backend), backend.config, first_run=False), calls


async def test_service_usd_budget_complete_flow_uses_revision_reason_and_receipt():
    app, calls = usd_service()
    async with app.run_test(size=(100, 36)) as pilot:
        await settle(app, pilot)
        await choose_record(app, pilot, "budgets", "sales")
        assert "Edit selected USD budget" in [name for name, *_ in FinOpsCommands(app.screen).commands()]
        await pilot.click("#budgets #action-set-usd-budget")
        await pilot.pause()
        await fill(app, pilot, "#amount", "1.230000001")
        await fill(app, pilot, "#audit-reason", "Approved USD capacity")
        await pilot.click("#preview")
        await settle(app, pilot)
        assert app.screen.preview_plan["after"] == "1.230000001"
        assert all(call.method == "GET" for call in calls)
        await pilot.click("#apply-change")
        await settle(app, pilot)
        writes = [call for call in calls if call.method != "GET"]
        assert len(writes) == 1 and writes[0].method == "PUT"
        assert writes[0].url.path == "/api/v1/usd-budgets/organization/sales"
        assert writes[0].headers["If-Match"] == '"revision-1"'
        assert json.loads(writes[0].content) == {
            "amount_usd": "1.230000001", "period": "month", "price_book_date": "2026-09-16",
            "reason": "Approved USD capacity",
        }
        assert app.screen.saved
        assert "Saved; awaiting reconciliation." in str(app.screen.query_one("#form-status", Static).render())
        assert not any("/gateway-apply" in call.url.path for call in calls)
        await pilot.click("#cancel-change")
        await settle(app, pilot)
        assert app.engine.read("usd_budgets")["items"][0]["amount_usd"] == "1.230000001"


async def test_service_usd_without_audit_reason_cannot_preview_or_write():
    app, calls = usd_service()
    async with app.run_test(size=(100, 36)) as pilot:
        await settle(app, pilot)
        await choose_record(app, pilot, "budgets", "sales")
        await pilot.press("u")
        await pilot.pause()
        await fill(app, pilot, "#amount", "2")
        await pilot.click("#preview")
        await settle(app, pilot)
        assert "audit reason" in str(app.screen.query_one("#form-status", Static).render())
        assert app.screen.query_one("#apply-change", Button).disabled
        assert all(call.method == "GET" for call in calls)


async def test_service_usd_palette_and_shortcut_refuse_read_only_selection():
    app, calls = usd_service()
    async with app.run_test(size=(100, 36)) as pilot:
        await settle(app, pilot)
        await choose_record(app, pilot, "budgets", "sales")
        app.selected()["writable"] = False
        app.update_action_buttons()
        assert app.query_one("#budgets #action-set-usd-budget", Button).disabled
        assert "Edit selected USD budget" not in [name for name, *_ in FinOpsCommands(app.screen).commands()]
        await pilot.press("u")
        app.action_usd_edit()
        await pilot.pause()
        assert len(app.screen_stack) == 1
        assert all(call.method == "GET" for call in calls)


async def test_service_native_token_receipt_does_not_follow_turnstile_apply():
    app, calls = usd_service()
    async with app.run_test(size=(100, 36)) as pilot:
        await settle(app, pilot)
        await choose_record(app, pilot, "budgets", "sales")
        await pilot.press("e")
        await pilot.pause()
        await fill(app, pilot, "#amount", "11M")
        await fill(app, pilot, "#confirm", "sales")
        await fill(app, pilot, "#audit-reason", "Approved token capacity")
        await pilot.click("#preview")
        await settle(app, pilot)
        assert app.screen.preview_plan["after"] == 11000000
        assert all(call.method == "GET" for call in calls)
        await pilot.click("#apply-change")
        await settle(app, pilot)
        writes = [call for call in calls if call.method != "GET"]
        assert len(writes) == 1 and writes[0].method == "PUT"
        assert writes[0].url.path == "/api/v1/budgets/organization/sales"
        assert writes[0].headers["If-Match"] == '"revision-1"'
        assert json.loads(writes[0].content)["token_limit"] == 11000000
        assert json.loads(writes[0].content)["reason"] == "Approved token capacity"
        assert "receipt" in str(app.screen.query_one("#form-status", Static).render())
        assert not any("/gateway-apply" in call.url.path for call in calls)


async def test_turnstile_usd_stays_disabled_without_fallback(monkeypatch, tmp_path):
    app, state = management_app(monkeypatch, tmp_path, "turnstile")
    async with app.run_test(size=(80, 24)) as pilot:
        await settle(app, pilot)
        await choose_record(app, pilot, "budgets", "sales")
        button = app.query_one("#budgets #action-set-usd-budget", Button)
        assert button.disabled
        assert str(button.tooltip) == app.usd_unavailable_text()
        assert app.usd_unavailable_text() in str(app.query_one("#note-budgets", Static).render())
        assert "Edit selected USD budget" not in [name for name, *_ in FinOpsCommands(app.screen).commands()]
        await pilot.press("u")
        app.action_usd_edit()
        await pilot.pause()
        assert len(app.screen_stack) == 1
        assert not state.calls and not state.fake.writes
        assert all(call.method == "GET" for call in state.http_calls)
