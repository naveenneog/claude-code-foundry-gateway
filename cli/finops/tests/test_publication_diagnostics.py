import os
from contextlib import contextmanager, nullcontext
from functools import partial
from pathlib import Path
import subprocess
import sys
import textwrap

import pytest
from rich.pretty import pretty_repr
from textual.events import Callback
from textual.notifications import Notify
from textual.widgets import Input

from claude_finops.publication_widgets import PublicationDispatch, _OriginNotification


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
