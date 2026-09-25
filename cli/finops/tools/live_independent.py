"""Read/preview both independent AUM backends. Tokens and raw identities never leave memory."""

import argparse
import asyncio
from datetime import datetime, timezone
import json
from pathlib import Path
import subprocess
import sys
import time

from claude_finops.backend import connect
from claude_finops.config import load_config
from claude_finops.engine import Engine
from claude_finops.redaction import privacy_problems
from claude_finops.tui import FinOpsApp


def utc():
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


async def journey(args):
    config = load_config(Path(args.config), backend=args.backend)
    backend = connect(config)
    engine = Engine(backend, args.month)
    record = dict(backend=backend.name, started_at=utc(), live_writes=0, commands=[], terminal=[])
    catalog = engine.read("catalog")
    budgets = engine.read("budgets")["items"]
    team = next((row for row in catalog["departments"] if not row.get("scope_context")), None)
    if team is None:
        team = next(iter(catalog["organizations"]), None)
    commands = [
        ("whoami", ["whoami"]), ("status", ["status"]), ("budgets", ["budget", "list"]),
        ("governance", ["governance", "show"]), ("requests", ["requests", "list", "--limit", "50"]),
        ("trends", ["trends", "show", "--interval", "day"]), ("settings", ["session", "show"]),
        ("chargeback", ["report", "chargeback"]),
    ]
    if team:
        commands += [("people", ["people", "find", "--team", team["id"], "--limit", "50"])]
    if args.backend == "direct":
        commands += [("hourly", ["trends", "show", "--interval", "hour"]),
                     ("anomalies", ["anomalies", "list"]),
                     ("tiers", ["usage", "show", "--dimension", "tier"])]
    else:
        commands += [("approval-mine", ["request", "list", "--view", "mine"]),
                     ("approval-waiting", ["request", "list", "--view", "waiting"]),
                     ("approval-history", ["request", "list", "--view", "history"]),
                     ("boosts", ["boost", "list"]), ("notifications", ["notifications", "list"]),
                     ("audit", ["governance", "audit"])]
    budget = next((row for row in budgets if row.get("token_limit") and row["scope_type"] == "department"), None)
    if budget:
        commands += [("budget-preview", ["budget", "set", "team", budget["scope_id"], str(budget["token_limit"]),
                                          "--reason", "AUM read-only acceptance preview", "--what-if"])]
    raw = {}
    try:
        for name, command in commands:
            started = time.monotonic()
            result = subprocess.run([sys.executable, "-m", "claude_finops.cli", *command, "--backend", args.backend,
                "--config", args.config, "--month", args.month, "--json"], capture_output=True,
                text=True, encoding="utf-8", timeout=300)
            if result.returncode:
                raise RuntimeError(f"{name} failed exit {result.returncode}; no success receipt written.")
            raw[name] = json.loads(result.stdout)
            record["commands"].append(dict(flow=name, exit_code=0, seconds=round(time.monotonic() - started, 3), at=utc()))
        app = FinOpsApp(engine, config, redact=True, first_run=False)
        async with app.run_test(size=(100, 32)) as pilot:
            await pilot.pause(.2)
            await app.workers.wait_for_complete()
            record["same_identity"] = app.identity["email"] == raw["whoami"]["email"]
            for tab in ("overview", "budgets", "governance", "trends", "requests", "people", "settings"):
                if tab not in app.allowed_tabs:
                    continue
                if tab == "people" and team:
                    app.team = team["id"]
                started = time.monotonic()
                app.action_tab(tab)
                await pilot.pause(.2)
                await app.workers.wait_for_complete()
                await pilot.wait_for_scheduled_animations()
                if tab not in app.data:
                    raise RuntimeError(f"Terminal {tab} did not load.")
                record["terminal"].append(dict(tab=tab, seconds=round(time.monotonic() - started, 3),
                                               rows=len(app.records.get(tab, [])), at=utc()))
            record["same_catalog"] = app.data["governance"]["catalog"] == raw["governance"]["catalog"]
            record["same_tiers"] = app.data["governance"]["tiers"] == raw["governance"]["tiers"]
            record["same_budget_limits"] = {(r["scope_type"], r["scope_id"]): r.get("token_limit")
                for r in app.data["budgets"]["items"]} == {(r["scope_type"], r["scope_id"]): r.get("token_limit")
                for r in raw["budgets"]["items"]}
            record["same_request_ids"] = [r["request_id"] for r in app.data["requests"]["items"]] == [
                r["request_id"] for r in raw["requests"]["items"]]
            record["same_overview_totals"] = app.data["overview"]["overview"]["totals"] == raw["status"]["overview"]["totals"]
            record["totals"] = raw["status"]["overview"]["totals"]
            record["scope_count"] = len(budgets)
            record["people_rows"] = len(raw.get("people", {}).get("items", []))
            record["hourly_buckets"] = len(raw.get("hourly", {}).get("points", []))
            record["statistical_findings"] = len(raw.get("anomalies", {}).get("items", []))
            record["role"] = app.identity.get("role")
            record["access"] = app.identity.get("access")
            if not all(record[key] for key in record if key.startswith("same_")):
                raise RuntimeError("Command/TUI facts changed between reads; no equality success is claimed.")
    finally:
        backend.close()
    record["finished_at"] = utc()
    text = json.dumps(record, indent=2)
    if privacy_problems(text):
        raise RuntimeError("Unexpected private data in count-only proof.")
    Path(args.out).write_text(text, encoding="utf-8")
    print(text)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--backend", choices=["direct", "aum-service"], required=True)
    parser.add_argument("--config", required=True)
    parser.add_argument("--month", required=True)
    parser.add_argument("--out", required=True)
    asyncio.run(journey(parser.parse_args()))
