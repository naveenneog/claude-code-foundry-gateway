import asyncio
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
    "label", "placeholder", "textarea", "textarea-edit", "table-row", "table-cell", "table-column",
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
