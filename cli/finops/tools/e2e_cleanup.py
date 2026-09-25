"""Independent cleanup steps: an early failure must not suppress later restoration."""

import time

from claude_finops.errors import FinOpsError


def restore_turnstile(engine, catalog, unit, team):
    errors = []
    for kind, key in (("department", team), ("organization", unit)):
        try:
            engine.backend.write("budget_remove", scope_type=kind, scope_id=key, month=engine.month)
        except FinOpsError as error:
            if error.code != 5:
                errors.append(str(error))
        except Exception as error:
            errors.append(str(error))
    try:
        restored = engine._replace("catalog", catalog, None, True)
        if restored.get("requested_at"):
            engine.wait_for_apply(restored["requested_at"], timeout=480, interval=8)
        deadline = time.monotonic() + 480
        while any(row.get("status", "").lower() in {"running", "processing", "pending"}
                  for row in engine.read("apply").get("executions", [])):
            if time.monotonic() > deadline:
                raise RuntimeError("Apply jobs did not drain before exact gateway restore.")
            time.sleep(8)
    except Exception as error:
        errors.append(str(error))
    return errors
