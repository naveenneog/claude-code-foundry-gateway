import asyncio

import pytest
from textual.widgets import Static as NativeStatic
from textual.widgets import Button as NativeButton, Input as NativeInput, DataTable as NativeTable
from textual.widgets import Label as NativeLabel
from textual.widgets import Markdown, Log, RichLog, Tree, Pretty, Sparkline, ProgressBar
from textual.widgets import Header, Footer

from claude_finops.config import Config
from claude_finops.errors import FinOpsError
from claude_finops.guarded_publication import guarded_publish
from claude_finops.tui import FinOpsApp
from claude_finops.publication_widgets import PublicationWidget
from test_publication_generation import bearer_tui_estate
from test_publication_widgets import capture_consoles


@pytest.mark.parametrize("lookup", ["query_one", "query", "children"])
async def test_native_caption_rejects_stale_method_alias_after_b(
        bearer_tui_estate, capsys, caplog, lookup):
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
        app.action_tab("settings")
        await pilot.pause()
        await app.workers.wait_for_complete()
        selector = app.query_one("#theme-choice")
        if lookup == "query_one":
            caption = selector.query_one("#label", NativeStatic)
        elif lookup == "query":
            caption = selector.query("#label").first()
        else:
            caption = next(child for parent in selector.children for child in parent.children if child.id == "label")
        emit = caption.update
        refused = None
        try:
            emit(value)
        except FinOpsError as error:
            refused = error
        await pilot.pause()
        captured = capsys.readouterr()
        assert value not in app.export_screenshot()
        assert value not in terminal.getvalue() + errors.getvalue() + captured.out + captured.err + caplog.text
        assert isinstance(refused, FinOpsError) and refused.code == 3
        with engine.backend.read_cycle():
            current = engine.read("budgets")["items"][0]["scope_name"]
            origin = app.current_guard()
        with guarded_publish(origin):
            emit(current)
        await pilot.pause()
        assert current in app.export_screenshot()
        assert app.is_running and app._exception is None


@pytest.mark.parametrize("family", ["static", "label", "button", "input", "table"])
async def test_native_content_families_are_protected_at_registration(bearer_tui_estate, family):
    engine, principal = bearer_tui_estate
    app = FinOpsApp(engine, Config(backend="fake"), first_run=False)
    async with app.run_test(size=(100, 30), notifications=True) as pilot:
        await pilot.pause()
        await app.workers.wait_for_complete()
        with engine.backend.read_cycle():
            value = engine.read("budgets")["items"][0]["scope_name"]
            origin = app.current_guard()
        factories = {"static": NativeStatic, "label": NativeLabel, "button": NativeButton,
                     "input": NativeInput, "table": NativeTable}
        with guarded_publish(origin):
            widget = factories[family](id="native-proof")
            pending = app.screen.mount(widget)
        await pending
        assert isinstance(widget, PublicationWidget)
        assert all(isinstance(child, PublicationWidget) for child in app.query("*"))
        principal[0] = "b"
        await asyncio.to_thread(engine.read, "whoami")
        await pilot.pause()
        operations = {
            "static": lambda: widget.update(value),
            "label": lambda: widget.update(value),
            "button": lambda: setattr(widget, "label", value),
            "input": lambda: setattr(widget, "value", value),
            "table": lambda: widget.add_row(value),
        }
        with pytest.raises(FinOpsError):
            operations[family]()
        await pilot.pause()
        assert value not in app.export_screenshot()
        assert app.is_running and app._exception is None


@pytest.mark.parametrize("widget_type,args", [
    pytest.param(Markdown, (), id="Markdown"),
    pytest.param(Log, (), id="Log"),
    pytest.param(RichLog, (), id="RichLog"),
    pytest.param(Tree, ("Unreviewed tree",), id="Tree"),
    pytest.param(Pretty, ({"unreviewed": "value"},), id="Pretty"),
    pytest.param(Sparkline, ([1, 2],), id="Sparkline"),
    pytest.param(ProgressBar, (), id="ProgressBar"),
])
async def test_unsupported_native_content_is_refused_before_dom_insertion(
        bearer_tui_estate, widget_type, args):
    engine, _ = bearer_tui_estate
    app = FinOpsApp(engine, Config(backend="fake"), first_run=False)
    async with app.run_test(size=(100, 30), notifications=True) as pilot:
        await pilot.pause()
        await app.workers.wait_for_complete()
        widget = widget_type(*args, id="unsupported-native-content")
        with pytest.raises(FinOpsError, match="not supported"):
            app.screen.mount(widget)
        assert not app.query("#unsupported-native-content")
        assert app.is_running and app._exception is None


async def test_unreviewed_native_subclass_is_not_approved_by_its_module(bearer_tui_estate):
    class UnreviewedStatic(NativeStatic):
        __module__ = "textual.widgets._static"

    engine, _ = bearer_tui_estate
    app = FinOpsApp(engine, Config(backend="fake"), first_run=False)
    async with app.run_test() as pilot:
        await pilot.pause()
        await app.workers.wait_for_complete()
        with pytest.raises(FinOpsError, match="not supported"):
            app.screen.mount(UnreviewedStatic("Unreviewed content", id="unreviewed-subclass"))
        assert not app.query("#unreviewed-subclass")


