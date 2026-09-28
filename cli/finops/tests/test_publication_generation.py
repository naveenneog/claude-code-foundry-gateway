import asyncio
from concurrent.futures import ThreadPoolExecutor
from copy import deepcopy
import json

import httpx
import pytest
from textual.widgets import Static, Input, DataTable, Select, TextArea
from textual.app import App
from textual import events
from types import SimpleNamespace
import typer
from contextlib import nullcontext

from claude_finops.cli import emit, report_chargeback
from claude_finops.config import Config
from claude_finops.engine import Engine
from claude_finops.errors import FinOpsError
from claude_finops.redaction import Redactor
from claude_finops.tui import FinOpsApp
from claude_finops.fake import FakeBackend
from claude_finops.screens import DetailScreen
from claude_finops.screens import ChangeScreen
from claude_finops.feature_screens import ActionForm
from claude_finops.dashboard import DashboardPanel
from claude_finops.dashboard_drill import DashboardRows
from claude_finops.turnstile import TurnstileBackend
from test_principal_tokens import estate, a_only_snapshot


@pytest.fixture
def http_estate():
    principal, calls = ["a"], []

    def respond(request):
        calls.append((principal[0], request.url.path))
        if request.url.path.endswith("/auth/me"):
            return httpx.Response(200, json={
                "id": principal[0], "email": principal[0] + "@contoso.com",
                "role": "owner" if principal[0] == "a" else "member",
                "manager_scope": None if principal[0] == "a" else {
                    "organizations": [], "departments": [{"id": "only-b", "parent_id": "b"}],
                    "writable_department_ids": []}})
        if request.url.path.endswith("/trends"):
            return httpx.Response(200, json={"points": [], "principal": principal[0], "source": principal[0] + "-only"})
        if request.url.path.endswith("/finops/capabilities"):
            return httpx.Response(200, json={"schema_version": 1, "features": {"private": principal[0]}})
        if request.url.path.endswith("/enterprise-catalog"):
            return httpx.Response(200, json={"organizations": [{"id": "a", "name": "A_ONLY_CATALOG"}],
                                           "departments": [{"id": "a-only", "name": "A_ONLY_CATALOG", "parent_id": "a"}]})
        return httpx.Response(404)

    backend = TurnstileBackend(Config(backend="turnstile", url="https://turnstile.contoso.com",
                                     scope="api://contoso/Turnstile.Manage"),
                               token_provider=lambda: "token-" + principal[0],
                               transport=httpx.MockTransport(respond))
    engine = Engine(backend, "2026-09")
    engine.read("whoami")
    yield engine, principal, calls
    backend.close()


def verify_b(engine, principal):
    principal[0] = "b"
    with ThreadPoolExecutor(max_workers=1) as pool:
        assert pool.submit(engine.read, "whoami").result(timeout=5)["id"] == "b"


def test_http_completed_current_trend_cannot_publish_with_b_comparison(http_estate):
    engine, principal, calls = http_estate
    original = engine.read

    def pause_assembly(resource, **params):
        result = original(resource, **params)
        if resource == "trends":
            assert result["source"] == "a-only"
            verify_b(engine, principal)
        return result

    engine.read = pause_assembly
    with pytest.raises(FinOpsError, match="sign-in changed") as stale:
        engine.compare_trends("2026-08", organization_id="only-a")
    assert stale.value.code == 3
    assert engine._identity["id"] == "b"
    with pytest.raises(FinOpsError) as denied:
        original("trends", organization_id="only-a")
    assert denied.value.code == 4
    assert [person for person, route in calls if route.endswith("/trends")] == ["a"]


def test_http_cycle_exit_checks_sources_completed_before_identity_change(http_estate):
    engine, principal, _ = http_estate
    with pytest.raises(FinOpsError, match="sign-in changed") as stale:
        with engine.backend.read_cycle():
            result = engine.read("trends")
            verify_b(engine, principal)
            assert result["source"] == "a-only"
    assert stale.value.code == 3


def test_http_unchanged_identity_preserves_a_completed_read_cycle(http_estate):
    engine, _, _ = http_estate
    with engine.backend.read_cycle():
        assert engine.read("trends")["source"] == "a-only"
        assert engine.read("whoami")["id"] == "a"
        assert engine.read("trends")["source"] == "a-only"


