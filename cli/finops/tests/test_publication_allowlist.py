import asyncio
import ast
import sys
from types import ModuleType

import pytest

from claude_finops.config import Config
from claude_finops.guarded_publication import guarded_publish
from claude_finops.publication_widgets import Static
from claude_finops.tui import FinOpsApp
from test_publication_generation import bearer_tui_estate
from test_publication_structure import ROOT, sinks, UI_FILES
from test_publication_widgets import capture_consoles


@pytest.mark.parametrize("source", [
    "from typer import echo as emit",
    "import typer as terminal\nemit = terminal.echo",
    "from rich.console import Console as Terminal",
    "from rich import print as emit",
    "from sys import stdout as destination",
    "from sys import stderr as destination",
    "import sys as runtime\ndestination = runtime.stdout",
    "from textual.widgets import Static as View",
    "from textual.widget import Widget as View",
    "from textual.containers import Vertical as Layout",
    "from textual.screen import ModalScreen as Page",
    "from textual.app import App as Application",
    "from subprocess import run as copy_to_system",
    "import subprocess as process",
    "from pathlib import Path as Destination",
    "from io import open as writer",
    "from os import write as emit",
    "from builtins import print as emit",
    "from claude_finops.publication_output import Console as Terminal",
    "from claude_finops.publication_widgets import TextualStatic as View",
    "import unreviewed_formatter",
    "from .unreviewed_output import emit",
    "from .publication_output import *",
])
def test_only_approved_presentation_imports_are_available(source):
    assert sinks(source, "example.py", {}), source


@pytest.mark.parametrize("statement", [
    "print(value)",
    "emit = print\nemit(value)",
    "open('report.txt', 'w')",
    "compile(code, 'callback', 'exec')",
    "__import__('typer')",
    "globals()['emit'](value)",
    "locals()['emit'](value)",
    "__builtins__['print'](value)",
    "getattr(widget, attribute)(value)",
    "setattr(widget, attribute, value)",
    "delattr(widget, attribute)",
    "widget.__class__ = RawStatic",
    "setattr(type(widget), 'render', lambda self: value)",
    "type(widget).render = lambda self: value",
    "kind = type(widget)\nkind.render = lambda self: value",
    "kind = type\nsetattr(kind(widget), 'render', lambda self: value)",
    "import json\njson.dumps = lambda value: value",
    "setattr(widget, '__class__', RawStatic)",
    "delattr(widget, '__class__')",
    "sys.modules[__name__]",
    "getattr(sys, 'modules')[__name__]",
    "emit.__wrapped__(value)",
    "import importlib as loader\nloader.import_module('typer')",
])
def test_metaprogramming_and_raw_output_are_not_authorized_by_a_guard(statement):
    source = "def handler(widget, value, origin, attribute, code):\n    with guarded_publish(origin):\n        "
    source += statement.replace("\n", "\n        ") + "\n"
    assert sinks(source, "example.py", {}), source


def test_module_level_raw_alias_cannot_publish_a_previous_principals_value(
        bearer_tui_estate, monkeypatch, capsys):
    engine, principal = bearer_tui_estate
    value = engine.read("budgets")["items"][0]["scope_name"]
    principal[0] = "b"
    engine.read("whoami")
    source = """
from typer import echo as emit
import sys
getattr(sys.modules[__name__], "emit")(value)
"""
    found = sinks(source, "example.py", {})
    if not found:
        module = ModuleType("p71_round_eight_raw_alias")
        module.value = value
        monkeypatch.setitem(sys.modules, module.__name__, module)
        exec(compile(source, "example.py", "exec"), module.__dict__)
    captured = capsys.readouterr()
    assert value not in captured.out + captured.err
    assert found, "The source gate must refuse this alias before the module can run."


async def test_class_mutation_source_cannot_render_a_previous_principals_value(
        bearer_tui_estate, monkeypatch, capsys, caplog):
    engine, principal = bearer_tui_estate
    app = FinOpsApp(engine, Config(backend="fake"), first_run=False)
    terminal, errors = capture_consoles(app)
    source = "setattr(type(widget), 'render', lambda self: stale)"
    found = sinks(source, "example.py", {})
    async with app.run_test(size=(100, 30)) as pilot:
        await pilot.pause()
        await app.workers.wait_for_complete()
        stale = engine.read("budgets")["items"][0]["scope_name"]
        principal[0] = "b"
        await asyncio.to_thread(engine.read, "whoami")
        await pilot.pause()
        widget = app.query_one("#status", Static)
        with monkeypatch.context() as patch:
            if not found:
                patch.setattr(type(widget), "render", lambda self: stale)
                widget.refresh(layout=True)
            await pilot.pause()
            screenshot = app.export_screenshot()
            assert stale not in screenshot
            assert found, "Presentation classes are immutable under the source contract."
        captured = capsys.readouterr()
        assert stale not in terminal.getvalue() + errors.getvalue() + captured.out + captured.err + caplog.text
        with engine.backend.read_cycle():
            current = engine.read("budgets")["items"][0]["scope_name"]
            origin = app.current_guard()
        with guarded_publish(origin):
            widget.update(current)
        await pilot.pause()
        assert current in app.export_screenshot()
        assert app.is_running and app._exception is None


