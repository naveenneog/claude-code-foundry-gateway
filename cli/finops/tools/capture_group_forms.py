"""Live group/scope form previews. No directory or gateway mutation is performed."""

import argparse
import asyncio
import json
from datetime import datetime, timezone
from pathlib import Path
import subprocess

from textual.widgets import DataTable, Input

from claude_finops.backend import connect
from claude_finops.config import load_config
from claude_finops.engine import Engine
from claude_finops.group_screens import GroupPicker
from claude_finops.publication import capture_lock, validate_capture
from claude_finops.tui import FinOpsApp

ROOT = Path(__file__).resolve().parents[3]


async def capture(args):
    config = load_config(Path(args.config))
    backend = connect(config)
    app = FinOpsApp(Engine(backend), config, redact=True, preview_only=True, first_run=False)
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    async def settle(pilot):
        await pilot.pause(.2)
        await app.workers.wait_for_complete()
        await pilot.wait_for_scheduled_animations()

    async def save(stage):
        folder = ROOT / "docs" / "images" / "aum"
        name = f"{config.backend}-group-form-{stage}-110x36.svg"
        entry = dict(file=name, source="live", backend=backend.name, captured_at=datetime.now(timezone.utc).isoformat(),
                     redaction=True, commit=commit, size=[110, 36], phase="after", tab="group-form",
                     flow=stage, preview_only=True)
        for field in app.screen.query(Input):
            if field.id in {"scope-group", "scope-manager", "confirm"}:
                field.password = True
        await asyncio.sleep(.2)
        problems = validate_capture(app.export_screenshot(), entry)
        if problems:
            raise RuntimeError("; ".join(problems))
        with capture_lock(ROOT / ".aum-evidence"):
            app.save_screenshot(name, path=str(folder))
            manifest_file = folder / "manifest.json"
            manifest = json.loads(manifest_file.read_text(encoding="utf-8"))
            manifest["images"] = [row for row in manifest["images"] if row["file"] != name] + [entry]
            manifest_file.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
        print("Captured LIVE preview: " + stage)

    try:
        async with app.run_test(size=(110, 36)) as pilot:
            await settle(pilot)
            app.push_screen(GroupPicker())
            await settle(pilot)
            app.screen.query_one("#group-search", Input).value = args.prefix
            app.screen.search()
            await settle(pilot)
            if not app.screen.rows:
                raise RuntimeError("No live test groups found; no selection screenshot fabricated.")
            await save("lookup")
            await pilot.click("#group-create")
            await settle(pilot)
            name = "aum-e2e-preview-" + datetime.now(timezone.utc).strftime("%H%M%S")
            app.screen.query_one("#field-name", Input).value = name
            app.screen.query_one("#field-description", Input).value = "Preview only; no group is created"
            app.screen.query_one("#field-confirm", Input).value = name
            await pilot.click("#action-preview")
            await settle(pilot)
            await save("create-preview")
            app.pop_screen()
            app.screen.query_one("#group-results", DataTable).focus()
            await pilot.press("enter")
            await settle(pilot)
            await save("scope-registration")
    finally:
        backend.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    parser.add_argument("--prefix", required=True)
    asyncio.run(capture(parser.parse_args()))
