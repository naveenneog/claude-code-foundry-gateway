from contextlib import contextmanager

import pytest
from rich.cells import cell_len
from textual.widgets import Button, DataTable, Static, TabPane

from claude_finops.errors import FinOpsError
from claude_finops.palette import FinOpsCommands
from p85_fixtures import (
    EMAIL, GROUPS, USER, fill, management_app, membership_writes, select_developer, settle,
)


@pytest.mark.parametrize("kind", ["direct", "turnstile"])
async def test_remove_person_preview_confirm_apply_and_refresh(monkeypatch, tmp_path, kind):
    app, state = management_app(monkeypatch, tmp_path, kind)
    async with app.run_test(size=(100, 36)) as pilot:
        await settle(app, pilot)
        await pilot.press("3")
        await settle(app, pilot)
        assert app.records["people"][0]["scope_id"] == USER
        await pilot.click("#people #action-remove-person")
        await select_developer(app, pilot)
        await pilot.click("#action-preview")
        await settle(app, pilot)
        preview = str(app.screen.query_one("#action-status", Static).render())
        for group in GROUPS.values():
            assert group in preview
        assert EMAIL in preview
        assert "allow-standard" in preview and "allow-premium" in preview
        assert "not just" in preview.lower()
        assert not state.directory.writes and not state.calls
        await fill(app, pilot, "#field-confirm", EMAIL)
        await pilot.pause(app.screen.query_one("#action-preview", Button).active_effect_duration)
        await pilot.click("#action-preview")
        await settle(app, pilot)
        assert not app.screen.query_one("#action-apply", Button).disabled
        await pilot.click("#action-apply")
        await settle(app, pilot)
        assert state.directory.writes == membership_writes(state, remove=True), str(
            app.screen.query_one("#action-status", Static).render())
        assert len(state.calls) == 1
        if kind == "direct":
            assert state.calls == [("developer_publish", None, {
                "standard_group": "contoso-standard", "premium_group": "contoso-premium",
                "user": USER,
                "allow_empty_standard": True,
            })]
        else:
            assert state.calls == [("delegated_publish", None, {})]
        assert EMAIL in str(app.screen.query_one("#action-status", Static).render())
        reads = state.people_reads
        # The People endpoint is observed usage, not the directory roster.
        state.observe_person(False)
        await pilot.click("#action-cancel")
        await settle(app, pilot)
        assert len(app.screen_stack) == 1
        assert state.people_reads > reads
        assert app.data["people"]["items"] == []
        assert app.records["people"] == [{}]
        assert "No results" in str(app.query_one("#table-people", DataTable).get_row_at(0)[0])


@pytest.mark.parametrize("kind", ["direct", "turnstile"])
@pytest.mark.parametrize("confirmation", ["", "someone-else@contoso.com"])
async def test_remove_person_wrong_confirmation_is_refused(monkeypatch, tmp_path, kind, confirmation):
    app, state = management_app(monkeypatch, tmp_path, kind)
    async with app.run_test(size=(100, 36)) as pilot:
        await settle(app, pilot)
        await pilot.press("3")
        await settle(app, pilot)
        await pilot.press("h")
        await select_developer(app, pilot)
        await fill(app, pilot, "#field-confirm", confirmation)
        await pilot.click("#action-preview")
        await settle(app, pilot)
        await pilot.click("#action-apply")
        await settle(app, pilot)
        assert "Type the resolved UPN" in str(app.screen.query_one("#action-status", Static).render())
        assert not state.directory.writes and not state.calls
        assert app.records["people"][0]["scope_id"] == USER


@pytest.mark.parametrize("role", ["member", "viewer"])
async def test_remove_person_owner_guard_covers_button_key_palette_and_direct_entry(monkeypatch, tmp_path, role):
    app, state = management_app(monkeypatch, tmp_path, "turnstile", role=role)
    async with app.run_test(size=(100, 36)) as pilot:
        await settle(app, pilot)
        await pilot.press("3")
        await settle(app, pilot)
        button = app.query_one("#people #action-remove-person", Button)
        assert button.disabled
        assert "Only owners" in str(button.tooltip)
        assert not app.check_action("remove_developer", ())
        assert "Remove person from team" not in [name for name, *_ in FinOpsCommands(app.screen).commands()]
        await pilot.press("h")
        app.action_remove_developer()
        await pilot.pause()
        assert len(app.screen_stack) == 1
        assert not state.directory.writes and not state.calls


async def test_remove_person_service_refusal_uses_existing_explanation(monkeypatch, tmp_path):
    from test_aum_service_backend import service
    from claude_finops.engine import Engine
    from claude_finops.tui import FinOpsApp

    backend, calls = service()
    app = FinOpsApp(Engine(backend), backend.config, first_run=False)
    async with app.run_test(size=(100, 36)) as pilot:
        await settle(app, pilot)
        await pilot.press("3")
        await settle(app, pilot)
        button = app.query_one("#people #action-remove-person", Button)
        assert button.disabled
        assert str(button.tooltip) == app.membership_unavailable_text()
        assert app.membership_unavailable_text() in str(app.query_one("#note-people", Static).render())
        assert not app.check_action("remove_developer", ())
        assert "Remove person from team" not in [name for name, *_ in FinOpsCommands(app.screen).commands()]
        await pilot.press("h")
        app.action_remove_developer()
        await pilot.pause()
        assert len(app.screen_stack) == 1
        assert all(call.method == "GET" for call in calls)


