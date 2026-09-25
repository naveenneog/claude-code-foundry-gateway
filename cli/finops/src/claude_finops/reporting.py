"""P50 adapter: activates automatically when the repository's generator is installed."""

from pathlib import Path
import json
import subprocess
from uuid import uuid4

from .errors import FinOpsError
from .rules import identifier, month_window, require_owner


def report_plan(engine, config, *, month=None, units=None, output="finops-reports",
                formats="CSV,HTML", send=False, apply=False):
    require_owner(engine.read("whoami"))
    period = month or engine.month
    month_window(period)
    units = [identifier(unit) for unit in (units or [])]
    wanted = [part.upper() for part in formats.split(",")]
    if not wanted or any(part not in {"CSV", "HTML"} for part in wanted):
        raise FinOpsError("Report formats must be CSV, HTML or CSV,HTML.")
    root = Path(config.repository) if config.repository else Path(__file__).resolve().parents[4]
    script = root / "scripts" / "New-ClaudeChargebackReport.ps1"
    plan = dict(preview=not apply, action="Generate reconciled P50 chargeback report",
                available=script.exists(), month=period, units=units, output=output,
                formats=wanted, send=send,
                note="Uses the repository generator and its reconciliation guard. Sending is explicit and defaults off.")
    if not apply:
        if not script.exists():
            plan["waiting_on"] = "P50 merge: scripts/New-ClaudeChargebackReport.ps1"
        return plan
    if not script.exists():
        raise FinOpsError("P50 report generator is not installed. Merge the chargeback-reports packet; this client activates automatically.", 5)
    folder = root / ".aum-evidence"
    folder.mkdir(exist_ok=True)
    request = folder / f"report-{uuid4().hex}.json"
    params = dict(Month=period, OutputPath=str(Path(output).resolve()), Format=wanted, NonInteractive=True)
    if units:
        params["BusinessUnit"] = units
    if send:
        params["Send"] = True
    for field, value in (("ResourceGroup", config.resource_group), ("ApimName", config.apim_name),
                         ("SubscriptionId", config.subscription), ("WorkspaceResourceId", config.workspace_resource_id)):
        if value:
            params[field] = value
    try:
        request.write_text(json.dumps(params), encoding="utf-8")
        bridge = root / "scripts" / "Invoke-AumReport.ps1"
        run = subprocess.run(["pwsh", "-NoProfile", "-File", str(bridge), "-InputFile", str(request)],
                             capture_output=True, text=True, encoding="utf-8", timeout=1800)
        if run.returncode:
            raise FinOpsError("Report generation failed reconciliation or delivery checks. Inspect the output manifest; no successful report is claimed.", 7)
        plan["result"] = json.loads(run.stdout)
        return plan
    except (OSError, ValueError, subprocess.TimeoutExpired):
        raise FinOpsError("Cannot run the P50 report generator. Verify PowerShell, repository path and output access.", 7) from None
    finally:
        request.unlink(missing_ok=True)
