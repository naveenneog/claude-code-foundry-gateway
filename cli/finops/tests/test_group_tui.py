from textual.widgets import DataTable, Input
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
