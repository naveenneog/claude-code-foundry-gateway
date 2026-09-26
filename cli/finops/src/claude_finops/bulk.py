import csv
from collections import defaultdict
from pathlib import Path

from .errors import FinOpsError
from .rules import identifier, parse_tokens, require_owner


def budget_csv_plan(engine, filename, *, apply=False):
    require_owner(engine.read("whoami"))
    engine.require_feature("bulk_budget", "write")
    path = Path(filename)
    if not path.is_file() or path.stat().st_size > 2_000_000:
        raise FinOpsError("Choose a CSV file below 2 MB with team, person and tokens columns.")
    with path.open(encoding="utf-8-sig", newline="") as source:
        reader = csv.DictReader(source)
        if not {"team", "person", "tokens"} <= set(reader.fieldnames or []):
            raise FinOpsError("CSV columns must include team, person and tokens; warning is optional.")
        rows = list(reader)
    if not 1 <= len(rows) <= 500:
        raise FinOpsError("A CSV batch must contain between 1 and 500 people.")
    seen, changes, headroom, deltas = set(), [], {}, defaultdict(int)
    for line, row in enumerate(rows, 2):
        team, person = identifier(row["team"].strip()), identifier(row["person"].strip())
        if person in seen:
            raise FinOpsError(f"CSV line {line}: each person may appear only once.")
        seen.add(person)
        page = engine.read("people", department_id=team, query=person, offset=0, limit=50)
        target = next((item for item in page["items"] if item["scope_id"] == person), None)
        if not target:
            raise FinOpsError(f"CSV line {line}: person was not found in the selected team.", 5)
        amount = parse_tokens(row["tokens"])
        warning = int(row.get("warning") or target.get("warning_threshold_percent", 80))
        if not 1 <= warning <= 100:
            raise FinOpsError(f"CSV line {line}: warning must be 1 to 100.")
        if amount < target["used_tokens"]:
            raise FinOpsError(f"CSV line {line}: lowering below usage needs an individual confirmed edit.")
        headroom[team] = page.get("department_available_tokens")
        deltas[team] += amount - (target.get("token_limit") or 0)
        changes.append(dict(team=team, person=person, before=target.get("token_limit"), after=amount, warning=warning))
    for team, delta in deltas.items():
        if headroom[team] is not None and delta > headroom[team]:
            raise FinOpsError("CSV allocations exceed parent headroom. Lower the batch or request more budget.", 6)
    plan = dict(preview=not apply, action="Bulk person budgets", count=len(changes), changes=changes,
                note="Each server batch is atomic; several amount groups are not a single transaction. Refresh after any failure.")
    if apply:
        plan["results"] = apply_budget_plan(engine, plan)
    return plan


def apply_budget_plan(engine, plan):
    require_owner(engine.read("whoami"))
    engine.require_feature("bulk_budget", "write")
    groups = defaultdict(list)
    for row in plan["changes"]:
        groups[(row["team"], row["after"], row["warning"])].append(row["person"])
    results = []
    for (team, amount, warning), people in groups.items():
        body = dict(department_id=team, selection="ids", user_ids=people, allocation_mode="fixed",
                    token_limit=amount, warning_threshold_percent=warning)
        results.append(engine.backend.write("bulk_budget", body, month=engine.month))
    return results