@pytest.mark.parametrize("delivery", ["partial", "final"])
async def test_direct_completed_sources_cannot_publish_after_b_verifies(estate, delivery):
    backend, state, _, _, _ = estate
    engine = Engine(backend, "2026-09")
    backend._bridge = lambda *args, **kwargs: deepcopy(a_only_snapshot())
    backend._client = httpx.Client(transport=httpx.MockTransport(lambda request: httpx.Response(
        200, json={"tables": [{"columns": [{"name": "total_tokens"}, {"name": "marker"}],
                              "rows": [[771, "A_ONLY"]]}]}
        if "| summarize " in json.loads(request.content)["query"] and " by " not in json.loads(request.content)["query"]
        else {"tables": [{"columns": [], "rows": []}]})))
    app = FinOpsApp(engine, Config(backend="fake"), first_run=False)
    sources = ("overview", "budgets", "ranking", "teams", "trends", "anomalies", "catalog")
    ready = {key: asyncio.Event() for key in sources}
    release = {key: asyncio.Event() for key in sources}
    final_ready, final_release = asyncio.Event(), asyncio.Event()
    original_tracked, original_load, original_render = app._tracked_read, app.load_tab, app.render_tab
    published, publication_seen = [], asyncio.Event()

    async def hold_arrival(key, operation, serial, tab):
        result = await original_tracked(key, operation, serial, tab)
        if delivery == "partial" and key in sources:
            ready[key].set()
            await release[key].wait()
        return result

    async def hold_final(tab):
        result = await original_load(tab)
        if delivery == "final" and tab == "overview":
            final_ready.set()
            await final_release.wait()
        return result

    def rendered(tab, data):
        if state["principal"] == "b@contoso.com" and "A_ONLY" in str(data):
            published.append(data)
            publication_seen.set()
        original_render(tab, data)

    app._tracked_read, app.load_tab, app.render_tab = hold_arrival, hold_final, rendered
    async with app.run_test(size=(100, 30)) as pilot:
        try:
            if delivery == "partial":
                await asyncio.wait_for(asyncio.gather(*(event.wait() for event in ready.values())), 8)
            else:
                await asyncio.wait_for(final_ready.wait(), 8)
            state["principal"] = "b@contoso.com"
            identity = await asyncio.to_thread(engine.read, "whoami")
            assert identity["email"] == "b@contoso.com"
            if delivery == "partial":
                release["overview"].set()
            else:
                final_release.set()
            for _ in range(20):
                await pilot.pause(.03)
                if publication_seen.is_set() or "sign-in changed" in str(app.query_one("#note-overview", Static).render()):
                    break
            assert not published, "A completed A-only source was rendered after B was verified."
            assert "overview" not in app.data, "Obsolete arrivals must be discarded before entering the current UI cache."
            assert "sign-in changed" in str(app.query_one("#note-overview", Static).render())
        finally:
            final_release.set()
            for event in release.values():
                event.set()
            await app.workers.wait_for_complete()


def test_completed_http_result_cannot_reach_json_after_b_verifies(http_estate, capsys):
    engine, principal, _ = http_estate
    ctx = SimpleNamespace(obj={"engine": engine, "redactor": Redactor(), "json": True,
                               "plain": True, "no_color": True})

    def completed(engine):
        result = engine.read("trends")
        verify_b(engine, principal)
        return result

    with pytest.raises(typer.Exit) as failure:
        emit(ctx, completed)
    assert failure.value.exit_code == 3
    output = json.loads(capsys.readouterr().out)
    assert output["exit_code"] == 3 and "a-only" not in str(output)


def test_completed_capabilities_are_not_cached_after_b_verifies(http_estate):
    engine, principal, _ = http_estate
    original = engine.backend.read

    def delayed(resource, **params):
        result = original(resource, **params)
        if resource == "capabilities":
            assert result["features"]["private"] == "a"
            verify_b(engine, principal)
        return result

    engine.backend.read = delayed
    with pytest.raises(FinOpsError, match="sign-in changed"):
        engine.capabilities(refresh=True)
    assert engine._capabilities is None