async def test_native_adapter_constructor_requires_an_origin(bearer_tui_estate):
    engine, _ = bearer_tui_estate
    app = FinOpsApp(engine, Config(backend="fake"), first_run=False)
    async with app.run_test(size=(100, 30), notifications=True) as pilot:
        await pilot.pause()
        await app.workers.wait_for_complete()
        native_type = type(app.query_one("#theme-choice").query_one("#label"))
        with pytest.raises(FinOpsError, match="unguarded"):
            native_type("PRIVATE_CONSTRUCTOR")


async def test_native_cached_render_rechecks_the_content_origin(bearer_tui_estate):
    engine, _ = bearer_tui_estate
    app = FinOpsApp(engine, Config(backend="fake"), first_run=False)
    async with app.run_test(size=(100, 30), notifications=True) as pilot:
        await pilot.pause()
        await app.workers.wait_for_complete()
        with engine.backend.read_cycle():
            value = engine.read("budgets")["items"][0]["scope_name"]
            origin = app.current_guard()
        with guarded_publish(origin):
            widget = NativeStatic(value, id="native-cache")
            widget.styles.dock = "top"
            pending = app.screen.mount(widget)
        await pending
        await pilot.pause()
        assert value in app.export_screenshot()
        revision = engine.identity_revision
        engine.backend.invalidate_credentials()
        assert revision == engine.identity_revision
        assert value not in app.export_screenshot()
        await pilot.pause()
        assert app.is_running and app._exception is None


async def test_native_command_palette_search_and_selection_remain_usable(bearer_tui_estate):
    engine, _ = bearer_tui_estate
    app = FinOpsApp(engine, Config(backend="fake"), first_run=False)
    async with app.run_test(size=(100, 30), notifications=True) as pilot:
        await pilot.pause()
        await app.workers.wait_for_complete()
        await pilot.press(":")
        await pilot.pause()
        await app.workers.wait_for_complete()
        assert len(app.screen_stack) == 2
        assert all(isinstance(widget, PublicationWidget) for widget in app.screen.query("*"))
        with guarded_publish(app.current_guard()):
            app.screen.query_one("CommandInput").value = "Open Budgets"
        await pilot.pause()
        await app.workers.wait_for_complete()
        assert app.screen.query_one("CommandList").option_count > 0
        await pilot.press("enter")
        await pilot.pause()
        await app.workers.wait_for_complete()
        assert app.active == "budgets" and len(app.screen_stack) == 1
        assert app.is_running and app._exception is None


@pytest.mark.parametrize("widget_type", [Header, Footer])
@pytest.mark.filterwarnings("error::pytest.PytestUnraisableExceptionWarning")
@pytest.mark.filterwarnings("error::RuntimeWarning")
async def test_framework_chrome_contains_only_guarded_receivers(bearer_tui_estate, widget_type):
    engine, _ = bearer_tui_estate
    app = FinOpsApp(engine, Config(backend="fake"), first_run=False)
    async with app.run_test(size=(100, 30), notifications=True) as pilot:
        await pilot.pause()
        await app.workers.wait_for_complete()
        with guarded_publish(app.safe_message_guard()):
            pending = app.screen.mount(widget_type())
        await pending
        await pilot.pause()
        assert all(isinstance(widget, PublicationWidget) for widget in app.query("*"))
        if widget_type is Header:
            assert app.title in str(app.query_one("HeaderTitle").render())
        assert "AUM" in app.export_screenshot()
        assert app.is_running and app._exception is None


@pytest.mark.parametrize("chrome,field", [
    ("HeaderIcon", "icon"), ("FooterKey", "description"),
    ("FooterKey", "key_display"), ("Screen", "title"),
])
async def test_native_chrome_content_requires_publication(bearer_tui_estate, chrome, field):
    engine, principal = bearer_tui_estate
    app = FinOpsApp(engine, Config(backend="fake"), first_run=False)
    async with app.run_test(size=(100, 30), notifications=True) as pilot:
        await pilot.pause()
        await app.workers.wait_for_complete()
        with guarded_publish(app.safe_message_guard()):
            pending = app.screen.mount(Header(), Footer())
        await pending
        await pilot.pause()
        value = engine.read("budgets")["items"][0]["scope_name"]
        principal[0] = "b"
        await asyncio.to_thread(engine.read, "whoami")
        await pilot.pause()
        widget = app.screen if chrome == "Screen" else app.query_one(chrome)
        with pytest.raises(FinOpsError):
            setattr(widget, field, value)
        await pilot.pause()
        assert value not in app.export_screenshot()
        assert app.is_running and app._exception is None


@pytest.mark.parametrize("field", ["title", "sub_title"])
async def test_application_chrome_titles_remain_static(bearer_tui_estate, field):
    engine, _ = bearer_tui_estate
    app = FinOpsApp(engine, Config(backend="fake"), first_run=False)
    async with app.run_test() as pilot:
        await pilot.pause()
        await app.workers.wait_for_complete()
        value = engine.read("budgets")["items"][0]["scope_name"]
        with pytest.raises(FinOpsError, match="static"):
            setattr(app, field, value)
        assert value not in str(getattr(app, field))


async def test_exit_message_is_refused_before_shutdown_but_exit_result_is_supported(
        bearer_tui_estate, capsys):
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
            app.exit(message=value)
        except FinOpsError as error:
            refused = error
        app._print_error_renderables()
        captured = capsys.readouterr()
        assert value not in terminal.getvalue() + errors.getvalue() + captured.out + captured.err
        assert isinstance(refused, FinOpsError) and refused.code == 3
        assert app.is_running and not app._exit
        app.exit(value)
    assert app.return_value == value
