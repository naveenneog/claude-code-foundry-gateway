"""Owner-approved, finally-restored group/budget/mode acceptance on an explicit live target."""

import argparse
import asyncio
from copy import deepcopy
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import subprocess
import time
from uuid import uuid4

from claude_finops.backend import connect
from claude_finops.config import load_config
from claude_finops.engine import Engine
from claude_finops.errors import FinOpsError
from claude_finops.gateway_probe import tiny_request
from claude_finops.group_actions import group_call, membership_refresh
from claude_finops.groups import EntraGroups
from claude_finops.publication import capture_lock, validate_capture
from claude_finops.screens import DetailScreen
from claude_finops.tui import FinOpsApp

from e2e_support import GatewayState, Journal, utc

ROOT = Path(__file__).resolve().parents[3]
RESTORE_NAMES = ["bu-members", "bu-modes", "bu-parents", "bu-registry", "turnstile-integration"]


async def screenshot(engine, config, journal, stage, result):
    app = FinOpsApp(engine, config, redact=True, first_run=False)
    async with app.run_test(size=(110, 36)) as pilot:
        await pilot.pause(.2)
        await app.workers.wait_for_complete()
        app.push_screen(DetailScreen("LIVE AUM E2E | " + stage, result))
        await pilot.pause(.3)
        await pilot.wait_for_scheduled_animations()
        folder = ROOT / "docs" / "images" / "aum"
        name = f"{config.backend}-e2e-{stage}-{journal.folder.name[-8:]}.svg"
        entry = dict(file=name, source="live", backend=engine.backend.name, captured_at=utc(), redaction=True,
                     commit=subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
                     size=[110, 36], phase="after", tab="e2e", flow=stage)
        problems = validate_capture(app.export_screenshot(), entry)
        if problems:
            raise RuntimeError("E2E screenshot refused: " + "; ".join(problems))
        with capture_lock(ROOT / ".aum-evidence"):
            app.save_screenshot(name, path=str(folder))
            path = folder / "manifest.json"
            manifest = json.loads(path.read_text(encoding="utf-8"))
            manifest["images"] = [row for row in manifest["images"] if row["file"] != name] + [entry]
            path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
        journal.record("screenshot", {"file": name, "flow": stage})


def configured_catalog(catalog):
    return dict(organizations=[{k: v for k, v in row.items() if k != "parent_id"} for row in catalog["organizations"]],
                departments=deepcopy(catalog["departments"]), default_department_id=catalog.get("default_department_id"))