def test_completed_http_identity_cannot_reach_json_after_new_identity_verifies(http_estate, capsys):
    engine, principal, _ = http_estate
    ctx = SimpleNamespace(obj={"engine": engine, "redactor": Redactor(), "json": True,
                               "plain": True, "no_color": True})

    def completed(engine):
        result = engine.read("whoami")
        verify_b(engine, principal)
        return result

    with pytest.raises(typer.Exit) as failure:
        emit(ctx, completed)
    assert failure.value.exit_code == 3
    output = json.loads(capsys.readouterr().out)
    assert output["exit_code"] == 3 and "a@contoso.com" not in str(output)


def test_completed_chargeback_cannot_reach_csv_after_b_verifies(http_estate, capsys):
    engine, principal, _ = http_estate
    ctx = SimpleNamespace(obj={"engine": engine, "redactor": Redactor(), "json": False})

    def chargeback(dimension):
        source = engine.read("trends")
        verify_b(engine, principal)
        return {"items": [{"id": source["source"], "total_tokens": 7}]}

    engine.chargeback = chargeback
    with pytest.raises(typer.Exit) as failure:
        report_chargeback(ctx, csv=True)
    assert failure.value.exit_code == 3
    assert capsys.readouterr().out == ""


def test_turnstile_completed_feature_document_is_not_cached_after_b_verifies(http_estate):
    engine, principal, _ = http_estate
    original = engine.backend._request

    def after_response(method, path, *args, **kwargs):
        result = original(method, path, *args, **kwargs)
        if path.endswith("/model-management"):
            verify_b(engine, principal)
        return result

    engine.backend._request = after_response
    with pytest.raises(FinOpsError, match="sign-in changed"):
        engine.capabilities(refresh=True)
    assert engine.backend._features is None


def test_aum_service_completed_catalog_is_not_cached_after_identity_change():
    from claude_finops.aum_service import AumServiceBackend
    principal = ["a"]

    def respond(request):
        if request.url.path.endswith("/me"):
            return httpx.Response(200, json={"id": principal[0], "role": "owner"})
        return httpx.Response(200, json={"revision": "one", "organizations": [
            {"id": principal[0] + "-only", "name": principal[0]}], "departments": []})

    backend = AumServiceBackend(Config(backend="aum-service", url="https://aum.contoso.com",
                                      scope="api://contoso/AUM.Access"), token_provider=lambda: "test-only",
                                transport=httpx.MockTransport(respond))
    engine = Engine(backend, "2026-09")
    engine.read("whoami")
    original = backend._get

    def after_get(path, *args, **kwargs):
        result = original(path, *args, **kwargs)
        if path == "catalog":
            verify_b(engine, principal)
        return result

    backend._get = after_get
    try:
        with pytest.raises(FinOpsError, match="sign-in changed"):
            engine.read("catalog")
        assert backend._catalog is None
    finally:
        backend.close()


