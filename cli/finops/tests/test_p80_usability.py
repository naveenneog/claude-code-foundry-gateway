import json
from pathlib import Path

import pytest
from textual.widgets import Button, DataTable, Input, Select, Static, TabbedContent
from typer.testing import CliRunner

from claude_finops.cli import app
from claude_finops.config import Config
from claude_finops.engine import Engine
from claude_finops.fake import FakeBackend
from claude_finops.guarded_publication import guarded_publish
from claude_finops.tui import FinOpsApp


def example(role="owner", *, backend=None, config=None):
    return FinOpsApp(Engine(backend or FakeBackend(role), "2026-09"), config or Config(backend="fake"))


async def settle(app, pilot):
    await pilot.pause()
    await app.workers.wait_for_complete()
    await pilot.pause()


def button_labels(app):
    return [str(button.label) for button in app.query(Button)]


async def test_people_and_budgets_show_visible_p80_action_bar():
    app = example()
    async with app.run_test(size=(100, 30)) as pilot:
        await settle(app, pilot)
        await pilot.press("3")
        await settle(app, pilot)
        labels = button_labels(app)
        assert "Add person to team" in labels
        assert "Set budget" in labels
        assert "Chargeback report" in labels
        assert "Set USD budget" in labels
        assert "P81 brings USD to Turnstile" in str(app.query_one("#note-people", Static).render())
        assert "Add person" in str(app.query_one("#key-hints", Static).render())

        await pilot.press("2")
        await settle(app, pilot)
        labels = button_labels(app)
        assert "Set budget" in labels
        assert "Chargeback report" in labels


async def test_add_person_from_people_loads_units_without_visiting_budgets(monkeypatch):
    from claude_finops import developer_screens

    def find(engine, config, query, limit=50, cursor=None):
        assert query == "sgiddegowda@microsoft.com"
        return {
            "items": [{
                "id": "00000000-0000-0000-0000-000000000090",
                "display_name": "S Giddegowda",
                "user_principal_name": "sgiddegowda@microsoft.com",
                "mail": "sgiddegowda@microsoft.com",
                "user_type": "Member",
                "current_tier": "",
                "current_unit": "",
            }],
            "next_cursor": None,
        }

    monkeypatch.setattr(developer_screens, "developer_find", find)
    app = example()
    async with app.run_test(size=(100, 30)) as pilot:
        await settle(app, pilot)
        await pilot.press("3")
        await settle(app, pilot)
        assert "budgets" not in app.data
        app.action_add_developer(prefill_user="sgiddegowda@microsoft.com", prefill_unit=app.team)
        await pilot.pause()
        with guarded_publish(app.current_guard()):
            app.screen.query_one("#developer-search", Input).value = "sgiddegowda@microsoft.com"
        await pilot.press("enter")
        await settle(app, pilot)
        assert app.screen.query_one("#developer-results", DataTable).row_count == 1
        await pilot.press("enter")
        await settle(app, pilot)
        unit = app.screen.query_one("#field-unit", Select)
        assert unit.value == "sales-emea"
        assert any(value == "sales-emea" for _, value in unit._options)


async def test_empty_people_search_offers_owner_add_and_non_owner_explains():
    owner = example()
    async with owner.run_test(size=(100, 30)) as pilot:
        await settle(owner, pilot)
        await pilot.press("3")
        await settle(owner, pilot)
        with guarded_publish(owner.current_guard()):
            owner.query_one("#people-query", Input).value = "sgiddegowda@microsoft.com"
        owner.find_people()
        await settle(owner, pilot)
        note = str(owner.query_one("#note-people", Static).render())
        assert "Add sgiddegowda@microsoft.com to sales-emea" in note

    member = example("member")
    async with member.run_test(size=(100, 30)) as pilot:
        await settle(member, pilot)
        await pilot.press("3")
        await settle(member, pilot)
        with guarded_publish(member.current_guard()):
            member.query_one("#people-query", Input).value = "sgiddegowda@microsoft.com"
        member.find_people()
        await settle(member, pilot)
        note = str(member.query_one("#note-people", Static).render())
        assert "No matching person in this team" in note
        assert "Add sgiddegowda" not in note


