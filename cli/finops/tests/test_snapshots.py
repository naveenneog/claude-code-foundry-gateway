import json
from pathlib import Path

import pytest
from textual.widgets import TabbedContent

from claude_finops.config import Config
from claude_finops.engine import Engine
from claude_finops.fake import FakeBackend
from claude_finops.tui import FinOpsApp
from claude_finops.views import TABS

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
            svg = Path(__file__).resolve().parents[3] / "docs" / "images" / "finops" / f"{tab}-{size[0]}x{size[1]}.svg"
            assert svg.exists()
            assert "admin@contoso.com" in svg.read_text(encoding="utf-8")
