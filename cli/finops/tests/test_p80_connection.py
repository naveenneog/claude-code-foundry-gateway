import json
from pathlib import Path

import pytest
from textual.widgets import Button, Input, Select, Static
from typer.testing import CliRunner

from claude_finops.cli import app as cli_app
from claude_finops.config import Config
from claude_finops.engine import Engine
from claude_finops.errors import FinOpsError
from claude_finops.fake import FakeBackend
from claude_finops.guarded_publication import guarded_publish
from claude_finops.tui import FinOpsApp


OLD_PROFILE = b'{\r\n  "backend": "turnstile", "url": "https://old.contoso.com",\n  "scope": "api://old/Turnstile.Access"\r\n}\n'


async def settle(app, pilot):
    await pilot.pause()
    await app.workers.wait_for_complete()
    await pilot.pause()


def make_app(path):
    backend = FakeBackend()
    config = Config(backend="turnstile", url="https://old.contoso.com", scope="api://old/Turnstile.Access")
    app = FinOpsApp(Engine(backend, "2026-09"), config, first_run=False)
    app.profile_path = path
    return app


async def preview_connection(app, pilot):
    await settle(app, pilot)
    app.action_tab("settings")
    await settle(app, pilot)
    await pilot.click("#settings-profile")
    await pilot.pause()
    form = app.screen
    assert {"backend", "url", "scope", "path", "subscription", "resource_group", "apim_name"} <= {
        field[0] for field in form.fields}
    assert form.query_one("#field-path", Input).value == str(app.profile_path)
    with guarded_publish(app.current_guard()):
        form.query_one("#field-backend", Select).value = "aum-service"
        form.query_one("#field-url", Input).value = "https://new.contoso.com"
        form.query_one("#field-scope", Input).value = "api://new/AUM.Access"
    await pilot.click("#action-preview")
    await settle(app, pilot)
    assert not form.query_one("#action-apply", Button).disabled
    return form


@pytest.mark.parametrize("backend,scope", [
    ("turnstile", "api://example/Turnstile.Access"),
    ("aum-service", "api://example/AUM.Access"),
])
def test_configure_explicit_http_address_does_not_discover_azure(tmp_path, monkeypatch, backend, scope):
    from claude_finops import configure

    monkeypatch.setattr(configure, "discover", lambda **kwargs: pytest.fail("An explicit HTTP connection needs no Azure discovery"))
    path = tmp_path / "config.json"
    result = CliRunner().invoke(cli_app, ["configure", "--backend", backend, "--url",
        "https://example.contoso.com", "--scope", scope, "--save", "--no-prompt", "--config", str(path)])
    assert result.exit_code == 0, result.output
    saved = json.loads(path.read_text(encoding="utf-8"))
    assert (saved["backend"], saved["url"], saved["scope"]) == (backend, "https://example.contoso.com", scope)


def test_configure_decline_keeps_exact_profile_and_creates_no_backup(tmp_path, monkeypatch):
    from claude_finops import cli, configure

    path = tmp_path / "config.json"
    path.write_bytes(OLD_PROFILE)
    monkeypatch.setattr(cli, "terminal_output", lambda: True)
    monkeypatch.setattr(configure, "discover", lambda **kwargs: {"config": {"backend": "direct"}, "portal": {}})
    result = CliRunner().invoke(cli_app, ["configure", "--save", "--backend", "direct", "--config", str(path)], input="n\n")
    assert result.exit_code == 6, result.output
    assert path.read_bytes() == OLD_PROFILE
    assert not list(tmp_path.glob("*.bak.json"))


def test_configure_force_backup_preserves_bytes_and_previous_backups(tmp_path, monkeypatch):
    from claude_finops import configure

    path = tmp_path / "config.json"
    path.write_bytes(OLD_PROFILE)
    monkeypatch.setattr(configure, "discover", lambda **kwargs: {"config": {"backend": "direct"}, "portal": {}})
    args = ["configure", "--save", "--force", "--no-prompt", "--backend", "direct", "--config", str(path)]
    first = CliRunner().invoke(cli_app, args)
    assert first.exit_code == 0, first.output
    backups = list(tmp_path.glob("config.*.bak.json"))
    assert len(backups) == 1
    assert backups[0].read_bytes() == OLD_PROFILE
    first_saved = path.read_bytes()
    second = CliRunner().invoke(cli_app, args)
    assert second.exit_code == 0, second.output
    assert len(list(tmp_path.glob("config.*.bak.json"))) == 2
    assert sorted(p.read_bytes() for p in tmp_path.glob("*.bak.json")) == sorted([OLD_PROFILE, first_saved])


def test_configure_failed_atomic_replace_keeps_original(tmp_path, monkeypatch):
    from claude_finops import configure

    path = tmp_path / "config.json"
    path.write_bytes(OLD_PROFILE)
    monkeypatch.setattr(configure, "discover", lambda **kwargs: {"config": {"backend": "direct"}, "portal": {}})
    original_replace = Path.replace

    def fail_replace(source, target):
        if Path(target) == path:
            raise PermissionError("test profile is locked")
        return original_replace(source, target)

    monkeypatch.setattr(Path, "replace", fail_replace)
    result = CliRunner().invoke(cli_app, ["configure", "--save", "--force", "--no-prompt", "--config", str(path)])
    assert result.exit_code == 7, result.output
    assert path.read_bytes() == OLD_PROFILE
    assert not list(tmp_path.glob("*.tmp"))


