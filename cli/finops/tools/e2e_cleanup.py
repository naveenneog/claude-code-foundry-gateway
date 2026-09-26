"""Independent cleanup steps: an early failure must not suppress later restoration."""

import time

from claude_finops.errors import FinOpsError


def restore_turnstile(engine, catalog, unit, team, baseline_budgets=None):
    errors = []
    try:
        current = engine.read("budgets").get("items", [])
    except Exception as error:
        errors.append(str(error))
        current = []
    targets = [(row["scope_type"], row["scope_id"]) for row in current
               if row["scope_id"] in {unit, team} and row.get("token_limit") is not None]
    targets.sort(key=lambda item: {"user": 0, "department": 1, "organization": 2}.get(item[0], 3))
    for kind, key in targets:
        try:
            engine.backend.write("budget_remove", scope_type=kind, scope_id=key, month=engine.month)
        except FinOpsError as error:
            if error.code != 5:
                errors.append(str(error))
        except Exception as error:
            errors.append(str(error))
    try:
        restored = engine._replace("catalog", catalog, None, True)
        if baseline_budgets:
            actual = {(row["scope_type"], row["scope_id"]): row for row in engine.read("budgets").get("items", [])}
            changed = []
            for row in baseline_budgets:
                prior = actual.get((row["scope_type"], row["scope_id"]), {})
                if (row.get("token_limit"), row.get("warning_threshold_percent", 80)) != (
                        prior.get("token_limit"), prior.get("warning_threshold_percent", 80)):
                    decrease = row.get("token_limit") is not None and (
                        prior.get("token_limit") is None or row["token_limit"] < prior["token_limit"])
                    priority = (3 if row["scope_type"] == "organization" else 0) if decrease else (
                        1 if row["scope_type"] == "organization" else 2)
                    changed.append((priority, row))
            for _, row in sorted(changed, key=lambda item: item[0]):
                body = None if row.get("token_limit") is None else {
                    "token_limit": row["token_limit"], "warning_threshold_percent": row.get("warning_threshold_percent", 80)}
                engine.backend.write("budget_remove" if body is None else "budget", body,
                                     scope_type=row["scope_type"], scope_id=row["scope_id"], month=engine.month)
        if restored.get("requested_at"):
            status = engine.read("apply")
            anchor = (status.get("last_request") or {}).get("requested_at") or restored["requested_at"]
            engine.wait_for_apply(anchor, timeout=480, interval=8)
        deadline = time.monotonic() + 480
        while any(row.get("status", "").lower() in {"running", "processing", "pending"}
                  for row in engine.read("apply").get("executions", [])):
            if time.monotonic() > deadline:
                raise RuntimeError("Apply jobs did not drain before exact gateway restore.")
            time.sleep(8)
    except Exception as error:
        errors.append(str(error))
    return errors
