"""Record deterministic terminal grids and SVG guides. Uses example data only."""

import asyncio
import json
import hashlib
from datetime import datetime, timezone
from pathlib import Path

from textual.widgets import TabbedContent

from claude_finops.config import Config
from claude_finops.engine import Engine
from claude_finops.fake import FakeBackend
from claude_finops.tui import FinOpsApp
from claude_finops.views import TABS
from claude_finops.ui_features import EXTRA_TABS

ROOT = Path(__file__).resolve().parents[3]


async def capture():
    snapshots = ROOT / "cli" / "finops" / "tests" / "snapshots"
    images = snapshots / "svg"
    images.mkdir(parents=True, exist_ok=True)
    snapshots.mkdir(exist_ok=True)
    written = []
    for optional in (False, True):
        tabs = EXTRA_TABS if optional else TABS
        features = dict(assistant=True, approvals=True, advanced=True) if optional else {}
        for size in ((80, 24), (160, 48)):
            grids = {}
            app = FinOpsApp(Engine(FakeBackend(features=features), "2026-09"), Config(backend="fake"))
            async with app.run_test(size=size) as pilot:
                await pilot.pause()
                await app.workers.wait_for_complete()
                await pilot.wait_for_scheduled_animations()
                for tab, _ in tabs:
                    app.query_one(TabbedContent).active = tab
                    await pilot.pause()
                    await app.workers.wait_for_complete()
                    await pilot.wait_for_scheduled_animations()
                    await pilot.pause(0.25)
                    grids[tab] = [strip.text for strip in app.screen._compositor.render_strips()]
                    name = f"{tab}-{size[0]}x{size[1]}.svg"
                    app.save_screenshot(name, path=str(images))
                    written.append(images / name)
            prefix = "optional-" if optional else ""
            grid = snapshots / f"{prefix}{size[0]}x{size[1]}.json"
            grid.write_text(json.dumps(grids, ensure_ascii=True), encoding="utf-8")
            written.append(grid)
    source_root = ROOT / "cli" / "finops" / "src" / "claude_finops"
    sources = [Path(__file__).resolve(), *sorted(path for path in source_root.iterdir()
                                               if path.suffix in {".py", ".json", ".tcss"})]

    def hashes(paths):
        return {path.relative_to(ROOT).as_posix(): hashlib.sha256(path.read_text(encoding="utf-8").encode("utf-8")).hexdigest()
                for path in sorted(paths)}

    manifest = dict(version=1, backend="Example", live=False, hash_format="utf8-lf-sha256",
                    captured_at_utc=datetime.now(timezone.utc).isoformat(),
                    sizes=[[80, 24], [160, 48]], sources=hashes(sources), outputs=hashes(written))
    (snapshots / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print("Recorded 24 FakeBackend SVGs and 24 terminal-grid snapshots, including conditional tabs.")


if __name__ == "__main__":
    asyncio.run(capture())
