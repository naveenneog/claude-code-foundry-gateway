"""One explicit usage-only execution of the existing exporter; no grants or schedule edits."""

from copy import deepcopy
from datetime import datetime, timezone, timedelta
import json
from pathlib import Path
import re
import time
from uuid import uuid4

from .config import az
from .errors import FinOpsError
from .rules import require_owner


def execution_plan(jobs, config, start, end):
    try:
        first, last = [datetime.fromisoformat(value.replace("Z", "+00:00")) for value in (start, end)]
        first = first.replace(tzinfo=timezone.utc) if first.tzinfo is None else first.astimezone(timezone.utc)
        last = last.replace(tzinfo=timezone.utc) if last.tzinfo is None else last.astimezone(timezone.utc)
        if last <= first or last - first > timedelta(hours=2):
            raise ValueError()
    except (ValueError, TypeError):
        raise FinOpsError("Choose an explicit ISO time window of at most two hours.") from None
    choices = []
    for item in jobs:
        for container in item["properties"].get("template", {}).get("containers", []):
            env = {row["name"]: row.get("value") for row in container.get("env", [])}
            if (env.get("CLAUDE_RG") == config.resource_group and env.get("CLAUDE_APIM") == config.apim_name
                    and env.get("TURNSTILE_SKIP_EXPORT") == "false"):
                choices.append((item, container["name"]))
    if len(choices) != 1:
        raise FinOpsError("Choose a gateway with exactly one configured usage exporter; no arbitrary job is started.", 5)
    job, container_name = choices[0]
    if job["properties"]["template"].get("volumes"):
        raise FinOpsError("Exporter has volume definitions not supported by the execution-template contract.", 5)
    template = {key: deepcopy(value) for key, value in job["properties"]["template"].items()
                if key in {"containers", "initContainers"} and value is not None}
    for row in template["containers"]:
        row.pop("imageType", None)
    container = next(row for row in template["containers"] if row["name"] == container_name)
    command = container.get("command", [])
    if len(command) != 3 or command[:2] != ["/bin/bash", "-c"]:
        raise FinOpsError("Exporter bootstrap shape is not recognized; refusing a command override.", 5)
    begin, finish = [value.strftime("%Y-%m-%dT%H:%M:%SZ") for value in (first, last)]
    replacement = ('/opt/pwsh/pwsh -NoProfile -File ./scripts/Export-ClaudeTurnstileUsage.ps1 '
                   '-ResourceGroup "${CLAUDE_RG}" -ApimName "${CLAUDE_APIM}" '
                   f'-From {begin} -To {finish} -NoCacheEvents -AsJson')
    changed, count = re.subn(r"(?m)^/opt/pwsh/pwsh -NoProfile -File \./scripts/Invoke-ClaudeTurnstileSchedule\.ps1[^\n]*$",
                            lambda _: replacement, command[2])
    if count != 1:
        raise FinOpsError("Cannot identify the one scheduled entry point; no execution started.", 5)
    command[2] = changed
    return dict(preview=True, action="Refresh recent Turnstile usage", job_id=job["id"], job_name=job["name"],
                start=begin, end=finish, changes_job_definition=False,
                effect="One usage-only execution with existing exporter identity; no governance, permission or schedule changes. Duplicate request ids remain idempotent."), template


def refresh_usage(engine, config, start, end, *, apply=False):
    require_owner(engine.read("whoami"))
    if engine.backend.name != "Turnstile":
        raise FinOpsError("Direct reads the ledger immediately. Explicit exporter refresh is for Turnstile.", 5)
    selected = ("--subscription", config.subscription) if config.subscription else ()
    jobs = json.loads(az("containerapp", "job", "list", "-g", config.resource_group, "-o", "json", *selected))
    plan, template = execution_plan(jobs, config, start, end)
    if not apply:
        return plan
    original = json.loads(az("containerapp", "job", "show", "-g", config.resource_group, "-n", plan["job_name"],
                            "-o", "json", *selected))
    plan, template = execution_plan([original], config, start, end)
    root = Path(config.repository) if config.repository else Path(__file__).resolve().parents[4]
    folder = root / ".aum-evidence"
    folder.mkdir(exist_ok=True)
    path = folder / ("usage-execution-" + uuid4().hex + ".json")
    try:
        path.write_text(json.dumps(template), encoding="utf-8")
        started = json.loads(az("rest", "--method", "post", "--url",
            "https://management.azure.com" + plan["job_id"] + "/start?api-version=2024-03-01",
            "--body", "@" + str(path), "-o", "json", *selected))
    finally:
        path.unlink(missing_ok=True)
    execution = started.get("name") or started["id"].rsplit("/", 1)[-1]
    deadline = time.monotonic() + 480
    while True:
        state = json.loads(az("rest", "--method", "get", "--url", "https://management.azure.com" +
            plan["job_id"] + "/executions/" + execution + "?api-version=2024-03-01", "-o", "json", *selected))
        status = state.get("properties", {}).get("status")
        if status in {"Succeeded", "Failed", "Stopped"}:
            break
        if time.monotonic() > deadline:
            raise FinOpsError("Usage execution is still running. Inspect job history; do not repeat the start.", 8)
        time.sleep(8)
    if status != "Succeeded":
        raise FinOpsError(f"Usage exporter execution {status}. Inspect its logs; no ingestion success is claimed.", 7)
    current = json.loads(az("containerapp", "job", "show", "-g", config.resource_group, "-n", plan["job_name"],
                           "-o", "json", *selected))
    if current["properties"]["template"] != original["properties"]["template"]:
        raise FinOpsError("The job definition changed during export. Verify its owner; this client changed no definition.", 6)
    return dict(plan, preview=False, execution=execution, status=status, job_definition_unchanged=True)