def test_chargeback_report_path_defaults_to_documents_and_never_overwrites(tmp_path, monkeypatch):
    from claude_finops.reports import chargeback_export_path

    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    folder = tmp_path / "Documents" / "AUM"
    folder.mkdir(parents=True)
    (folder / "chargeback-2026-09.csv").write_text("existing", encoding="utf-8")
    path = chargeback_export_path("2026-09")
    assert path == folder / "chargeback-2026-09-1.csv"


def test_cli_chargeback_can_save_complete_csv_without_overwriting(tmp_path):
    folder = tmp_path / "reports"
    folder.mkdir()
    (folder / "chargeback-2026-09.csv").write_text("old", encoding="utf-8")
    result = CliRunner().invoke(app, ["--backend", "fake", "--month", "2026-09", "report", "chargeback", "--output", str(folder)])
    assert result.exit_code == 0, result.output
    path = folder / "chargeback-2026-09-1.csv"
    assert path.exists()
    assert "chargeback-2026-09-1.csv" in result.output
    assert "scope,tokens" in path.read_text(encoding="utf-8")


def test_configure_attended_save_replaces_existing_profile_with_backup(tmp_path, monkeypatch):
    from claude_finops import cli

    path = tmp_path / "config.json"
    path.write_text(json.dumps({"backend": "turnstile", "url": "https://old.contoso.com"}) + "\n", encoding="utf-8")
    monkeypatch.setattr(cli, "terminal_output", lambda: True)
    monkeypatch.setattr("claude_finops.configure.discover", lambda **kwargs:
                        {"config": {"backend": "direct", "subscription": "00000000-0000-0000-0000-000000000001"}, "portal": {}})
    result = CliRunner().invoke(app, ["configure", "--save", "--config", str(path), "--backend", "direct"], input="y\n")
    assert result.exit_code == 0, result.output
    assert json.loads(path.read_text(encoding="utf-8"))["backend"] == "direct"
    backups = list(tmp_path.glob("config.*.bak.json"))
    assert len(backups) == 1
    assert json.loads(backups[0].read_text(encoding="utf-8"))["backend"] == "turnstile"


def test_configure_unattended_existing_profile_still_refuses(tmp_path, monkeypatch):
    path = tmp_path / "config.json"
    path.write_text(json.dumps({"backend": "turnstile", "url": "https://old.contoso.com"}) + "\n", encoding="utf-8")
    monkeypatch.setattr("claude_finops.configure.discover", lambda **kwargs:
                        {"config": {"backend": "direct", "subscription": "00000000-0000-0000-0000-000000000001"}, "portal": {}})
    result = CliRunner().invoke(app, ["configure", "--save", "--no-prompt", "--config", str(path), "--backend", "direct"])
    assert result.exit_code == 6
    assert "use --force" in result.output
    assert not list(tmp_path.glob("*.bak.json"))


async def test_settings_names_connection_and_rolls_back_failed_switch(monkeypatch):
    from claude_finops import ui_features

    class BrokenBackend(FakeBackend):
        def read(self, resource, **params):
            if resource == "whoami":
                raise RuntimeError("new backend failed")
            return super().read(resource, **params)

    old_backend = FakeBackend()
    app = example(backend=old_backend, config=Config(backend="turnstile", url="https://turnstile.contoso.com"))
    monkeypatch.setattr(ui_features, "connect", lambda config: BrokenBackend())
    async with app.run_test(size=(100, 30)) as pilot:
        await settle(app, pilot)
        owner_tab = app.query_one(TabbedContent)
        owner_tab.active = "settings"
        app.action_refresh()
        await settle(app, pilot)
        settings = [row for row in app.records["settings"] if "connection" in row]
        assert any("via Turnstile" in str(row) for row in settings)
        await app.activate_profile(Config(backend="direct"))
        await settle(app, pilot)
        assert app.engine.backend is old_backend
        assert app.config.backend == "turnstile"
