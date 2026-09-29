import asyncio
from contextlib import contextmanager
import os
from pathlib import Path
import subprocess
import sys
import textwrap

import httpx
import pytest
from textual import log

from claude_finops.config import Config
from claude_finops.engine import Engine
from claude_finops.errors import FinOpsError, READ_FAILURES, read_error
from claude_finops.fake import FakeBackend
from claude_finops.feature_screens import ActionForm, QuitScreen
from claude_finops.guarded_publication import guarded_publish
from claude_finops.publication_widgets import Static
from claude_finops.tui import FinOpsApp
from p85_fixtures import settle
from test_progressive_tui import until
from test_publication_structure import ROOT, sinks


@pytest.mark.parametrize("source", [
    "from .errors import READ_FAILURES",
    "from .errors import read_error",
    "from .feature_screens import QuitScreen",
])
def test_p85_imports_expose_only_the_reviewed_interface(source):
    assert not sinks(source, "example.py", {})
    assert sinks(source + ", unreviewed_capability", "example.py", {})


@pytest.mark.parametrize("member", [
    "action_clear_filter", "action_next_page", "action_previous_page", "action_quit",
    "action_remove_developer", "commit_action", "commit_change", "open_remove_form",
    "quit_message", "refresh_saving", "run_mutation", "saving",
])
def test_p85_public_interfaces_require_explicit_approval(member):
    assert not sinks(f"value = receiver.{member}", "example.py", {})
    assert sinks(f"value = receiver.{member}_unreviewed", "example.py", {})


@pytest.mark.parametrize("member", [
    "switch_screen", "add_done_callback", "shield", "CancelledError", "cancelled",
    "exception", "screen",
])
def test_p85_native_effects_are_not_name_wide_approvals(member):
    assert sinks(f"value = receiver.{member}", "example.py", {})


@pytest.mark.parametrize("filename,before,after", [
    ("tui.py", "guarded_deferred(self.safe_message_guard(), self._mutation_finished)",
     "self._mutation_finished"),
    ("tui.py", "guarded_deferred(self.safe_message_guard(), self._orphaned_mutation)",
     "self._orphaned_mutation"),
    ("developer_screens.py", "with guarded_publish(directory_guard):",
     "with guarded_publish(app.safe_message_guard()):"),
])
def test_p85_exact_contexts_do_not_authorize_changed_callbacks(filename, before, after):
    source = (ROOT / filename).read_text(encoding="utf-8")
    assert not sinks(source, filename)
    assert source.count(before) == 1
    assert sinks(source.replace(before, after), filename)


def make_app():
    return FinOpsApp(Engine(FakeBackend(), "2026-09"), Config(backend="fake"), first_run=False)


def expiring_origin():
    valid = [True]

    @contextmanager
    def origin():
        if not valid[0]:
            raise FinOpsError("The sign-in changed. Refresh the current view.", 3)
        yield

    return valid, origin


@pytest.mark.parametrize("current", [False, True])
async def test_p85_screen_replacement_cannot_rebind_a_retained_form(current):
    valid, origin = expiring_origin()
    app = make_app()
    async with app.run_test(size=(100, 32)) as pilot:
        await settle(app, pilot)
        app.push_screen(QuitScreen())
        await pilot.pause()
        with guarded_publish(origin):
            form = ActionForm("P85_PRIVATE_RETAINED_FORM", [], lambda values, apply: {},
                              read_guard=origin)
        valid[0] = current
        with guarded_publish(app.safe_message_guard()):
            if current:
                app.switch_screen(form)
            else:
                with pytest.raises(FinOpsError, match="sign-in changed"):
                    app.switch_screen(form)
        await pilot.pause()
        assert (form in app.screen_stack) is current
        assert ("P85_PRIVATE_RETAINED_FORM" in app.export_screenshot()) is current
        assert app.is_running and app._exception is None


