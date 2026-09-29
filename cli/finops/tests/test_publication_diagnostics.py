import asyncio
import os
from contextlib import contextmanager, nullcontext
from functools import partial, wraps
from pathlib import Path
import subprocess
import sys
import textwrap

import pytest
from rich.pretty import pretty_repr
from textual.events import Callback, MouseDown, MouseScrollDown
from textual.notifications import Notify
from textual.widgets import Input, Select as NativeSelect, TabbedContent

from claude_finops.config import Config
from claude_finops.engine import Engine
from claude_finops.fake import FakeBackend
from claude_finops.guarded_publication import guarded_publish
from claude_finops.publication_widgets import (
    PublicationApp, PublicationDispatch, Select, _OriginNotification, _protect_native_widget,
)
from claude_finops.tui import FinOpsApp


@pytest.mark.parametrize("receiver", ["protected", "native"])
@pytest.mark.parametrize("control", ["prevent", "disable"])
@pytest.mark.parametrize("delivery", ["new", "forwarded"])
def test_sealed_messages_preserve_native_delivery_controls(receiver, control, delivery):
    with guarded_publish(nullcontext):
        selector = (Select if receiver == "protected" else NativeSelect)([("Mine", "mine")])
    if receiver == "native":
        _protect_native_widget(selector, nullcontext)
    message = NativeSelect.Changed(selector, "PRIVATE_MESSAGE")
    if delivery == "forwarded":
        assert selector.post_message(message)
    if control == "disable":
        selector.disable_messages(NativeSelect.Changed)
    try:
        with selector.prevent(NativeSelect.Changed) if control == "prevent" else nullcontext():
            assert not selector.post_message(message), "Diagnostic sealing bypassed a native message control."
            assert not selector.check_message_enabled(message)
    finally:
        selector.enable_messages(NativeSelect.Changed)
    assert selector.check_message_enabled(message)
    assert selector.post_message(message), "A message must be deliverable again after suppression ends."
    assert isinstance(message, NativeSelect.Changed)
    assert message.value == "PRIVATE_MESSAGE"
    assert "PRIVATE_MESSAGE" not in repr(message) + pretty_repr(message)


@pytest.mark.parametrize("receiver", ["protected", "native"])
@pytest.mark.parametrize("event, enabled", [(MouseDown, False), (MouseScrollDown, True)], ids=["press", "scroll"])
def test_sealed_messages_keep_native_disabled_widget_rules(receiver, event, enabled):
    with guarded_publish(nullcontext):
        selector = (Select if receiver == "protected" else NativeSelect)([("Mine", "mine")], disabled=True)
    if receiver == "native":
        _protect_native_widget(selector, nullcontext)
    message = event(widget=selector, x=1, y=1, delta_x=0, delta_y=1, button=1,
                    shift=False, meta=False, ctrl=False)
    assert selector.post_message(message) is enabled
    selector.disabled = False
    assert selector.post_message(message)


@pytest.mark.parametrize("delivery", ["new", "forwarded"])
def test_sealed_app_messages_preserve_disable_and_enable(delivery):
    app = PublicationApp()
    message = Callback(partial(lambda value: value, "PRIVATE_CALLBACK"))
    if delivery == "forwarded":
        assert app.post_message(message)
    app.disable_messages(Callback)
    try:
        assert not app.post_message(message), "Diagnostic sealing bypassed the app's disabled message type."
        assert not app.check_message_enabled(message)
    finally:
        app.enable_messages(Callback)
    assert app.check_message_enabled(message) and app.post_message(message)
    assert "PRIVATE_CALLBACK" not in repr(message) + pretty_repr(message)


