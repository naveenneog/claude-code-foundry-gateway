from pathlib import Path

import pytest

from claude_finops.config import Config
from claude_finops.direct import DirectBackend
from claude_finops.errors import FinOpsError


def test_direct_uses_repository_query_and_bounded_server_filter():
    captured = []
    backend = DirectBackend(Config(backend="direct", resource_group="rg-contoso", apim_name="apim-contoso"))
    backend.query = lambda kql: captured.append(kql) or []
    backend.read("people", month="2026-09", department_id="sales-emea", query="dev", limit=50, offset=50)
    assert "ApiManagementGatewayLlmLog" in captured[0]
    assert "2026-09-01" in captured[0]
    assert 'contains "dev"' in captured[0]
    assert "row_number" in captured[0]
    assert "take 50" in captured[0]


def test_direct_requests_preserve_unknown_cache_and_cost():
    backend = DirectBackend(Config(backend="direct", resource_group="rg-contoso", apim_name="apim-contoso"))
    backend.query = lambda _: [dict(request_id="example", total_tokens=1500, cache_read_tokens=None)]
    row = backend.read("requests", month="2026-09", limit=20)["items"][0]
    assert row["cache_read_tokens"] is None
    assert row["estimated_cost"] is None


def test_direct_historical_writes_are_refused():
    backend = DirectBackend(Config(backend="direct", resource_group="rg-contoso", apim_name="apim-contoso"))
    with pytest.raises(FinOpsError, match="current month"):
        backend.write("budget", {"token_limit": 100}, month="2001-01", scope_type="department", scope_id="sales-emea")


def test_no_duplicate_registry_format():
    root = Path(__file__).resolve().parents[3]
    bridge = (root / "scripts" / "Invoke-ClaudeFinOps.ps1").read_text(encoding="utf-8-sig")
    assert "ConvertFrom-ClaudeBuRegistry" in bridge
    assert "ConvertTo-ClaudeBuRegistry" in bridge
    assert "Set-ClaudeTier.ps1" in bridge

