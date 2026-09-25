import pytest
from textual.widgets import Input

from claude_finops.config import Config
from claude_finops.engine import Engine
from claude_finops.fake import FakeBackend
from claude_finops.tui import FinOpsApp


async def settle(app, pilot):
    await pilot.pause(.15)
    await app.workers.wait_for_complete()
    await pilot.pause(.15)


@pytest.mark.parametrize("change", ["month", "request-filter", "scope"])
async def test_query_context_changes_discard_bound_cursor(change):
    app = FinOpsApp(Engine(FakeBackend(features={"request_cursor": True}), "2026-09"), Config(backend="fake"))
    async with app.run_test(size=(100, 32)) as pilot:
        await settle(app, pilot)
        app.action_tab("requests")
        await settle(app, pilot)
        app.action_next_page()
        await settle(app, pilot)
        assert app.request_cursor
        if change == "month":
            app.action_month()
            await pilot.pause()
            app.screen.query_one("#month-input", Input).value = "2026-08"
            await pilot.click("#set-month")
        elif change == "request-filter":
            app.query_one("#request-model", Input).value = "claude-sonnet"
            app.filter_requests()
        else:
            app.scope_filters = {"organization_id": "engineering"}
            app.update_access({"id": "manager", "role": "member", "manager_scope": {
                "organizations": [], "departments": [{"id": "sales-emea", "parent_id": "sales"}],
                "writable_department_ids": []}})
            assert app.scope_filters == {}
        await settle(app, pilot)
        assert app.request_cursor is None
        assert app.cursor_stack == []


async def test_profile_switch_clears_every_query_and_navigation_context(monkeypatch):
    replacement = FakeBackend()
    monkeypatch.setattr("claude_finops.ui_features.connect", lambda _: replacement)
    app = FinOpsApp(Engine(FakeBackend(), "2026-09"), Config(backend="fake"))
    async with app.run_test(size=(100, 32)) as pilot:
        await settle(app, pilot)
        app.request_before = "2026-09-10T00:00:00Z"
        app.request_filters = {"model_id": "old-profile-model"}
        app.people_query = "old-person"
        app.budget_parent = "old-unit"
        app.breadcrumbs = [("budgets", "old-unit")]
        await app.activate_profile(Config(backend="fake"))
        await settle(app, pilot)
        assert app.request_filters == {}
        assert app.request_before == app.people_query == ""
        assert app.budget_parent is None and app.breadcrumbs == []


async def test_viewer_palette_never_offers_model_configuration():
    from claude_finops.palette import FinOpsCommands
    app = FinOpsApp(Engine(FakeBackend(role="member", features={"assistant": True}), "2026-09"), Config(backend="fake"))
    async with app.run_test(size=(100, 32)) as pilot:
        await settle(app, pilot)
        names = [name for name, *_ in FinOpsCommands(app.screen).commands()]
        assert "Configure assistant model and cost" not in names


async def test_filter_chips_open_editor_by_mouse():
    from claude_finops.feature_screens import FiltersScreen
    app = FinOpsApp(Engine(FakeBackend(), "2026-09"), Config(backend="fake"))
    async with app.run_test(size=(80, 24)) as pilot:
        await settle(app, pilot)
        await pilot.click("#filter-chips")
        assert isinstance(app.screen, FiltersScreen)
