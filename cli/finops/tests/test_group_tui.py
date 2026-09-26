from textual.widgets import Button, DataTable, Input
from claude_finops.config import Config
from claude_finops.engine import Engine
from claude_finops.fake import FakeBackend
from claude_finops.tui import FinOpsApp


class FakeGraph:
    def search(self, query, **kwargs):
        return dict(items=[dict(id="00000000-0000-0000-0000-000000000001", displayName="contoso-sales",
                               securityEnabled=True, mailEnabled=False, groupTypes=[])], next_cursor=None)
    def close(self):
        pass


async def test_add_scope_discovers_group_before_catalog_form():
    engine = Engine(FakeBackend(), "2026-09")
    engine.group_factory = FakeGraph
    app = FinOpsApp(engine, Config(backend="fake"))
    async with app.run_test(size=(80, 24)) as pilot:
        await pilot.pause()
        await app.workers.wait_for_complete()
        app.action_add()
        await pilot.pause()
        app.screen.query_one("#group-search", Input).value = "contoso"
        await pilot.press("enter")
        await pilot.pause()
        await app.workers.wait_for_complete()
        assert app.screen.query_one("#group-results", DataTable).row_count == 1
        await pilot.press("enter")
        await pilot.pause()
        assert app.screen.query_one("#scope-group", Input).value == "00000000-0000-0000-0000-000000000001"
        assert not engine.backend.writes


async def test_group_creation_form_previews_owner_implications_before_apply():
    writes = []
    class Groups(FakeGraph):
        def create(self, name, description, *, apply=False, confirm=None):
            if apply:
                assert confirm == name
                writes.append(name)
            return dict(preview=not apply, action="Create group", name=name, owner_id="contoso-admin",
                        effect="Owner manages membership; gateway requires refresh", owner_verified=apply)
    engine = Engine(FakeBackend(), "2026-09")
    engine.group_factory = Groups
    app = FinOpsApp(engine, Config(backend="fake"))
    async with app.run_test(size=(100, 32)) as pilot:
        await pilot.pause()
        await app.workers.wait_for_complete()
        app.action_add()
        await pilot.pause()
        await pilot.click("#group-create")
        await pilot.pause()
        app.screen.query_one("#field-name", Input).value = "aum-e2e-unit-example"
        app.screen.query_one("#field-confirm", Input).value = "aum-e2e-unit-example"
        await pilot.click("#action-preview")
        await pilot.pause()
        await app.workers.wait_for_complete()
        assert not writes and not app.screen.query_one("#action-apply", Button).disabled
        await pilot.click("#action-apply")
        await pilot.pause()
        await app.workers.wait_for_complete()
        assert writes == ["aum-e2e-unit-example"]


async def test_group_discovery_is_not_blocked_by_separate_gateway_write_authority():
    engine = Engine(FakeBackend(), "2026-09")
    engine.group_factory = FakeGraph
    app = FinOpsApp(engine, Config(backend="fake"))
    async with app.run_test(size=(80, 24)) as pilot:
        await pilot.pause()
        await app.workers.wait_for_complete()
        app.editable = False
        app.action_group_lookup()
        await pilot.pause()
        assert app.screen.query_one("#group-search", Input)


async def test_viewer_palette_hides_group_creation_and_billable_probe():
    from claude_finops.palette import FinOpsCommands
    app = FinOpsApp(Engine(FakeBackend(role="member"), "2026-09"), Config(backend="fake"))
    async with app.run_test(size=(80, 24)) as pilot:
        await pilot.pause()
        await app.workers.wait_for_complete()
        commands = [name for name, *_ in FinOpsCommands(app.screen).commands()]
        assert "Find or create Entra security group" not in commands
        assert "Probe gateway budget enforcement" not in commands
