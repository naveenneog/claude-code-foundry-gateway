from textual.widgets import Input, Static

from claude_finops.config import Config
from claude_finops.engine import Engine
from claude_finops.fake import FakeBackend
from claude_finops.guarded_publication import guarded_publish
from claude_finops.tui import FinOpsApp


async def test_repeated_user_edits_remain_usable():
    app = FinOpsApp(Engine(FakeBackend(), "2026-09"), Config(backend="fake"), first_run=False)
    async with app.run_test(size=(100, 30)) as pilot:
        await pilot.pause()
        await app.workers.wait_for_complete()
        field = app.query_one("#people-query", Input)
        with guarded_publish(app.current_guard()):
            field.value = "a" * 256
        field.cursor_position = len(field.value)
        for _ in range(256):
            await app._dispatch_action(field, "delete_left", ())
        assert field.value == ""
        assert app.is_running


async def test_rejected_raw_scheduled_publication_keeps_the_app_open_and_explains():
    app = FinOpsApp(Engine(FakeBackend(), "2026-09"), Config(backend="fake"), first_run=False)
    async with app.run_test(size=(100, 30)) as pilot:
        await pilot.pause()
        await app.workers.wait_for_complete()
        with guarded_publish(app.current_guard()):
            callback = lambda: app.query_one("#status", Static).update("DEFERRED_PRIVATE_ROW")
        app.call_later(callback)
        await pilot.pause()
        assert app.is_running
        assert "Read failed (exit 3)" in str(app.query_one("#status", Static).render())
        assert "DEFERRED_PRIVATE_ROW" not in str(app.query_one("#status", Static).render())
