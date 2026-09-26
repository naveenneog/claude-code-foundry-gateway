import json
from pathlib import Path
from uuid import uuid4

import pytest
from typer.testing import CliRunner

from claude_finops.bulk import budget_csv_plan
from claude_finops.cli import app
from claude_finops.config import Config
from claude_finops.engine import Engine
from claude_finops.errors import FinOpsError
from claude_finops.fake import FakeBackend
from claude_finops.reporting import report_plan


def test_bulk_csv_checks_total_parent_allocation_before_writing():
    path = Path(__file__).resolve().parents[3] / ".aum-evidence" / f"batch-{uuid4().hex}.csv"
    path.parent.mkdir(exist_ok=True)
    try:
        path.write_text("team,person,tokens\nsales-emea,dev-001@contoso.com,200000\nsales-emea,dev-002@contoso.com,200000\n", encoding="utf-8")
        backend = FakeBackend()
        plan = budget_csv_plan(Engine(backend, "2026-09"), path)
        assert plan["count"] == 2 and not backend.writes
        budget_csv_plan(Engine(backend, "2026-09"), path, apply=True)
        assert backend.writes[-1][0] == "bulk_budget"
        path.write_text("team,person,tokens\nsales-emea,dev-001@contoso.com,9000000\n", encoding="utf-8")
        before = len(backend.writes)
        with pytest.raises(FinOpsError, match="headroom"):
            budget_csv_plan(Engine(backend, "2026-09"), path, apply=True)
        assert len(backend.writes) == before
    finally:
        path.unlink(missing_ok=True)


@pytest.mark.parametrize("arguments", [
    ["mode", "show"],
    ["mode", "set", "team", "sales-emea", "notify"],
    ["trends", "show", "--compare", "2026-08"],
    ["session", "show"],
    ["session", "signout", "--what-if"],
    ["report", "generate", "--what-if"],
    ["people", "show", "dev-001@contoso.com", "--team", "sales-emea"],
])
def test_revision_four_commands_are_scriptable(arguments):
    result = CliRunner().invoke(app, [*arguments, "--backend", "fake", "--month", "2026-09", "--json"])
    assert result.exit_code == 0, result.output
    assert isinstance(json.loads(result.output), dict)


def test_p50_adapter_is_ready_without_claiming_missing_generator_ran():
    result = report_plan(Engine(FakeBackend(), "2026-09"), Config(backend="fake"))
    assert result["preview"]
    if not result["available"]:
        assert "New-ClaudeChargebackReport.ps1" in result["waiting_on"]
