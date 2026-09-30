import asyncio
from functools import wraps

import pytest
from textual.widgets import DataTable, Input, TabbedContent, TabPane

from claude_finops.config import Config
from claude_finops.dashboard import DashboardPanel
from claude_finops.dashboard_drill import DashboardRows
from claude_finops.engine import Engine
from claude_finops.errors import FinOpsError
from claude_finops.fake import FakeBackend
from claude_finops.screens import DetailScreen, LookupScreen
from claude_finops.tui import FinOpsApp


SECRET_PERSON = "11111111-2222-3333-4444-555555555555"
SURFACES = [
    ("lookup-person", "people"),
    ("lookup-team", "people"),
    ("lookup-unit", "budgets"),
    ("lookup-model", "usage"),
    ("breadcrumb", "budgets"),
    ("saved-view", "usage"),
    ("comparison", "trends"),
    ("request-time-usage", "usage"),
    ("priced-usage", "usage"),
    ("overview-ranking", "overview"),
    ("dashboard-budget", "budgets"),
    ("dashboard-usage", "usage"),
    ("dashboard-anomaly", "anomalies"),
    ("advanced-view", "advanced"),
    ("advanced-view-same-choice", "advanced"),
]


def invoke_compound_action(app, drill, surface, target):
    if surface.startswith("lookup-"):
        kind = surface.removeprefix("lookup-")
        key = {"person": SECRET_PERSON, "team": "sales-emea", "unit": "sales", "model": "model-a"}[kind]
        app.open_lookup_result(
            dict(kind=kind, id=key, name="Private Person", department_id="sales-emea", tab=target),
            read_guard=app.current_guard(),
        )
    elif surface == "breadcrumb":
        app.breadcrumbs = [("budgets", None)]
        app.budget_parent = "sales"
        app.action_clear_filter()
    elif surface == "saved-view":
        app.restore_view(
            dict(tab=target, month="2026-08", dimension="model", interval="hour",
                 filters={"department_id": "sales-emea"}),
            read_guard=app.current_guard(),
        )
    elif surface == "comparison":
        app.scope_filters.update({"from": "2026-09-01T00:00:00Z", "to": "2026-09-02T00:00:00Z"})
        app.set_comparison("2026-08")
    elif surface == "request-time-usage":
        app.engine.backend.name = "Direct"
        app.action_request_time_usage()
    elif surface == "priced-usage":
        app.usage_basis = "ledger"
        app.action_priced_usage()
    elif surface == "overview-ranking":
        app.action_overview_rank("department")
    elif surface == "dashboard-budget":
        drill.navigate_selected("budget", {"scope_id": "sales-emea"})
    elif surface == "dashboard-usage":
        drill.navigate_selected("department", {"id": "sales-emea"})
    elif surface == "dashboard-anomaly":
        drill.navigate_selected("anomaly", {"id": "anomaly-example", "severity": "warning"})
    elif surface in {"advanced-view", "advanced-view-same-choice"}:
        app.action_advanced("models" if surface == "advanced-view-same-choice" else "pools")
    else:
        raise AssertionError(f"Uncovered compound action: {surface}")


@pytest.fixture
def pane_focus(monkeypatch):
    focused = {tab: asyncio.Event() for tab in ("overview", "people", "budgets", "usage", "trends", "requests", "anomalies", "advanced")}
    focus_pane = TabbedContent._on_tab_pane_focused

    @wraps(focus_pane)
    def record_focus(tabs, event):
        focus_pane(tabs, event)
        if tabs.id == "main-tabs" and event.tab_pane.id in focused:
            focused[event.tab_pane.id].set()

    monkeypatch.setattr(TabbedContent, "_on_tab_pane_focused", record_focus)
    return focused


