from contextlib import contextmanager, nullcontext
import json

import pytest

from claude_finops import publication_output, reports
from claude_finops.config import Config
from claude_finops.errors import FinOpsError
from claude_finops.guarded_publication import guarded_publish


@pytest.mark.parametrize("operation", ["profile", "transaction", "confirmation", "report"])
@pytest.mark.parametrize("current", [False, True])
def test_p80_file_and_prompt_effects_recheck_the_origin(tmp_path, monkeypatch, operation, current):
    valid = [True]
    prompts = []
    monkeypatch.setattr(publication_output.typer, "confirm",
                        lambda *args, **kwargs: prompts.append(args[0]) or True)

    @contextmanager
    def origin():
        if not valid[0]:
            raise FinOpsError("The sign-in changed.", 3)
        yield

    destination = tmp_path / "new-folder" / "config.json"

    def run():
        if operation == "profile":
            publication_output.save_profile(str(destination), Config(backend="fake"))
        elif operation == "transaction":
            with publication_output.profile_transaction(
                    str(destination), Config(backend="fake"), "", origin=origin):
                pass
        elif operation == "confirmation":
            publication_output.confirm_profile_replace()
        else:
            reports.save_chargeback_csv("2026-09", "PRIVATE_REPORT", destination.parent)

    with guarded_publish(origin):
        valid[0] = current
        if current:
            run()
        else:
            with pytest.raises(FinOpsError, match="sign-in changed"):
                run()
    assert destination.parent.exists() is (current and operation != "confirmation")
    assert destination.exists() is (current and operation in {"profile", "transaction"})
    assert bool(prompts) is (current and operation == "confirmation")
    assert bool(list(tmp_path.rglob("*.csv"))) is (current and operation == "report")


def test_profile_transaction_checks_enter_and_exit_without_holding_publication(tmp_path):
    valid = [True]

    @contextmanager
    def origin():
        if not valid[0]:
            raise FinOpsError("The sign-in changed.", 3)
        yield

    path = tmp_path / "config.json"
    before = b'{"backend": "direct"}\r\n'
    path.write_bytes(before)
    reviewed = publication_output.preview_profile(Config(backend="fake"), str(path))
    with pytest.raises(FinOpsError, match="sign-in changed"):
        with publication_output.profile_transaction(
                str(path), Config(backend="fake"), reviewed.revision, reviewed=reviewed, origin=origin):
            with pytest.raises(FinOpsError, match="unguarded"):
                publication_output.write_text("UNGUARDED_DURING_VERIFICATION")
            assert json.loads(path.read_bytes())["backend"] == "fake"
            valid[0] = False
    assert path.read_bytes() == before, "A refused final verification must restore the transaction's own bytes"
    assert [backup.read_bytes() for backup in tmp_path.glob("*.bak.json")] == [before]

    unopened = tmp_path / "never-created" / "config.json"
    with pytest.raises(FinOpsError, match="sign-in changed"):
        with publication_output.profile_transaction(str(unopened), Config(backend="fake"), "", origin=origin):
            pytest.fail("An expired source cannot enter the file transaction")
    assert not unopened.parent.exists()


def test_p80_file_interfaces_return_values_not_filesystem_capabilities(tmp_path, monkeypatch):
    monkeypatch.setenv("AUM_CONFIG", str(tmp_path / "selected.json"))
    assert publication_output.profile_path() == str((tmp_path / "selected.json").resolve())
    reviewed = publication_output.preview_profile(Config(backend="fake"), str(tmp_path / "new.json"))
    assert isinstance(reviewed.path, str)
    assert reviewed.before is None and reviewed.configuration().backend == "fake"
    assert isinstance(reports.chargeback_export_path("2026-09", tmp_path), str)
    assert isinstance(reports.chargeback_folder(), str)
    with guarded_publish(nullcontext):
        saved = reports.save_chargeback_csv("2026-09", "complete", tmp_path)
    assert isinstance(saved, str)


@pytest.mark.parametrize("call", [
    "save_profile(path, config)", "confirm_profile_replace()", "widget.publication_scroll_home()",
])
@pytest.mark.parametrize("guarded", [False, True])
def test_p80_named_effects_are_guarded_in_the_source_contract(call, guarded):
    from test_publication_structure import sinks

    body = f"with guarded_publish(origin):\n        {call}" if guarded else call
    source = f"def handler(path, config, origin, widget):\n    {body}\n"
    assert bool(sinks(source, "example.py", {})) is not guarded


