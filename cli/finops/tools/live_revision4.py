"""Read/preview proof for revision four; never mutates remote budgets, tiers or chat."""

import argparse
import asyncio
from datetime import datetime, timezone
import json
from pathlib import Path
import subprocess
import sys
import time

from textual.widgets import Button, Input

from claude_finops.backend import connect
from claude_finops.config import load_config
from claude_finops.engine import Engine
from claude_finops.feature_screens import TourScreen
from claude_finops.publication import validate_capture
from claude_finops.redaction import Redactor, privacy_problems
from claude_finops.tui import FinOpsApp

ROOT = Path(__file__).resolve().parents[3]


def utc():
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


async def run(args):
    config = load_config(Path(args.config), backend="turnstile")
    backend = connect(config)
    engine = Engine(backend, args.month)
    identity = engine.read("whoami")
    if identity["role"] != "owner":
        raise RuntimeError("This Owner preview journey requires the existing Owner sign-in.")
    catalog = engine.read("catalog")
    budgets = engine.read("budgets")["items"]
    team = next(row for row in budgets if row["scope_type"] == "department" and row.get("token_limit"))
    key = team["scope_id"]
    tier = engine.read("tiers")["items"][0]
    request = engine.read("requests", limit=1)["items"][0]
    commands = [
        ("mode-read", ["mode", "show"]),
        ("mode-preview", ["mode", "set", "team", key, "strict", "--what-if"]),
        ("budget-preview", ["budget", "set", "team", key, str(team["token_limit"]), "--what-if"]),
        ("tier-preview", ["tier", "set", tier["id"], "--per-minute", str(tier["tokens_per_minute"]), "--what-if"]),
        ("people-search", ["people", "find", "--team", key]),
        ("lookup", ["lookup", key]),
        ("tier-pivot", ["usage", "show", "--dimension", "tier"]),
        ("comparison", ["trends", "show", "--compare", args.compare]),
        ("anomalies", ["anomalies", "list"]),
        ("ledger-link", ["requests", "ledger", request["request_id"]]),
        ("copy-preview", ["requests", "copy", request["request_id"], "--what-if"]),
        ("assistant-settings", ["ask", "settings"]),
        ("assistant-history", ["ask", "history"]),
        ("assistant-pins", ["ask", "pins"]),
        ("assistant-preview", ["ask", "query", "Compare monthly token use by unit", "--what-if"]),
        ("profile", ["session", "show"]),
        ("signout-preview", ["session", "signout", "--what-if"]),
        ("view-preview", ["view", "save", "contoso-review", "--tab", "usage", "--unit", catalog["organizations"][0]["id"], "--what-if"]),
        ("report-preview", ["report", "generate", "--month-to-date", "--what-if"]),
    ]
    evidence = dict(started_at=utc(), commit=subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(), live_writes=0,
        classification="Live reads and validated previews; no remote mutation or assistant model invocation.",
        commands=[], terminal=[])
    try:
        for flow, command in commands:
            started = time.monotonic()
            result = subprocess.run([sys.executable, "-m", "claude_finops.cli", *command,
                "--config", args.config, "--month", args.month, "--json", "--redact"],
                capture_output=True, text=True, encoding="utf-8", timeout=180)
            if result.returncode:
                raise RuntimeError(f"{flow} failed with exit {result.returncode}; no success evidence is recorded.")
            value = json.loads(result.stdout)
            if privacy_problems(result.stdout):
                raise RuntimeError("Redaction failed for " + flow)
            evidence["commands"].append(dict(flow=flow, exit_code=0, seconds=round(time.monotonic() - started, 3),
                                             at=utc(), preview=value.get("preview"), output=value))

        app = FinOpsApp(engine, config, redact=True, preview_only=True, first_run=False)
        folder = ROOT / "docs" / "images" / "aum"
        manifest_path = folder / "manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))

        async def settle(pilot):
            await pilot.pause(.2)
            await app.workers.wait_for_complete()
            await pilot.wait_for_scheduled_animations()
            await pilot.pause(.2)

        def capture(flow):
            name = f"turnstile-flow-r4-{flow}-100x32-after.svg"
            entry = dict(file=name, source="live", backend="Turnstile", captured_at=utc(),
                         redaction=True, commit=evidence["commit"], size=[100, 32], tab=app.active,
                         phase="after", flow=flow, preview_only=True)
            svg = app.export_screenshot()
            issues = validate_capture(svg, entry)
            if issues:
                raise RuntimeError(flow + ": " + "; ".join(issues))
            app.save_screenshot(name, path=str(folder))
            manifest["images"] = [row for row in manifest["images"] if row["file"] != name] + [entry]
            manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
            evidence["terminal"].append(dict(flow=flow, at=entry["captured_at"], file=name))

        async with app.run_test(size=(100, 32)) as pilot:
            await settle(pilot)
            for flow, action in (
                ("filters", app.action_scope_filters), ("saved-view", app.action_save_view),
                ("profile-switch", app.action_profile), ("signout-preview", app.action_sign_out),
                ("first-run-tour", lambda: app.push_screen(TourScreen())),
            ):
                action()
                await settle(pilot)
                if flow == "saved-view":
                    app.screen.query_one("#field-name", Input).value = "contoso-review"
                    await pilot.click("#action-preview")
                elif flow == "profile-switch":
                    app.screen.query_one("#field-path", Input).value = args.config
                    await pilot.click("#action-preview")
                elif flow == "signout-preview":
                    app.screen.query_one("#field-confirm", Input).value = "sign out"
                    await pilot.click("#action-preview")
                await settle(pilot)
                capture(flow)
                app.pop_screen()
                await settle(pilot)
            app.set_comparison(args.compare)
            await settle(pilot)
            capture("comparison")
            app.action_tab("ask")
            await settle(pilot)
            app.action_assistant_history()
            await settle(pilot)
            capture("assistant-history")
            app.pop_screen()
            app.action_assistant_pins()
            await settle(pilot)
            capture("assistant-pins")
            app.pop_screen()
    finally:
        backend.close()
    evidence["finished_at"] = utc()
    output = ROOT / ".aum-evidence" / "revision4-live-flows.json"
    output.write_text(json.dumps(evidence, indent=2), encoding="utf-8")
    print(json.dumps({key: value for key, value in evidence.items() if key not in {"commands", "terminal"}} |
                     dict(command_count=len(evidence["commands"]), terminal_count=len(evidence["terminal"])), indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    parser.add_argument("--month", required=True)
    parser.add_argument("--compare", required=True)
    asyncio.run(run(parser.parse_args()))
