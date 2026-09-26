import json
import os
from pathlib import Path
import shutil
import subprocess
from uuid import uuid4

from claude_finops.config import Config
from claude_finops.engine import Engine
from claude_finops.fake import FakeBackend
from claude_finops.reporting import report_plan

ROOT = Path(__file__).resolve().parents[3]


def test_month_to_date_reaches_existing_generator(monkeypatch):
    seen = {}
    def run(command, **kwargs):
        seen.update(json.loads(Path(command[-1]).read_text()))
        return subprocess.CompletedProcess(command, 0, '{"Manifest":{"Status":"Complete"}}', "")
    monkeypatch.setattr("claude_finops.reporting.subprocess.run", run)
    result = report_plan(Engine(FakeBackend(), "2026-09"), Config(backend="fake"),
                         month_to_date=True, apply=True)
    assert seen["MonthToDate"] is True
    assert result["result"]["Manifest"]["Status"] == "Complete"


def test_report_bridge_does_not_change_shared_azure_subscription():
    folder = ROOT / ".aum-evidence" / f"report-bridge-{uuid4().hex}"
    folder.mkdir(parents=True)
    try:
        (folder / "scripts").mkdir()
        shutil.copyfile(ROOT / "scripts" / "Invoke-AumReport.ps1", folder / "scripts" / "Invoke-AumReport.ps1")
        (folder / "az.cmd").write_text('@echo off\r\necho {"arguments":"%*"}\r\n', encoding="ascii")
        (folder / "scripts" / "New-ClaudeChargebackReport.ps1").write_text(
            "param([string]$SubscriptionId)\n"
            "az account set --subscription $SubscriptionId | Out-Null\n"
            "$setExit=$LASTEXITCODE\n"
            "$probe=az account show -o json | ConvertFrom-Json\n"
            "[pscustomobject]@{arguments=$probe.arguments; setExit=$setExit}\n", encoding="utf-8")
        subscription = "00000000-0000-0000-0000-000000000001"
        request = folder / "input.json"
        request.write_text(json.dumps({"SubscriptionId": subscription}), encoding="utf-8")
        env = os.environ | {"PATH": str(folder) + os.pathsep + os.environ["PATH"]}
        result = subprocess.run(["pwsh", "-NoProfile", "-File", str(folder / "scripts" / "Invoke-AumReport.ps1"),
                                 "-InputFile", str(request)], env=env, capture_output=True, text=True, timeout=30)
        assert result.returncode == 0, result.stderr
        output = json.loads(result.stdout)
        assert "--subscription " + subscription in output["arguments"]
        assert output["setExit"] == 0
    finally:
        shutil.rmtree(folder)