@pytest.mark.parametrize("tab", ["budgets", "requests"])
async def test_tab_activation_keeps_the_in_flight_refresh(monkeypatch, tab):
    app = FinOpsApp(Engine(FakeBackend(), "2026-09"), Config(backend="fake"), first_run=False)
    focused = asyncio.Event()
    focus_pane = TabbedContent._on_tab_pane_focused

    @wraps(focus_pane)
    def initial_focus(tabs, event):
        focus_pane(tabs, event)
        if tabs.id == "main-tabs" and event.tab_pane.id == "overview":
            focused.set()

    monkeypatch.setattr(TabbedContent, "_on_tab_pane_focused", initial_focus)
    async with app.run_test(size=(100, 30)) as pilot:
        await pilot.pause()
        await app.workers.wait_for_complete()
        await focused.wait()
        entered, release = asyncio.Event(), asyncio.Event()
        workers = []
        refresh, load = app.action_refresh, app.load_tab

        def record_refresh():
            worker = refresh()
            workers.append(worker)
            return worker

        async def held_load(view):
            entered.set()
            await release.wait()
            return await load(view)

        monkeypatch.setattr(app, "action_refresh", record_refresh)
        monkeypatch.setattr(app, "load_tab", held_load)
        try:
            app.action_tab(tab)
            await entered.wait()
            await pilot.pause()
        finally:
            release.set()
        await workers[-1].wait()
        assert len(workers) == 1, "One tab activation must not start replacement refresh workers."
        assert not workers[0].is_cancelled
        assert app.active == tab and tab in app.data
        assert app.is_running and app._exception is None


@pytest.mark.parametrize("lifecycle", ["running-gap", "shutdown"])
async def test_stale_tab_activation_is_ignored_without_main_tabs(monkeypatch, lifecycle):
    app = FinOpsApp(Engine(FakeBackend(), "2026-09"), Config(backend="fake"), first_run=False)
    refreshes = []
    async with app.run_test(size=(100, 30)) as pilot:
        await pilot.pause()
        await app.workers.wait_for_complete()
        tabs = app.query_one("#main-tabs", TabbedContent)
        activation = TabbedContent.TabActivated(tabs, tabs.get_tab(tabs.active))
        monkeypatch.setattr(app, "action_refresh", lambda: refreshes.append("refresh"))
        app.switched(activation)
        assert refreshes == ["refresh"], "A current activation must still refresh the live view."
        refreshes.clear()
        if lifecycle == "running-gap":
            app.set_focus(None)
            with app.batch_update():
                await app.screen.remove_children()
                assert app.is_running and not app.query("#main-tabs")
                app.switched(activation)
                assert not refreshes
    if lifecycle == "shutdown":
        assert not app.is_running and not app.query("#main-tabs")
        app.switched(activation)
    assert not refreshes, "A retained activation must not restart a read without main content."
    assert app._exception is None


def test_notification_record_omits_payload_in_both_representations():
    notification = _OriginNotification(message="PRIVATE_MESSAGE", title="PRIVATE_TITLE", origin=nullcontext)
    for rendered in (repr(notification), pretty_repr(notification)):
        assert "PRIVATE_MESSAGE" not in rendered and "PRIVATE_TITLE" not in rendered
    assert notification.message == "PRIVATE_MESSAGE" and notification.title == "PRIVATE_TITLE"


@pytest.mark.parametrize("payload", ["notification", "callback", "input-event"])
def test_messages_are_payload_free_before_the_framework_receives_them(payload):
    received = []

    class Receiver:
        def post_message(self, message):
            received.append(message)
            return True

    class ProtectedReceiver(PublicationDispatch, Receiver):
        pass

    notification = _OriginNotification(message="PRIVATE_MESSAGE", title="PRIVATE_TITLE", origin=nullcontext)
    messages = {
        "notification": Notify(notification),
        "callback": Callback(partial(lambda value: value, "PRIVATE_MESSAGE")),
        "input-event": Input.Changed(Input(), "PRIVATE_MESSAGE"),
    }
    message = messages[payload]
    original_type, handler = type(message), message.handler_name
    assert ProtectedReceiver().post_message(message) and received == [message]
    assert isinstance(message, original_type) and message.handler_name == handler
    for rendered in (repr(message), pretty_repr(message)):
        assert "PRIVATE_MESSAGE" not in rendered and "PRIVATE_TITLE" not in rendered