def test_approved_output_alias_keeps_a_current_origin_and_prints(bearer_tui_estate, capsys):
    engine, principal = bearer_tui_estate
    engine.read("whoami")
    principal[0] = "b"
    with engine.backend.read_cycle():
        value = engine.read("budgets")["items"][0]["scope_name"]
        origin = engine.backend.read_guard()
    source = """
from claude_finops.publication_output import write_text as emit
from claude_finops.guarded_publication import guarded_publish
with guarded_publish(origin):
    emit(value)
"""
    assert not sinks(source, "example.py", {})
    exec(compile(source, "example.py", "exec"), {"origin": origin, "value": value})
    assert value in capsys.readouterr().out


def test_all_cli_and_formatter_modules_are_in_the_source_contract():
    assert {"configure.py", "commands_groups.py", "commands_v4.py", "brand.py",
            "views.py", "feature_views.py"} <= set(UI_FILES)


def test_unreviewed_source_module_cannot_be_omitted_from_the_inventory(tmp_path):
    import publication_policy
    (tmp_path / "new_presentation.py").write_text("value = 1\n", encoding="utf-8")
    assert any("Unclassified source module: new_presentation.py" in failure
               for failure in publication_policy.inventory_failures(tmp_path))


@pytest.mark.parametrize("source", [
    "from claude_finops.publication_widgets import Static as View",
    "from claude_finops.publication_output import write_text as emit",
    "from rich.text import Text",
    "from typing import Annotated",
    "import json\nvalue = json.dumps({'current': True})",
])
def test_approved_imports_do_not_depend_on_their_local_alias(source):
    assert sinks(source, "example.py", {}) == []


def test_import_approvals_and_exception_contexts_have_checked_justifications():
    import publication_policy as policy

    assert set(policy.BOUNDARIES) == {"publication_output.py", "publication_widgets.py"}
    assert set(policy.META_CONTEXTS) == {(name, scope) for name, scope, _ in policy.META_EXCEPTIONS}
    classified = set(policy.PRESENTATION)
    for reason, names in policy.NON_PRESENTATION.values():
        assert len(reason.strip()) >= 20 and names and not classified.intersection(names)
        classified.update(names)
    assert policy.inventory_failures(ROOT) == []
    for module, (reason, members) in policy.APPROVED.items():
        assert module and len(reason.strip()) >= 20 and members and "*" not in members
    for name, (reason, expected, imports) in policy.BOUNDARIES.items():
        assert len(reason.strip()) >= 20 and imports
        assert policy.digest(ast.parse((ROOT / name).read_text(encoding="utf-8"))) == expected
        assert all(members and "*" not in members for members in imports.values())
    for (name, scope, expression), reason in policy.META_EXCEPTIONS.items():
        assert len(reason.strip()) >= 20
        tree = ast.parse((ROOT / name).read_text(encoding="utf-8"))
        function = policy.functions(tree)[scope]
        assert policy.digest(function) == policy.META_CONTEXTS[name, scope]
        assert expression in {ast.unparse(node) for node in ast.walk(function)}


def test_a_boundary_filename_does_not_approve_new_raw_code():
    source = "from typer import echo as emit\nemit(value)\n"
    assert sinks(source, "publication_output.py", {})


def test_changed_exception_context_does_not_inherit_its_old_approval():
    source = (ROOT / "principal_ui.py").read_text(encoding="utf-8")
    changed = source.replace('("data", {})', '("unreviewed_state", {})', 1)
    assert changed != source
    assert any("Computed reflection" in failure for failure in sinks(changed, "principal_ui.py"))


@pytest.mark.parametrize("source", [
    "import typer as api\napi.echo(value)",
    "import typer as api\nother = api\nother.echo(value)",
    "import json as api\nmodule = api",
    "import json as api\napi.unreviewed_member(value)",
    "import textual.events\nprovider = textual.events",
])
def test_module_approval_does_not_approve_its_unlisted_members_or_escape(source):
    assert sinks(source, "example.py", {}), source
