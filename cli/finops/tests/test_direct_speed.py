import json
import threading
from concurrent.futures import ThreadPoolExecutor
from contextvars import copy_context
from copy import deepcopy
from datetime import datetime, timezone
from pathlib import Path
import subprocess

import pytest

from claude_finops.config import Config
from claude_finops.direct import DirectBackend
from claude_finops.engine import Engine
from claude_finops.errors import FinOpsError
from aum_clock import PINNED_MONTH


SUB = "00000000-0000-0000-0000-000000000071"
MONTH = PINNED_MONTH


def direct():
    backend = DirectBackend(Config(backend="direct", subscription=SUB, resource_group="rg-contoso",
                                   apim_name="apim-contoso", workspace=SUB))
    calls = []
    state = dict(catalog={"organizations": [{"id": "sales", "name": "Sales"}], "departments": []},
                 tiers=[{"id": "standard", "tokens_per_day": 1000}],
                 registry=[{"Id": "sales", "TokensPerMonth": 1000}], parents={},
                 quota_org=5000, authority="Gateway", usd_supported=True,
                 modes_supported=True, person_budgets_supported=True)
    usd = dict(usd_budgets={"items": [], "price_book_date": "2026-09-16"},
               usd_status={"items": {}, "enabled": True, "fresh": False},
               usd_price_book={"price_book": {"date": "2026-09-16", "models": {}}})

    def bridge(action, body=None, **params):
        calls.append((action, body, params))
        if action == "read":
            return deepcopy(dict(state, reads=usd))
        if action in usd:
            return deepcopy(usd[action])
        if action == "budget":
            state["registry"][0]["TokensPerMonth"] = body["token_limit"]
            return {"verified": True}
        raise AssertionError(action)

    def query(kql):
        if "by business_unit" in kql:
            return [{"business_unit": "sales", "used_tokens": 42}]
        if "by bucket_start" in kql:
            return []
        if "by id=" in kql:
            return []
        return [{"total_tokens": 42, "total_requests": 2, "estimated_cost": None, "unknown_prices": 1}]

    backend._bridge = bridge
    backend.query = query
    backend._az = lambda *args: json.dumps(
        dict(id=SUB, user={"name": "admin@contoso.com"}, tenantId=SUB) if args[:2] == ("account", "show")
        else {"value": [{"actions": ["*"], "notActions": []}]})
    return backend, calls, state, usd


def test_status_uses_one_snapshot_for_tokens_capabilities_and_usd_and_refreshes_next_call():
    backend, calls, state, _ = direct()
    engine = Engine(backend, MONTH)
    result = engine.status()
    assert result["overview"]["totals"]["total_tokens"] == 42
    assert result["overview"]["totals"]["estimated_cost"] is None
    assert result["budgets"]["items"][0]["remaining_tokens"] == 958
    assert [call[0] for call in calls] == ["read"]
    assert calls[0][2]["snapshot"] is True
    state["registry"][0]["TokensPerMonth"] = 2000
    assert engine.status()["budgets"]["items"][0]["remaining_tokens"] == 1958
    assert [call[0] for call in calls] == ["read", "read"]


def test_concurrent_named_value_views_share_one_read_cycle_without_mutating_each_other():
    backend, calls, _, _ = direct()
    with backend.read_cycle():
        with ThreadPoolExecutor(max_workers=4) as pool:
            jobs = [pool.submit(copy_context().run, backend.read, resource, month=MONTH)
                    for resource in ("catalog", "tiers", "usd_budgets", "usd_status")]
            results = [job.result(timeout=5) for job in jobs]
        results[0]["organizations"].clear()
        assert backend.read("catalog")["organizations"][0]["id"] == "sales"
    assert [call[0] for call in calls] == ["read"]
    backend.read("catalog")
    assert [call[0] for call in calls] == ["read", "read"]