@pytest.mark.parametrize("selection", ["explicit", "environment"])
def test_terminal_keeps_the_selected_profile_path(tmp_path, monkeypatch, selection):
    from claude_finops import cli

    path = tmp_path / "selected.json"
    path.write_text('{"backend":"fake"}', encoding="utf-8")
    seen = []
    monkeypatch.setattr(cli, "terminal_output", lambda: True)
    monkeypatch.setattr(FinOpsApp, "run", lambda self: seen.append(self.profile_path))
    if selection == "environment":
        monkeypatch.setenv("AUM_CONFIG", str(path))
    args = ["--config", str(path)] if selection == "explicit" else []
    result = CliRunner().invoke(cli_app, args)
    assert result.exit_code == 0, result.output
    assert seen == [path]


async def test_connection_preview_saves_backup_and_verifies_before_live_switch(tmp_path, monkeypatch):
    from claude_finops import ui_features

    path = tmp_path / "config.json"
    path.write_bytes(OLD_PROFILE)
    app = make_app(path)
    old_backend = app.engine.backend
    observed = []

    class VerifiedBackend(FakeBackend):
        def read(self, resource, **params):
            if resource == "whoami":
                assert json.loads(path.read_bytes())["url"] == "https://new.contoso.com"
                observed.append(app.engine.backend)
            return super().read(resource, **params)

    replacement = VerifiedBackend()
    monkeypatch.setattr(ui_features, "connect", lambda config: replacement)
    async with app.run_test(size=(100, 34)) as pilot:
        form = await preview_connection(app, pilot)
        assert path.read_bytes() == OLD_PROFILE
        assert not list(tmp_path.glob("*.bak.json"))
        assert observed == []
        assert form.query_one("#action-apply", Button).label == "Save and connect"
        await pilot.click("#action-apply")
        await settle(app, pilot)
        assert observed[0] is old_backend
        assert app.engine.backend is replacement
        assert app.config.backend == "aum-service"
        assert app.config.url == "https://new.contoso.com"
        assert app.profile_path == path
        assert len(list(tmp_path.glob("*.bak.json"))) == 1
        assert next(tmp_path.glob("*.bak.json")).read_bytes() == OLD_PROFILE
        assert "via AUM service" in str(app.query_one("#identity", Static).render())


@pytest.mark.parametrize("existing", [True, False])
async def test_failed_connection_restores_disk_and_live_engine(tmp_path, monkeypatch, existing):
    from claude_finops import ui_features

    path = tmp_path / "config.json"
    if existing:
        path.write_bytes(OLD_PROFILE)
    app = make_app(path)
    old_engine, old_config = app.engine, app.config
    closed = []
    verified = []

    class RefusedBackend(FakeBackend):
        def read(self, resource, **params):
            if resource == "whoami":
                verified.append(json.loads(path.read_bytes())["url"])
                raise FinOpsError("The replacement identity is denied.", 4)
            return super().read(resource, **params)

        def close(self):
            closed.append("replacement")
            super().close()

    monkeypatch.setattr(old_engine.backend, "close", lambda: closed.append("original"))
    monkeypatch.setattr(ui_features, "connect", lambda config: RefusedBackend())
    async with app.run_test(size=(100, 34)) as pilot:
        await preview_connection(app, pilot)
        await pilot.click("#action-apply")
        await settle(app, pilot)
        assert verified == ["https://new.contoso.com"]
        assert app.engine is old_engine and app.config is old_config
        assert closed == ["replacement"]
        assert path.read_bytes() == OLD_PROFILE if existing else not path.exists()
        assert len(list(tmp_path.glob("*.bak.json"))) == int(existing)
        status = str(app.query_one("#status", Static).render())
        assert "previous connection" in status.lower()
        assert "denied" in status


async def test_backup_failure_cannot_start_a_half_switch(tmp_path, monkeypatch):
    from claude_finops import configure, ui_features

    path = tmp_path / "config.json"
    path.write_bytes(OLD_PROFILE)
    app = make_app(path)
    old_engine = app.engine

    def cannot_backup(path):
        raise PermissionError("No backup permission")

    monkeypatch.setattr(configure, "backup_profile", cannot_backup)
    monkeypatch.setattr(ui_features, "connect", lambda config: pytest.fail("No connection before a successful backup"))
    async with app.run_test(size=(100, 34)) as pilot:
        await preview_connection(app, pilot)
        await pilot.click("#action-apply")
        await settle(app, pilot)
        assert path.read_bytes() == OLD_PROFILE
        assert app.engine is old_engine
        assert "previous connection" in str(app.query_one("#status", Static).render()).lower()


async def test_changed_profile_since_preview_is_not_replaced(tmp_path, monkeypatch):
    from claude_finops import ui_features

    path = tmp_path / "config.json"
    path.write_bytes(OLD_PROFILE)
    app = make_app(path)
    monkeypatch.setattr(ui_features, "connect", lambda config: pytest.fail("A changed profile must be previewed again"))
    async with app.run_test(size=(100, 34)) as pilot:
        form = await preview_connection(app, pilot)
        newer = OLD_PROFILE.replace(b"old.contoso.com", b"someone-else.contoso.com")
        path.write_bytes(newer)
        await pilot.click("#action-apply")
        await settle(app, pilot)
        assert path.read_bytes() == newer
        assert not list(tmp_path.glob("*.bak.json"))
        assert "changed since preview" in str(form.query_one("#action-status", Static).render()).lower()
