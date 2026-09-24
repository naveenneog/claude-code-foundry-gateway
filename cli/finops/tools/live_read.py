"""Read-only live proof. Emits counts and equality results, never identities or tokens."""

import argparse
import asyncio
import json
from datetime import datetime, timezone
from pathlib import Path
import subprocess
import sys

from textual.widgets import TabbedContent

from claude_finops.config import Config
from claude_finops.engine import Engine
from claude_finops.tui import FinOpsApp
from claude_finops.turnstile import TurnstileBackend


def utc():
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


async def probe(args):
    evidence = dict(started_at=utc(), live_writes=0, screenshots=0, commands=[], terminal=[])
    outputs = {}
    for name, command in (("whoami", ["whoami"]), ("status", ["status"]),
                          ("budgets", ["budget", "list"]), ("governance", ["governance", "show"]),
                          ("requests", ["requests", "list", "--limit", "200"])):
        result = subprocess.run([sys.executable, "-m", "claude_finops.cli", *command, "--json",
                                 "--url", args.url, "--scope", args.scope, "--month", args.month],
                                capture_output=True, text=True, encoding="utf-8", timeout=240)
        if result.returncode:
            raise RuntimeError(f"{name} command failed with exit {result.returncode}; run it interactively for the safe error.")
        outputs[name] = json.loads(result.stdout)
        evidence["commands"].append(dict(command=name, exit_code=result.returncode, at=utc()))
    config = Config(url=args.url, scope=args.scope)
    backend = TurnstileBackend(config)
    app = FinOpsApp(Engine(backend, args.month), config)
    try:
        async with app.run_test(size=(80, 24)) as pilot:
            await pilot.pause()
            await app.workers.wait_for_complete()
            for tab in ("overview", "budgets", "governance", "requests", "settings"):
                app.query_one(TabbedContent).active = tab
                await pilot.pause()
                await app.workers.wait_for_complete()
                await pilot.pause(.25)
                if tab not in app.data:
                    raise RuntimeError(f"Live terminal {tab} did not load.")
                evidence["terminal"].append(dict(tab=tab, row_count=len(app.records.get(tab, [])), at=utc()))
            evidence["role"] = app.identity.get("role")
            evidence["method"] = app.identity.get("method")
            evidence["same_identity"] = app.identity.get("id") == outputs["whoami"].get("id")
            evidence["same_budget_rows"] = app.data["budgets"]["items"] == outputs["budgets"]["items"]
            evidence["same_catalog"] = app.data["governance"]["catalog"] == outputs["governance"]["catalog"]
            evidence["same_tiers"] = app.data["governance"]["tiers"] == outputs["governance"]["tiers"]
            evidence["same_overview_totals"] = app.data["overview"]["overview"]["totals"] == outputs["status"]["overview"]["totals"]
            evidence["same_request_ids"] = [r["request_id"] for r in app.data["requests"]["all_items"]] == [
                r["request_id"] for r in outputs["requests"]["items"]]
            evidence["budget_scope_count"] = len(outputs["budgets"]["items"])
            evidence["unit_count"] = len(outputs["governance"]["catalog"]["organizations"])
            evidence["team_count"] = len(outputs["governance"]["catalog"]["departments"])
            evidence["tier_count"] = len(outputs["governance"]["tiers"]["items"])
            evidence["request_count"] = len(outputs["requests"]["items"])
            evidence["month_tokens"] = outputs["status"]["overview"]["totals"]["total_tokens"]
            evidence["estimated_cost"] = outputs["status"]["overview"]["totals"]["estimated_cost"]
    finally:
        backend.close()
    evidence["finished_at"] = utc()
    output = Path(args.out)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(evidence, indent=2), encoding="utf-8")
    print(json.dumps(evidence, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", required=True)
    parser.add_argument("--scope", required=True)
    parser.add_argument("--month", required=True)
    parser.add_argument("--out", default=".finops-evidence/live-read.json")
    asyncio.run(probe(parser.parse_args()))
