"""Publish redacted LIVE terminal SVGs, with provenance, using existing Azure rights."""

import argparse
import asyncio
from datetime import datetime, timezone
import json
from pathlib import Path
import subprocess
import time

from textual.widgets import TabbedContent

from claude_finops.backend import connect
from claude_finops.config import load_config
from claude_finops.engine import Engine
from claude_finops.publication import validate_capture, validate_manifest, capture_lock
from claude_finops.tui import FinOpsApp
from claude_finops.views import TABS
from claude_finops.ui_features import EXTRA_TABS

ROOT = Path(__file__).resolve().parents[3]


async def capture(args):
    config = load_config(Path(args.config) if args.config else None, backend=args.backend, url=args.url, scope=args.scope)
    if config.backend == "fake":
        raise ValueError("Documentation capture must use a live backend; fake renders belong to tests.")
    backend = connect(config)
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    folder = ROOT / "docs" / "images" / "aum"
    folder.mkdir(parents=True, exist_ok=True)
    manifest_file = folder / "manifest.json"
    manifest = json.loads(manifest_file.read_text(encoding="utf-8")) if manifest_file.exists() else {"schema": 1, "images": []}
    tabs = args.tabs.split(",") if args.tabs else None
    measurements = []
    try:
        for size in ((80, 24), (160, 48)):
            app = FinOpsApp(Engine(backend, args.month), config, redact=True, first_run=False)
            async with app.run_test(size=size) as pilot:
                await pilot.pause(.25)
                await app.workers.wait_for_complete()
                await pilot.wait_for_scheduled_animations()
                available = tabs or [key for key, _ in TABS + EXTRA_TABS if key in app.allowed_tabs]
                for tab in available:
                    started = time.monotonic()
                    if tab == "people":
                        overview = app.data.get("overview", {})
                        allowed = {row["id"] for row in overview.get("catalog", {}).get("departments", [])}
                        preferred = next((row["id"] for row in overview.get("teams", {}).get("items", [])
                                          if row["id"] in allowed), None)
                        if preferred:
                            app.team = preferred
                    if tab == "advanced":
                        app.action_tab(tab)
                    else:
                        shortcut = next(label[0] for key, label in TABS + EXTRA_TABS if key == tab)
                        await pilot.press(shortcut)
                    if tab == "overview":
                        app.action_refresh()
                    await pilot.pause(.25)
                    await app.workers.wait_for_complete()
                    await pilot.wait_for_scheduled_animations()
                    await pilot.pause(.5)
                    if tab not in app.data:
                        state = app.redactor.text(str(app.query_one(f"#note-{tab}").render()))
                        raise RuntimeError(f"Live {tab} failed; no image published. {state}")
                    filename = f"{config.backend}-{tab}-{size[0]}x{size[1]}-{args.phase}.svg"
                    entry = dict(file=filename, source="live", backend=backend.name,
                                 captured_at=datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
                                 redaction=app.redactor.enabled, commit=commit, size=list(size), tab=tab, phase=args.phase)
                    svg = app.export_screenshot()
                    problems = validate_capture(svg, entry)
                    if problems:
                        raise RuntimeError("Privacy/provenance guard refused image: " + "; ".join(problems))
                    app.save_screenshot(filename, path=str(folder))
                    problems = validate_capture((folder / filename).read_text(encoding="utf-8"), entry)
                    if problems:
                        (folder / filename).unlink()
                        raise RuntimeError("Saved image failed privacy guard.")
                    manifest["images"] = [e for e in manifest["images"] if e["file"] != filename] + [entry]
                    manifest_file.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
                    measurements.append(dict(file=filename, seconds=round(time.monotonic() - started, 2),
                                             rows=len(app.records.get(tab, [])), captured_at=entry["captured_at"]))
    finally:
        backend.close()
    assert not validate_manifest(folder)
    evidence = ROOT / ".aum-evidence"
    evidence.mkdir(exist_ok=True)
    (evidence / f"capture-{config.backend}-{args.phase}.json").write_text(json.dumps(measurements, indent=2), encoding="utf-8")
    print(json.dumps(measurements, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--backend", choices=["direct", "aum-service", "turnstile"], default="direct")
    parser.add_argument("--config")
    parser.add_argument("--url")
    parser.add_argument("--scope")
    parser.add_argument("--month", required=True)
    parser.add_argument("--tabs")
    parser.add_argument("--phase", choices=["before", "after"], default="after")
    with capture_lock(ROOT / ".aum-evidence"):
        asyncio.run(capture(parser.parse_args()))
