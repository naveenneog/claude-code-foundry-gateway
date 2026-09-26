"""Read-only historical test-attribution screens after all governance has been restored."""

import argparse
import asyncio
from datetime import datetime, timezone
import json
from pathlib import Path
import subprocess

from claude_finops.backend import connect
from claude_finops.config import load_config
from claude_finops.engine import Engine
from claude_finops.publication import capture_lock, validate_capture
from claude_finops.tui import FinOpsApp
from textual.widgets import Select

ROOT = Path(__file__).resolve().parents[3]


async def capture(args):
    if not args.team.startswith("aum-e2e-team-"):
        raise RuntimeError("This evidence tool accepts only the test-team identifier.")
    config = load_config(Path(args.config))
    backend = connect(config)
    app = FinOpsApp(Engine(backend), config, redact=True, preview_only=True, first_run=False)
    try:
        async with app.run_test(size=(110, 36)) as pilot:
            await pilot.pause()
            await app.workers.wait_for_complete()
            app.scope_filters = {"department_id": args.team}
            app.dimension = "department"
            app.query_one("#dimension", Select).value = "department"
            if backend.name == "Direct":
                app.usage_basis = "ledger"
            app.action_tab("usage")
            await pilot.pause(.5)
            await app.workers.wait_for_complete()
            for tab in ("usage", "requests"):
                app.action_tab(tab)
                await pilot.pause(.5)
                await app.workers.wait_for_complete()
                await pilot.wait_for_scheduled_animations()
                if not app.data.get(tab, {}).get("items"):
                    raise RuntimeError("No live attribution rows; no image fabricated.")
                app.update_filter_chips()
                await pilot.pause(.2)
                name = f"{config.backend}-e2e-post-cleanup-{tab}-{args.team[-8:]}.svg"
                entry = dict(file=name, source="live", backend=backend.name, captured_at=datetime.now(timezone.utc).isoformat(),
                    redaction=True, commit=subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
                    size=[110, 36], phase="after", tab=tab, flow="post-cleanup-test-attribution")
                issues = validate_capture(app.export_screenshot(), entry)
                if issues:
                    raise RuntimeError("; ".join(issues))
                folder = ROOT / "docs" / "images" / "aum"
                with capture_lock(ROOT / ".aum-evidence"):
                    app.save_screenshot(name, path=str(folder))
                    path = folder / "manifest.json"
                    document = json.loads(path.read_text())
                    document["images"] = [row for row in document["images"] if row["file"] != name] + [entry]
                    path.write_text(json.dumps(document, indent=2) + "\n", encoding="utf-8")
    finally:
        backend.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    parser.add_argument("--team", required=True)
    asyncio.run(capture(parser.parse_args()))
