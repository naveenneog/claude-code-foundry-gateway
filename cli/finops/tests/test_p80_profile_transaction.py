import asyncio
from contextlib import contextmanager, nullcontext
import ctypes
from ctypes import wintypes
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
from threading import Event, Thread

import pytest
from textual.widgets import Static

from claude_finops.config import Config
from claude_finops.errors import FinOpsError
from claude_finops.fake import FakeBackend
from claude_finops import configure, publication_output
from claude_finops.guarded_publication import guarded_publish
from test_p80_connection import OLD_PROFILE, make_app, preview_connection, settle


def revision(content):
    return hashlib.sha256(content).hexdigest()


async def test_apply_keeps_the_reviewed_revision_after_the_last_comparison(tmp_path, monkeypatch):
    from claude_finops import ui_features

    path = tmp_path / "config.json"
    path.write_bytes(OLD_PROFILE)
    newer = OLD_PROFILE.replace(b"old.contoso.com", b"intervening.contoso.com")
    app = make_app(path)
    old_engine = app.engine
    connected = []
    monkeypatch.setattr(ui_features, "connect", lambda config: connected.append(config) or FakeBackend())
    async with app.run_test(size=(100, 34)) as pilot:
        form = await preview_connection(app, pilot)
        original = form.operation
        rechecked = []

        def edit_after_recheck(values, apply):
            result = original(values, apply)
            if not apply:
                path.write_bytes(newer)
                rechecked.append(True)
            return result

        form.operation = edit_after_recheck
        await pilot.click("#action-apply")
        await settle(app, pilot)
        assert rechecked == [True], "The edit must occur after the last preview result was assembled"
        assert path.read_bytes() == newer
        assert app.engine is old_engine
        assert not connected
        assert not list(tmp_path.glob("*.bak.json"))
        message = str(form.query_one("#action-status", Static).render())
        assert "changed since preview" in message.lower()
        assert "url" in message
        assert revision(OLD_PROFILE) in message and revision(newer) in message


async def test_preview_recheck_conflict_also_names_changed_fields_and_revisions(tmp_path, monkeypatch):
    from claude_finops import ui_features

    path = tmp_path / "config.json"
    path.write_bytes(OLD_PROFILE)
    newer = OLD_PROFILE.replace(b"old.contoso.com", b"changed-before-apply.contoso.com")
    app = make_app(path)
    monkeypatch.setattr(ui_features, "connect", lambda config: pytest.fail("A conflict must not connect"))
    async with app.run_test(size=(100, 34)) as pilot:
        form = await preview_connection(app, pilot)
        path.write_bytes(newer)
        await pilot.click("#action-apply")
        await settle(app, pilot)
        assert path.read_bytes() == newer
        message = str(form.query_one("#action-status", Static).render())
        assert "Changed fields: url" in message
        assert revision(OLD_PROFILE) in message and revision(newer) in message


async def test_apply_uses_reviewed_config_without_rediscovering_after_comparison(tmp_path, monkeypatch):
    from claude_finops import ui_features

    path = tmp_path / "config.json"
    path.write_bytes(OLD_PROFILE)
    app = make_app(path)
    actual_connection = []
    monkeypatch.setattr(ui_features, "connect", lambda config: actual_connection.append(config.url) or FakeBackend())
    original = configure.connection_config
    calls = []

    def discovery_changes_after_comparison(config):
        calls.append(config.url)
        result = original(config)
        if len(calls) > 2:
            result.url = "https://not-reviewed.contoso.com"
        return result

    monkeypatch.setattr(configure, "connection_config", discovery_changes_after_comparison)
    async with app.run_test(size=(100, 34)) as pilot:
        await preview_connection(app, pilot)
        await pilot.click("#action-apply")
        await settle(app, pilot)
        assert calls == ["https://new.contoso.com", "https://new.contoso.com"]
        assert actual_connection[0] == "https://new.contoso.com"
        assert json.loads(path.read_bytes())["url"] == "https://new.contoso.com"


