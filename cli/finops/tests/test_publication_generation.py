import asyncio
from concurrent.futures import ThreadPoolExecutor
from copy import deepcopy
import json

import httpx
import pytest

from claude_finops.config import Config
from claude_finops.engine import Engine
from claude_finops.errors import FinOpsError
from claude_finops.turnstile import TurnstileBackend
from test_principal_tokens import estate, a_only_snapshot


@pytest.fixture
def http_estate():
    principal, calls = ["a"], []

    def respond(request):
        calls.append((principal[0], request.url.path))
        if request.url.path.endswith("/auth/me"):
            return httpx.Response(200, json={
                "id": principal[0], "email": principal[0] + "@contoso.com",
                "role": "owner" if principal[0] == "a" else "member",
                "manager_scope": None if principal[0] == "a" else {
                    "organizations": [], "departments": [{"id": "only-b", "parent_id": "b"}],
                    "writable_department_ids": []}})
        if request.url.path.endswith("/trends"):
            return httpx.Response(200, json={"points": [], "principal": principal[0], "source": principal[0] + "-only"})
        if request.url.path.endswith("/finops/capabilities"):
            return httpx.Response(200, json={"schema_version": 1, "features": {"private": principal[0]}})
        return httpx.Response(404)

    backend = TurnstileBackend(Config(backend="turnstile", url="https://turnstile.contoso.com",
                                     scope="api://contoso/Turnstile.Manage"),
                               token_provider=lambda: "token-" + principal[0],
                               transport=httpx.MockTransport(respond))
    engine = Engine(backend, "2026-09")
    engine.read("whoami")
    yield engine, principal, calls
    backend.close()


def verify_b(engine, principal):
    principal[0] = "b"
    with ThreadPoolExecutor(max_workers=1) as pool:
        assert pool.submit(engine.read, "whoami").result(timeout=5)["id"] == "b"


def test_http_completed_current_trend_cannot_publish_with_b_comparison(http_estate):
    engine, principal, calls = http_estate
    original = engine.read

    def pause_assembly(resource, **params):
        result = original(resource, **params)
        if resource == "trends":
            assert result["source"] == "a-only"
            verify_b(engine, principal)
        return result

    engine.read = pause_assembly
    with pytest.raises(FinOpsError, match="sign-in changed") as stale:
        engine.compare_trends("2026-08", organization_id="only-a")
    assert stale.value.code == 3
    assert engine._identity["id"] == "b"
    with pytest.raises(FinOpsError) as denied:
        original("trends", organization_id="only-a")
    assert denied.value.code == 4
    assert [person for person, route in calls if route.endswith("/trends")] == ["a"]


def test_http_cycle_exit_checks_sources_completed_before_identity_change(http_estate):
    engine, principal, _ = http_estate
    with pytest.raises(FinOpsError, match="sign-in changed") as stale:
        with engine.backend.read_cycle():
            result = engine.read("trends")
            verify_b(engine, principal)
            assert result["source"] == "a-only"
    assert stale.value.code == 3


def test_http_unchanged_identity_preserves_a_completed_read_cycle(http_estate):
    engine, _, _ = http_estate
    with engine.backend.read_cycle():
        assert engine.read("trends")["source"] == "a-only"
        assert engine.read("whoami")["id"] == "a"
        assert engine.read("trends")["source"] == "a-only"
