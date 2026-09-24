from copy import deepcopy

import pytest
from textual.widgets import DataTable, TabbedContent

from claude_finops.config import Config
from claude_finops.engine import Engine
from claude_finops.errors import FinOpsError, http_error
from claude_finops.fake import FakeBackend
from claude_finops.rules import can_edit
from claude_finops.tui import FinOpsApp

TEAM_SCOPE = dict(organizations=[], departments=[
    dict(id="sales-emea", name="Sales EMEA", parent_id="sales")], writable_department_ids=[])
EMPTY_SCOPE = dict(organizations=[], departments=[], writable_department_ids=[])


class ScopedBackend(FakeBackend):
    def __init__(self, scope=TEAM_SCOPE):
        super().__init__(role="member")
        self.scope = deepcopy(scope)

    def read(self, resource, **params):
        result = super().read(resource, **params)
        if resource == "whoami":
            result["manager_scope"] = deepcopy(self.scope)
        elif self.scope is not None:
            if resource == "catalog":
                result["organizations"] = result["organizations"][:1]
                result["departments"] = result["departments"][:1] if self.scope["departments"] else []
            elif resource == "budgets":
                result["items"] = [r for r in result["items"] if r["scope_id"] == "sales-emea"]
            elif params.get("organization_id"):
                raise http_error(403)
        return result


def test_empty_scope_is_not_an_unrestricted_viewer():
    from claude_finops.scope import visible_tabs
    assert visible_tabs({"role": "member", "manager_scope": EMPTY_SCOPE}) == {"governance", "settings"}
    assert "overview" in visible_tabs({"role": "member", "manager_scope": None})
    assert "overview" in visible_tabs({"role": "member"})


def test_malformed_scope_fails_closed():
    from claude_finops.scope import visible_tabs
    assert visible_tabs({"role": "member", "manager_scope": "invalid"}) == {"settings"}


def test_scoped_identity_never_enables_edits():
    assert not can_edit({"role": "owner", "manager_scope": TEAM_SCOPE})
    assert not can_edit({"role": "member", "manager_scope": dict(TEAM_SCOPE, writable_department_ids=["sales-emea"])})


def test_team_manager_cannot_query_context_parent():
    backend = ScopedBackend()
    engine = Engine(backend, "2026-09")
    with pytest.raises(FinOpsError, match="Not in your scope"):
        engine.read("overview", organization_id="sales")
    assert not any(op == "overview" for op, _ in backend.reads)
    engine.read("overview")
    assert backend.reads[-1] == ("overview", {"month": "2026-09"})


def test_team_manager_report_uses_authorized_teams_not_context_units():
    backend = ScopedBackend()
    report = Engine(backend, "2026-09").chargeback()
    assert report["dimension"] == "department"
    assert len(report["items"]) == 1
    assert report["items"][0]["id"] == "sales-emea"
    assert "managed teams" in report["note"]
    assert not any(params.get("organization_id") for _, params in backend.reads)


def test_context_units_are_not_lookup_budget_targets():
    result = Engine(ScopedBackend(), "2026-09").lookup("sales")
    assert not any(row["kind"] == "unit" for row in result)
    assert any(row["kind"] == "team" for row in result)


def test_403_is_scope_denial_401_is_sign_in():
    assert "Not in your scope" in str(http_error(403))
    assert http_error(403).code == 4
    assert "Sign-in expired" in str(http_error(401))
    assert http_error(401).code == 3


def test_owner_manager_group_uses_deployed_attribute():
    backend = FakeBackend()
    group_id = "00000000-0000-0000-0000-000000000001"
    Engine(backend, "2026-09").catalog_change("team", "sales-emea", manager_group=group_id, apply=True)
    row = next(row for row in backend.catalog["departments"] if row["id"] == "sales-emea")
    assert row["attributes"]["manager_group_id"] == group_id
    with pytest.raises(FinOpsError, match="object id"):
        Engine(backend, "2026-09").catalog_change("team", "sales-emea", manager_group="contoso-manager")


def test_future_unlisted_manager_read_is_refused():
    backend = ScopedBackend()
    with pytest.raises(FinOpsError, match="organization-wide"):
        Engine(backend, "2026-09").read("assistant")
    assert all(op != "assistant" for op, _ in backend.reads)


async def settle(app, pilot):
    await pilot.pause(.25)
    await app.workers.wait_for_complete()
    await pilot.pause(.25)


async def test_team_manager_opens_scoped_overview_without_parent_filter():
    backend = ScopedBackend()
    app = FinOpsApp(Engine(backend, "2026-09"), Config(backend="fake"))
    async with app.run_test(size=(80, 24)) as pilot:
        await settle(app, pilot)
        assert "overview" in app.data
        assert not any(params.get("organization_id") for _, params in backend.reads)
        assert "sales-emea" in str(app.query_one("#identity").render())
        assert not app.editable


async def test_empty_scope_hides_tabs_keys_and_palette_targets():
    backend = ScopedBackend(EMPTY_SCOPE)
    app = FinOpsApp(Engine(backend, "2026-09"), Config(backend="fake"))
    async with app.run_test(size=(80, 24)) as pilot:
        await settle(app, pilot)
        assert app.active == "settings"
        tabs = app.query_one(TabbedContent)
        assert not tabs.get_tab("overview").display
        assert not tabs.get_tab("people").display
        assert app.check_action("tab", ("overview",)) is False
        await pilot.press("1", "3")
        assert app.active == "settings"
        assert not any(op in {"overview", "people", "budgets"} for op, _ in backend.reads)
        from claude_finops.palette import FinOpsCommands
        palette = FinOpsCommands(app.screen)
        names = [name for name, _, _ in palette.commands()]
        assert "Open Overview" not in names
        assert "Open Settings" in names
        assert "Export complete chargeback CSV" not in names


async def test_scope_denied_view_discards_stale_table_and_explains_fix():
    class DeniedBackend(ScopedBackend):
        denied = False

        def read(self, resource, **params):
            if self.denied and resource == "overview":
                raise http_error(403)
            return super().read(resource, **params)

    backend = DeniedBackend()
    app = FinOpsApp(Engine(backend, "2026-09"), Config(backend="fake"))
    async with app.run_test(size=(80, 24)) as pilot:
        await settle(app, pilot)
        backend.denied = True
        app.action_refresh()
        await settle(app, pilot)
        assert app.query_one("#table-overview", DataTable).row_count == 0
        assert "overview" not in app.data
        assert "Not in your scope" in str(app.query_one("#note-overview").render())


async def test_scope_refresh_removes_previously_loaded_data():
    backend = ScopedBackend()
    app = FinOpsApp(Engine(backend, "2026-09"), Config(backend="fake"))
    async with app.run_test(size=(80, 24)) as pilot:
        await settle(app, pilot)
        assert app.query_one("#table-overview", DataTable).row_count
        backend.scope = EMPTY_SCOPE
        app.action_refresh()
        await settle(app, pilot)
        assert app.active == "settings"
        assert "overview" not in app.data
        assert app.query_one("#table-overview", DataTable).row_count == 0


async def test_unchanged_identity_does_not_rebuild_navigation():
    from unittest.mock import patch
    app = FinOpsApp(Engine(ScopedBackend(), "2026-09"), Config(backend="fake"))
    async with app.run_test(size=(80, 24)) as pilot:
        await settle(app, pilot)
        tabs = app.query_one(TabbedContent)
        with patch.object(tabs, "show_tab", wraps=tabs.show_tab) as show:
            app.update_access(deepcopy(app.identity))
            assert not show.called
