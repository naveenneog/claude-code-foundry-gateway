import json

import httpx
import pytest
from typer.testing import CliRunner

from claude_finops.cli import app
from claude_finops.engine import Engine
from claude_finops.errors import FinOpsError
from claude_finops.fake import FakeBackend


OID = "00000000-0000-0000-0000-000000000001"


class UsdFake(FakeBackend):
    def __init__(self):
        super().__init__()
        self.writes = []
        self.usd = {
            "schema_version": 1,
            "currency": "USD",
            "revision": "revision-1",
            "price_book_date": "2026-09-16",
            "items": [
                {
                    "scope_type": "organization",
                    "scope_id": "sales",
                    "amount_usd": "0.020000000",
                    "period": "month",
                    "price_book_date": "2026-09-16",
                    "writable": True,
                }
            ],
        }
        self.status = {
            "enabled": True,
            "fresh": True,
            "reconciled_at": "2026-09-26T00:00:00Z",
            "valid_until": "2026-09-26T00:15:00Z",
            "reconcile_interval_seconds": 300,
            "state_max_age_seconds": 900,
            "items": {
                "organization:sales": {
                    "scope_type": "organization",
                    "scope_id": "sales",
                    "period": "month",
                    "period_start": "2026-09-01T00:00:00Z",
                    "period_end": "2026-10-01T00:00:00Z",
                    "budget_usd": "0.020000000",
                    "effective_budget_usd": "0.020000000",
                    "spent_usd": "0.0364984",
                    "enforcement": "strict",
                    "price_book_date": "2026-09-16",
                    "status": "stop",
                    "exact": True,
                    "cache_read_known": True,
                    "cache_write_known": True,
                    "unpriced_models": [],
                    "categories": {
                        "input_usd": "0.004",
                        "output_usd": "0.005",
                        "cache_read_usd": "0.002",
                        "cache_write_5m_usd": "0.025",
                        "cache_write_1h_usd": "0.0004984",
                    },
                }
            },
        }

    def read(self, resource, **params):
        if resource == "capabilities":
            result = super().read(resource, **params)
            result["features"]["usd_budgets"] = {
                "enabled": True,
                "actions": ["read", "write", "reconcile", "price_book_write"],
            }
            return result
        if resource == "usd_budgets":
            return self.usd
        if resource == "usd_status":
            return self.status
        if resource == "usd_price_book":
            return {
                "revision": "revision-1",
                "price_book": {
                    "date": "2026-09-16",
                    "models": {"claude-sonnet-5": {"inputPerM": "2", "outputPerM": "10"}},
                },
            }
        return super().read(resource, **params)

    def write(self, resource, body=None, **params):
        self.writes.append((resource, body, params))
        if resource == "usd_budget":
            return {
                "audit_id": "audit-1",
                "revision": "revision-2",
                "result": {
                    "scope_type": params["scope_type"],
                    "scope_id": params["scope_id"],
                    "amount_usd": body["amount_usd"],
                    "period": body["period"],
                    "price_book_date": "2026-09-16",
                },
            }
        if resource == "usd_budget_remove":
            return {"audit_id": "audit-2", "revision": "revision-3", "result": {"cleared": True}}
        if resource == "usd_reconcile":
            return self.status
        if resource == "usd_price_book":
            return {"audit_id": "audit-3", "revision": "revision-4", "price_book": body["price_book"]}
        return super().write(resource, body, **params)


def test_usd_engine_preserves_decimal_text_and_saved_pending_message():
    backend = UsdFake()
    engine = Engine(backend, "2026-09")
    plan = engine.usd_budget_change("unit", "sales", "0.000000001", period="month", apply=True)
    assert plan["after"] == "0.000000001"
    assert plan["effect"] == "Saved; awaiting reconciliation."
    assert backend.writes[-1][1]["amount_usd"] == "0.000000001"
    with pytest.raises(FinOpsError, match="up to 9"):
        engine.usd_budget_change("unit", "sales", "0.0000000001")


def test_usd_clear_requires_typed_confirmation_and_reconcile_is_capability_gated():
    backend = UsdFake()
    engine = Engine(backend, "2026-09")
    with pytest.raises(FinOpsError, match="--confirm sales"):
        engine.usd_budget_change("unit", "sales", remove=True, apply=True)
    assert engine.usd_budget_change("unit", "sales", remove=True, apply=True, confirm="sales")["result"]["result"]["cleared"]
    assert engine.usd_reconcile(apply=False)["preview"]
    assert not engine.usd_reconcile(apply=True)["preview"]


