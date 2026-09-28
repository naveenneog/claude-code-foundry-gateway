import asyncio
from copy import copy

import pytest
from textual.widget import Widget
from textual.widgets import Static as RawStatic

from claude_finops.config import Config
from claude_finops.errors import FinOpsError
from claude_finops.guarded_publication import guarded_publish
from claude_finops.publication_widgets import Static
from claude_finops.tui import FinOpsApp
from test_publication_generation import bearer_tui_estate, guard_exit_code
from test_publication_widgets import capture_consoles


@pytest.mark.parametrize("route", ["mount", "copy", "compose", "reparent", "subtree"])
@pytest.mark.parametrize("changed_principal", [False, True])
async def test_retained_widget_attachment_checks_its_original_principal(
        bearer_tui_estate, monkeypatch, capsys, caplog, route, changed_principal):
    engine, principal = bearer_tui_estate
    app = FinOpsApp(engine, Config(backend="fake"), first_run=False)
    terminal, errors = capture_consoles(app)
    refused = []
    handle = app._handle_exception

    def record(error):
        refused.append(error)
        handle(error)

    monkeypatch.setattr(app, "_handle_exception", record)
    async with app.run_test(size=(100, 30)) as pilot:
        await pilot.pause()
        await app.workers.wait_for_complete()
        with engine.backend.read_cycle():
            value = engine.read("budgets")["items"][0]["scope_name"]
            origin = app.current_guard()
        with guarded_publish(origin):
            widget = Static(value, id="reuse-proof", markup=False)
        widget.styles.dock = "top"
        widget.styles.height = 1
        if route == "copy":
            original = widget
            widget = copy(widget)
            assert widget is not original
        elif route == "reparent":
            await app.screen.mount(widget)
            await pilot.pause()
            assert value in app.export_screenshot()
            await widget.remove()
        if changed_principal:
            principal[0] = "b"
            await asyncio.to_thread(engine.read, "whoami")
            await pilot.pause()
            assert guard_exit_code(origin) == 3
        else:
            assert guard_exit_code(origin) == 0
        for stream in (terminal, errors):
            stream.seek(0)
            stream.truncate()
        capsys.readouterr()
        caplog.clear()

        class Composed(Static):
            def compose(self):
                yield widget

        with guarded_publish(app.safe_message_guard()):
            target = Composed() if route == "compose" else (
                Widget(widget, id="reuse-container") if route == "subtree" else widget)
        if route in {"compose", "subtree"}:
            target.styles.dock = "top"
            target.styles.height = 1
        try:
            await app.screen.mount(target)
        except FinOpsError as error:
            record(error)
        await pilot.pause()
        screenshot = app.export_screenshot()
        captured = capsys.readouterr()
        output = terminal.getvalue() + errors.getvalue() + captured.out + captured.err + caplog.text
        if changed_principal:
            assert value not in screenshot, "A retained A-origin widget reached B's display."
            assert value not in output
            assert refused and all(isinstance(error, FinOpsError) and error.code == 3 for error in refused)
            assert not app.query("#reuse-proof"), "Rejection must precede insertion into the DOM."
            if route == "subtree":
                assert not app.query("#reuse-container"), "A retained subtree is validated before any insertion."
        else:
            assert not refused
            assert value in screenshot
        assert app.is_running and app._exception is None


@pytest.mark.parametrize("changed_principal", [False, True])
async def test_protected_instances_cannot_replace_their_class(
        bearer_tui_estate, capsys, caplog, changed_principal):
    engine, principal = bearer_tui_estate
    app = FinOpsApp(engine, Config(backend="fake"), first_run=False)
    terminal, errors = capture_consoles(app)
    async with app.run_test(size=(100, 30)) as pilot:
        await pilot.pause()
        await app.workers.wait_for_complete()
        value = engine.read("budgets")["items"][0]["scope_name"]
        if changed_principal:
            principal[0] = "b"
            await asyncio.to_thread(engine.read, "whoami")
            await pilot.pause()
        widget = app.query_one("#status", Static)
        original_type = type(widget)
        refused = None
        try:
            try:
                widget.__class__ = RawStatic
                emit = widget.update
                emit(value)
            except FinOpsError as error:
                refused = error
            await pilot.pause()
            screenshot = app.export_screenshot()
            assert value not in screenshot
            assert isinstance(refused, FinOpsError) and refused.code == 3
            assert type(widget) is original_type
        finally:
            if type(widget) is not original_type:
                object.__setattr__(widget, "__class__", original_type)
        captured = capsys.readouterr()
        assert value not in terminal.getvalue() + errors.getvalue() + captured.out + captured.err + caplog.text
        with engine.backend.read_cycle():
            current_value = engine.read("budgets")["items"][0]["scope_name"]
            current = app.current_guard()
        with guarded_publish(current):
            widget.update(current_value)
        await pilot.pause()
        assert current_value in app.export_screenshot()
        assert app.is_running and app._exception is None
