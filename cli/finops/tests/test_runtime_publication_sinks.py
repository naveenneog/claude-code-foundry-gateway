import asyncio
from contextlib import contextmanager
from functools import partial
import io
from types import SimpleNamespace

import pytest
from rich.console import Console
from textual.app import App
from textual.widgets import Button, DataTable, Input, Static, TextArea

from claude_finops.config import Config
from claude_finops.errors import FinOpsError
from claude_finops.guarded_publication import guarded_publish
from claude_finops.tui import FinOpsApp
from test_publication_generation import bearer_tui_estate


@pytest.mark.parametrize("spelling", ["lambda", "nested", "getattr", "setattr", "partial"])
@pytest.mark.parametrize("changed_principal", [False, True])
async def test_raw_sink_refuses_deferred_backend_data_for_every_spelling(
        bearer_tui_estate, spelling, changed_principal):
    engine, principal = bearer_tui_estate
    app = FinOpsApp(engine, Config(backend="fake"), first_run=False)
    async with app.run_test(size=(100, 30)) as pilot:
        await pilot.pause()
        await app.workers.wait_for_complete()
        with engine.backend.read_cycle():
            row = engine.read("budgets")["items"][0]
            origin = app.current_guard()
        status = app.query_one("#status", Static)
        field = app.query_one("#people-query", Input)
        value = row["scope_name"]
        assert value == "A_ONLY_BUDGET"
        with guarded_publish(origin):
            if spelling == "lambda":
                callback = lambda: status.update(value)
            elif spelling == "nested":
                def callback():
                    status.update(value)
            elif spelling == "getattr":
                callback = lambda: getattr(status, "update")(value)
            elif spelling == "setattr":
                callback = lambda: setattr(field, "value", value)
            else:
                callback = partial(status.update, value)
        if changed_principal:
            principal[0] = "b"
            await asyncio.to_thread(engine.read, "whoami")
            await pilot.pause()
        with pytest.raises(FinOpsError, match="publication|unguarded|sign-in changed"):
            callback()
        assert value not in str(status.render())
        assert value not in field.value


async def test_sink_rechecks_origin_even_inside_an_active_but_obsolete_scope(bearer_tui_estate):
    engine, _ = bearer_tui_estate
    app = FinOpsApp(engine, Config(backend="fake"), first_run=False)
    async with app.run_test(size=(100, 30)) as pilot:
        await pilot.pause()
        await app.workers.wait_for_complete()
        with engine.backend.read_cycle():
            value = engine.read("budgets")["items"][0]["scope_name"]
            origin = app.current_guard()
        with guarded_publish(origin):
            engine.backend.invalidate_credentials()
            with pytest.raises(FinOpsError, match="sign-in changed"):
                getattr(app.query_one("#status", Static), "update")(value)
        assert value not in str(app.query_one("#status", Static).render())


@pytest.mark.parametrize("sink", [
    "content", "label", "placeholder", "textarea", "textarea-edit", "table-row", "table-cell", "table-column",
    "clipboard", "link",
])
async def test_app_installs_enforcement_at_every_live_sink(bearer_tui_estate, monkeypatch, sink):
    engine, _ = bearer_tui_estate
    sent = []
    monkeypatch.setattr(App, "copy_to_clipboard", lambda self, value: sent.append(value))
    monkeypatch.setattr(App, "open_url", lambda self, value: sent.append(value))
    app = FinOpsApp(engine, Config(backend="fake"), first_run=False)
    async with app.run_test(size=(100, 30)) as pilot:
        await pilot.pause()
        await app.workers.wait_for_complete()
        with engine.backend.read_cycle():
            value = engine.read("budgets")["items"][0]["scope_name"]
        table = app.query_one("#table-overview", DataTable)
        operations = {
            "content": lambda: setattr(app.query_one("#status", Static), "content", value),
            "label": lambda: setattr(app.query_one("#find-people", Button), "label", value),
            "placeholder": lambda: setattr(app.query_one("#people-query", Input), "placeholder", value),
            "textarea": lambda: app.query_one("#ask-answer", TextArea).load_text(value),
            "textarea-edit": lambda: app.query_one("#ask-answer", TextArea).insert(value),
            "table-row": lambda: table.add_row(value),
            "table-cell": lambda: table.update_cell_at((0, 0), value),
            "table-column": lambda: table.add_column(value),
            "clipboard": lambda: app.copy_to_clipboard(value),
            "link": lambda: app.open_url(value),
        }
        with pytest.raises(FinOpsError, match="publication|unguarded"):
            operations[sink]()
        assert sent == []
        assert "Read failed (exit 3)" in str(app.query_one("#status", Static).render())


