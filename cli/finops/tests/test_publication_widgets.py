import asyncio
from functools import partial
import io

import pytest
from rich.console import Console
from textual import events
from textual.app import App
from textual.message_pump import CallbackError
from textual.widgets import Input, Static

from claude_finops.config import Config
from claude_finops.engine import Engine
from claude_finops.errors import FinOpsError
from claude_finops.fake import FakeBackend
from claude_finops.guarded_publication import guarded_publish
from claude_finops.tui import FinOpsApp
from test_publication_generation import bearer_tui_estate


class BoundedContextCycle(RuntimeError):
    reads = 0

    @property
    def __context__(self):
        self.reads += 1
        assert self.reads < 3, "A repeated exception must end traversal, not wait for a timeout."
        return self


async def test_repeated_user_edits_remain_usable():
    app = FinOpsApp(Engine(FakeBackend(), "2026-09"), Config(backend="fake"), first_run=False)
    async with app.run_test(size=(100, 30), notifications=True) as pilot:
        await pilot.pause()
        await app.workers.wait_for_complete()
        field = app.query_one("#people-query", Input)
        with guarded_publish(app.current_guard()):
            field.value = "a" * 1024
        field.cursor_position = len(field.value)
        for _ in range(1024):
            await app._dispatch_action(field, "delete_left", ())
        assert field.value == ""
        assert app.is_running


def schedule_callback(app, scheduler, callback, *args):
    loop = asyncio.get_running_loop()
    if scheduler == "set_timer":
        app.set_timer(.01, partial(callback, *args))
    elif scheduler == "call_soon":
        loop.call_soon(callback, *args)
    elif scheduler == "call_at":
        loop.call_at(loop.time(), callback, *args)
    elif scheduler == "timer_event":
        timer = app.set_timer(10, pause=True)
        app.post_message(events.Timer(timer=timer, time=loop.time(), count=1,
                                      callback=partial(callback, *args)))
    else:
        getattr(app, scheduler)(callback, *args)


def capture_consoles(app):
    terminal, errors = io.StringIO(), io.StringIO()
    app.console = Console(file=terminal, width=200)
    app.error_console = Console(file=errors, width=200)
    return terminal, errors


@pytest.mark.parametrize("scheduler", [
    "call_later", "set_timer", "call_after_refresh", "call_next", "call_soon", "call_at", "timer_event",
])
async def test_rejected_raw_scheduled_publication_keeps_the_app_open_and_explains(
        scheduler, capsys, caplog):
    app = FinOpsApp(Engine(FakeBackend(), "2026-09"), Config(backend="fake"), first_run=False)
    terminal, errors = capture_consoles(app)
    payload = "ROUND7_A_ONLY_COSTS"
    executed = asyncio.Event()
    fatal, running, responsive = None, False, False
    status, screen = "", ""

    def publish(value):
        try:
            app.query_one("#status", Static).update(value)
        finally:
            executed.set()

    try:
        async with app.run_test(size=(100, 30)) as pilot:
            await pilot.pause()
            await app.workers.wait_for_complete()
            with guarded_publish(app.current_guard()):
                callback = partial(publish, payload)
            schedule_callback(app, scheduler, callback)
            await asyncio.wait_for(executed.wait(), timeout=3)
            running = app.is_running
            status = str(app.query_one("#status", Static).render())
            screen = app.export_screenshot()
            if running:
                await pilot.press("ctrl+f", "x", "y", "backspace", "z")
                responsive = app.query_one("#quick-filter", Input).value == "xz"
            app._print_error_renderables()
    except (FinOpsError, CallbackError) as error:
        fatal = error
    captured = capsys.readouterr()
    output = terminal.getvalue() + errors.getvalue() + captured.out + captured.err + caplog.text + screen
    assert payload not in output
    assert fatal is None and app._exception is None
    assert running and responsive
    assert "Read failed (exit 3)" in status


