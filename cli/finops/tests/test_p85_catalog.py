from copy import deepcopy
import json

import pytest
from textual.widgets import Button, Input, Select, Static

from claude_finops.guarded_publication import guarded_publish
from claude_finops.palette import FinOpsCommands
from p85_fixtures import GROUPS, PICKED_GROUP, USER, choose_record, fill, management_app, settle


def command(app, title):
    next(callback for name, callback, _ in FinOpsCommands(app.screen).commands() if name == title)()


def assert_catalog_write(state, kind, expected):
    if kind == "direct":
        assert state.calls == [("catalog", expected, {})]
    else:
        assert state.fake.writes == [("catalog", {}, expected)]
        writes = [call for call in state.http_calls if call.method != "GET"]
        assert len(writes) == 1
        assert writes[0].method == "PUT"
        assert writes[0].url.path == "/api/v1/enterprise-catalog"
        assert json.loads(writes[0].content) == expected
        assert not state.calls
    assert state.directory.writes == []


@pytest.mark.parametrize("kind", ["direct", "turnstile"])
@pytest.mark.parametrize("scope", ["unit", "team"])
async def test_create_scope_picker_catalog_preview_apply(monkeypatch, tmp_path, kind, scope):
    app, state = management_app(monkeypatch, tmp_path, kind)
    key = f"p85-{scope}"
    before = deepcopy(state.fake.catalog)
    async with app.run_test(size=(100, 36)) as pilot:
        await settle(app, pilot)
        await pilot.press("4")
        await settle(app, pilot)
        command(app, "Add unit or team")
        await pilot.pause()
        await fill(app, pilot, "#group-search", "contoso")
        app.screen.query_one("#group-search", Input).focus()
        await pilot.press("enter")
        await settle(app, pilot)
        await pilot.press("enter")
        await settle(app, pilot)
        assert app.screen.kind == "catalog"
        assert app.screen.query_one("#scope-group", Input).value == PICKED_GROUP
        with guarded_publish(app.current_guard()):
            app.screen.query_one("#scope-kind", Select).value = scope
        await fill(app, pilot, "#scope-id", key)
        await fill(app, pilot, "#scope-name", "P85 scope")
        if scope == "team":
            await fill(app, pilot, "#scope-parent", "sales")
        await pilot.click("#preview")
        await settle(app, pilot)
        plan = app.screen.preview_plan
        assert plan["before"] == before
        expected = {field: deepcopy(before[field])
                    for field in ("organizations", "departments", "default_department_id")}
        row = dict(id=key, name="P85 scope", external_ref=f"entra-group:{PICKED_GROUP}",
                   attributes={"source": "claude-gateway"})
        if scope == "team":
            row.update(parent_id="sales")
            row["attributes"]["kind"] = "team"
        expected["organizations" if scope == "unit" else "departments"].append(row)
        assert plan["after"] == expected
        assert not state.calls and not state.fake.writes and not state.directory.writes
        await pilot.click("#apply-change")
        await settle(app, pilot)
        assert app.screen.saved
        assert_catalog_write(state, kind, expected)
        await pilot.click("#cancel-change")
        await settle(app, pilot)
        assert any(row.get("id") == key and row["kind"] == scope for row in app.records["governance"])


@pytest.mark.parametrize("kind", ["direct", "turnstile"])
@pytest.mark.parametrize("scope,key", [("unit", "engineering"), ("team", "sales-apac")])
async def test_remove_scope_with_members_confirms_catalog_only(monkeypatch, tmp_path, kind, scope, key):
    app, state = management_app(monkeypatch, tmp_path, kind)
    group = GROUPS[f"contoso-{key}"]
    state.directory.direct.add(group)
    state.directory.group_members[group] = {USER}
    before = deepcopy(state.fake.catalog)
    async with app.run_test(size=(100, 36)) as pilot:
        await settle(app, pilot)
        await choose_record(app, pilot, "governance", key)
        command(app, "Remove selected budget or scope")
        await pilot.pause()
        assert app.screen.removing and app.screen.kind == "catalog"
        await fill(app, pilot, "#confirm", key)
        await pilot.click("#preview")
        await settle(app, pilot)
        expected = {field: deepcopy(before[field])
                    for field in ("organizations", "departments", "default_department_id")}
        collection = "organizations" if scope == "unit" else "departments"
        expected[collection] = [row for row in expected[collection] if row["id"] != key]
        assert app.screen.preview_plan["before"] == before
        assert app.screen.preview_plan["after"] == expected
        assert not state.calls and not state.fake.writes and not state.directory.writes
        await pilot.click("#apply-change")
        await settle(app, pilot)
        assert app.screen.saved
        assert_catalog_write(state, kind, expected)
        assert state.directory.group_members[group] == {USER}
        await pilot.click("#cancel-change")
        await settle(app, pilot)
        assert all(row.get("id") != key for row in app.records["governance"])


@pytest.mark.parametrize("kind", ["direct", "turnstile"])
@pytest.mark.parametrize("key", ["engineering", "sales-apac"])
async def test_remove_scope_wrong_confirmation_cannot_write(monkeypatch, tmp_path, kind, key):
    app, state = management_app(monkeypatch, tmp_path, kind)
    before = deepcopy(state.fake.catalog)
    async with app.run_test(size=(100, 36)) as pilot:
        await settle(app, pilot)
        await choose_record(app, pilot, "governance", key)
        command(app, "Remove selected budget or scope")
        await pilot.pause()
        await fill(app, pilot, "#confirm", "wrong-scope")
        await pilot.click("#preview")
        await settle(app, pilot)
        assert app.screen.preview_plan is not None
        await pilot.click("#apply-change")
        await settle(app, pilot)
        assert "Removal requires confirmation" in str(app.screen.query_one("#form-status", Static).render())
        assert not app.screen.saved
        assert not state.calls and not state.fake.writes and not state.directory.writes
        assert state.fake.catalog == before


@pytest.mark.parametrize("kind", ["direct", "turnstile"])
@pytest.mark.parametrize("rule,key,message", [
    ("children", "sales", "Move or remove this unit's teams first"),
    ("default", "sales-emea", "This is the default department"),
    ("last-unit", "engineering", "Keep at least one business unit"),
])
async def test_catalog_removal_rules_refuse_before_apply(monkeypatch, tmp_path, kind, rule, key, message):
    app, state = management_app(monkeypatch, tmp_path, kind)
    if rule == "last-unit":
        state.fake.catalog["organizations"] = [
            row for row in state.fake.catalog["organizations"] if row["id"] == key]
        state.fake.catalog["departments"] = []
        state.fake.catalog["default_department_id"] = None
    before = deepcopy(state.fake.catalog)
    async with app.run_test(size=(100, 36)) as pilot:
        await settle(app, pilot)
        await choose_record(app, pilot, "governance", key)
        command(app, "Remove selected budget or scope")
        await pilot.pause()
        await fill(app, pilot, "#confirm", key)
        await pilot.click("#preview")
        await settle(app, pilot)
        assert message in str(app.screen.query_one("#form-status", Static).render())
        assert app.screen.query_one("#apply-change", Button).disabled
        assert not state.calls and not state.fake.writes and not state.directory.writes
        assert state.fake.catalog == before
