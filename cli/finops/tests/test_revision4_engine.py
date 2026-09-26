from datetime import datetime, timezone
import pytest

from claude_finops.engine import Engine
from claude_finops.errors import FinOpsError
from claude_finops.fake import FakeBackend


def test_mode_change_preserves_catalog_and_validates_allowance():
    backend = FakeBackend()
    engine = Engine(backend, "2026-09")
    original = engine.read("catalog")
    plan = engine.mode_change("team", "sales-emea", "allowance", allowance=10)
    assert plan["preview"]
    assert not backend.writes
    engine.mode_change("team", "sales-emea", "allowance", allowance=10, apply=True)
    saved = engine.read("catalog")
    assert len(saved["departments"]) == len(original["departments"])
    row = next(row for row in saved["departments"] if row["id"] == "sales-emea")
    assert row["attributes"]["enforcement"] == "allowance"
    assert row["attributes"]["allowance_percent"] == 10
    with pytest.raises(FinOpsError):
        engine.mode_change("team", "sales-emea", "notify", allowance=10)


def test_mode_writes_remain_owner_only():
    with pytest.raises(FinOpsError):
        Engine(FakeBackend(role="member"), "2026-09").mode_change("team", "sales-emea", "notify", apply=True)


def test_unadvertised_future_feature_never_calls_its_endpoint():
    backend = FakeBackend()
    engine = Engine(backend, "2026-09")
    with pytest.raises(FinOpsError, match="budget-requests"):
        engine.request_budget("team", "sales-emea", "10M", "capacity")
    assert not backend.writes


def test_advertised_approval_request_preview_apply_and_self_approval():
    backend = FakeBackend(features={"approvals": True})
    engine = Engine(backend, "2026-09")
    preview = engine.request_budget("team", "sales-emea", "10M", "capacity")
    assert preview["preview"] and not backend.writes
    saved = engine.request_budget("team", "sales-emea", "10M", "capacity", apply=True)
    record = saved["result"]
    with pytest.raises(FinOpsError, match="own"):
        engine.decide_request(record["id"], "approve", "approved", apply=True)
    backend.actor_id = "contoso-reviewer"
    engine.read("whoami")
    result = engine.decide_request(record["id"], "approve", "approved", apply=True)
    assert result["result"]["state"] == "approved"


def test_boost_expiry_and_headroom_are_checked():
    backend = FakeBackend(features={"boosts": True})
    engine = Engine(backend, "2026-09")
    with pytest.raises(FinOpsError, match="future"):
        engine.boost("dev-001@contoso.com", "sales-emea", "1k", "2001-01-01", "test")
    with pytest.raises(FinOpsError, match="headroom"):
        engine.boost("dev-001@contoso.com", "sales-emea", "2M", "2099-01-01", "test")
    plan = engine.boost("dev-001@contoso.com", "sales-emea", "1k", "2099-01-01", "test")
    assert plan["after"]["extra_tokens"] == 1000


def test_period_comparison_keeps_each_window_and_unknowns():
    engine = Engine(FakeBackend(), "2026-09")
    result = engine.compare_trends("2026-08", interval="day")
    assert result["current_period"] == "2026-09"
    assert result["comparison_period"] == "2026-08"
    assert result["current"]["points"]


def test_assistant_and_chart_pin_share_exact_server_chart():
    backend = FakeBackend(features={"assistant": True})
    engine = Engine(backend, "2026-09")
    reply = engine.ask("Show token usage")
    chart = reply["charts"][0]
    plan = engine.pin_chart(reply, chart["id"], "Usage")
    assert plan["after"]["chart"] == chart
    assert plan["preview"]


def test_anomaly_disposition_is_capability_gated():
    engine = Engine(FakeBackend(features={"anomaly_dispositions": True}), "2026-09")
    plan = engine.disposition("contoso-finding-1", "false_positive", "Known batch")
    assert plan["after"]["status"] == "false_positive"
