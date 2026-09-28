from contextlib import asynccontextmanager
from copy import deepcopy
import hashlib
import os
from pathlib import Path
import re

import pytest
from textual.containers import VerticalScroll
from textual.widgets import Static

from claude_finops import configure
from claude_finops.fake import FakeBackend
from test_p80_connection import OLD_PROFILE, make_app, preview_connection, settle
from test_p80_profile_transaction import windows_deny_read


@asynccontextmanager
async def verified_then_locked(tmp_path, monkeypatch):
    from claude_finops import ui_features

    path = tmp_path / "config.json"
    path.write_bytes(OLD_PROFILE)
    app = make_app(path)
    old_engine = app.engine
    held = []
    events = {"verified": [], "denied_reads": 0, "adoptions": [], "closed": []}
    original_read, original_bind = Path.read_bytes, app._bind_engine

    class VerifiedButLocked(FakeBackend):
        def read(self, resource, **params):
            result = super().read(resource, **params)
            if resource == "whoami":
                result = dict(result, id="candidate-id", email="candidate@contoso.com")
                handle = windows_deny_read(path)
                handle.__enter__()
                held.append(handle)
                events["verified"].append(dict(result))
            return result

        def close(self):
            events["closed"].append("candidate")
            super().close()

    def read(profile):
        try:
            return original_read(profile)
        except PermissionError:
            if profile == path and held:
                events["denied_reads"] += 1
            raise

    def bind(engine):
        if engine is not old_engine:
            events["adoptions"].append(engine)
        return original_bind(engine)

    monkeypatch.setattr(ui_features, "connect", lambda config: VerifiedButLocked())
    monkeypatch.setattr(Path, "read_bytes", read)
    monkeypatch.setattr(app, "_bind_engine", bind)
    monkeypatch.setattr(old_engine.backend, "close", lambda: events["closed"].append("previous"))
    try:
        async with app.run_test(size=(80, 24)) as pilot:
            form = await preview_connection(app, pilot)
            previous = dict(engine=app.engine, config=app.config, identity=deepcopy(app.identity),
                            preferences=app.preferences, feature_caps=deepcopy(app.feature_caps),
                            data=deepcopy(app.data), records=deepcopy(app.records),
                            profile=app.profile_path, screens=list(app.screen_stack))
            await pilot.click("#action-apply")
            await settle(app, pilot)
            assert len(events["verified"]) == 1, "whoami must succeed before the persistent lock matters"
            assert events["denied_reads"] >= 2, "The same handle must deny final validation and restoration"
            with pytest.raises(PermissionError):
                path.read_bytes()
            yield app, pilot, form, path, previous, events
    finally:
        for handle in held:
            handle.__exit__(None, None, None)


@pytest.mark.skipif(os.name != "nt", reason="Windows file-sharing semantics")
async def test_successful_whoami_then_persistent_lock_preserves_previous_ui(tmp_path, monkeypatch):
    async with verified_then_locked(tmp_path, monkeypatch) as (app, pilot, form, path, previous, events):
        assert app.engine is previous["engine"]
        assert app.config is previous["config"]
        assert app.identity == previous["identity"]
        assert app.preferences is previous["preferences"]
        assert app.feature_caps == previous["feature_caps"]
        assert app.data == previous["data"]
        assert app.records == previous["records"]
        assert app.profile_path == previous["profile"]
        assert list(app.screen_stack) == previous["screens"]
        assert app.screen is form
        assert events["adoptions"] == []
        assert events["closed"] == ["candidate"]
        backup = next(tmp_path.glob("*.bak.json"))
        assert backup.read_bytes() == OLD_PROFILE
        text = str(form.query_one("#action-status", Static).render())
        assert str(backup) in text and "Recovery:" in text


@pytest.mark.skipif(os.name != "nt", reason="Windows file-sharing semantics")
async def test_locked_recovery_path_and_every_instruction_are_keyboard_readable_at_80x24(tmp_path, monkeypatch):
    async with verified_then_locked(tmp_path, monkeypatch) as (app, pilot, form, path, previous, events):
        assert app.screen is form
        status = form.query_one("#action-status", Static)
        feedback = form.query_one("#action-feedback", VerticalScroll)
        backup = next(tmp_path.glob("*.bak.json"))
        text = str(status.render())
        assert str(backup) in text
        assert "Recovery: Close the application holding the profile" in text
        assert "copy the backup" in text and "verify whoami" in text
        assert feedback.can_focus and app.focused is feedback
        assert feedback.region.right <= 80 and feedback.region.bottom <= 24
        assert feedback.max_scroll_y > 0

        await pilot.press("home")
        await pilot.pause()
        lines = {}
        for _ in range(int(feedback.max_scroll_y) + 1):
            region = feedback.scrollable_content_region
            rendered = app.screen._compositor.render_strips()
            for offset, strip in enumerate(rendered[region.y:region.bottom]):
                lines[int(feedback.scroll_y) + offset] = strip.text[region.x:region.right].rstrip()
            await pilot.press("down")
            await pilot.pause()
        visible = "".join(lines[key] for key in sorted(lines))
        normalize = lambda value: re.sub(r"\s+", "", value)
        assert normalize(text) == normalize(visible), "Every recovery character must be reachable through the viewport"
        assert normalize(str(backup)) in normalize(visible)
        assert normalize("then reopen AUM with the previous connection and verify whoami") in normalize(visible)
        assert app.screen is form and app.identity == previous["identity"]
        with pytest.raises(PermissionError):
            path.read_bytes()


async def test_candidate_is_adopted_only_after_the_saved_revision_check(tmp_path, monkeypatch):
    from claude_finops import ui_features

    path = tmp_path / "config.json"
    path.write_bytes(OLD_PROFILE)
    app = make_app(path)
    old_engine = app.engine
    original_check, original_bind = configure.require_profile_revision, app._bind_engine
    events = []
    candidate_revision = None
    monkeypatch.setattr(ui_features, "connect", lambda config: FakeBackend())

    def check(profile, revision, before=None):
        original_check(profile, revision, before)
        if revision == candidate_revision:
            assert app.engine is old_engine, "The last saved-file check still belongs to the old UI"
            assert len(app.screen_stack) == 2
            events.append("validated")

    def bind(engine):
        if engine is not old_engine:
            assert events == ["validated"], "Adoption must follow successful transaction exit"
            events.append("adopted")
        return original_bind(engine)

    monkeypatch.setattr(configure, "require_profile_revision", check)
    monkeypatch.setattr(app, "_bind_engine", bind)
    async with app.run_test(size=(80, 24)) as pilot:
        form = await preview_connection(app, pilot)
        candidate_revision = hashlib.sha256(form.preview["profile_change"].content).hexdigest()
        await pilot.click("#action-apply")
        await settle(app, pilot)
        assert events == ["validated", "adopted"]
        assert app.config.backend == "aum-service"
        assert len(app.screen_stack) == 1