@pytest.fixture
def bearer_tui_estate():
    principal = ["a"]

    def respond(request):
        person = request.headers["Authorization"].removeprefix("Bearer token-")
        assert person in {"a", "b"}, "The server fixture authorizes the bearer, not the selected UI identity."
        path = request.url.path
        row = {"scope_id": "only-" + person, "scope_name": person.upper() + "_ONLY_BUDGET",
               "scope_type": "department", "parent_scope_id": person, "used_tokens": 11,
               "token_limit": 99, "remaining_tokens": 88, "status": "healthy"}
        if path.endswith("/auth/me"):
            result = {"id": person, "email": person + "@contoso.com",
                      "role": "owner" if person == "a" else "member",
                      "manager_scope": None if person == "a" else {
                          "organizations": [], "departments": [{"id": "only-b", "parent_id": "b"}],
                          "writable_department_ids": []}}
        elif path.endswith("/finops/capabilities"):
            result = {"schema_version": 1, "features": {}}
        elif path.endswith("/budgets"):
            result = {"items": [row]}
        elif path.endswith("/enterprise-catalog"):
            result = {"organizations": [{"id": person, "name": person.upper() + "_ONLY_UNIT"}],
                      "departments": [{"id": "only-" + person, "name": person.upper() + "_ONLY_TEAM", "parent_id": person}]}
        elif path.endswith("/executive-overview"):
            result = {"totals": {"total_tokens": 11, "total_requests": 1}}
        elif path.endswith("/distribution"):
            result = {"dimension": request.url.params.get("dimension", "organization"), "items": [
                {"id": "only-" + person, "name": person.upper() + "_ONLY_RANK", "total_tokens": 11}]}
        elif path.endswith("/trends"):
            result = {"points": []}
        elif path.endswith("/anomalies"):
            result = {"items": []}
        elif path.endswith("/requests"):
            result = {"items": [{"request_id": person + "-request", "user_name": person + "@contoso.com",
                                 "total_tokens": 11, "timestamp": "2026-09-01T00:00:00Z"}]}
        elif "/requests/" in path:
            result = {"request_id": person + "-request", "marker": person.upper() + "_ONLY_REQUEST"}
        elif path.endswith("/assistant/settings"):
            result = {"model_available": True, "available_models": []}
        elif path.endswith("/assistant/ask"):
            result = {"conversation_id": person + "-conversation", "message": person.upper() + "_ONLY_REPLY",
                      "charts": [{"id": person + "-chart", "title": person.upper() + "_ONLY_CHART",
                                  "type": "bar", "data": [{"tokens": 11}]}]}
        else:
            return httpx.Response(404)
        return httpx.Response(200, json=result)

    backend = TurnstileBackend(Config(backend="turnstile", url="https://turnstile.contoso.com",
                                     scope="api://contoso/Turnstile.Manage"),
                               token_provider=lambda: "token-" + principal[0],
                               transport=httpx.MockTransport(respond))
    engine = Engine(backend, "2026-09")
    yield engine, principal
    backend.close()


def guard_exit_code(guard):
    try:
        with guard():
            pass
    except FinOpsError as error:
        return error.code
    return 0


@pytest.mark.parametrize("tab", ["budgets", "requests"])
async def test_deferred_detail_retains_cached_or_fresh_origin_after_b_verifies(bearer_tui_estate, monkeypatch, tab):
    engine, principal = bearer_tui_estate
    app = FinOpsApp(engine, Config(backend="fake"), first_run=False)
    original_compose = DetailScreen.compose
    observed = {}
    async with app.run_test(size=(100, 30)) as pilot:
        await pilot.pause()
        await app.workers.wait_for_complete()
        app.action_tab(tab)
        await pilot.pause()
        await app.workers.wait_for_complete()
        assert "A_ONLY" in str(app.data[tab]) or tab == "requests"
        origin = app._data_guards[tab][1]

        def paused_compose(screen):
            principal[0] = "b"
            with ThreadPoolExecutor(max_workers=1) as pool:
                identity = pool.submit(engine.read, "whoami").result(timeout=5)
            app.update_access(identity)
            observed.update(identity=app.identity["id"], cache_cleared=tab not in app.data,
                            origin_code=guard_exit_code(origin), detail_code=guard_exit_code(screen.read_guard))
            yield from original_compose(screen)

        monkeypatch.setattr(DetailScreen, "compose", paused_compose)
        app.action_exact_detail()
        await pilot.pause()
        await app.workers.wait_for_complete()
        await pilot.pause()
        assert observed["identity"] == "b" and observed["cache_cleared"]
        assert observed["origin_code"] == 3
        assert observed["detail_code"] == 3, "The deferred dialog replaced the source guard with an unpinned guard."
        # Round 5 additionally closes the obsolete dialog before another input.
        shown = "\n".join(strip.text for strip in app.screen._compositor.render_strips())
        assert "A_ONLY" not in shown and "only-a" not in shown
        assert "sign-in changed" in shown
        assert all(row["scope_id"] == "only-b" for row in engine.read("budgets")["items"])


@pytest.mark.parametrize("surface", ["panel-exact", "rank-list", "rank-exact", "budget-edit", "pin-chart",
                                    "mode-form", "request-form"])
