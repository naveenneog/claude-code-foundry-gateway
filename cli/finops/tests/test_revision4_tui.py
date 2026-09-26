import pytest
from textual.widgets import Button, Input, Select, TabbedContent, TextArea

from claude_finops.config import Config
from claude_finops.engine import Engine
from claude_finops.fake import FakeBackend
from claude_finops.tui import FinOpsApp
from claude_finops.feature_screens import TourScreen


async def settle(app, pilot):
    await pilot.pause(.3)
    await app.workers.wait_for_complete()
    await pilot.pause(.3)


async def test_advertised_tabs_and_assistant_reply():
    app = FinOpsApp(Engine(FakeBackend(features={"assistant": True, "approvals": True, "advanced": True}), "2026-09"),
                    Config(backend="fake"))
    async with app.run_test(size=(100, 32)) as pilot:
        await settle(app, pilot)
        assert {"ask", "approvals", "advanced"} <= app.allowed_tabs
        await pilot.press("a")
        await settle(app, pilot)
        app.query_one("#ask-question", Input).value = "Show token usage"
        await pilot.click("#ask-send")
        await settle(app, pilot)
        assert "Sales" in app.query_one("#ask-answer", TextArea).text
        assert app.ask_reply["charts"]
        await pilot.press("9")
        await settle(app, pilot)
        assert app.active == "approvals"


async def test_unadvertised_tabs_are_hidden_and_keys_do_not_open_them():
    app = FinOpsApp(Engine(FakeBackend(), "2026-09"), Config(backend="fake"))
    async with app.run_test(size=(80, 24)) as pilot:
        await settle(app, pilot)
        assert not app.query_one(TabbedContent).get_tab("approvals").display
        assert not app.query_one(TabbedContent).get_tab("ask").display
        await pilot.press("9", "a")
        assert app.active == "overview"


async def test_owner_mode_form_preview_and_apply():
    backend = FakeBackend()
    app = FinOpsApp(Engine(backend, "2026-09"), Config(backend="fake"))
    async with app.run_test(size=(100, 32)) as pilot:
        await settle(app, pilot)
        app.action_mode()
        await pilot.pause(.3)
        app.screen.query_one("#field-scope", Input).value = "sales-emea"
        app.screen.query_one("#field-mode", Select).value = "allowance"
        app.screen.query_one("#field-allowance", Input).value = "10"
        await pilot.click("#action-preview")
        await settle(app, pilot)
        assert not app.screen.query_one("#action-apply", Button).disabled
        await pilot.click("#action-apply")
        await settle(app, pilot)
        assert backend.catalog["departments"][0]["attributes"]["enforcement"] == "allowance"


async def test_first_run_tour_and_identity_saved_view():
    app = FinOpsApp(Engine(FakeBackend(), "2026-09"), Config(backend="fake"), first_run=True)
    async with app.run_test(size=(100, 32)) as pilot:
        await settle(app, pilot)
        assert isinstance(app.screen, TourScreen)
        await pilot.click("#tour-start")
        assert app.preferences.toured
        app.action_save_view()
        await pilot.pause(.2)
        app.screen.query_one("#field-name", Input).value = "My month"
        await pilot.click("#action-preview")
        await settle(app, pilot)
        await pilot.click("#action-apply")
        await settle(app, pilot)
        assert "My month" in app.preferences.views()


async def test_comparison_and_server_cursor_navigation():
    app = FinOpsApp(Engine(FakeBackend(features={"request_cursor": True}), "2026-09"), Config(backend="fake"))
    async with app.run_test(size=(100, 32)) as pilot:
        await settle(app, pilot)
        app.set_comparison("2026-08")
        await settle(app, pilot)
        assert app.data["trends"]["comparison_period"] == "2026-08"
        await pilot.press("7")
        await settle(app, pilot)
        first = app.records["requests"][0]["request_id"]
        await pilot.press("n")
        await settle(app, pilot)
        assert app.records["requests"][0]["request_id"] != first
        await pilot.press("p")
        await settle(app, pilot)
        assert app.records["requests"][0]["request_id"] == first


async def test_budget_tree_drills_to_people_and_back():
    from textual.widgets import DataTable
    app = FinOpsApp(Engine(FakeBackend(), "2026-09"), Config(backend="fake"))
    async with app.run_test(size=(100, 32)) as pilot:
        await settle(app, pilot)
        await pilot.press("2")
        await settle(app, pilot)
        await pilot.press("enter")
        await settle(app, pilot)
        assert app.budget_parent == "sales"
        app.query_one("#table-budgets", DataTable).move_cursor(row=1)
        await pilot.press("enter")
        await settle(app, pilot)
        assert app.active == "people" and app.team == "sales-emea"
        await pilot.press("escape")
        await settle(app, pilot)
        assert app.active == "budgets"


async def test_approval_paging_and_queue_change_reset_cursor():
    backend = FakeBackend(features={"approvals": True})
    engine = Engine(backend, "2026-09")
    for index in range(55):
        engine.request_budget("team", "sales-emea", "9M", f"Capacity {index}", apply=True)
    app = FinOpsApp(engine, Config(backend="fake"))
    async with app.run_test(size=(100, 32)) as pilot:
        await settle(app, pilot)
        await pilot.press("9")
        await settle(app, pilot)
        assert len(app.records["approvals"]) == 50
        await pilot.press("n")
        await settle(app, pilot)
        assert len(app.records["approvals"]) == 5
        app.query_one("#approval-view", Select).value = "history"
        await settle(app, pilot)
        assert app.feature_cursor is None and not app.feature_cursor_stack
