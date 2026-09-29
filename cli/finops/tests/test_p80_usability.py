import json
from contextlib import contextmanager
from pathlib import Path

import pytest
from rich.cells import cell_len
from textual.widgets import Button, DataTable, Input, Select, Static, TabbedContent, TabPane
from typer.testing import CliRunner

from claude_finops.cli import app
from claude_finops.config import Config
from claude_finops.engine import Engine
from claude_finops.errors import FinOpsError
from claude_finops.fake import FakeBackend
from claude_finops.feature_screens import ActionForm
from claude_finops.guarded_publication import guarded_publish
from claude_finops.tui import FinOpsApp


def example(role="owner", *, backend=None, config=None):
    return FinOpsApp(Engine(backend or FakeBackend(role), "2026-09"), config or Config(backend="fake"),
                     first_run=False)


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
    assert path == str(folder / "chargeback-2026-09-1.csv")


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


@pytest.mark.parametrize("tab", ["people", "budgets"])
async def test_actions_fit_compact_terminal_and_help_matches_footer(tab):
    app = example()
    async with app.run_test(size=(80, 24)) as pilot:
        await settle(app, pilot)
        app.action_tab(tab)
        await settle(app, pilot)
        pane = app.query_one(f"#{tab}", TabPane)
        labels = ["Add person to team", "Set budget", "Set USD budget", "Chargeback report"]
        buttons = {str(button.label): button for button in pane.query(Button)}
        for label in labels:
            assert label in buttons
            button = buttons[label]
            assert button.content_size.width >= cell_len(label), label
            assert button.region.right <= pane.region.right, label
        hints = str(app.query_one("#key-hints", Static).render())
        for label in labels:
            assert label in hints
        assert app.query_one("#key-hints", Static).size.height <= 2
        await pilot.press("?")
        await pilot.pause()
        help_text = str(app.screen.data)
        for label in labels:
            assert label in help_text
        assert not app.engine.backend.writes


@pytest.mark.parametrize("kind,label", [
    ("direct", "Direct"), ("aum-service", "AUM service"), ("turnstile", "Turnstile"),
])
async def test_header_names_selected_connection(kind, label):
    app = example(config=Config(backend=kind, url="https://selected.contoso.com"))
    async with app.run_test(size=(100, 30)) as pilot:
        await settle(app, pilot)
        assert f"via {label}" in str(app.query_one("#identity", Static).render())
        app.action_tab("settings")
        await settle(app, pilot)
        assert "selected.contoso.com" in str(app.records["settings"]) or kind == "direct"


async def test_set_budget_button_tracks_selected_writable_person():
    backend = FakeBackend()
    app = example(backend=backend)
    async with app.run_test(size=(100, 30)) as pilot:
        await settle(app, pilot)
        app.action_tab("people")
        await settle(app, pilot)
        app.records["people"][0]["writable"] = False
        app.update_action_buttons()
        button = app.query_one("#people #action-set-budget", Button)
        assert button.disabled
        app.query_one("#table-people", DataTable).move_cursor(row=1)
        await pilot.pause()
        assert not button.disabled
        await pilot.click(button)
        await pilot.pause()
        assert app.screen.kind == "budget"
        assert app.screen.row["scope_id"] == app.records["people"][1]["scope_id"]
        assert not backend.writes


@pytest.mark.parametrize("role", ["member", "viewer"])
async def test_non_owner_cannot_open_add_person_from_button_or_shortcut(role):
    app = example(role)
    async with app.run_test(size=(100, 30)) as pilot:
        await settle(app, pilot)
        app.action_tab("people")
        await settle(app, pilot)
        assert app.query_one("#people #action-add-person", Button).disabled
        app.action_add_developer()
        await pilot.press("g")
        await pilot.pause()
        assert len(app.screen_stack) == 1
        assert not app.engine.backend.writes


@pytest.fixture
def directory_person(monkeypatch):
    from claude_finops import developer_screens

    person = dict(id="00000000-0000-0000-0000-000000000090", display_name="Example Person",
                  user_principal_name="person@contoso.com", mail="person@contoso.com",
                  user_type="Member", current_tier="", current_unit="")
    monkeypatch.setattr(developer_screens, "developer_find",
                        lambda *args, **kwargs: dict(items=[person], next_cursor=None))
    return person


async def open_empty_search_add(app, pilot):
    await settle(app, pilot)
    app.action_tab("people")
    await settle(app, pilot)
    with guarded_publish(app.current_guard()):
        app.query_one("#people-query", Input).value = "person@contoso.com"
    app.find_people()
    await settle(app, pilot)
    await pilot.click("#people #action-add-person")
    await pilot.pause(0.4)
    await settle(app, pilot)
    assert app.screen.query_one("#developer-search", Input).value == "person@contoso.com"
    assert app.screen.query_one("#developer-results", DataTable).row_count == 1
    return app.screen


async def test_empty_search_button_prefills_person_and_selected_team(directory_person):
    app = example()
    async with app.run_test(size=(100, 30)) as pilot:
        picker = await open_empty_search_add(app, pilot)
        assert "budgets" not in app.data
        await pilot.press("enter")
        await settle(app, pilot)
        assert isinstance(app.screen, ActionForm)
        assert app.screen.query_one("#field-user", Input).value == directory_person["user_principal_name"]
        assert app.screen.query_one("#field-unit", Select).value == app.team
        assert app.screen.preview is None
        assert not app.engine.backend.writes


