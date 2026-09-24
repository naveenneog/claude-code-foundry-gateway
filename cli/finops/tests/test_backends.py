import json

import httpx
import pytest

from claude_finops.config import Config, parse_integration
from claude_finops.errors import FinOpsError
from claude_finops.fake import FakeBackend
from claude_finops.turnstile import TurnstileBackend
from claude_finops.engine import Engine


def test_integration_quote_free():
    settings = parse_integration("version=1;url=https://finops.contoso.com;scope=api://example/Turnstile.Manage")
    assert settings["url"] == "https://finops.contoso.com"
    with pytest.raises(FinOpsError):
        parse_integration("version=99;url=https://finops.contoso.com")


@pytest.mark.parametrize("url", ["http://evil.com", "https://user:pass@contoso.com", "https://contoso.com/path", "https://contoso.com?token=x"])
def test_origin_validation(url):
    with pytest.raises(FinOpsError):
        Config(url=url, scope="api://example/Turnstile.Manage").validate()


def test_http_contract_and_no_write_on_preview():
    seen = []
    fake = FakeBackend()

    def respond(request):
        seen.append(request)
        path = request.url.path
        if path.endswith("/auth/me"):
            result = fake.read("whoami")
        elif path.endswith("/budgets"):
            result = fake.read("budgets", month="2026-09")
        else:
            result = {}
        return httpx.Response(200, json=result)

    backend = TurnstileBackend(Config(url="https://finops.contoso.com", scope="api://example/scope"),
                               token_provider=lambda: "test-only", transport=httpx.MockTransport(respond))
    result = Engine(backend, "2026-09").budget_change("team", "sales-emea", "9M")
    assert result["preview"] is True
    assert all(request.method == "GET" for request in seen)
    assert seen[-1].url.params["period"] == "2026-09"


def test_server_search_and_window_params():
    seen = []

    def respond(request):
        seen.append(request)
        return httpx.Response(200, json={"items": []})

    backend = TurnstileBackend(Config(url="https://finops.contoso.com", scope="api://example/scope"),
                               token_provider=lambda: "test-only", transport=httpx.MockTransport(respond))
    backend.read("people", month="2026-09", department_id="sales-emea", query="dev", offset=50, limit=50)
    assert dict(seen[-1].url.params) == dict(period="2026-09", department_id="sales-emea",
                                           query="dev", offset="50", limit="50")
    backend.read("requests", month="2026-09", limit=50, model_id="claude-sonnet-5")
    assert seen[-1].url.params["from"] == "2026-09-01T00:00:00Z"
    assert seen[-1].url.params["to"] == "2026-10-01T00:00:00Z"


def test_write_denied_to_member():
    backend = FakeBackend(role="member")
    with pytest.raises(FinOpsError, match="Read-only"):
        Engine(backend, "2026-09").budget_change("team", "sales-emea", "9M", apply=True)
    assert backend.writes == []


def test_write_exact_and_apply_status():
    backend = FakeBackend()
    engine = Engine(backend, "2026-09")
    result = engine.budget_change("team", "sales-emea", "9M", apply=True)
    assert not result["preview"]
    assert backend.writes[0][0] == "budget"
    assert backend.writes[0][2]["token_limit"] == 9000000
    assert engine.wait_for_apply(result["requested_at"], timeout=1, interval=0)["state"].startswith("Apply succeeded")


def test_errors_cannot_echo_response_secrets():
    backend = TurnstileBackend(Config(url="https://finops.contoso.com", scope="api://example/scope"),
                               token_provider=lambda: "test-only",
                               transport=httpx.MockTransport(lambda _: httpx.Response(403, text="secret-body")))
    with pytest.raises(FinOpsError) as caught:
        backend.read("whoami")
    assert "secret-body" not in str(caught.value)
    assert caught.value.code == 4


def test_token_refresh_only_for_reads():
    calls = []
    backend = TurnstileBackend(Config(url="https://finops.contoso.com", scope="api://example/scope"),
                               token_provider=lambda: calls.append("token") or "test-only",
                               transport=httpx.MockTransport(lambda _: httpx.Response(401)))
    with pytest.raises(FinOpsError):
        backend.read("whoami")
    assert len(calls) == 2


def test_lowering_below_usage_requires_confirmation():
    engine = Engine(FakeBackend(), "2026-09")
    preview = engine.budget_change("team", "sales-emea", "1M")
    assert preview["confirmation_required"]
    with pytest.raises(FinOpsError, match="confirmation"):
        engine.budget_change("team", "sales-emea", "1M", apply=True)


def test_bounded_people_lookup():
    backend = FakeBackend()
    result = Engine(backend, "2026-09").lookup("dev", department_id="sales-emea")
    assert any(row["kind"] == "person" for row in result)
    assert all(call[1].get("limit", 20) <= 50 for call in backend.reads)


def test_fake_budget_save_recomputes_remaining():
    backend = FakeBackend()
    engine = Engine(backend, "2026-09")
    engine.budget_change("team", "sales-emea", "9M", apply=True)
    row = next(row for row in engine.read("budgets")["items"] if row["scope_id"] == "sales-emea")
    assert row["remaining_tokens"] == 2900000


def test_moving_team_cannot_overallocate_parent():
    backend = FakeBackend()
    backend.rows[-1]["token_limit"] = 1000
    with pytest.raises(FinOpsError, match="headroom"):
        Engine(backend, "2026-09").catalog_change("team", "sales-emea", parent="engineering", apply=True)
    assert not backend.writes