async def test_remove_person_retains_directory_guard(monkeypatch, tmp_path):
    app, state = management_app(monkeypatch, tmp_path)
    async with app.run_test(size=(100, 36)) as pilot:
        await settle(app, pilot)
        await pilot.press("h")
        await pilot.pause()
        await fill(app, pilot, "#developer-search", EMAIL)
        await pilot.press("enter")
        await settle(app, pilot)
        picker = app.screen

        @contextmanager
        def stale():
            raise FinOpsError("Directory sign-in changed. Search again.", 3)
            yield

        picker.read_guard = stale
        await pilot.press("enter")
        await settle(app, pilot)
        assert app.screen is picker
        assert "sign-in changed" in str(picker.query_one("#developer-status", Static).render())
        assert not state.directory.writes and not state.calls


@pytest.mark.parametrize("size", [(80, 24), (100, 36)])
async def test_remove_person_action_bar_key_help_and_palette(monkeypatch, tmp_path, size):
    app, state = management_app(monkeypatch, tmp_path)
    async with app.run_test(size=size) as pilot:
        await settle(app, pilot)
        await pilot.press("3")
        await settle(app, pilot)
        pane = app.query_one("#people", TabPane)
        buttons = list(pane.query(Button))
        labels = [str(button.label) for button in buttons]
        assert labels.index("Remove person from team") == labels.index("Add person to team") + 1
        for button in buttons:
            assert button.content_size.width >= cell_len(str(button.label))
            assert button.region.right <= pane.region.right
        assert "h Remove person from team" in str(app.query_one("#key-hints", Static).render())
        assert app.query_one("#key-hints", Static).size.height <= 2
        assert app.query_one("#table-people", DataTable).content_size.height >= 1
        commands = dict((name, callback) for name, callback, _ in FinOpsCommands(app.screen).commands())
        commands["Remove person from team"]()
        await pilot.pause()
        assert app.screen.query("#developer-search")
        await pilot.press("escape", "?")
        await pilot.pause()
        assert "h Remove person from team" in str(app.screen.data)
        assert not state.directory.writes and not state.calls


@pytest.mark.parametrize("kind", ["direct", "turnstile"])
async def test_add_person_preview_apply_and_refresh(monkeypatch, tmp_path, kind):
    app, state = management_app(monkeypatch, tmp_path, kind, member=False)
    async with app.run_test(size=(100, 36)) as pilot:
        await settle(app, pilot)
        await pilot.press("3")
        await settle(app, pilot)
        assert app.data["people"]["items"] == []
        await pilot.click("#people #action-add-person")
        await select_developer(app, pilot)
        await pilot.click("#action-preview")
        await settle(app, pilot)
        assert app.screen.preview["developer"]["user_principal_name"] == EMAIL
        assert [change["present"] for change in app.screen.preview["changes"]] == [True, False, True]
        assert not state.directory.writes and not state.calls
        await pilot.click("#action-apply")
        await settle(app, pilot)
        assert state.directory.writes == membership_writes(state, remove=False)
        expected = ("developer_publish", None, {
            "standard_group": "contoso-standard", "premium_group": "contoso-premium", "user": USER,
        }) if kind == "direct" else ("delegated_publish", None, {})
        assert state.calls == [expected]
        reads = state.people_reads
        state.observe_person(True)
        await pilot.click("#action-cancel")
        await settle(app, pilot)
        assert len(app.screen_stack) == 1
        assert state.people_reads > reads
        assert app.records["people"][0]["scope_id"] == USER
        assert app.query_one("#table-people", DataTable).row_count == 1


async def test_remove_person_stale_form_cannot_preview_or_apply(monkeypatch, tmp_path):
    app, state = management_app(monkeypatch, tmp_path)
    async with app.run_test(size=(100, 36)) as pilot:
        await settle(app, pilot)
        await pilot.press("h")
        await pilot.pause()
        await fill(app, pilot, "#developer-search", EMAIL)
        await pilot.press("enter")
        await settle(app, pilot)
        origin = {"current": True}

        @contextmanager
        def stale():
            if not origin["current"]:
                raise FinOpsError("Directory sign-in changed. Search again.", 3)
            yield

        app.screen.read_guard = stale
        await pilot.press("enter")
        await settle(app, pilot)
        await fill(app, pilot, "#field-confirm", EMAIL)
        await pilot.click("#action-preview")
        await settle(app, pilot)
        origin["current"] = False
        await pilot.click("#action-apply")
        await settle(app, pilot)
        assert "sign-in changed" in str(app.screen.query_one("#action-status", Static).render())
        await pilot.pause(app.screen.query_one("#action-preview", Button).active_effect_duration)
        await pilot.click("#action-preview")
        await settle(app, pilot)
        assert "sign-in changed" in str(app.screen.query_one("#action-status", Static).render())
        assert not state.directory.writes and not state.calls


async def test_remove_person_preview_only_cannot_write(monkeypatch, tmp_path):
    app, state = management_app(monkeypatch, tmp_path, preview_only=True)
    async with app.run_test(size=(100, 36)) as pilot:
        await settle(app, pilot)
        await pilot.press("h")
        await select_developer(app, pilot)
        await fill(app, pilot, "#field-confirm", EMAIL)
        await pilot.click("#action-preview")
        await settle(app, pilot)
        assert app.screen.query_one("#action-apply", Button).disabled
        app.screen.apply_action()
        await settle(app, pilot)
        assert not state.directory.writes and not state.calls


async def test_remove_person_redaction_cannot_open_writer(monkeypatch, tmp_path):
    app, state = management_app(monkeypatch, tmp_path, redact=True)
    async with app.run_test(size=(100, 36)) as pilot:
        await settle(app, pilot)
        await pilot.press("3")
        await settle(app, pilot)
        assert app.query_one("#people #action-remove-person", Button).disabled
        assert not app.check_action("remove_developer", ())
        app.action_remove_developer()
        await pilot.press("h")
        await pilot.pause()
        assert len(app.screen_stack) == 1
        assert not state.directory.writes and not state.calls