def test_usd_status_keeps_null_spend_unpriced_not_zero():
    backend = UsdFake()
    backend.status["items"]["organization:sales"]["spent_usd"] = None
    backend.status["items"]["organization:sales"]["status"] = "unpriced"
    result = Engine(backend, "2026-09").usd_status()
    assert result["items"]["organization:sales"]["spent_usd"] is None
    assert result["items"]["organization:sales"]["status"] == "unpriced"


def test_usd_commands_are_preview_first_and_apply_never_falls_back_to_token_budget(monkeypatch):
    from claude_finops import cli

    backend = UsdFake()
    monkeypatch.setattr(cli, "connect", lambda settings: backend)
    runner = CliRunner()
    preview = runner.invoke(app, ["--backend", "fake", "--json", "usd", "set", "unit", "sales", "0"])
    assert preview.exit_code == 0, preview.output
    payload = json.loads(preview.output)
    assert payload["preview"] is True
    assert payload["after"] == "0"
    assert backend.writes == []
    applied = runner.invoke(app, ["--backend", "fake", "--json", "usd", "set", "unit", "sales", "0", "--apply"])
    assert applied.exit_code == 0, applied.output
    assert backend.writes[-1][0] == "usd_budget"
    assert "Saved; awaiting reconciliation" in applied.output


def test_aum_service_usd_contract_uses_capabilities_and_if_match():
    from claude_finops.aum_service import AumServiceBackend
    from claude_finops.config import Config

    calls = []

    def respond(request):
        calls.append(request)
        if request.url.path == "/api/v1/me":
            return httpx.Response(200, json={"id": OID, "role": "owner", "email": "admin@contoso.com", "manager_scope": None})
        if request.url.path == "/api/v1/capabilities":
            return httpx.Response(
                200,
                json={
                    "schema_version": 1,
                    "capabilities": {
                        "usage_read": True,
                        "budgets_read": True,
                        "usd_budgets_read": True,
                        "usd_budget_write": True,
                        "usd_budget_reconcile": True,
                        "usd_price_book_write": True,
                    },
                },
            )
        if request.url.path == "/api/v1/usd-budgets" and request.method == "GET":
            return httpx.Response(200, json={"revision": "revision-1", "price_book_date": "2026-09-16", "items": []}, headers={"ETag": '"revision-1"'})
        if request.url.path == "/api/v1/catalog":
            return httpx.Response(200, json={"revision": "revision-1", "organizations": [{"id": "sales", "name": "Sales"}], "departments": []})
        if request.url.path == "/api/v1/budgets":
            return httpx.Response(200, json={"revision": "revision-1", "items": [{"scope_type": "organization", "scope_id": "sales", "period": "month", "writable": True}]})
        if request.url.path == "/api/v1/usd-budgets/organization/sales" and request.method == "PUT":
            return httpx.Response(200, json={"revision": "revision-2", "audit_id": "audit-1", "result": {"amount_usd": "1.23"}})
        if request.url.path == "/api/v1/usd-budget-reconcile" and request.method == "POST":
            return httpx.Response(200, json={"enabled": True, "items": {}})
        return httpx.Response(404)

    backend = AumServiceBackend(
        Config(backend="aum-service", url="https://aum.contoso.com", scope="api://example/AUM.Access"),
        token_provider=lambda: "test-only",
        transport=httpx.MockTransport(respond),
    )
    engine = Engine(backend, "2026-09")
    engine.change_reason = "Approved USD capacity"
    assert engine.has_feature("usd_budgets", "write")
    engine.read("usd_budgets")
    engine.usd_budget_change("unit", "sales", "1.23", apply=True)
    write = [call for call in calls if call.method == "PUT"][-1]
    assert write.headers["If-Match"] == '"revision-1"'
    assert json.loads(write.content) == {
        "amount_usd": "1.23",
        "period": "month",
        "price_book_date": "2026-09-16",
        "reason": "Approved USD capacity",
    }


def test_turnstile_refuses_usd_writes_with_authority_reason():
    from claude_finops.turnstile import TurnstileBackend
    from claude_finops.config import Config

    backend = TurnstileBackend(Config(backend="turnstile", url="https://turnstile.contoso.com"), token_provider=lambda: "test")
    with pytest.raises(FinOpsError, match="Turnstile does not expose a USD budget writer"):
        backend.write("usd_budget", {"amount_usd": "1", "period": "month"}, scope_type="organization", scope_id="sales")