def test_raw_assistant_transport_requires_an_active_publication(bearer_tui_estate):
    engine, _ = bearer_tui_estate
    engine.read("whoami")
    with pytest.raises(FinOpsError, match="publication|unguarded"):
        engine.backend.write("assistant_ask", dict(question="spend", history=[{"content": "A_PRIVATE"}]))


async def test_guarded_deferral_reenters_at_execution_and_keeps_input_usable(bearer_tui_estate):
    from claude_finops.guarded_publication import guarded_deferred
    engine, _ = bearer_tui_estate
    app = FinOpsApp(engine, Config(backend="fake"), first_run=False)
    async with app.run_test(size=(100, 30)) as pilot:
        await pilot.pause()
        await app.workers.wait_for_complete()
        with engine.backend.read_cycle():
            value = engine.read("budgets")["items"][0]["scope_name"]
            source = app.current_guard()
        done = asyncio.Event()
        def publish():
            app.query_one("#status", Static).update(value)
            done.set()
        app.call_later(guarded_deferred(source, publish))
        await asyncio.wait_for(done.wait(), timeout=3)
        assert value in str(app.query_one("#status", Static).render())
        app.action_tab("people")
        await pilot.pause()
        await app.workers.wait_for_complete()
        field = app.query_one("#people-query", Input)
        field.focus()
        await pilot.press("x", "y", "backspace", "z")
        assert field.value == "xz"


@pytest.mark.parametrize("asynchronous", [False, True])
async def test_guarded_deferral_refuses_a_changed_origin_without_writing(bearer_tui_estate, asynchronous):
    from claude_finops.guarded_publication import guarded_deferred
    engine, principal = bearer_tui_estate
    app = FinOpsApp(engine, Config(backend="fake"), first_run=False)
    async with app.run_test(size=(100, 30)) as pilot:
        await pilot.pause()
        await app.workers.wait_for_complete()
        with engine.backend.read_cycle():
            value = engine.read("budgets")["items"][0]["scope_name"]
            source = app.current_guard()
        def publish():
            app.query_one("#status", Static).update(value)
        async def publish_async():
            await asyncio.sleep(0)
            publish()
        callback = guarded_deferred(source, publish_async if asynchronous else publish)
        principal[0] = "b"
        await asyncio.to_thread(engine.read, "whoami")
        with pytest.raises(FinOpsError, match="sign-in changed"):
            if asynchronous:
                await callback()
            else:
                callback()
        assert value not in str(app.query_one("#status", Static).render())


async def test_async_deferral_rechecks_sinks_after_await_without_blocking_identity(bearer_tui_estate):
    from claude_finops.guarded_publication import guarded_deferred
    engine, principal = bearer_tui_estate
    app = FinOpsApp(engine, Config(backend="fake"), first_run=False)
    async with app.run_test(size=(100, 30)) as pilot:
        await pilot.pause()
        await app.workers.wait_for_complete()
        with engine.backend.read_cycle():
            value = engine.read("budgets")["items"][0]["scope_name"]
            source = app.current_guard()
        entered, release = asyncio.Event(), asyncio.Event()
        async def publish():
            entered.set()
            await release.wait()
            app.query_one("#status", Static).update(value)
        task = asyncio.create_task(guarded_deferred(source, publish)())
        try:
            await asyncio.wait_for(entered.wait(), timeout=3)
            principal[0] = "b"
            await asyncio.wait_for(asyncio.to_thread(engine.read, "whoami"), timeout=3)
            release.set()
            with pytest.raises(FinOpsError, match="sign-in changed"):
                await task
        finally:
            release.set()
            await asyncio.gather(task, return_exceptions=True)
        assert value not in str(app.query_one("#status", Static).render())