async def test_catalog_failure_stays_in_picker_with_visible_error(directory_person, monkeypatch):
    app = example()
    async with app.run_test(size=(100, 30)) as pilot:
        picker = await open_empty_search_add(app, pilot)
        original = app.engine.read

        def read(resource, **kwargs):
            if resource == "budgets":
                raise FinOpsError("Catalog is unavailable. Retry the directory selection.", 7)
            return original(resource, **kwargs)

        monkeypatch.setattr(app.engine, "read", read)
        await pilot.press("enter")
        await settle(app, pilot)
        assert app.screen is picker
        assert "Catalog is unavailable" in str(picker.query_one("#developer-status", Static).render())
        assert not app.engine.backend.writes


@pytest.mark.parametrize("when", ["before", "during"])
async def test_on_demand_catalog_cannot_replace_a_stale_directory_guard(directory_person, monkeypatch, when):
    app = example()
    async with app.run_test(size=(100, 30)) as pilot:
        picker = await open_empty_search_add(app, pilot)

        state = {"stale": when == "before"}

        @contextmanager
        def stale_directory():
            if state["stale"]:
                raise FinOpsError("Directory sign-in changed. Search again.", 3)
            yield

        original = app.engine.read

        def read(resource, **kwargs):
            result = original(resource, **kwargs)
            if resource == "budgets" and when == "during":
                state["stale"] = True
            return result

        picker.read_guard = stale_directory
        monkeypatch.setattr(app.engine, "read", read)
        await pilot.press("enter")
        await settle(app, pilot)
        assert app.screen is picker
        assert "sign-in changed" in str(picker.query_one("#developer-status", Static).render())
        assert not app.engine.backend.writes


async def test_add_form_keeps_a_cached_catalog_guard(directory_person):
    app = example()
    async with app.run_test(size=(100, 30)) as pilot:
        await settle(app, pilot)
        app.action_tab("budgets")
        await settle(app, pilot)
        picker = await open_empty_search_add(app, pilot)

        @contextmanager
        def stale_catalog():
            raise FinOpsError("Catalog sign-in changed. Refresh the scopes.", 3)
            yield

        app._data_guards["budgets"] = (app.data["budgets"], stale_catalog)
        await pilot.press("enter")
        await settle(app, pilot)
        assert app.screen is picker
        assert "Catalog sign-in changed" in str(picker.query_one("#developer-status", Static).render())


async def test_turnstile_usd_action_is_disabled_without_a_token_fallback():
    app = example(config=Config(backend="turnstile", url="https://turnstile.contoso.com"))
    async with app.run_test(size=(100, 30)) as pilot:
        await settle(app, pilot)
        app.action_tab("people")
        await settle(app, pilot)
        assert app.query_one("#people #action-set-usd-budget", Button).disabled
        assert "Turnstile" in str(app.query_one("#note-people", Static).render())
        await pilot.press("u")
        await pilot.pause()
        assert len(app.screen_stack) == 1
        assert not app.engine.backend.writes


async def test_budget_usd_explanation_is_visible_at_80_columns():
    app = example(config=Config(backend="turnstile", url="https://turnstile.contoso.com"))
    async with app.run_test(size=(80, 24)) as pilot:
        await settle(app, pilot)
        app.action_tab("budgets")
        await settle(app, pilot)
        rendered = "\n".join(strip.text for strip in app.screen._compositor.render_strips())
        assert "USD budget writes need" in rendered
        assert "P81 brings USD to Turnstile." in rendered


async def test_settings_connection_is_the_first_visible_fact():
    app = example(config=Config(backend="turnstile", url="https://turnstile.contoso.com"))
    async with app.run_test(size=(80, 24)) as pilot:
        await settle(app, pilot)
        app.action_tab("settings")
        await settle(app, pilot)
        assert "connection" in app.records["settings"][0]
        rendered = "\n".join(strip.text for strip in app.screen._compositor.render_strips())
        assert "via Turnstile" in rendered
        assert "https://turnstile.contoso.com" in rendered


async def test_usd_action_keeps_its_own_capability_instead_of_requiring_token_writes():
    from test_usd_budgets import UsdFake

    class UsdOnly(UsdFake):
        def read(self, resource, **params):
            result = super().read(resource, **params)
            if resource == "capabilities":
                result["features"]["native_writes"] = {"enabled": True, "actions": []}
            return result

    backend = UsdOnly()
    app = example(backend=backend)
    async with app.run_test(size=(100, 30)) as pilot:
        await settle(app, pilot)
        app.action_tab("budgets")
        await settle(app, pilot)
        assert not app.check_action("edit", ())
        button = app.query_one("#budgets #action-set-usd-budget", Button)
        assert not button.disabled
        await pilot.click(button)
        await pilot.pause()
        assert app.screen.kind == "usd_budget"
        with guarded_publish(app.current_guard()):
            app.screen.query_one("#amount", Input).value = "1.23"
        await pilot.pause()
        await pilot.click("#preview")
        await settle(app, pilot)
        assert app.screen.preview_plan is not None, str(app.screen.query_one("#form-status", Static).render())
        assert app.screen.preview_plan["preview"] is True
        assert backend.writes == []