def test_profile_edit_during_backup_is_refused_before_replacement(tmp_path, monkeypatch):
    path = tmp_path / "config.json"
    path.write_bytes(OLD_PROFILE)
    newer = OLD_PROFILE.replace(b"old.contoso.com", b"during-backup.contoso.com")
    original = publication_output.backup_profile

    def edit_during_backup(profile):
        backup = original(profile)
        profile.write_bytes(newer)
        return backup

    monkeypatch.setattr(publication_output, "backup_profile", edit_during_backup)
    with pytest.raises(FinOpsError, match="changed since preview"):
        with publication_output.profile_transaction(path, Config(backend="fake"), revision(OLD_PROFILE), origin=nullcontext):
            pytest.fail("A changed profile cannot reach connection verification")
    assert path.read_bytes() == newer
    assert next(tmp_path.glob("*.bak.json")).read_bytes() == OLD_PROFILE


@pytest.mark.parametrize("writer", ["thread", "process"])
def test_profile_commit_serializes_other_aum_writers(tmp_path, monkeypatch, writer):
    path = tmp_path / "config.json"
    path.write_bytes(OLD_PROFILE)
    entered, release = Event(), Event()
    original = publication_output.backup_profile
    failures = []

    def paused_backup(profile):
        entered.set()
        assert release.wait(10), "The fixture must release the first writer"
        return original(profile)

    monkeypatch.setattr(publication_output, "backup_profile", paused_backup)

    def first_writer():
        try:
            with publication_output.profile_transaction(path, Config(backend="fake"), revision(OLD_PROFILE), origin=nullcontext):
                pass
        except Exception as error:
            failures.append(error)

    first = Thread(target=first_writer)
    first.start()
    assert entered.wait(5), "The first writer must reach its protected backup"
    try:
        if writer == "thread":
            monkeypatch.setattr(publication_output, "backup_profile", original)
            with pytest.raises(FinOpsError, match="Another AUM"), guarded_publish(nullcontext):
                publication_output.save_profile(path, Config(backend="direct"))
        else:
            code = """
import sys
from contextlib import nullcontext
from pathlib import Path
from claude_finops.config import Config
from claude_finops.publication_output import save_profile
from claude_finops.guarded_publication import guarded_publish
from claude_finops.errors import FinOpsError
try:
    with guarded_publish(nullcontext):
        save_profile(Path(sys.argv[1]), Config(backend='direct'))
except FinOpsError as error:
    assert error.code == 6 and 'Another AUM' in str(error)
    print('BUSY')
else:
    print('OVERWROTE')
"""
            result = subprocess.run([sys.executable, "-B", "-c", code, str(path)],
                                    capture_output=True, text=True, timeout=5)
            assert result.returncode == 0, result.stderr
            assert result.stdout.strip() == "BUSY"
        assert path.read_bytes() == OLD_PROFILE
    finally:
        release.set()
        first.join(10)
    assert not first.is_alive()
    assert not failures, failures
    assert json.loads(path.read_bytes())["backend"] == "fake"
    assert next(tmp_path.glob("*.bak.json")).read_bytes() == OLD_PROFILE
    with guarded_publish(nullcontext):
        publication_output.save_profile(path, Config(backend="direct"))
    assert json.loads(path.read_bytes())["backend"] == "direct"


def test_post_replacement_read_failure_runs_verification_then_restores(tmp_path, monkeypatch):
    path = tmp_path / "config.json"
    path.write_bytes(OLD_PROFILE)
    original_replace, original_read = publication_output.replace_profile, Path.read_bytes
    state = {"saved": False, "failed": False}
    verified = []

    def replace(profile, content):
        original_replace(profile, content)
        state["saved"] = content != OLD_PROFILE

    def read(profile):
        if profile == path and state["saved"] and not state["failed"]:
            state["failed"] = True
            raise PermissionError("post-save read lock")
        return original_read(profile)

    monkeypatch.setattr(publication_output, "replace_profile", replace)
    monkeypatch.setattr(Path, "read_bytes", read)
    with pytest.raises((OSError, FinOpsError)):
        with publication_output.profile_transaction(path, Config(backend="fake"), revision(OLD_PROFILE), origin=nullcontext):
            verified.append(True)
    assert verified == [True], "No post-save read belongs before rollback protection or whoami"
    assert state["failed"]
    assert path.read_bytes() == OLD_PROFILE
    assert next(tmp_path.glob("*.bak.json")).read_bytes() == OLD_PROFILE


