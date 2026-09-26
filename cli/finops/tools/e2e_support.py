"""Live acceptance plumbing: snapshots and verified restoration, never application secrets."""

from copy import deepcopy
from datetime import datetime, timezone
from hashlib import sha256
import json
from pathlib import Path
import time

import httpx

from claude_finops.config import az, token_needs_refresh
from claude_finops.errors import FinOpsError
from claude_finops.redaction import Redactor
from claude_finops.config import parse_integration


def utc():
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def digest(value):
    return sha256(value.encode()).hexdigest()


class GatewayState:
    def __init__(self, config):
        self.config = config
        self.path = (f"/subscriptions/{config.subscription}/resourceGroups/{config.resource_group}"
                     f"/providers/Microsoft.ApiManagement/service/{config.apim_name}")
        self.token = az("account", "get-access-token", "--resource", "https://management.azure.com",
                        "--query", "accessToken", "-o", "tsv", "--subscription", config.subscription)
        self.client = httpx.Client(base_url="https://management.azure.com", timeout=90, follow_redirects=False)

    def close(self):
        self.token = ""
        self.client.close()

    def call(self, method, suffix, body=None, allow_missing=False):
        if token_needs_refresh(self.token):
            self.token = az("account", "get-access-token", "--resource", "https://management.azure.com",
                            "--query", "accessToken", "-o", "tsv", "--subscription", self.config.subscription)
        response = self.client.request(method, self.path + suffix, params={"api-version": "2024-05-01"},
                                       headers={"Authorization": "Bearer " + self.token}, json=body)
        if response.status_code == 404 and allow_missing:
            return None
        if not response.is_success:
            try:
                payload = response.json()["error"]
                detail = f"{payload['code']}: {payload['message']}"
            except (ValueError, KeyError):
                detail = "Unexpected ARM response"
            raise FinOpsError(f"ARM HTTP {response.status_code}: {detail}", 7)
        if not response.content:
            return {}
        return response.json()

    def snapshot(self):
        response = self.call("GET", "/namedValues")
        result = {}
        while True:
            for row in response["value"]:
                if row["properties"].get("secret") and row["name"].startswith(
                        ("bu-", "allow-", "quota-", "tpm-", "models-", "turnstile-integration")):
                    raise FinOpsError("Cannot safely snapshot secret governance values; no acceptance mutation is allowed.", 7)
                if not row["properties"].get("secret"):
                    result[row["name"]] = deepcopy(row["properties"])
            if not response.get("nextLink"):
                break
            raise FinOpsError("Named-value snapshot is unexpectedly paginated. Refusing incomplete restore coverage.", 7)
        return result

    def put(self, name, value):
        current = self.call("GET", "/namedValues/" + name, allow_missing=True)
        props = current["properties"] if current else dict(displayName=name, secret=False)
        allowed = {key: val for key, val in props.items() if key in {"displayName", "secret", "tags"}}
        allowed["value"] = value
        self.call("PUT", "/namedValues/" + name, {"properties": allowed})
        for _ in range(20):
            actual = self.call("GET", "/namedValues/" + name)["properties"].get("value")
            if actual == value:
                return
            time.sleep(2)
        raise FinOpsError(f"Named value {name} did not read back as written.", 7)

    def restore(self, snapshot, names):
        failures = []
        for name in names:
            try:
                current = self.call("GET", "/namedValues/" + name, allow_missing=True)
                if name not in snapshot:
                    if current:
                        self.call("DELETE", "/namedValues/" + name)
                elif not current or current["properties"].get("value") != snapshot[name].get("value"):
                    self.put(name, snapshot[name].get("value", ""))
            except Exception as error:
                failures.append(f"{name}: {error}")
        actual = self.snapshot()
        checks = {name: ((name not in actual) if name not in snapshot else
                        actual.get(name, {}).get("value") == snapshot[name].get("value")) for name in names}
        if failures or not all(checks.values()):
            raise FinOpsError("RESTORE INCOMPLETE: " + "; ".join(failures or [name for name, ok in checks.items() if not ok]), 7)
        return dict(verified=True, values=checks, hashes={name: digest(snapshot[name].get("value", "")) for name in names if name in snapshot})


class Journal:
    def __init__(self, folder, backend, config):
        self.folder = Path(folder)
        self.folder.mkdir(parents=True, exist_ok=True)
        self.redactor = Redactor(True)
        self.redactor.present(config.public())
        self.data = dict(backend=backend, started_at=utc(), events=[], cleanup=None, completed=False)

    def record(self, stage, result, seconds=None):
        event = dict(stage=stage, at=utc(), result=self.redactor.present(result))
        if seconds is not None:
            event["seconds"] = round(seconds, 3)
        self.data["events"].append(event)
        self.flush()

    def flush(self):
        (self.folder / "journal.json").write_text(json.dumps(self.data, indent=2, default=str), encoding="utf-8")

    def call(self, stage, operation):
        start = time.monotonic()
        try:
            result = operation()
            self.record(stage, result, time.monotonic() - start)
            return result
        except Exception as error:
            self.record(stage + "-error", dict(error=self.redactor.text(str(error)), type=type(error).__name__),
                        time.monotonic() - start)
            raise


def assert_restored(snapshot, actual, names):
    return all(actual.get(name, {}).get("value") == snapshot.get(name, {}).get("value") for name in names)


def enforcement_matches(probe, mode, scope):
    status = probe.get("status_code")
    error = probe.get("error") or {}
    notice = probe.get("headers", {}).get("x-claude-budget-notice", "")
    if mode == "strict":
        return (status in {403, 429} and isinstance(error, dict) and error.get("type") == "rate_limit_error"
                and error.get("budget") == "business unit" and scope in error.get("message", ""))
    required = "estimated-over-budget" if mode == "allowance" else "usage-reported"
    return status == 200 and scope + ";" in notice and required in notice


def linked_turnstile(config, snapshot):
    from dataclasses import replace
    from claude_finops.backend import connect
    from claude_finops.engine import Engine
    from claude_finops.rules import require_owner
    value = snapshot.get("turnstile-integration", {}).get("value", "")
    if not any(key + "=Turnstile" in value for key in ("governanceAuthority", "budgetAuthority")):
        return None
    settings = parse_integration(value)
    related = Engine(connect(replace(config, backend="turnstile", url=settings["url"], scope=settings["scope"])))
    require_owner(related.read("whoami"))
    return related


def require_quiet_direct_window(jobs, config, now):
    for job in jobs:
        properties = job["properties"]
        env = {row["name"]: row.get("value") for container in properties.get("template", {}).get("containers", [])
               for row in container.get("env", [])}
        if env.get("CLAUDE_APIM") != config.apim_name or env.get("TURNSTILE_GOVERNANCE") != "true":
            continue
        schedule = (properties.get("configuration") or {}).get("scheduleTriggerConfig") or {}
        cron = schedule.get("cronExpression")
        if not cron:
            continue
        import re
        match = re.fullmatch(r"(\d{1,2}) \* \* \* \*", cron)
        if not match:
            raise FinOpsError("A scheduled governance writer requires a separately coordinated quiet window before Direct authority testing.", 6)
        seconds = ((int(match[1]) - now.minute) % 60) * 60 - now.second
        if seconds <= 0:
            seconds += 3600
        if seconds < 45 * 60:
            raise FinOpsError("The scheduled governance writer can overlap this Direct test. Wait for its next run to finish; no authority was changed.", 6)