async def test_cached_dialog_handoffs_retain_origin_during_deferred_composition(bearer_tui_estate, monkeypatch, surface):
    engine, principal = bearer_tui_estate
    app = FinOpsApp(engine, Config(backend="fake"), first_run=False)
    target = ActionForm if surface in {"pin-chart", "mode-form", "request-form"} else ChangeScreen if surface == "budget-edit" else (
        DashboardRows if surface == "rank-list" else DetailScreen)
    original_compose = target.compose
    observed = {}
    async with app.run_test(size=(100, 30)) as pilot:
        await pilot.pause()
        await app.workers.wait_for_complete()
        if surface in {"budget-edit", "mode-form", "request-form"}:
            app.action_tab("budgets")
        elif surface == "pin-chart":
            app.action_tab("ask")
        await pilot.pause()
        await app.workers.wait_for_complete()
        if surface == "pin-chart":
            app.query_one("#ask-question", Input).value = "Show usage"
            await app.ask_current()
            await pilot.pause()
            assert "A_ONLY_CHART" in str(app.ask_reply)
        if surface == "request-form":
            app.feature_caps["features"]["approvals"] = {"enabled": True, "actions": ["read", "request"]}
        if surface == "rank-exact":
            app.query_one("#dash-rank", DashboardPanel).focus()
            await pilot.press("enter")
            await pilot.pause()
            assert isinstance(app.screen, DashboardRows)
        origin = app._data_guards[app.active][1]

        def paused_compose(screen):
            principal[0] = "b"
            with ThreadPoolExecutor(max_workers=1) as pool:
                identity = pool.submit(engine.read, "whoami").result(timeout=5)
            app.update_access(identity)
            observed.update(origin=guard_exit_code(origin),
                            dialog=guard_exit_code(getattr(screen, "read_guard", nullcontext)))
            yield from original_compose(screen)

        monkeypatch.setattr(target, "compose", paused_compose)
        if surface == "panel-exact":
            app.query_one("#dash-kpis", DashboardPanel).focus()
            await pilot.press("d")
        elif surface == "rank-list":
            app.query_one("#dash-rank", DashboardPanel).focus()
            await pilot.press("enter")
        elif surface == "rank-exact":
            app.screen.action_detail()
        elif surface == "budget-edit":
            app.action_edit()
        elif surface == "mode-form":
            app.action_mode()
        elif surface == "request-form":
            app.action_request_budget()
        else:
            app.action_pin_chart()
        await pilot.pause()
        await app.workers.wait_for_complete()
        await pilot.pause()
        assert observed["origin"] == 3
        assert observed["dialog"] == 3, f"{surface} lost the cached source guard."
        shown = "\n".join(strip.text for strip in app.screen._compositor.render_strips())
        assert "A_ONLY" not in shown and "only-a" not in shown
        assert "sign-in changed" in shown


@pytest.mark.parametrize("action", ["action_copy_request", "action_open_ledger"])
async def test_cached_request_actions_recheck_the_origin_not_an_empty_cycle(bearer_tui_estate, monkeypatch, action):
    engine, principal = bearer_tui_estate
    app = FinOpsApp(engine, Config(
        backend="fake", tenant_id="00000000-0000-0000-0000-000000000071",
        workspace_resource_id="/subscriptions/00000000-0000-0000-0000-000000000071/resourceGroups/contoso/providers/Microsoft.OperationalInsights/workspaces/contoso"),
        first_run=False)
    published, notices = [], []
    monkeypatch.setattr(app, "copy_to_clipboard", lambda value: published.append(value))
    monkeypatch.setattr(app, "open_url", lambda value: published.append(value))
    monkeypatch.setattr(app, "notify", lambda value, **kwargs: notices.append(str(value)))
    async with app.run_test(size=(100, 30)) as pilot:
        await pilot.pause()
        await app.workers.wait_for_complete()
        app.action_tab("requests")
        await pilot.pause()
        await app.workers.wait_for_complete()
        assert app.selected()["request_id"] == "a-request"
        origin = app._data_guards["requests"][1]
        principal[0] = "b"
        await asyncio.to_thread(engine.read, "whoami")
        assert guard_exit_code(origin) == 3
        getattr(app, action)()
        assert published == []
        assert not app.records and app.identity["id"] == "b"
        assert "sign-in changed" in str(app.query_one("#note-requests", Static).render())