async def test_input_edits_never_replace_the_content_credential_guard(bearer_tui_estate):
    engine, _ = bearer_tui_estate
    app = FinOpsApp(engine, Config(backend="fake"), first_run=False)
    async with app.run_test(size=(100, 30)) as pilot:
        await pilot.pause()
        await app.workers.wait_for_complete()
        field = app.query_one("#people-query", Input)
        with engine.backend.read_cycle():
            value = engine.read("budgets")["items"][0]["scope_name"]
            origin = app.current_guard()
        with guarded_publish(origin):
            field.value = value
        field.cursor_position = len(field.value)
        await app._dispatch_action(field, "delete_left", ())
        assert field.value == value[:-1]
        revision = engine.identity_revision
        engine.backend.invalidate_credentials()
        assert engine.identity_revision == revision
        await app._dispatch_action(field, "delete_left", ())
        assert field.value == ""
        assert not app.data
        assert "Read failed (exit 3)" in str(app.query_one("#status", Static).render())


async def test_refused_overview_screen_callback_never_renders_its_arguments(
        bearer_tui_estate, monkeypatch, capsys, caplog):
    engine, _ = bearer_tui_estate
    app = FinOpsApp(engine, Config(backend="fake"), first_run=False)
    terminal, errors = capture_consoles(app)
    payload = "ROUND7_A_ONLY_COSTS"
    handled = asyncio.Event()
    rendered, observed = [], []
    original = app._handle_exception

    def handle(error):
        observed.append(error)
        original(error)
        handled.set()

    monkeypatch.setattr(app, "_handle_exception", handle)
    fatal, running, responsive = None, False, False
    screen = ""
    try:
        async with app.run_test(size=(100, 30)) as pilot:
            await pilot.pause()
            await app.workers.wait_for_complete()
            assert app.data.get("overview")
            app.data["overview"]["round_seven_private"] = payload
            monkeypatch.setattr(app, "render_tab", lambda *args: rendered.append(args))
            app.on_resize()
            engine.backend.invalidate_credentials()
            await asyncio.wait_for(handled.wait(), timeout=3)
            running = app.is_running
            screen = app.export_screenshot()
            if running:
                await pilot.press("ctrl+f", "x")
                responsive = app.query_one("#quick-filter", Input).value == "x"
            app._print_error_renderables()
    except (FinOpsError, CallbackError) as error:
        fatal = error
    captured = capsys.readouterr()
    assert rendered == [], "The originating guard must reject before calling the renderer."
    output = terminal.getvalue() + errors.getvalue() + captured.out + captured.err + caplog.text + screen
    assert payload not in output
    assert observed and fatal is None and app._exception is None
    assert running and responsive


@pytest.mark.parametrize("wrapping", ["direct", "cause", "context"])
async def test_application_exception_boundary_uses_only_the_safe_refusal(wrapping, capsys):
    app = FinOpsApp(Engine(FakeBackend(), "2026-09"), Config(backend="fake"), first_run=False)
    terminal, errors = capture_consoles(app)
    private = "ROUND7_A_ONLY_COSTS"
    safe = FinOpsError("The sign-in changed. Previous data is unavailable.", 3)
    error = safe
    if wrapping != "direct":
        error = CallbackError(f"callback arguments: {private}")
        if wrapping == "cause":
            error.__cause__ = safe
        else:
            error.__context__ = safe
    fatal, running, status, notice, screen = None, False, "", "", ""
    try:
        async with app.run_test(size=(100, 30)) as pilot:
            await pilot.pause()
            await app.workers.wait_for_complete()
            app._handle_exception(error)
            running = app.is_running
            status = str(app.query_one("#status", Static).render())
            notice = str(app.query_one("#note-overview", Static).render())
            screen = app.export_screenshot()
            app._print_error_renderables()
    except (FinOpsError, CallbackError) as caught:
        fatal = caught
    captured = capsys.readouterr()
    assert private not in terminal.getvalue() + errors.getvalue() + captured.out + captured.err + screen
    assert fatal is None and app._exception is None and running
    assert "Read failed (exit 3)" in status
    assert str(safe) in notice