@pytest.mark.parametrize("failed", [False, True])
def test_every_write_invalidates_snapshot_even_when_its_outcome_is_uncertain(failed):
    backend, calls, state, _ = direct()
    original = backend._bridge

    def bridge(action, body=None, **params):
        if action == "budget" and failed:
            state["registry"][0]["TokensPerMonth"] = 2000
            calls.append((action, body, params))
            raise FinOpsError("Uncertain write; inspect current state.", 7)
        return original(action, body, **params)

    backend._bridge = bridge
    with backend.read_cycle():
        assert backend.read("budgets", month=MONTH)["items"][0]["token_limit"] == 1000
        if failed:
            with pytest.raises(FinOpsError, match="Uncertain write"):
                backend.write("budget", {"token_limit": 2000}, month=MONTH,
                              scope_type="organization", scope_id="sales")
        else:
            backend.write("budget", {"token_limit": 2000}, month=MONTH,
                          scope_type="organization", scope_id="sales")
        assert backend.read("budgets", month=MONTH)["items"][0]["token_limit"] == 2000
    assert [call[0] for call in calls] == ["read", "budget", "read"]


@pytest.mark.parametrize("resource,params", [
    ("overview", {}), ("budgets", {}), ("catalog", {}), ("tiers", {}),
    ("distribution", {"dimension": "model"}), ("trends", {"interval": "day"}),
])
def test_direct_read_only_facts_are_authorized_by_azure_not_blocked_by_identity_label(resource, params):
    backend, _, _, _ = direct()
    original = backend._az
    calls = []

    def account_only(*args):
        assert args[:2] == ("account", "show"), "Read-only facts must not wait for the RBAC permission label."
        calls.append(args)
        return original(*args)

    backend._az = account_only
    assert isinstance(Engine(backend, MONTH).read(resource, **params), dict)
    assert calls == [("account", "show", "-o", "json")]


def test_budget_usage_query_starts_while_gateway_read_is_pending():
    backend, _, _, _ = direct()
    original = backend._bridge
    querying = threading.Event()

    def bridge(action, body=None, **params):
        assert querying.wait(timeout=3), "Independent budget usage must overlap named values."
        return original(action, body, **params)

    backend._bridge = bridge
    backend.query = lambda _: querying.set() or []
    assert Engine(backend, MONTH).read("budgets")["items"][0]["token_limit"] == 1000


def test_status_independent_usage_queries_overlap():
    backend, _, _, _ = direct()
    barrier = threading.Barrier(2)

    def query(kql):
        barrier.wait(timeout=3)
        return [{"business_unit": "sales", "used_tokens": 42}] if "by business_unit" in kql else [
            {"total_tokens": 42, "total_requests": 2, "estimated_cost": None}]

    backend.query = query
    assert Engine(backend, MONTH).status()["overview"]["totals"]["total_tokens"] == 42


def test_legacy_direct_profile_still_filters_ledger_to_the_selected_gateway():
    backend, _, _, _ = direct()
    backend.config.subscription = ""
    queries, accounts = [], []
    backend._az = lambda *args: accounts.append(args) or json.dumps(
        {"id": SUB, "tenantId": SUB, "user": {"name": "reader@contoso.com"}})
    backend.query = lambda kql: queries.append(kql) or []
    Engine(backend, MONTH).read("requests", limit=10)
    assert f'| where _ResourceId =~ "/subscriptions/{SUB}/resourceGroups/rg-contoso/' in queries[0]
    assert accounts == [("account", "show", "-o", "json")]


def test_missing_subscription_never_returns_unscoped_workspace_ledger():
    backend, _, _, _ = direct()
    backend.config.subscription = ""
    backend._az = lambda *args: "{}"
    queries = []
    backend.query = lambda kql: queries.append(kql) or []
    with pytest.raises(FinOpsError, match="subscription"):
        Engine(backend, MONTH).read("requests", limit=10)
    assert not queries


def test_snapshot_read_errors_remain_visible_and_do_not_turn_into_empty_dollar_state():
    backend, _, _, usd = direct()
    usd["usd_status"] = {"error": "USD state unreadable", "exit_code": 7}
    engine = Engine(backend, MONTH)
    with backend.read_cycle():
        with pytest.raises(FinOpsError, match="USD state unreadable"):
            engine.read("usd_status")
    status = engine.status()
    assert status["usd_error"] == "USD state unreadable"
    assert status["budgets"]["items"][0]["token_limit"] == 1000


@pytest.mark.parametrize("host", ["pwsh", "powershell"])
def test_snapshot_bridge_contract_runs_on_both_powershell_hosts(host):
    root = Path(__file__).resolve().parents[3]
    result = subprocess.run([host, "-NoProfile", "-File", str(root / "tests" / "Test-AumReadBatch.ps1")],
                            capture_output=True, text=True, encoding="utf-8", timeout=60)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "14/14 AUM batch read assertions passed" in result.stdout