async def exercise_orphaned_mutation(current):
    valid, origin = expiring_origin()
    app = make_app()
    started, release = asyncio.Event(), asyncio.Event()
    async with app.run_test(size=(100, 32)) as pilot:
        await settle(app, pilot)
        log("P85_NATIVE_LOG_CONTROL")

        async def operation():
            started.set()
            await release.wait()
            with guarded_publish(origin):
                app.query_one("#status", Static).update("P85_PRIVATE_MUTATION_RECEIPT")

        owner = asyncio.create_task(app.run_mutation(operation()))
        try:
            await asyncio.wait_for(started.wait(), timeout=5)
            assert app.saving
            owner.cancel()
            with pytest.raises(asyncio.CancelledError):
                await owner
            assert app.saving, "Cancelling the modal must not release its application-owned write"
            valid[0] = current
        finally:
            release.set()
        await until(lambda: not app.saving, pilot)
        await pilot.pause()
        visible = app.export_screenshot()
        assert ("P85_PRIVATE_MUTATION_RECEIPT" in visible) is current
        assert app.is_running and app._exception is None
        if not current:
            assert "sign-in changed" in str(app.query_one("#status", Static).render()).lower()


@pytest.mark.parametrize("current", [False, True])
async def test_p85_owned_mutation_rechecks_origin_after_modal_cancellation(current):
    await exercise_orphaned_mutation(current)


def test_p85_orphaned_refusal_does_not_leak_to_native_log(tmp_path):
    root = Path(__file__).resolve().parents[1]
    destination = tmp_path / "textual.log"
    script = textwrap.dedent("""
        import asyncio
        import os
        from pathlib import Path
        import claude_finops
        from textual import constants
        from test_p85_publication_contract import exercise_orphaned_mutation
        assert Path(claude_finops.__file__).resolve() == Path(os.environ["P85_EXPECTED_SOURCE"]).resolve()
        assert constants.LOG_FILE == os.environ["TEXTUAL_LOG"]
        asyncio.run(exercise_orphaned_mutation(False))
    """)
    env = dict(os.environ, TEXTUAL_LOG=str(destination),
               P85_EXPECTED_SOURCE=str(root / "src" / "claude_finops" / "__init__.py"),
               PYTHONPATH=os.pathsep.join([str(root / "src"), str(root / "tests")]),
               PYTHONDONTWRITEBYTECODE="1")
    result = subprocess.run([sys.executable, "-c", script], env=env, capture_output=True,
                            text=True, encoding="utf-8", timeout=60)
    assert result.returncode == 0, result.stdout + result.stderr
    native_log = destination.read_text(encoding="utf-8")
    assert "P85_NATIVE_LOG_CONTROL" in native_log and "method=" in native_log
    assert "P85_PRIVATE_MUTATION_RECEIPT" not in native_log + result.stdout + result.stderr


@pytest.mark.parametrize("error,expected", [
    (OSError("P85_PRIVATE_TRANSPORT"), "Backend I/O failed"),
    (httpx.ConnectError("P85_PRIVATE_TRANSPORT"), "Network read failed"),
])
def test_p85_read_normalization_returns_safe_values_not_transport_diagnostics(error, expected):
    assert isinstance(error, READ_FAILURES)
    normalized = read_error(error)
    assert normalized.code == 7 and expected in str(normalized)
    assert "P85_PRIVATE_TRANSPORT" not in str(normalized)
    with pytest.raises(TypeError, match="Only expected backend read failures"):
        read_error(ValueError("Not an expected read error"))


async def test_p85_exit_still_refuses_raw_farewell_output(capsys):
    app = make_app()
    async with app.run_test(size=(100, 32)) as pilot:
        await settle(app, pilot)
        with pytest.raises(FinOpsError, match="Exit text requires guarded publication"):
            app.exit(message="P85_PRIVATE_FAREWELL")
        assert app.is_running
        app.action_quit()
        await pilot.pause()
        assert isinstance(app.screen, QuitScreen)
        await pilot.press("escape", "escape")
        assert app.is_running
        assert "P85_PRIVATE_FAREWELL" not in app.export_screenshot()
    captured = capsys.readouterr()
    assert "P85_PRIVATE_FAREWELL" not in captured.out + captured.err