@pytest.mark.parametrize("cycle", [False, True])
def test_unrelated_application_errors_retain_framework_handling(monkeypatch, cycle):
    app = FinOpsApp(Engine(FakeBackend(), "2026-09"), Config(backend="fake"), first_run=False)
    error_type = BoundedContextCycle if cycle else RuntimeError
    error = error_type("Unrelated application failure")
    handled = []
    monkeypatch.setattr(App, "_handle_exception", lambda self, error: handled.append(error))
    app._handle_exception(error)
    assert handled == [error]


def test_exception_chain_cycle_is_bounded_before_framework_handling(monkeypatch):
    app = FinOpsApp(Engine(FakeBackend(), "2026-09"), Config(backend="fake"), first_run=False)
    error, handled = BoundedContextCycle("unrelated cycle"), []
    monkeypatch.setattr(App, "_handle_exception", lambda self, error: handled.append(error))
    app._handle_exception(error)
    assert handled == [error]
    assert error.reads <= 1


@pytest.mark.parametrize("prior_handler", [False, True])
async def test_loop_handler_preserves_unrelated_errors_and_restores_its_owner(monkeypatch, prior_handler):
    app = FinOpsApp(Engine(FakeBackend(), "2026-09"), Config(backend="fake"), first_run=False)
    loop = asyncio.get_running_loop()
    original = loop.get_exception_handler()
    handled = []

    def previous(loop, context):
        handled.append(context)

    def default(context):
        handled.append(context)

    monkeypatch.setattr(loop, "default_exception_handler", default)
    loop.set_exception_handler(previous if prior_handler else None)
    try:
        async with app.run_test(size=(100, 30)) as pilot:
            await pilot.pause()
            assert loop.get_exception_handler() not in (None, previous)
            context = {"message": "unrelated loop failure", "exception": RuntimeError("unrelated")}
            loop.call_exception_handler(context)
            assert handled == [context]
        assert loop.get_exception_handler() is (previous if prior_handler else None)
    finally:
        loop.set_exception_handler(original)


async def test_loop_handler_does_not_replace_a_new_owners_handler():
    app = FinOpsApp(Engine(FakeBackend(), "2026-09"), Config(backend="fake"), first_run=False)
    loop = asyncio.get_running_loop()
    original = loop.get_exception_handler()

    def replacement(loop, context):
        loop.default_exception_handler(context)

    try:
        async with app.run_test(size=(100, 30)) as pilot:
            await pilot.pause()
            assert loop.get_exception_handler() is not original
            loop.set_exception_handler(replacement)
        assert loop.get_exception_handler() is replacement
    finally:
        loop.set_exception_handler(original)


async def test_loop_handler_does_not_claim_a_foreign_app_refusal():
    app = FinOpsApp(Engine(FakeBackend(), "2026-09"), Config(backend="fake"), first_run=False)
    loop = asyncio.get_running_loop()
    original = loop.get_exception_handler()
    forwarded = []
    loop.set_exception_handler(lambda loop, context: forwarded.append(context))
    context = {"message": "another application's refusal", "exception": FinOpsError("Not this app", 3)}
    try:
        async with app.run_test(size=(100, 30)) as pilot:
            await pilot.pause()
            with App()._context():
                loop.call_exception_handler(context)
            assert forwarded == [context]
            assert app.is_running and app._exception is None
    finally:
        loop.set_exception_handler(original)


async def test_retained_loop_hook_forwards_after_its_app_stops():
    app = FinOpsApp(Engine(FakeBackend(), "2026-09"), Config(backend="fake"), first_run=False)
    loop = asyncio.get_running_loop()
    original = loop.get_exception_handler()
    forwarded = []

    def previous(loop, context):
        forwarded.append(context)

    loop.set_exception_handler(previous)
    try:
        async with app.run_test(size=(100, 30)) as pilot:
            await pilot.pause()
            hook = loop.get_exception_handler()
            assert hook is not previous
        context = {"message": "retained hook", "exception": FinOpsError("The app has stopped.", 3)}
        with app._context():
            hook(loop, context)
        assert forwarded == [context]
        assert loop.get_exception_handler() is previous
    finally:
        loop.set_exception_handler(original)
