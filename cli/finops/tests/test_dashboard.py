import pytest
from textual.widgets import Input, Static

from claude_finops.brand import BANNER, COMPACT, PRODUCT
from claude_finops.config import Config
from claude_finops.dashboard import DashboardPanel, budget_totals, enforcement_badge, sparkline
from claude_finops.engine import Engine
from claude_finops.fake import FakeBackend
from claude_finops.tui import FinOpsApp


def test_gauge_never_double_counts_unit_and_team():
    rows = [dict(scope_type="organization", used_tokens=10, token_limit=100),
            dict(scope_type="department", used_tokens=8, token_limit=80)]
    assert budget_totals(rows) == (10, 100, 1)
    assert budget_totals([dict(scope_type="department", used_tokens=8, token_limit=None)]) == (0, 0, 0)


@pytest.mark.parametrize("attributes,expected", [
    ({}, "STRICT"), ({"enforcement": "notify"}, "NOTIFY"),
    ({"enforcement": "allowance", "allowance_percent": 10}, "ALLOW +10%"),
    ({"enforcement": "unexpected"}, "UNKNOWN"),
])
def test_enforcement_badges_do_not_invent_attributes(attributes, expected):
    assert enforcement_badge({"attributes": attributes}) == expected


def test_sparkline_missing_data_is_not_zero():
    assert sparkline([]) == "No data"
    assert sparkline([None, None]) == "Unknown"
    assert sparkline([1, 5, 2], ascii_only=True).isascii()


@pytest.mark.parametrize("size", [(80, 24), (160, 48)])
async def test_dashboard_panels_fit_and_receive_keyboard_focus(size):
    app = FinOpsApp(Engine(FakeBackend(), "2026-09"), Config(backend="fake"))
    async with app.run_test(size=size) as pilot:
        await pilot.pause(.25)
        await app.workers.wait_for_complete()
        await pilot.pause(.25)
        panels = list(app.query(DashboardPanel))
        assert len(panels) == 5
        for panel in panels:
            assert panel.region.width >= 22
            assert panel.region.bottom <= size[1] - 2
            assert panel.region.height >= 4
            assert panel.border_title
        text = str(app.query_one("#brand", Static).render())
        assert (BANNER in text) is (size[0] >= 120)
        assert (PRODUCT if size[0] >= 120 else COMPACT) in text
        panels[0].focus()
        focused = {app.focused.id}
        for _ in range(4):
            await pilot.press("tab")
            focused.add(app.focused.id)
        assert {p.id for p in panels}.issubset(focused)
        await pilot.press("enter")
        await pilot.pause()
        assert len(app.screen_stack) == 2


async def test_slash_filters_current_table_and_lookup_remains_available():
    app = FinOpsApp(Engine(FakeBackend(), "2026-09"), Config(backend="fake"))
    async with app.run_test(size=(80, 24)) as pilot:
        await pilot.pause(.25)
        await app.workers.wait_for_complete()
        await pilot.press("2")
        await pilot.pause(.25)
        await app.workers.wait_for_complete()
        await pilot.press("/")
        app.query_one("#quick-filter", Input).value = "sales-emea"
        await pilot.pause()
        assert len(app.records["budgets"]) == 1
        await pilot.press("escape", "ctrl+f")
        await pilot.pause()
        assert app.screen.query_one("#lookup-query", Input)


async def test_live_style_redaction_applies_to_dashboard_and_identity():
    backend = FakeBackend()
    original = backend.read
    def read(resource, **params):
        result = original(resource, **params)
        if resource == "whoami":
            result.update(name="Private Person", email="private@example.org")
        return result
    backend.read = read
    app = FinOpsApp(Engine(backend, "2026-09"), Config(backend="fake"), redact=True)
    async with app.run_test(size=(80, 24)) as pilot:
        await pilot.pause(.25)
        await app.workers.wait_for_complete()
        svg = app.export_screenshot()
        assert "private@example.org" not in svg
        assert "Private Person" not in svg
        assert not app.editable


async def test_preselected_people_team_does_not_trigger_refresh_loop():
    from textual.widgets import Select
    backend = FakeBackend()
    backend.catalog["departments"].reverse()
    app = FinOpsApp(Engine(backend, "2026-09"), Config(backend="fake"), redact=True)
    async with app.run_test(size=(80, 24)) as pilot:
        await pilot.pause(.25)
        await app.workers.wait_for_complete()
        app.team = "sales-emea"
        await pilot.press("3")
        await pilot.pause(.25)
        await app.workers.wait_for_complete()
        await pilot.pause(.25)
        assert app.query_one("#people-team", Select).value == "sales-emea"
        assert len(app.data["people"]["items"]) == 50
        calls = [(op, params) for op, params in backend.reads if op == "people"]
        assert len(calls) == 1


async def test_redacted_queries_do_not_leak_through_input_or_filter_echo():
    app = FinOpsApp(Engine(FakeBackend(), "2026-09"), Config(backend="fake"), redact=True)
    secret_id = "11111111-2222-3333-4444-555555555555"
    async with app.run_test(size=(80, 24)) as pilot:
        await pilot.pause(.25)
        await app.workers.wait_for_complete()
        app.team = "sales-emea"
        app.open_lookup_result(dict(kind="person", id=secret_id, name="Private Person", tab="people"))
        await pilot.pause(.25)
        await app.workers.wait_for_complete()
        await pilot.pause(.25)
        assert app.query_one("#people-query", Input).value == secret_id
        assert app.query_one("#people-query", Input).password
        assert secret_id not in app.export_screenshot()
        await pilot.press("/")
        app.query_one("#quick-filter", Input).value = "private@example.org"
        await pilot.pause(.25)
        assert "private@example.org" not in app.export_screenshot()