@pytest.mark.parametrize("surface,target", SURFACES, ids=[surface for surface, _ in SURFACES])
@pytest.mark.parametrize("navigation", ["switch", "current", "notice-switch", "notice-current"])
async def test_compound_action_starts_one_view_refresh(monkeypatch, pane_focus, surface, target, navigation):
    app = FinOpsApp(
        Engine(FakeBackend(features={"advanced": True}), "2026-09"),
        Config(backend="fake"), redact=surface == "lookup-person", first_run=False,
    )
    async with app.run_test(size=(100, 32)) as pilot:
        await pilot.pause()
        await app.workers.wait_for_complete()
        await pane_focus["overview"].wait()
        drill = DashboardRows(app.query_one("#dash-rank", DashboardPanel))
        initial = target if navigation.endswith("current") else ("budgets" if target == "overview" else "overview")
        if initial != "overview":
            app.action_tab(initial)
            await pilot.pause()
            await app.workers.wait_for_complete()
            await pane_focus[initial].wait()

        workers, loaded = [], []
        release = asyncio.Event()
        refresh, load = app.action_refresh, app.load_tab

        def record_refresh():
            worker = refresh()
            workers.append(worker)
            return worker

        async def held_load(tab):
            loaded.append(tab)
            await release.wait()
            return await load(tab)

        monkeypatch.setattr(app, "action_refresh", record_refresh)
        monkeypatch.setattr(app, "load_tab", held_load)
        if navigation.startswith("notice-"):
            app._principal_notice = True
        try:
            invoke_compound_action(app, drill, surface, target)
            assert len(workers) == 1, "An accepted compound action must own its refresh before returning."
            await pilot.pause()
        finally:
            release.set()
        if workers:
            await workers[-1].wait()
        assert len(workers) == 1, f"{surface} started {len(workers)} exclusive view workers."
        assert not workers[0].is_cancelled
        assert app.active == target and loaded == [target]
        assert target in app.data
        if navigation.startswith("notice-"):
            assert app._principal_notice, "Refreshing must not clear the principal notice to bypass it."
        if surface == "lookup-person":
            field = app.query_one("#people-query", Input)
            assert field.value == SECRET_PERSON and field.password
            assert SECRET_PERSON not in app.export_screenshot()
        if surface == "saved-view":
            assert app.engine.month == "2026-08" and app.dimension == "model" and app.interval == "hour"
            assert app.scope_filters == {"department_id": "sales-emea"}
        if surface == "comparison":
            assert app.compare_period == "2026-08"
            assert "from" not in app.scope_filters and "to" not in app.scope_filters
        if surface == "dashboard-usage":
            assert app.scope_filters["department_id"] == "sales-emea"
            assert any(resource == "distribution" and params.get("department_id") == "sales-emea"
                       for resource, params in app.engine.backend.reads)


@pytest.mark.parametrize("activation", ["stale", "missing-main"])
async def test_lookup_owns_refresh_when_activation_cannot_deliver(monkeypatch, pane_focus, activation):
    app = FinOpsApp(Engine(FakeBackend(), "2026-09"), Config(backend="fake"), first_run=False)
    async with app.run_test(size=(100, 32)) as pilot:
        await pilot.pause()
        await app.workers.wait_for_complete()
        await pane_focus["overview"].wait()
        tabs = app.query_one("#main-tabs", TabbedContent)
        event = TabbedContent.TabActivated(tabs, tabs.get_tab("overview" if activation == "stale" else "people"))
        workers = []
        refresh = app.action_refresh

        def record_refresh():
            worker = refresh()
            workers.append(worker)
            return worker

        monkeypatch.setattr(app, "action_refresh", record_refresh)
        with tabs.prevent(TabbedContent.TabActivated):
            app.open_lookup_result(
                dict(kind="person", id=SECRET_PERSON, department_id="sales-emea", tab="people"),
                read_guard=app.current_guard(),
            )
        assert len(workers) == 1, "An accepted lookup must own a refresh without relying on queued activation."
        await workers[0].wait()
        assert app.people_query == SECRET_PERSON and "people" in app.data
        assert app.query_one("#people-query", Input).value == SECRET_PERSON
        if activation == "missing-main":
            app.set_focus(None)
            with app.batch_update():
                await app.screen.remove_children()
                assert app.is_running and not app.query("#main-tabs")
                app.switched(event)
        else:
            assert event.pane.id != app.active
            app.switched(event)
        assert len(workers) == 1 and not workers[0].is_cancelled
        assert app.people_query == SECRET_PERSON and "people" in app.data
        assert app._exception is None


async def test_principal_notice_does_not_authorize_an_expired_lookup(monkeypatch, pane_focus):
    backend = FakeBackend()
    app = FinOpsApp(Engine(backend, "2026-09"), Config(backend="fake"), first_run=False)
    async with app.run_test(size=(100, 32)) as pilot:
        await pilot.pause()
        await app.workers.wait_for_complete()
        await pane_focus["overview"].wait()
        previous = app.current_guard()
        backend.role = "member"
        await asyncio.to_thread(app.engine.read, "whoami")
        await pilot.pause()
        assert app._principal_notice
        refreshes = []
        monkeypatch.setattr(app, "action_refresh", lambda: refreshes.append(True))
        with pytest.raises(FinOpsError, match="sign-in changed"):
            app.open_lookup_result(
                dict(kind="person", id=SECRET_PERSON, department_id="sales-emea", tab="people"),
                read_guard=previous,
            )
        assert not refreshes
        assert not app.people_query and not app.query_one("#people-query", Input).value
        assert SECRET_PERSON not in app.export_screenshot()