@pytest.mark.parametrize("authority", ["http", "direct"])
def test_cached_item_guards_cannot_outlive_the_source_connection(http_estate, estate, authority):
    http_engine, _, _ = http_estate
    direct_backend, _, _, _, _ = estate
    engine = http_engine if authority == "http" else Engine(direct_backend, "2026-09")
    with engine.backend.read_cycle():
        engine.read("trends" if authority == "http" else "overview")
        origin = engine.backend.read_guard()
    assert guard_exit_code(origin) == 0
    engine.backend.close()
    assert guard_exit_code(origin) == 3, "A deferred cached item must not retain authority after its connection closes."


async def test_highlight_input_after_b_verifies_cannot_publish_a_row(bearer_tui_estate, monkeypatch):
    engine, principal = bearer_tui_estate
    original = engine.backend._client._transport
    def respond(request):
        response = original.handle_request(request)
        if request.url.path.endswith("/budgets") and request.headers["Authorization"] == "Bearer token-a":
            data = response.json()
            data["items"].append(dict(data["items"][0], scope_id="a-second", scope_name="A_ONLY_SECOND"))
            return httpx.Response(200, json=data)
        return response
    engine.backend._client._transport = httpx.MockTransport(respond)
    app = FinOpsApp(engine, Config(backend="fake"), first_run=False)
    leaked, observed_input = [], []
    original_update = Static.update
    original_event = App.on_event

    async def dispatched(owner, event):
        if owner is app and isinstance(event, events.Key) and event.key == "down" and not event.is_forwarded:
            observed_input.append((app.identity.get("id"), dict(app.records), app.pending_selection))
        await original_event(owner, event)

    def update(widget, value="", **kwargs):
        if (engine._identity or {}).get("id") == "b" and widget.id == "status" and ("a-second" in str(value) or "only-a" in str(value)):
            leaked.append(str(value))
        return original_update(widget, value, **kwargs)

    monkeypatch.setattr(Static, "update", update)
    monkeypatch.setattr(App, "on_event", dispatched)
    async with app.run_test(size=(100, 30)) as pilot:
        await pilot.pause()
        await app.workers.wait_for_complete()
        app.action_tab("budgets")
        await pilot.pause()
        await app.workers.wait_for_complete()
        app.set_focus(app.query_one("#table-budgets", DataTable))
        origin = app.cached_guard("budgets")
        principal[0] = "b"
        await asyncio.to_thread(engine.read, "whoami")
        assert guard_exit_code(origin) == 3
        await pilot.press("down")
        await pilot.pause()
        assert not leaked, "A stale highlighted row reached the status widget after B verified."
        assert observed_input == [("b", {}, None)], "Old cached rows must be cleared before input dispatch, not after the handler."
        assert all(row["scope_id"] == "only-b" for row in engine.read("budgets")["items"])


async def test_assistant_context_is_cleared_before_b_request(bearer_tui_estate, monkeypatch):
    engine, principal = bearer_tui_estate
    original = engine.backend._client._transport
    asks = []

    def respond(request):
        if request.url.path.endswith("/finops/capabilities"):
            return httpx.Response(200, json={"schema_version": 1, "features": {
                "assistant": {"enabled": True, "actions": ["read", "ask", "pin", "manage"]}}})
        if request.url.path.endswith("/assistant/ask"):
            asks.append((request.headers["Authorization"], json.loads(request.content)))
        return original.handle_request(request)

    engine.backend._client._transport = httpx.MockTransport(respond)
    app = FinOpsApp(engine, Config(backend="fake"), first_run=False)
    async with app.run_test(size=(100, 30)) as pilot:
        await pilot.pause()
        await app.workers.wait_for_complete()
        app.action_tab("ask")
        await pilot.pause()
        await app.workers.wait_for_complete()
        app.query_one("#ask-question", Input).value = "A question"
        await app.ask_current()
        assert app.ask_history and app.ask_conversation == "a-conversation"
        old_guard = app.ask_reply_guard
        principal[0] = "b"
        await asyncio.to_thread(engine.read, "whoami")
        assert guard_exit_code(old_guard) == 3
        app.query_one("#ask-question", Input).value = "B question"
        await app.ask_current()
        assert len(asks) == 2 and asks[-1][0] == "Bearer token-b"
        assert asks[-1][1]["history"] == [] and asks[-1][1]["conversation_id"] is None
        assert "A_ONLY" not in str(app.ask_history)
        assert app.ask_conversation == "b-conversation"