@pytest.mark.parametrize("delivery", ["posted", "prequeued"])
@pytest.mark.parametrize("payload", ["notification", "callback", "input-event"])
def test_real_textual_log_never_contains_queued_backend_payload(tmp_path, payload, delivery):
    log = tmp_path / "textual.log"
    script = textwrap.dedent(r'''
        import asyncio
        import os
        from functools import partial
        from pathlib import Path
        from textual import log, constants
        from textual.events import Callback
        from textual.notifications import Notify
        from textual.widgets import Input
        from claude_finops.config import Config
        from claude_finops.guarded_publication import guarded_deferred
        from claude_finops.tui import FinOpsApp
        import claude_finops
        from test_publication_generation import bearer_tui_estate

        assert Path(claude_finops.__file__).resolve() == Path(os.environ["P71_EXPECTED_SOURCE"]).resolve()
        assert constants.LOG_FILE == os.environ["TEXTUAL_LOG"]
        fixture = bearer_tui_estate.__wrapped__()
        engine, principal = next(fixture)
        async def main():
            app = FinOpsApp(engine, Config(backend="fake"), first_run=False)
            async with app.run_test(size=(100, 30), notifications=True) as pilot:
                await pilot.pause()
                await app.workers.wait_for_complete()
                with engine.backend.read_cycle():
                    value = "ROUND10_REFUSED_NOTIFICATION_" + engine.read("budgets")["items"][0]["scope_name"]
                    origin = app.current_guard()
                title = "ROUND10_PRIVATE_TITLE"
                log("ROUND10_LOG_CONTROL")
                queued = []
                original = app.post_message
                def hold(message):
                    if isinstance(message, (Notify, Callback, Input.Changed)):
                        queued.append(message)
                        return True
                    return original(message)
                app.post_message = hold
                if os.environ["P71_LOG_PAYLOAD"] == "notification":
                    app.publish_notification(value, title=title, origin=origin, timeout=60)
                elif os.environ["P71_LOG_PAYLOAD"] == "callback":
                    app.call_later(guarded_deferred(origin, lambda value: None), value)
                else:
                    app.post_message(Input.Changed(app.query_one("#people-query", Input), value))
                app.post_message = original
                assert queued
                principal[0] = "b"
                await asyncio.to_thread(engine.read, "whoami")
                await pilot.pause()
                for message in queued:
                    if os.environ["P71_LOG_DELIVERY"] == "prequeued":
                        app._message_queue.put_nowait(message)
                    else:
                        original(message)
                await pilot.pause()
                assert value not in app.export_screenshot()
                assert app.is_running and app._exception is None
        try:
            asyncio.run(main())
        finally:
            fixture.close()
        data = Path(os.environ["TEXTUAL_LOG"]).read_text(encoding="utf-8")
        assert "ROUND10_LOG_CONTROL" in data and "method=" in data, "Native TEXTUAL_LOG event logging did not execute."
        assert "ROUND10_REFUSED_NOTIFICATION_A_ONLY_BUDGET" not in data, "Native TEXTUAL_LOG exposed a queued backend payload."
        assert "ROUND10_PRIVATE_TITLE" not in data, "Native TEXTUAL_LOG exposed a notification title."
    ''')
    root = Path(__file__).resolve().parents[1]
    env = dict(os.environ, TEXTUAL_LOG=str(log), P71_LOG_PAYLOAD=payload, P71_LOG_DELIVERY=delivery,
               P71_EXPECTED_SOURCE=str(root / "src" / "claude_finops" / "__init__.py"),
               PYTHONPATH=os.pathsep.join([str(root / "src"), str(root / "tests")]),
               PYTHONDONTWRITEBYTECODE="1")
    result = subprocess.run([sys.executable, "-c", script], env=env, capture_output=True,
                            text=True, encoding="utf-8", timeout=60)
    assert result.returncode == 0, result.stdout + result.stderr


@pytest.mark.parametrize("lifetime", ["abandoned", "refused"])
async def test_unused_framework_watcher_coroutines_are_closed(lifetime):
    from textual.reactive import await_watcher
    from claude_finops.errors import FinOpsError
    from claude_finops.publication_widgets import _RetainedWatcher

    executed, refused = [], []

    class Owner:
        def _publication_rejected(self, error):
            refused.append(error)

    @contextmanager
    def expired():
        raise FinOpsError("The originating read expired.", 3)
        yield

    async def update():
        executed.append(True)

    owner = Owner()
    pending = update()
    watcher = _RetainedWatcher(owner, partial(await_watcher, owner, pending), expired)
    try:
        if lifetime == "abandoned":
            watcher.close()
        else:
            await watcher()
        assert pending.cr_frame is None, "The unused framework coroutine must be closed."
        assert not executed
        assert bool(refused) == (lifetime == "refused")
    finally:
        pending.close()