async def test_connection_runtime_error_restores_bytes_without_rendering_diagnostics(tmp_path, monkeypatch):
    from claude_finops import ui_features
    from claude_finops.fake import FakeBackend
    from claude_finops.publication_widgets import Static
    from test_p80_connection import OLD_PROFILE, make_app, preview_connection, settle

    class Refused(FakeBackend):
        def read(self, resource, **params):
            if resource == "whoami":
                raise RuntimeError("PRIVATE_CONNECTION_DIAGNOSTICS")
            return super().read(resource, **params)

    path = tmp_path / "config.json"
    path.write_bytes(OLD_PROFILE)
    app = make_app(path)
    old_engine = app.engine
    monkeypatch.setattr(ui_features, "connect", lambda config: Refused())
    async with app.run_test(size=(100, 34), notifications=True) as pilot:
        form = await preview_connection(app, pilot)
        await pilot.click("#action-apply")
        await settle(app, pilot)
        assert app.engine is old_engine and path.read_bytes() == OLD_PROFILE
        assert app.screen is form
        visible = app.export_screenshot()
        assert "PRIVATE_CONNECTION_DIAGNOSTICS" not in visible
        assert "could not be saved or verified" in str(form.query_one("#action-status", Static).render())


@pytest.mark.parametrize("current", [False, True])
async def test_recovery_scroll_reuses_only_current_retained_content(current):
    from claude_finops.engine import Engine
    from claude_finops.fake import FakeBackend
    from claude_finops.feature_screens import ActionForm
    from claude_finops.publication_widgets import Static, VerticalScroll
    from claude_finops.tui import FinOpsApp
    from test_p80_connection import settle

    valid = [True]

    @contextmanager
    def origin():
        if not valid[0]:
            raise FinOpsError("The sign-in changed.", 3)
        yield

    app = FinOpsApp(Engine(FakeBackend(), "2026-09"), Config(backend="fake"), first_run=False)
    async with app.run_test(size=(80, 24), notifications=True) as pilot:
        await settle(app, pilot)
        with guarded_publish(origin):
            form = ActionForm("Recovery", [], lambda values, apply: {}, mutation=False, read_guard=origin)
            app.push_screen(form)
        await pilot.pause()
        with guarded_publish(origin):
            form.query_one("#action-status", Static).update("P80_CURRENT_RECOVERY\n" + "remaining step\n" * 30)
        feedback = form.query_one("#action-feedback", VerticalScroll)
        await pilot.pause()
        feedback.scroll_end(animate=False)
        await pilot.pause()
        valid[0] = current
        with guarded_publish(app.safe_message_guard()):
            if current:
                feedback.publication_scroll_home()
            else:
                with pytest.raises(FinOpsError, match="sign-in changed"):
                    feedback.publication_scroll_home()
        await pilot.pause()
        assert ("P80_CURRENT_RECOVERY" in app.export_screenshot()) is current
        assert app.is_running and app._exception is None


def test_local_profile_validation_is_not_a_principal_publication_refusal(tmp_path):
    from claude_finops.guarded_publication import PublicationOrigin

    valid = [True]
    rejected = []

    @contextmanager
    def guard():
        if not valid[0]:
            raise FinOpsError("The sign-in changed.", 3)
        yield

    origin = PublicationOrigin(guard, rejected.append)
    path = tmp_path / "config.json"
    before = b'{"backend":"direct"}'
    path.write_bytes(before)
    with pytest.raises(FinOpsError, match="changed since preview") as conflict:
        with publication_output.profile_transaction(str(path), Config(backend="fake"), "obsolete", origin=origin):
            pytest.fail("An obsolete profile cannot reach verification")
    assert conflict.value.code == 6
    assert rejected == [], "A profile conflict must leave the current principal's form and cached facts intact"
    assert path.read_bytes() == before
    valid[0] = False
    with pytest.raises(FinOpsError, match="sign-in changed"):
        with publication_output.profile_transaction(str(path), Config(backend="fake"), "obsolete", origin=origin):
            pytest.fail("A stale principal must still be refused")
    assert [error.code for error in rejected] == [3]


def test_explicit_empty_report_folder_retains_cli_current_directory_semantics(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    expected = tmp_path / "chargeback-2026-09.csv"
    assert reports.chargeback_export_path("2026-09", "") == str(expected)
    with guarded_publish(nullcontext):
        assert reports.save_chargeback_csv("2026-09", "complete", "") == str(expected)
    assert expected.read_text(encoding="utf-8") == "complete"
