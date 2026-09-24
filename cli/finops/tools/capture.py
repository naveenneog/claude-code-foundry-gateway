"""Record deterministic terminal grids and SVG guides. Uses example data only."""

import asyncio
import json
from pathlib import Path

from textual.widgets import TabbedContent

from claude_finops.config import Config
from claude_finops.engine import Engine
from claude_finops.fake import FakeBackend
from claude_finops.tui import FinOpsApp
from claude_finops.views import TABS

ROOT = Path(__file__).resolve().parents[3]


async def capture():
    snapshots = ROOT / "cli" / "finops" / "tests" / "snapshots"
    images = snapshots / "svg"
    images.mkdir(parents=True, exist_ok=True)
    snapshots.mkdir(exist_ok=True)
    for size in ((80, 24), (160, 48)):
        grids = {}
        app = FinOpsApp(Engine(FakeBackend(), "2026-09"), Config(backend="fake"))
        async with app.run_test(size=size) as pilot:
            await pilot.pause()
            await app.workers.wait_for_complete()
            for tab, _ in TABS:
                app.query_one(TabbedContent).active = tab
                await pilot.pause()
                await app.workers.wait_for_complete()
                await pilot.pause(0.25)
                grids[tab] = [strip.text for strip in app.screen._compositor.render_strips()]
                app.save_screenshot(f"{tab}-{size[0]}x{size[1]}.svg", path=str(images))
        (snapshots / f"{size[0]}x{size[1]}.json").write_text(json.dumps(grids, ensure_ascii=True), encoding="utf-8")
    print("Recorded 18 FakeBackend SVGs and 18 terminal-grid snapshots.")


if __name__ == "__main__":
    asyncio.run(capture())