async def test_principal_change_closes_prior_forms_and_clears_state_before_input(bearer_tui_estate):
    engine, principal = bearer_tui_estate
    app = FinOpsApp(engine, Config(backend="fake"), first_run=False)
    async with app.run_test(size=(100, 30)) as pilot:
        await pilot.pause()
        await app.workers.wait_for_complete()
        app.action_tab("budgets")
        await pilot.pause()
        await app.workers.wait_for_complete()
        app.action_edit()
        await pilot.pause()
        assert len(app.screen_stack) == 2
        principal[0] = "b"
        await asyncio.to_thread(engine.read, "whoami")
        await pilot.press("tab")
        await pilot.pause()
        assert len(app.screen_stack) == 1
        assert app.identity["id"] == "b" and not app.data and not app.records
        assert app.ask_history == [] and app.ask_conversation is None and app.preferences is None


async def test_principal_change_clears_cached_picker_options_before_input(bearer_tui_estate):
    engine, principal = bearer_tui_estate
    app = FinOpsApp(engine, Config(backend="fake"), first_run=False)
    async with app.run_test(size=(100, 30)) as pilot:
        await pilot.pause()
        await app.workers.wait_for_complete()
        app.action_tab("people")
        await pilot.pause()
        await app.workers.wait_for_complete()
        assert "A_ONLY_TEAM" in str(app.query_one("#people-team", Select)._options)
        principal[0] = "b"
        await asyncio.to_thread(engine.read, "whoami")
        await pilot.press("tab")
        assert "A_ONLY" not in str(app.query_one("#people-team", Select)._options)
        assert app.team == ""


@pytest.mark.parametrize("style", ["json", "plain", "table"])
def test_output_formatter_cannot_publish_outside_the_choke_point(style, capsys):
    from claude_finops.output import display
    with pytest.raises(FinOpsError, match="unguarded"):
        display({"private": "A_ONLY"}, as_json=style == "json", plain=style == "plain")
    assert "A_ONLY" not in capsys.readouterr().out


@pytest.mark.parametrize("surface", ["lookup-catalog", "lookup-results", "detail", "export", "people-selector",
                                    "assistant-history", "assistant-settings", "assistant-answer", "membership"])
