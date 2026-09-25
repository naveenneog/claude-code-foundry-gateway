import json
from pathlib import Path

import pytest
from textual.widgets import TabbedContent

from claude_finops.config import Config
from claude_finops.engine import Engine
from claude_finops.fake import FakeBackend
from claude_finops.tui import FinOpsApp
from claude_finops.views import TABS
from claude_finops.ui_features import EXTRA_TABS

BASE = Path(__file__).parent / "snapshots"


@pytest.mark.parametrize("size", [(80, 24), (160, 48)])
async def test_all_main_screen_snapshots(size):
    baseline = json.loads((BASE / f"{size[0]}x{size[1]}.json").read_text(encoding="utf-8"))
    app = FinOpsApp(Engine(FakeBackend(), "2026-09"), Config(backend="fake"))
    async with app.run_test(size=size) as pilot:
        await pilot.pause()
        await app.workers.wait_for_complete()
        for tab, _ in TABS:
            app.query_one(TabbedContent).active = tab
            await pilot.pause()
            await app.workers.wait_for_complete()
            await pilot.pause(0.25)
            rendered = [strip.text for strip in app.screen._compositor.render_strips()]
            assert rendered == baseline[tab], f"{tab} changed at {size}; inspect SVG before recording."
            svg = BASE / "svg" / f"{tab}-{size[0]}x{size[1]}.svg"
            assert svg.exists()
            assert "admin@contoso.com" in svg.read_text(encoding="utf-8")


@pytest.mark.parametrize("size", [(80, 24), (160, 48)])
async def test_optional_capability_screen_snapshots(size):
    baseline = json.loads((BASE / f"optional-{size[0]}x{size[1]}.json").read_text(encoding="utf-8"))
    backend = FakeBackend(features={"assistant": True, "approvals": True, "advanced": True})
    app = FinOpsApp(Engine(backend, "2026-09"), Config(backend="fake"))
    async with app.run_test(size=size) as pilot:
        await pilot.pause()
        await app.workers.wait_for_complete()
        for tab, _ in EXTRA_TABS:
            app.query_one(TabbedContent).active = tab
            await pilot.pause()
            await app.workers.wait_for_complete()
            await pilot.pause(.25)
            rendered = [strip.text for strip in app.screen._compositor.render_strips()]
            assert rendered == baseline[tab], f"{tab} changed at {size}; inspect the SVG before updating."
            assert all(len(line) <= size[0] for line in rendered)
            assert (BASE / "svg" / f"{tab}-{size[0]}x{size[1]}.svg").exists()
