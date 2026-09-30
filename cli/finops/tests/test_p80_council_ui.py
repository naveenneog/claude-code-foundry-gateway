from contextlib import contextmanager
from pathlib import Path

import pytest
from textual.widgets import Button, DataTable, Input, Static

from claude_finops.config import Config
from claude_finops.errors import FinOpsError
from claude_finops.guarded_publication import guarded_publish
from claude_finops.palette import FinOpsCommands
from test_p80_usability import example, settle


@pytest.mark.parametrize("backend,kind", [("turnstile", "Turnstile"), ("aum-service", "AUM service")])
async def test_settings_address_is_independent_of_cached_table_widths(backend, kind):
    address = "https://turnstile.contoso.com"
    app = example(config=Config(backend=backend, url=address))
    async with app.run_test(size=(80, 24)) as pilot:
        await settle(app, pilot)
        app.action_tab("settings")
        await settle(app, pilot)
        table = app.query_one("#table-settings", DataTable)
        with guarded_publish(app.cached_guard("settings")):
            table.clear(columns=True)
            table.add_column("Setting", width=7)
            table.add_column("Value", width=6)
            table.add_row("connection", app.connection_label())
        await pilot.pause()
        await pilot.pause(0.5)
        rendered = "\n".join(strip.text for strip in app.screen._compositor.render_strips())
        assert f"via {kind}" in rendered
        assert address in rendered
        label = app.query_one("#settings-connection", Static)
        assert address in str(label.render())
        assert label.size.width >= 70


async def test_settings_connection_wraps_long_addresses_within_the_viewport():
    address = "https://" + "gateway-" * 7 + "contoso.example.com"
    app = example(config=Config(backend="turnstile", url=address))
    async with app.run_test(size=(80, 24)) as pilot:
        await settle(app, pilot)
        app.action_tab("settings")
        await settle(app, pilot)
        label = app.query_one("#settings-connection", Static)
        assert address in str(label.render())
        assert label.size.height >= 2
        assert label.region.right <= 80
        region = label.region
        strips = app.screen._compositor.render_strips()
        visible = "".join(strip.text[region.x:region.right].strip() for strip in strips[region.y:region.bottom])
        assert "via Turnstile" in visible
        assert address in visible


async def test_settings_connection_label_rejects_a_stale_settings_origin():
    app = example(config=Config(backend="turnstile", url="https://current.contoso.com"))
    async with app.run_test(size=(80, 24)) as pilot:
        await settle(app, pilot)
        app.action_tab("settings")
        await settle(app, pilot)
        label = app.query_one("#settings-connection", Static)
        with guarded_publish(app.safe_message_guard()):
            label.update("Cleared")

        @contextmanager
        def stale():
            raise FinOpsError("Settings sign-in changed.", 3)
            yield

        data = dict(app.data["settings"], connection="via Turnstile: https://obsolete.contoso.com")
        app._data_guards["settings"] = (data, stale)
        app.render_tab("settings", data)
        await pilot.pause()
        assert "obsolete.contoso.com" not in str(label.render())
        assert "sign-in changed" in str(app.query_one("#note-settings", Static).render())


@pytest.mark.parametrize("tab", ["people", "budgets"])
async def test_aum_service_disables_membership_with_a_visible_explanation(tab):
    app = example(config=Config(backend="aum-service", url="https://aum.contoso.com"))
    async with app.run_test(size=(80, 24)) as pilot:
        await settle(app, pilot)
        app.action_tab(tab)
        await settle(app, pilot)
        button = app.query_one(f"#{tab} #action-add-person", Button)
        assert button.disabled
        assert "AUM service" in str(button.tooltip)
        assert "unavailable" in str(button.tooltip).lower()
        rendered = "\n".join(strip.text for strip in app.screen._compositor.render_strips())
        assert "Add person unavailable on AUM service" in rendered
        assert not app.check_action("add_developer", ())
        app.action_add_developer()
        await pilot.press("g")
        await pilot.pause()
        assert len(app.screen_stack) == 1
        assert "Add developer" not in [name for name, *_ in FinOpsCommands(app.screen).commands()]
        assert not app.engine.backend.writes


async def test_aum_service_empty_people_search_does_not_offer_unavailable_membership():
    app = example(config=Config(backend="aum-service", url="https://aum.contoso.com"))
    async with app.run_test(size=(80, 24)) as pilot:
        await settle(app, pilot)
        app.action_tab("people")
        await settle(app, pilot)
        with guarded_publish(app.current_guard()):
            app.query_one("#people-query", Input).value = "person@contoso.com"
        app.find_people()
        await settle(app, pilot)
        assert "Add person@contoso.com" not in str(app.query_one("#note-people", Static).render())
        await pilot.press("?")
        await pilot.pause()
        assert "membership_availability" in app.screen.data
        assert "AUM service" in app.screen.data["membership_availability"]


def test_guide_states_aum_service_membership_is_unavailable():
    root = Path(__file__).resolve().parents[3]
    text = (root / "docs" / "AUM.md").read_text(encoding="utf-8")
    row = next(line for line in text.splitlines() if line.startswith("| AUM service |"))
    membership = row.split("|")[4].strip()
    assert "Unavailable" in membership
    assert "authorize" not in membership
    assert "developer_actions.py" in text