async def test_delayed_screen_or_export_read_cannot_publish_after_identity_change(http_estate, monkeypatch, tmp_path, surface):
    engine, principal, _ = http_estate
    app = FinOpsApp(Engine(FakeBackend(), "2026-09"), Config(backend="fake"), first_run=False)
    original_to_thread = asyncio.to_thread
    fired = []
    published = []
    notices, opened = [], []
    monkeypatch.setattr(app, "notify", lambda message, **kwargs: notices.append(str(message)))
    monkeypatch.setattr(app, "open_url", lambda url: opened.append(url))
    original_row, original_options = DataTable.add_row, Select.set_options
    original_text = TextArea.load_text

    def load_text(widget, text):
        if principal[0] == "b" and "A_ONLY" in text:
            published.append(text)
        return original_text(widget, text)

    def add_row(widget, *values, **kwargs):
        if principal[0] == "b" and "A_ONLY" in str(values):
            published.append(values)
        return original_row(widget, *values, **kwargs)

    def set_options(widget, options):
        options = list(options)
        if principal[0] == "b" and "A_ONLY" in str(options):
            published.append(options)
        return original_options(widget, options)

    monkeypatch.setattr(DataTable, "add_row", add_row)
    monkeypatch.setattr(Select, "set_options", set_options)
    monkeypatch.setattr(TextArea, "load_text", load_text)
    target_resource = "catalog"
    original_read = engine.read

    if surface == "lookup-results":
        def lookup(*args):
            source = original_read("trends")["source"]
            return [{"id": source, "name": "A_ONLY_RESULT", "kind": "team", "tab": "budgets"}]
        engine.lookup = lookup
        target = lookup
    elif surface == "export":
        def chargeback(*args):
            return {"items": [{"id": original_read("trends")["source"], "name": "A_ONLY_RESULT"}]}
        engine.chargeback = chargeback
        target = chargeback
        monkeypatch.chdir(tmp_path)
    elif surface in {"detail", "assistant-history", "assistant-settings"}:
        target_resource = {"detail": "request", "assistant-history": "conversations",
                           "assistant-settings": "assistant_settings"}[surface]
        def read(resource, **params):
            if resource == target_resource:
                return {"request_id": original_read("trends")["source"], "marker": "A_ONLY_RESULT",
                        "items": [], "available_models": []}
            return original_read(resource, **params)
        engine.read = read
        target = read
    elif surface == "assistant-answer":
        def ask(*args):
            return {"conversation_id": original_read("trends")["source"], "message": "A_ONLY_RESULT", "charts": []}
        engine.ask = ask
        target = ask
    elif surface == "membership":
        def membership(*args):
            return "https://portal.contoso.com/" + original_read("trends")["source"]
        engine.membership_url = membership
        target = membership
    else:
        target = engine.read

    async def after_completion(operation, *args, **kwargs):
        result = await original_to_thread(operation, *args, **kwargs)
        if not fired and operation == target and (
                surface in {"lookup-results", "export", "assistant-answer", "membership"} or args[:1] == (target_resource,)):
            verify_b(engine, principal)
            fired.append(True)
        return result

    async with app.run_test(size=(100, 30)) as pilot:
        await pilot.pause()
        await app.workers.wait_for_complete()
        if surface in {"detail", "people-selector", "membership"}:
            app.action_tab("requests" if surface == "detail" else "people")
            await pilot.pause()
            await app.workers.wait_for_complete()
        app.engine = engine
        app.update_access(engine._identity)
        monkeypatch.setattr(asyncio, "to_thread", after_completion)
        if surface.startswith("lookup"):
            app.action_lookup()
            await pilot.pause()
            await app.workers.wait_for_complete()
            if surface == "lookup-results":
                app.screen.query_one("#lookup-query", Input).value = "a-only"
                app.screen.search()
        elif surface == "detail":
            app.open_detail({"request_id": "a-only"})
        elif surface == "export":
            app.action_export()
            await pilot.pause()
            app.screen.export()
        elif surface == "assistant-history":
            app.action_assistant_history()
        elif surface == "assistant-settings":
            app.action_assistant_configure()
        elif surface == "assistant-answer":
            app.query_one("#ask-question", Input).value = "Show usage"
            app.run_worker(app.ask_current())
        elif surface == "membership":
            app.team = "a-only"
            app.action_membership()
        else:
            app.action_refresh()
        await pilot.pause()
        await app.workers.wait_for_complete()
        await pilot.pause()
        assert fired, "The source must finish under A before B is verified."
        assert not published, "Completed A-only values must never briefly reach a B-visible widget."
        if surface.startswith("lookup"):
            assert len(app.screen_stack) == 1 and not app.records
            assert "sign-in changed" in str(app.query_one("#status", Static).render())
        elif surface == "detail":
            assert len(app.screen_stack) == 1
            assert "sign-in changed" in str(app.query_one("#status", Static).render())
        elif surface == "export":
            assert len(app.screen_stack) == 1
            assert "sign-in changed" in str(app.query_one("#status", Static).render())
            assert not list(tmp_path.glob("finops-reports\\*.csv"))
        elif surface in {"assistant-history", "assistant-settings", "membership"}:
            assert len(app.screen_stack) == 1
            assert any("sign-in changed" in note for note in notices)
            assert not opened
        elif surface == "assistant-answer":
            assert app.ask_reply is None and app.ask_conversation is None and app.ask_history == []
            assert "sign-in changed" in app.query_one("#ask-answer").text
        else:
            assert "A_ONLY_CATALOG" not in str(app.query_one("#people-team", Select)._options)
            assert "sign-in changed" in str(app.query_one("#note-people", Static).render())
