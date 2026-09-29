import asyncio
import ast

import pytest

from claude_finops.config import Config
from claude_finops.guarded_publication import guarded_publish
from claude_finops.publication_widgets import Static
from claude_finops.tui import FinOpsApp
from test_publication_generation import bearer_tui_estate
from test_publication_structure import sinks
from test_publication_widgets import capture_consoles
from publication_attributes import APPROVED_ATTRIBUTES, EXCLUDED_ATTRIBUTES, ATTRIBUTE_EXCEPTIONS


@pytest.mark.parametrize("source", [
    "destination = getattr(app.console, 'file'); destination.writelines([value])",
    "emit = super(Static, widget).update; emit(value)",
    "app.notify(value)",
])
async def test_round_nine_object_capabilities_cannot_publish_after_b(
        bearer_tui_estate, capsys, caplog, source):
    engine, principal = bearer_tui_estate
    app = FinOpsApp(engine, Config(backend="fake"), first_run=False)
    terminal, errors = capture_consoles(app)
    found = sinks(source, "example.py", {})
    async with app.run_test(size=(100, 30), notifications=True) as pilot:
        await pilot.pause()
        await app.workers.wait_for_complete()
        value = engine.read("budgets")["items"][0]["scope_name"]
        principal[0] = "b"
        await asyncio.to_thread(engine.read, "whoami")
        await pilot.pause()
        if not found:
            exec(compile(source, "example.py", "exec"), {
                "app": app, "widget": app.query_one("#status", Static), "Static": Static, "value": value,
            })
        await pilot.pause()
        captured = capsys.readouterr()
        assert value not in terminal.getvalue() + errors.getvalue() + captured.out + captured.err + caplog.text
        assert value not in app.export_screenshot()
        assert found, "The maintained source contract must reject this capability path."
        with engine.backend.read_cycle():
            current = engine.read("budgets")["items"][0]["scope_name"]
            origin = app.current_guard()
        with guarded_publish(origin):
            app.query_one("#status", Static).update(current)
        await pilot.pause()
        assert current in app.export_screenshot()
        assert app.is_running and app._exception is None


@pytest.mark.parametrize("name", [
    "console", "error_console", "file", "stdout", "stderr", "_driver",
    "_unreviewed_private", "__wrapped__", "writelines", "write", "notify", "unreviewed_member",
])
@pytest.mark.parametrize("form", ["attribute", "getattr", "hasattr"])
def test_object_attributes_are_default_deny(name, form):
    expression = f"item.{name}" if form == "attribute" else f"{form}(item, {name!r})"
    assert sinks(f"def handler(item):\n    return {expression}\n", "example.py", {})


@pytest.mark.parametrize("source", [
    "emit = super(Static, widget).update; emit(value)",
    "parent = super; emit = parent(Static, widget).update; emit(value)",
    "parent = super(Static, widget); emit = parent.update; emit(value)",
    "def handler(widget):\n    return super().update",
])
def test_super_cannot_recover_an_unwrapped_implementation(source):
    assert sinks(source, "example.py", {})


@pytest.mark.parametrize("expression", [
    "item.value", "item.query_one", "item.current_guard", "item.publish_notification",
    "getattr(item, 'value')", "hasattr(item, 'value')",
])
def test_reviewed_public_members_remain_available(expression):
    assert not sinks(f"def handler(item):\n    return {expression}\n", "example.py", {})


def test_attribute_approvals_exclude_raw_and_private_capabilities():
    assert APPROVED_ATTRIBUTES
    assert not APPROVED_ATTRIBUTES.intersection(EXCLUDED_ATTRIBUTES)
    assert all(not name.startswith("_") for name in APPROVED_ATTRIBUTES)
    assert {"console", "file", "stdout", "stderr", "_driver", "write", "writelines", "notify"} <= EXCLUDED_ATTRIBUTES


def test_super_forwarding_exceptions_never_select_a_supplied_base():
    forwarding = [key for key in ATTRIBUTE_EXCEPTIONS if key[2].startswith("super(")]
    assert forwarding
    for filename, scope, expression in forwarding:
        call = ast.parse(expression, mode="eval").body
        assert isinstance(call, ast.Call) and isinstance(call.func, ast.Attribute)
        base = call.func.value
        assert isinstance(base, ast.Call) and isinstance(base.func, ast.Name) and base.func.id == "super"
        assert base.args == [] and base.keywords == []
        assert "." in scope and filename.endswith(".py")


def test_a_known_function_does_not_approve_another_private_attribute():
    source = """
class PrincipalUI:
    def cached_guard(self, tab=None):
        return self._driver
"""
    assert any("Unapproved presentation attribute: _driver" in failure
               for failure in sinks(source, "principal_ui.py", {}))
