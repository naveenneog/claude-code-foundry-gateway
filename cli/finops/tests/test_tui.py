import pytest
from textual.widgets import Button, DataTable, Input, TabbedContent

from claude_finops.config import Config
from claude_finops.engine import Engine
from claude_finops.fake import FakeBackend
from claude_finops.tui import FinOpsApp


def example(role="owner"):
    return FinOpsApp(Engine(FakeBackend(role), "2026-09"), Config(backend="fake"))


async def settle(app, pilot):
    await pilot.pause()
    await app.workers.wait_for_complete()
    await pilot.pause()


@pytest.mark.parametrize("size", [(80, 24), (160, 48)])
async def test_nine_tabs_keyboard_and_resize(size):
    app = example()
    async with app.run_test(size=size) as pilot:
        await settle(app, pilot)
        for key, tab in [("2", "budgets"), ("3", "people"), ("4", "governance"), ("5", "usage"),
                         ("6", "trends"), ("7", "requests"), ("8", "anomalies"), ("0", "settings"), ("1", "overview")]:
            await pilot.press(key)
            await settle(app, pilot)
            assert app.query_one(TabbedContent).active == tab
            assert app.query_one(f"#table-{tab}", DataTable).row_count > 0
        assert app.query_one("#identity").region.width <= size[0]


async def test_lookup_jumps_to_scope():
    app = example()
    async with app.run_test(size=(80, 24)) as pilot:
        await settle(app, pilot)
        await pilot.press("/")
        await pilot.pause()
        app.screen.query_one("#lookup-query", Input).value = "sales-emea"
        await pilot.press("enter")
        await settle(app, pilot)
        assert app.screen.query_one("#lookup-results", DataTable).row_count >= 1
        await pilot.press("tab", "enter")
        await settle(app, pilot)
        assert app.query_one(TabbedContent).active == "budgets"


async def test_budget_form_preview_apply_status():
    app = example()
    async with app.run_test(size=(80, 24)) as pilot:
        await settle(app, pilot)
        await pilot.press("2")
        await settle(app, pilot)
        table = app.query_one("#table-budgets", DataTable)
        table.move_cursor(row=1)
        await pilot.press("e")
        await pilot.pause()
        app.screen.query_one("#amount", Input).value = "9M"
        await pilot.click("#preview")
        await settle(app, pilot)
        assert not app.screen.query_one("#apply-change", Button).disabled
        await pilot.click("#apply-change")
        await settle(app, pilot)
        assert len(app.engine.backend.writes) == 1
        assert "Apply succeeded" in str(app.screen.query_one("#form-status").render())


async def test_member_forms_are_absent():
    app = example("member")
    async with app.run_test(size=(80, 24)) as pilot:
        await settle(app, pilot)
        await pilot.press("2")
        await settle(app, pilot)
        assert app.check_action("edit", ()) is False
        await pilot.press("e")
        assert app.screen is app.screen_stack[0]
        assert not app.engine.backend.writes


async def test_palette_and_month_validation():
    app = example()
    async with app.run_test(size=(80, 24)) as pilot:
        await settle(app, pilot)
        await pilot.press(":")
        await pilot.pause()
        assert len(app.screen_stack) == 2
        await pilot.press("escape", "m")
        await pilot.pause()
        app.screen.query_one("#month-input", Input).value = "invalid"
        await pilot.click("#set-month")
        assert "YYYY-MM" in str(app.screen.query_one("#month-error").render())