@pytest.mark.parametrize("existing", [True, False])
async def test_failed_restore_has_durable_backup_and_recovery_steps(tmp_path, monkeypatch, existing):
    from claude_finops import ui_features

    path = tmp_path / "config.json"
    if existing:
        path.write_bytes(OLD_PROFILE)
    app = make_app(path)
    old_engine = app.engine
    original_replace, original_unlink = publication_output.replace_profile, Path.unlink
    restored = []

    class Refused(FakeBackend):
        def read(self, resource, **params):
            if resource == "whoami":
                raise FinOpsError("Candidate identity denied.", 4)
            return super().read(resource, **params)

    def restore_denied(profile, content):
        if content == OLD_PROFILE:
            restored.append(True)
            raise PermissionError("restore target is locked")
        return original_replace(profile, content)

    def unlink_denied(profile, *args, **kwargs):
        if profile == path:
            restored.append(True)
            raise PermissionError("new profile is locked")
        return original_unlink(profile, *args, **kwargs)

    monkeypatch.setattr(ui_features, "connect", lambda config: Refused())
    monkeypatch.setattr(publication_output, "replace_profile", restore_denied)
    monkeypatch.setattr(Path, "unlink", unlink_denied)
    async with app.run_test(size=(100, 34)) as pilot:
        form = await preview_connection(app, pilot)
        await pilot.click("#action-apply")
        await settle(app, pilot)
        assert restored == [True]
        assert app.engine is old_engine
        assert json.loads(path.read_bytes())["url"] == "https://new.contoso.com"
        message = str(form.query_one("#action-status", Static).render())
        assert "could not be restored" in message.lower()
        assert "Recovery:" in message and str(path) in message
        assert "Close" in message and "holding" in message
        if existing:
            backup = next(tmp_path.glob("*.bak.json"))
            assert str(backup) in message and "copy" in message.lower()
            assert backup.read_bytes() == OLD_PROFILE
        else:
            assert "remove" in message.lower() and "no previous file" in message
        assert "restored successfully" not in message.lower()


@contextmanager
def windows_deny_read(path):
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    create = kernel.CreateFileW
    create.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, ctypes.c_void_p,
                       wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
    create.restype = wintypes.HANDLE
    close = kernel.CloseHandle
    close.argtypes, close.restype = [wintypes.HANDLE], wintypes.BOOL
    handle = create(str(path), 0x80000000, 0, None, 3, 0x80, None)
    if handle == ctypes.c_void_p(-1).value:
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        yield
    finally:
        assert close(handle), ctypes.WinError(ctypes.get_last_error())


@pytest.mark.skipif(os.name != "nt", reason="Windows file-sharing semantics")
def test_real_windows_read_lock_after_replace_is_not_an_unprotected_failure(tmp_path, monkeypatch):
    path = tmp_path / "config.json"
    path.write_bytes(OLD_PROFILE)
    original = publication_output.replace_profile
    locked = []
    verified = []

    def replace_then_lock(profile, content):
        original(profile, content)
        if content != OLD_PROFILE:
            handle = windows_deny_read(profile)
            handle.__enter__()
            locked.append(handle)

    monkeypatch.setattr(publication_output, "replace_profile", replace_then_lock)
    try:
        with publication_output.profile_transaction(path, Config(backend="fake"), revision(OLD_PROFILE), origin=nullcontext):
            verified.append(True)
            with pytest.raises(PermissionError):
                path.read_bytes()
            locked.pop().__exit__(None, None, None)
        assert verified == [True]
    finally:
        for handle in locked:
            handle.__exit__(None, None, None)
    assert json.loads(path.read_bytes())["backend"] == "fake"