@pytest.mark.parametrize("sink", ["export", "text", "renderable", "clipboard"])
@pytest.mark.parametrize("state", ["expired", "obsolete", "current"])
def test_output_sinks_check_the_origin_at_the_write(bearer_tui_estate, tmp_path, capsys, monkeypatch, sink, state):
    from claude_finops import publication_output
    engine, _ = bearer_tui_estate
    with engine.backend.read_cycle():
        value = engine.read("budgets")["items"][0]["scope_name"]
        origin = engine.backend.read_guard()
    target = tmp_path / "usage.csv"
    rich_output, clipboard = io.StringIO(), []
    def copy(command, **kwargs):
        clipboard.append(kwargs["input"])
        return SimpleNamespace(returncode=0)
    monkeypatch.setattr(publication_output.subprocess, "run", copy)
    operations = {
        "export": partial(publication_output.write_export, target, value),
        "text": partial(publication_output.write_text, value),
        "renderable": partial(publication_output.write_renderable, Console(file=rich_output), value),
        "clipboard": partial(publication_output.copy_with_helper, ["synthetic-clipboard"], value),
    }
    if state == "current":
        with guarded_publish(origin):
            operations[sink]()
    elif state == "obsolete":
        with guarded_publish(origin):
            engine.backend.invalidate_credentials()
            with pytest.raises(FinOpsError, match="sign-in changed"):
                operations[sink]()
    else:
        with guarded_publish(origin):
            callback = operations[sink]
        with pytest.raises(FinOpsError, match="publication|unguarded"):
            callback()
    actual = capsys.readouterr().out + rich_output.getvalue() + str(clipboard)
    if target.exists():
        actual += target.read_text()
    assert (value in actual) is (state == "current")
    assert target.exists() is (state == "current" and sink == "export")


async def test_content_property_refuses_a_scheduled_old_principal_value(bearer_tui_estate):
    engine, principal = bearer_tui_estate
    app = FinOpsApp(engine, Config(backend="fake"), first_run=False)
    async with app.run_test(size=(100, 30)) as pilot:
        await pilot.pause()
        await app.workers.wait_for_complete()
        with engine.backend.read_cycle():
            value = engine.read("budgets")["items"][0]["scope_name"]
        principal[0] = "b"
        await asyncio.to_thread(engine.read, "whoami")
        await pilot.pause()
        status = app.query_one("#status", Static)
        loop = asyncio.get_running_loop()
        previous = loop.get_exception_handler()
        refused, executed = [], asyncio.Event()

        def publish():
            try:
                status.content = value
            finally:
                executed.set()

        loop.set_exception_handler(lambda loop, context: refused.append(context["exception"]))
        try:
            loop.call_soon(publish)
            await asyncio.wait_for(executed.wait(), timeout=3)
            await asyncio.sleep(0)
        finally:
            loop.set_exception_handler(previous)
        assert len(refused) == 1 and isinstance(refused[0], FinOpsError)
        assert refused[0].code == 3
        assert value not in str(status.render())
        assert value not in app.export_screenshot()


async def test_content_assignment_replaces_and_retains_its_actual_source():
    from claude_finops.engine import Engine
    from claude_finops.fake import FakeBackend

    valid = {"previous": True, "content": True}

    def origin(name):
        @contextmanager
        def guard():
            if not valid[name]:
                raise FinOpsError("The sign-in changed.", 3)
            yield
        return guard

    app = FinOpsApp(Engine(FakeBackend(), "2026-09"), Config(backend="fake"), first_run=False)
    async with app.run_test(size=(100, 30)) as pilot:
        await pilot.pause()
        await app.workers.wait_for_complete()
        status = app.query_one("#status", Static)
        with guarded_publish(origin("previous")):
            status.update("Previous content")
        with guarded_publish(origin("content")):
            status.content = "Current content"
        assert "Current content" in str(status.render())
        valid["previous"] = False
        with status.input_origin()():
            pass
        valid["content"] = False
        with pytest.raises(FinOpsError, match="sign-in changed"):
            with status.input_origin()():
                pass
