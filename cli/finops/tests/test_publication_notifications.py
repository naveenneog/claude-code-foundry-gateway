import asyncio

import pytest
from textual.widgets._toast import Toast

from claude_finops.config import Config
from claude_finops.errors import FinOpsError
from claude_finops.tui import FinOpsApp
from test_publication_generation import bearer_tui_estate
from test_publication_widgets import capture_consoles


async def test_raw_notify_cannot_publish_a_previous_principals_value(bearer_tui_estate, capsys, caplog):
    engine, principal = bearer_tui_estate
    app = FinOpsApp(engine, Config(backend="fake"), first_run=False)
    terminal, errors = capture_consoles(app)
    async with app.run_test(size=(100, 30), notifications=True) as pilot:
        await pilot.pause()
        await app.workers.wait_for_complete()
        value = engine.read("budgets")["items"][0]["scope_name"]
        principal[0] = "b"
        await asyncio.to_thread(engine.read, "whoami")
        await pilot.pause()
        refused = None
        try:
            app.notify(value)
        except FinOpsError as error:
            refused = error
        await pilot.pause()
        captured = capsys.readouterr()
        assert value not in app.export_screenshot()
        assert value not in terminal.getvalue() + errors.getvalue() + captured.out + captured.err + caplog.text
        assert isinstance(refused, FinOpsError) and refused.code == 3
        assert app.is_running and app._exception is None


@pytest.mark.parametrize("delivery", ["current", "before-queue", "queued", "shown"])
async def test_notification_retains_origin_until_visible_delivery(
        bearer_tui_estate, capsys, caplog, delivery):
    engine, principal = bearer_tui_estate
    app = FinOpsApp(engine, Config(backend="fake"), first_run=False)
    terminal, errors = capture_consoles(app)
    async with app.run_test(size=(100, 30), notifications=True) as pilot:
        await pilot.pause()
        await app.workers.wait_for_complete()
        with engine.backend.read_cycle():
            value = engine.read("budgets")["items"][0]["scope_name"]
            origin = app.current_guard()
        if delivery == "before-queue":
            principal[0] = "b"
            await asyncio.to_thread(engine.read, "whoami")
            await pilot.pause()
            with pytest.raises(FinOpsError, match="sign-in changed"):
                app.publish_notification(value, origin=origin, timeout=60)
        else:
            app.publish_notification(value, origin=origin, timeout=60)
            if delivery == "queued":
                engine.backend.invalidate_credentials()
            elif delivery == "shown":
                await pilot.pause()
                assert value in app.export_screenshot() and app.query(Toast)
                principal[0] = "b"
                await asyncio.to_thread(engine.read, "whoami")
        await pilot.pause()
        screenshot = app.export_screenshot()
        captured = capsys.readouterr()
        if delivery == "current":
            assert value in screenshot and app.query(Toast)
        else:
            assert value not in screenshot
            assert not app.query(Toast)
            assert value not in terminal.getvalue() + errors.getvalue() + captured.out + captured.err + caplog.text
        await pilot.press("ctrl+f", "x")
        assert app.query_one("#quick-filter").value == "x"
        assert app.is_running and app._exception is None


async def test_notification_rechecks_after_queue_acceptance_before_toast_creation(
        bearer_tui_estate, monkeypatch, capsys, caplog):
    engine, _ = bearer_tui_estate
    app = FinOpsApp(engine, Config(backend="fake"), first_run=False)
    terminal, errors = capture_consoles(app)
    async with app.run_test(size=(100, 30), notifications=True) as pilot:
        await pilot.pause()
        await app.workers.wait_for_complete()
        with engine.backend.read_cycle():
            value = engine.read("budgets")["items"][0]["scope_name"]
            origin = app.current_guard()
        accepted = asyncio.Event()
        refresh = app._refresh_notifications
        with monkeypatch.context() as patch:
            patch.setattr(app, "_refresh_notifications", accepted.set)
            app.publish_notification(value, origin=origin, timeout=60)
            await asyncio.wait_for(accepted.wait(), timeout=3)
            assert list(app._notifications)
            engine.backend.invalidate_credentials()
        refresh()
        await pilot.pause()
        assert value not in app.export_screenshot() and not app.query(Toast)
        captured = capsys.readouterr()
        assert value not in terminal.getvalue() + errors.getvalue() + captured.out + captured.err + caplog.text
        assert app.is_running and app._exception is None


async def test_cached_toast_checks_its_origin_without_an_identity_revision_change(bearer_tui_estate):
    engine, _ = bearer_tui_estate
    app = FinOpsApp(engine, Config(backend="fake"), first_run=False)
    async with app.run_test(size=(100, 30), notifications=True) as pilot:
        await pilot.pause()
        await app.workers.wait_for_complete()
        with engine.backend.read_cycle():
            value = engine.read("budgets")["items"][0]["scope_name"]
            origin = app.current_guard()
        app.publish_notification(value, origin=origin, timeout=60)
        await pilot.pause()
        assert value in app.export_screenshot()
        revision = engine.identity_revision
        engine.backend.invalidate_credentials()
        assert engine.identity_revision == revision
        assert value not in app.export_screenshot()
        await pilot.pause()
        assert not app.query(Toast)
        assert app.is_running and app._exception is None