@pytest.mark.parametrize("notice", [False, True], ids=["ordinary", "notice"])
async def test_delayed_pane_focus_cannot_retarget_a_lookup(monkeypatch, pane_focus, notice):
    app = FinOpsApp(Engine(FakeBackend(), "2026-09"), Config(backend="fake"), first_run=False)
    async with app.run_test(size=(100, 32)) as pilot:
        await pilot.pause()
        await app.workers.wait_for_complete()
        await pane_focus["overview"].wait()
        tabs = app.query_one("#main-tabs", TabbedContent)
        delayed = TabPane.Focused(tabs.get_pane("overview"))
        active_changes, workers = [], []
        app.watch(tabs, "active", lambda value: active_changes.append(value), init=False)
        release = asyncio.Event()
        refresh, load = app.action_refresh, app.load_tab

        def record_refresh():
            worker = refresh()
            workers.append(worker)
            return worker

        async def held_load(tab):
            await release.wait()
            return await load(tab)

        monkeypatch.setattr(app, "action_refresh", record_refresh)
        monkeypatch.setattr(app, "load_tab", held_load)
        app._principal_notice = notice
        try:
            app.open_lookup_result(
                dict(kind="person", id=SECRET_PERSON, department_id="sales-emea", tab="people"),
                read_guard=app.current_guard(),
            )
            assert len(workers) == 1, "An accepted lookup must own its refresh before processing old focus."
            assert app.focused.id == "table-people"
            assert tabs.post_message(delayed)
            await pilot.pause()
        finally:
            release.set()
        await workers[-1].wait()
        assert "overview" not in active_changes, "An obsolete focus event retargeted the current lookup."
        assert len(workers) == 1 and not workers[0].is_cancelled
        assert app.active == "people" and app.people_query == SECRET_PERSON
        assert "people" in app.data


@pytest.mark.parametrize("navigation", ["switch", "current", "notice-switch", "notice-current"])
@pytest.mark.parametrize("paging", ["offset", "cursor"])
async def test_request_lookup_refreshes_once_and_keeps_detail_and_paging(monkeypatch, pane_focus, navigation, paging):
    backend = FakeBackend(features={"request_cursor": paging == "cursor"})
    app = FinOpsApp(Engine(backend, "2026-09"), Config(backend="fake"), first_run=False)
    async with app.run_test(size=(100, 32)) as pilot:
        await pilot.pause()
        await app.workers.wait_for_complete()
        await pane_focus["overview"].wait()
        app.action_tab("requests")
        await pilot.pause()
        await app.workers.wait_for_complete()
        await pane_focus["requests"].wait()
        app.request_page = 1
        app.request_cursor = "50"
        app.cursor_stack = [None]
        app.request_before = "2026-09-25T00:00:00Z"
        app.request_filters = {"model_id": "claude-sonnet-5"}
        await app.action_refresh().wait()
        request_id = app.records["requests"][7]["request_id"]
        if navigation.endswith("switch"):
            app.action_tab("overview")
            await pilot.pause()
            await app.workers.wait_for_complete()
            await pane_focus["overview"].wait()

        before = (app.request_page, app.request_cursor, list(app.cursor_stack),
                  app.request_before, dict(app.request_filters))
        views, details = [], []
        release = asyncio.Event()
        refresh, detail, load = app.action_refresh, app._open_detail, app.load_tab

        def record_view():
            worker = refresh()
            views.append(worker)
            return worker

        def record_detail(*args, **kwargs):
            worker = detail(*args, **kwargs)
            details.append(worker)
            return worker

        async def held_view(tab):
            await release.wait()
            return await load(tab)

        monkeypatch.setattr(app, "action_refresh", record_view)
        monkeypatch.setattr(app, "_open_detail", record_detail)
        monkeypatch.setattr(app, "load_tab", held_view)
        if navigation.startswith("notice-"):
            app._principal_notice = True
        try:
            app.open_lookup_result(dict(kind="request", id=request_id, tab="requests"),
                                   read_guard=app.current_guard())
            await pilot.pause()
            assert len(views) == 1, "Every request lookup must own one view refresh."
            assert len(details) == 1, "A request lookup must open its detail exactly once."
            await details[0].wait()
            await pilot.pause()
            modal = app.screen
            assert isinstance(modal, DetailScreen) and modal.data["request_id"] == request_id
        finally:
            release.set()
        await views[0].wait()
        await pilot.pause()
        assert len(views) == len(details) == 1
        assert not views[0].is_cancelled and not details[0].is_cancelled
        assert app.screen is modal and modal.data["request_id"] == request_id
        assert app.active == "requests" and app.pending_selection is None
        assert before == (app.request_page, app.request_cursor, list(app.cursor_stack),
                          app.request_before, app.request_filters), "Request lookup reset paging or filters."
        table = app.query_one("#table-requests", DataTable)
        assert app.records["requests"][table.cursor_row]["request_id"] == request_id
        if navigation.startswith("notice-"):
            assert app._principal_notice


async def test_first_lookup_input_clears_notice_before_action(monkeypatch, pane_focus):
    app = FinOpsApp(Engine(FakeBackend(), "2026-09"), Config(backend="fake"), first_run=False)
    async with app.run_test(size=(100, 32)) as pilot:
        await pilot.pause()
        await app.workers.wait_for_complete()
        await pane_focus["overview"].wait()
        notices = []
        lookup = app.action_lookup

        def record_lookup():
            notices.append(app._principal_notice)
            return lookup()

        monkeypatch.setattr(app, "action_lookup", record_lookup)
        app._principal_notice = True
        await pilot.press("/")
        await pilot.pause()
        await app.workers.wait_for_complete()
        assert notices == [False], "Input must clear the notice before dispatching the lookup action."
        assert isinstance(app.screen, LookupScreen)