async def journey(args):
    if not args.apply or args.confirm != "restore all test changes":
        raise RuntimeError('Explicit --apply --confirm "restore all test changes" is required.')
    config = load_config(Path(args.config), backend=args.backend)
    backend = connect(config)
    engine = Engine(backend, datetime.now(timezone.utc).strftime("%Y-%m"))
    suffix = uuid4().hex[:8]
    unit, team = "aum-e2e-unit-" + suffix, "aum-e2e-team-" + suffix
    journal = Journal(ROOT / ".aum-evidence" / ("e2e-" + args.backend + "-" + suffix), args.backend, config)
    arm, graph = GatewayState(config), EntraGroups()
    snapshot, original_catalog, created, mutated = None, None, [], False
    try:
        snapshot = journal.call("snapshot", lambda: arm.snapshot())
        # Raw restoration state is local-only and contains no access token.
        (journal.folder / "restore-state.json").write_text(json.dumps(snapshot, indent=2), encoding="utf-8")
        me = graph.me()["id"]
        journal.redactor.present({"user_id": me})
        original_catalog = engine.read("catalog")
        if backend.name == "Turnstile":
            state = engine.read("apply")
            if any(row.get("status", "").lower() in {"running", "processing", "pending"} for row in state.get("executions", [])[:1]):
                raise RuntimeError("Another Turnstile apply is active. No acceptance mutation started.")
        for name in (unit, team):
            preview = journal.call("group-preview-" + ("unit" if name == unit else "team"),
                                   lambda name=name: group_call(engine, "create", name, "AUM temporary E2E acceptance group; delete after test"))
            result = journal.call("group-create-" + ("unit" if name == unit else "team"),
                lambda name=name: group_call(engine, "create", name, "AUM temporary E2E acceptance group; delete after test",
                                             apply=True, confirm=name))
            created.append((result["result"]["id"], name))
            await screenshot(engine, config, journal, "group-created-" + ("unit" if name == unit else "team"), result)
        for group, name in created:
            journal.call("member-add-" + ("unit" if name == unit else "team"),
                         lambda group=group: group_call(engine, "member", group, me, apply=True))
        if args.backend == "direct":
            old = snapshot.get("turnstile-integration", {}).get("value", "")
            changed = re.sub(r"(governanceAuthority|budgetAuthority)=Turnstile", r"\1=Gateway", old)
            if changed != old:
                mutated = True
                journal.call("temporary-direct-authority", lambda: arm.put("turnstile-integration", changed) or
                             {"changed": True, "restore_in_finally": True})
        elif args.backend == "aum-service":
            engine.change_reason = "Owner-approved temporary AUM E2E; restore all test state"
        mutated = True
        for kind, key, group, parent in (("unit", unit, created[0][0], None), ("team", team, created[1][0], unit)):
            result = journal.call("register-" + kind, lambda kind=kind, key=key, group=group, parent=parent:
                engine.catalog_change(kind, key, name=key, group=group, parent=parent, apply=True))
            if result.get("requested_at"):
                journal.call("apply-register-" + kind, lambda result=result: engine.wait_for_apply(result["requested_at"], timeout=480, interval=8))
            await screenshot(engine, config, journal, "registered-" + kind, result)
        for kind, key, amount in (("unit", unit, "100000"), ("team", team, "1")):
            result = journal.call("budget-" + kind, lambda kind=kind, key=key, amount=amount:
                engine.budget_change(kind, key, amount, apply=True, confirm=key))
            if result.get("requested_at"):
                journal.call("apply-budget-" + kind, lambda result=result: engine.wait_for_apply(result["requested_at"], timeout=480, interval=8))
            await screenshot(engine, config, journal, "budget-" + kind, result)
        if args.backend == "direct":
            result = journal.call("membership-refresh", lambda: membership_refresh(engine, [unit, team], apply=True, allow_reassignment=True))
            await screenshot(engine, config, journal, "membership-refreshed", result)
        mapping = arm.snapshot()["bu-members"]["value"]
        if f",{me}={team}," not in mapping:
            raise RuntimeError("Gateway did not map the signed-in member to the test team. Enforcement was not probed against the wrong scope.")
        for mode in ("strict", "allowance", "notify"):
            if mode == "allowance":
                # The first strict admitted request gives an observed token lower bound.
                spent = sum((event.get("usage") or {}).get("input_tokens", 0) + (event.get("usage") or {}).get("output_tokens", 0)
                            for event in probes if event.get("status_code") == 200)
                base = max(20, int(spent / 1.05))
                change = journal.call("allowance-nominal-budget", lambda: engine.budget_change("team", team, str(base), apply=True, confirm=team))
                if change.get("requested_at"):
                    journal.call("apply-allowance-budget", lambda: engine.wait_for_apply(change["requested_at"], timeout=480, interval=8))
            change = journal.call("mode-" + mode, lambda mode=mode: engine.mode_change("team", team, mode,
                                 10 if mode == "allowance" else None, apply=True))
            if change.get("requested_at"):
                journal.call("apply-mode-" + mode, lambda: engine.wait_for_apply(change["requested_at"], timeout=480, interval=8))
            probes = [] if mode == "strict" else probes
            deadline = time.monotonic() + args.propagation_timeout
            success = False
            while time.monotonic() < deadline:
                probe = journal.call("probe-" + mode, lambda: tiny_request(config, apply=True))
                probes.append(probe)
                notice = probe.get("headers", {}).get("x-claude-budget-notice", "")
                success = ((mode == "strict" and probe["status_code"] == 429 and team in json.dumps(probe.get("error"))) or
                           (mode == "allowance" and probe["status_code"] == 200 and team in notice and "estimated-over-budget" in notice) or
                           (mode == "notify" and probe["status_code"] == 200 and team in notice and "usage-reported" in notice))
                if success:
                    await screenshot(engine, config, journal, "enforcement-" + mode, probe)
                    break
                await asyncio.sleep(12)
            if not success:
                raise RuntimeError("No measured gateway enforcement confirmation for " + mode + " before timeout.")
        started = time.monotonic()
        while time.monotonic() - started < args.ingestion_timeout:
            rows = await asyncio.to_thread(engine.read, "requests", department_id=team, limit=50)
            if rows.get("items"):
                journal.record("attribution", dict(rows=len(rows["items"]), ingestion_wait_seconds=time.monotonic() - started))
                await screenshot(engine, config, journal, "request-attribution", rows)
                break
            await asyncio.sleep(20)
        else:
            raise RuntimeError("Test request attribution did not arrive before ingestion timeout.")
        journal.data["completed"] = True
    except Exception as error:
        journal.record("journey-error", {"error": journal.redactor.text(str(error)), "type": type(error).__name__})
    finally:
        cleanup = {"errors": [], "groups_deleted": []}
        if mutated and snapshot:
            try:
                if backend.name == "Turnstile" and original_catalog:
                    for key in (team, unit):
                        backend.write("budget_remove", scope_type="department" if key == team else "organization", scope_id=key, month=engine.month)
                    restored = engine._replace("catalog", configured_catalog(original_catalog), None, True)
                    if restored.get("requested_at"):
                        engine.wait_for_apply(restored["requested_at"], timeout=480, interval=8)
                    deadline = time.monotonic() + 480
                    while any(row.get("status", "").lower() in {"running", "processing", "pending"}
                              for row in engine.read("apply").get("executions", [])):
                        if time.monotonic() > deadline:
                            raise RuntimeError("Apply jobs did not drain before exact gateway restore.")
                        time.sleep(8)
                cleanup["gateway"] = arm.restore(snapshot, RESTORE_NAMES)
            except Exception as error:
                cleanup["errors"].append(journal.redactor.text(str(error)))
                # Even if server restore failed, always attempt the byte-exact gateway restore.
                try:
                    cleanup["gateway"] = arm.restore(snapshot, RESTORE_NAMES)
                except Exception as again:
                    cleanup["errors"].append(journal.redactor.text(str(again)))
        elif snapshot:
            cleanup["gateway"] = {"verified": arm.snapshot() == snapshot, "mutation_started": False}
        for group, name in reversed(created):
            try:
                group_call(engine, "member", group, remove=True, apply=True)
                group_call(engine, "delete", group, name, apply=True, confirm=name)
                cleanup["groups_deleted"].append(name)
            except Exception as error:
                cleanup["errors"].append(journal.redactor.text(str(error)))
        journal.data["cleanup"] = cleanup
        journal.data["finished_at"] = utc()
        journal.flush()
        try:
            await screenshot(engine, config, journal, "cleanup", cleanup)
        except Exception as error:
            journal.record("cleanup-screenshot-error", {"error": str(error)})
        graph.close()
        backend.close()
        arm.close()
    print(json.dumps(dict(journal=str(journal.folder), completed=journal.data["completed"],
                          cleanup_errors=journal.data["cleanup"]["errors"]), indent=2))
    if journal.data["cleanup"]["errors"] or not journal.data["completed"]:
        raise SystemExit(1)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    parser.add_argument("--backend", choices=["direct", "turnstile", "aum-service"], required=True)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--confirm", default="")
    parser.add_argument("--propagation-timeout", type=int, default=240)
    parser.add_argument("--ingestion-timeout", type=int, default=600)
    asyncio.run(journey(parser.parse_args()))
