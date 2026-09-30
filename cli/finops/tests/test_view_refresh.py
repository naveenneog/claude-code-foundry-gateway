import asyncio
from functools import wraps

import pytest
from textual.widgets import Input, TabbedContent

from claude_finops.config import Config
from claude_finops.dashboard import DashboardPanel
from claude_finops.dashboard_drill import DashboardRows
from claude_finops.engine import Engine
from claude_finops.fake import FakeBackend
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


@pytest.mark.parametrize("surface,target", SURFACES, ids=[surface for surface, _ in SURFACES])
@pytest.mark.parametrize("navigation", ["switch", "current"])
async def test_compound_action_starts_one_view_refresh(monkeypatch, surface, target, navigation):
    app = FinOpsApp(
        Engine(FakeBackend(features={"advanced": True}), "2026-09"),
        Config(backend="fake"), redact=surface == "lookup-person", first_run=False,
    )
    focused = {tab: asyncio.Event() for tab in ("overview", "people", "budgets", "usage", "trends", "anomalies", "advanced")}
    focus_pane = TabbedContent._on_tab_pane_focused

    @wraps(focus_pane)
    def record_focus(tabs, event):
        focus_pane(tabs, event)
        if tabs.id == "main-tabs" and event.tab_pane.id in focused:
            focused[event.tab_pane.id].set()

    monkeypatch.setattr(TabbedContent, "_on_tab_pane_focused", record_focus)
    async with app.run_test(size=(100, 32)) as pilot:
        await pilot.pause()
        await app.workers.wait_for_complete()
        await focused["overview"].wait()
        drill = DashboardRows(app.query_one("#dash-rank", DashboardPanel))
        initial = target if navigation == "current" else ("budgets" if target == "overview" else "overview")
        if initial != "overview":
            app.action_tab(initial)
            await pilot.pause()
            await app.workers.wait_for_complete()
            await focused[initial].wait()

        workers, loaded = [], []
        release, activated = asyncio.Event(), asyncio.Event()
        refresh, load, dispatch = app.action_refresh, app.load_tab, app._dispatch_message

        def record_refresh():
            worker = refresh()
            workers.append(worker)
            return worker

        async def held_load(tab):
            loaded.append(tab)
            await release.wait()
            return await load(tab)

        async def record_activation(message):
            await dispatch(message)
            if isinstance(message, TabbedContent.TabActivated) and message.pane.id == target:
                activated.set()

        monkeypatch.setattr(app, "action_refresh", record_refresh)
        monkeypatch.setattr(app, "load_tab", held_load)
        monkeypatch.setattr(app, "_dispatch_message", record_activation)
        try:
            invoke_compound_action(app, drill, surface, target)
            if navigation == "switch":
                await activated.wait()
            await pilot.pause()
        finally:
            release.set()
        if workers:
            await workers[-1].wait()
        assert len(workers) == 1, f"{surface} started {len(workers)} exclusive view workers."
        assert not workers[0].is_cancelled
        assert app.active == target and loaded == [target]
        assert target in app.data
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
