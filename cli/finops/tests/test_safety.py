import pytest

from claude_finops.engine import Engine
from claude_finops.fake import FakeBackend
from claude_finops.errors import FinOpsError
from claude_finops.rules import apply_state
from claude_finops.output import chargeback_csv, safe_text


def test_apply_never_accepts_previous_execution():
    status = dict(configured=True, last_request=dict(requested_at="2026-09-24T12:00:00Z", execution="old"),
                  executions=[dict(name="old", status="Succeeded", ended_at="2026-09-24T12:01:00Z")])
    assert apply_state(status, "2026-09-24T13:00:00Z").startswith("Pending")


def test_apply_compares_instants_not_string_offsets():
    status = dict(configured=True, last_request=dict(requested_at="2026-09-24T12:00:00+00:00", execution="new"),
                  executions=[dict(name="new", status="Succeeded", ended_at="2026-09-24T12:01:00Z")])
    assert apply_state(status, "2026-09-24T11:59:59.900Z").startswith("Apply succeeded")


def test_full_chargeback_is_not_top_100_ranking():
    backend = FakeBackend()
    backend.catalog["organizations"] = [dict(id=f"unit-{i}", name=f"Unit {i}") for i in range(105)]
    rows = Engine(backend, "2026-09").chargeback()["items"]
    assert len(rows) == 105
    assert sum(call[0] == "overview" for call in backend.reads) == 105


def test_unsafe_group_never_reaches_script():
    backend = FakeBackend()
    with pytest.raises(FinOpsError):
        Engine(backend, "2026-09").catalog_change("team", "sales-emea", group="sales & command", apply=True)
    assert backend.writes == []


def test_csv_formula_and_terminal_escape_are_inert():
    assert "'=COMMAND" in chargeback_csv([{"name": "=COMMAND"}], "2026-09")
    assert "\x1b" not in safe_text("\x1b]52;clipboard")


def test_direct_read_only_role_is_explicit_not_claimed_owner():
    from claude_finops.direct import DirectBackend
    from claude_finops.config import Config
    from unittest.mock import patch
    import json
    backend = DirectBackend(Config(backend="direct", resource_group="rg-contoso", apim_name="apim-contoso"))
    with patch("claude_finops.direct.az", return_value=json.dumps({"user": {"name": "reader@contoso.com"}})):
        identity = backend.read("whoami")
    assert identity["method"] == "azure-rbac"
    assert "Azure RBAC" in identity["scope"]
    assert identity["role"] == "member"


def test_ascii_filter_preserves_cell_width():
    from rich.segment import Segment
    from textual.color import Color
    from claude_finops.accessibility import AsciiFilter
    rows = AsciiFilter().apply([Segment("─│█→界")], Color.parse("black"))
    assert "".join(segment.text for segment in rows).isascii()
    assert sum(segment.cell_length for segment in rows) == 6
