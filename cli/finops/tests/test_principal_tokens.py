import base64
from concurrent.futures import ThreadPoolExecutor
from copy import deepcopy
import json
import os
import threading
import time

import httpx
import pytest

from claude_finops import config
from claude_finops.direct import DirectBackend
from claude_finops.engine import Engine
from claude_finops.errors import FinOpsError


SUB = "00000000-0000-0000-0000-000000000071"
RESOURCE = "https://api.loganalytics.io"


def token(principal, session="one"):
    claims = json.dumps({"exp": time.time() + 3600, "principal": principal, "session": session})
    return "header." + base64.urlsafe_b64encode(claims.encode()).decode().rstrip("=") + ".signature"


@pytest.fixture
def estate(monkeypatch):
    config.clear_resource_tokens()
    state = {"principal": "a@contoso.com", "account": True}
    acquisitions, requests, accounts = [], [], []

    def az(*args, **kwargs):
        if args[:2] == ("account", "show"):
            accounts.append(state["principal"])
            if not state["account"]:
                raise FinOpsError("Azure sign-in unavailable", 3)
            return json.dumps({"id": SUB, "tenantId": SUB, "user": {"name": state["principal"], "type": "user"}})
        if args[:2] == ("account", "get-access-token"):
            value = token(state["principal"], os.environ.get("AZURE_CONFIG_DIR", "one"))
            acquisitions.append(value)
            return value
        assert args[:1] == ("rest",)
        return json.dumps({"value": [{"actions": ["*"], "notActions": []}]})

    def respond(request):
        value = request.headers["Authorization"].removeprefix("Bearer ")
        requests.append(value)
        payload = value.split(".")[1]
        principal = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))["principal"]
        return httpx.Response(200, json={"tables": [{"columns": [{"name": "principal"}], "rows": [[principal]]}]})

    original = httpx.Client
    monkeypatch.setattr("claude_finops.direct.az", az)
    monkeypatch.setattr(config, "az", az)
    monkeypatch.setattr(httpx, "Client", lambda *args, **kwargs:
                        original(*args, transport=kwargs.pop("transport", httpx.MockTransport(respond)), **kwargs))
    backend = DirectBackend(config.Config(backend="direct", subscription=SUB, resource_group="rg-contoso",
                                         apim_name="apim-contoso", workspace=SUB, tenant_id=SUB))
    yield backend, state, acquisitions, requests, accounts
    backend.close()
    config.clear_resource_tokens()


def test_verified_principal_change_never_reuses_the_previous_persons_bearer(estate):
    backend, state, acquired, requests, _ = estate
    engine = Engine(backend, "2026-09")
    assert engine.read("whoami")["email"] == "a@contoso.com"
    assert engine.read("overview")["totals"]["principal"] == "a@contoso.com"
    state["principal"] = "b@contoso.com"
    assert engine.read("whoami")["email"] == "b@contoso.com"
    assert engine.read("overview")["totals"]["principal"] == "b@contoso.com"
    assert len(acquired) == 2 and requests[0] != requests[1]


def test_independent_read_verifies_principal_before_using_any_cached_credential(estate):
    backend, state, acquired, requests, accounts = estate
    engine = Engine(backend, "2026-09")
    assert engine.read("overview")["totals"]["principal"] == "a@contoso.com"
    state["principal"] = "b@contoso.com"
    assert engine.read("overview")["totals"]["principal"] == "b@contoso.com"
    assert accounts == ["a@contoso.com", "b@contoso.com"]
    assert len(acquired) == 2 and requests[0] != requests[1]


def test_account_verification_failure_does_not_fall_back_to_a_cached_bearer(estate):
    backend, state, _, requests, _ = estate
    engine = Engine(backend, "2026-09")
    engine.read("overview")
    state["account"] = False
    with pytest.raises(FinOpsError, match="sign-in unavailable"):
        engine.read("overview")
    assert len(requests) == 1


def test_principal_changed_after_acquisition_sends_no_old_bearer(estate, monkeypatch):
    from claude_finops import direct
    backend, state, _, requests, _ = estate
    engine = Engine(backend, "2026-09")
    engine.read("whoami")
    original = direct.resource_token

    def changing(*args, **kwargs):
        value = original(*args, **kwargs)
        state["principal"] = "b@contoso.com"
        with ThreadPoolExecutor(max_workers=1) as pool:
            pool.submit(engine.read, "whoami").result(timeout=5)
        return value

    monkeypatch.setattr(direct, "resource_token", changing)
    with pytest.raises(FinOpsError, match="sign-in changed"):
        engine.read("overview")
    assert requests == []


def test_distinct_azure_cli_sessions_do_not_share_cached_bearers(estate, monkeypatch, tmp_path):
    backend, _, acquired, requests, _ = estate
    engine = Engine(backend, "2026-09")
    monkeypatch.setenv("AZURE_CONFIG_DIR", str(tmp_path / "one"))
    engine.read("overview")
    monkeypatch.setenv("AZURE_CONFIG_DIR", str(tmp_path / "two"))
    engine.read("overview")
    assert len(acquired) == 2 and requests[0] != requests[1]


def test_one_verified_cycle_coalesces_account_reads_without_waiting_for_permission_labels(estate):
    backend, _, acquired, _, accounts = estate
    engine = Engine(backend, "2026-09")
    with backend.read_cycle():
        engine.read("overview")
        engine.read("overview")
        engine.read("whoami")
    assert len(accounts) == 1
    assert len(acquired) == 1


@pytest.mark.parametrize("change", ["principal", "session"])
def test_changed_principal_invalidates_a_result_already_in_flight(estate, monkeypatch, tmp_path, change):
    backend, state, _, _, _ = estate
    engine = Engine(backend, "2026-09")
    engine.read("whoami")
    entered, release = threading.Event(), threading.Event()

    def slow(request):
        entered.set()
        assert release.wait(timeout=5)
        return httpx.Response(200, json={"tables": [{"columns": [{"name": "principal"}], "rows": [["a@contoso.com"]]}]})

    backend._client = httpx.Client(transport=httpx.MockTransport(slow))
    with ThreadPoolExecutor(max_workers=1) as executor:
        old = executor.submit(engine.read, "overview")
        assert entered.wait(timeout=5)
        try:
            if change == "principal":
                state["principal"] = "b@contoso.com"
            else:
                monkeypatch.setenv("AZURE_CONFIG_DIR", str(tmp_path / "new-session"))
            engine.read("whoami")
        finally:
            release.set()
        with pytest.raises(FinOpsError, match="sign-in changed"):
            old.result(timeout=5)


def test_unbound_callers_cannot_borrow_process_cached_credentials(monkeypatch):
    config.clear_resource_tokens()
    acquired = []
    monkeypatch.setattr(config, "az", lambda *args, **kwargs:
                        acquired.append(1) or token("person@contoso.com"))
    config.resource_token(RESOURCE, SUB)
    config.resource_token(RESOURCE, SUB)
    assert len(acquired) == 2
    config.clear_resource_tokens()


def test_obsolete_verified_binding_and_logout_cannot_reuse_credentials(monkeypatch):
    config.clear_resource_tokens()
    monkeypatch.setattr(config, "az", lambda *args, **kwargs: token("person@contoso.com"))
    first = config.bind_resource_principal(("tenant", "a@contoso.com"), "session-one")
    config.resource_token(RESOURCE, SUB, credential=first)
    second = config.bind_resource_principal(("tenant", "b@contoso.com"), "session-one")
    with pytest.raises(FinOpsError, match="sign-in changed"):
        config.resource_token(RESOURCE, SUB, credential=first)
    config.resource_token(RESOURCE, SUB, credential=second)
    config.clear_resource_tokens()
    with pytest.raises(FinOpsError, match="sign-in changed"):
        config.resource_token(RESOURCE, SUB, credential=second)


def test_http_identity_uses_current_credentials_after_the_cli_principal_changes():
    from claude_finops.turnstile import TurnstileBackend
    principal, acquired = ["a@contoso.com"], []

    def obtain():
        acquired.append(principal[0])
        return token(principal[0])

    def respond(request):
        payload = request.headers["Authorization"].split(".")[1]
        user = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))["principal"]
        return httpx.Response(200, json={"id": user, "email": user, "role": "owner"})

    backend = TurnstileBackend(config.Config(backend="turnstile", url="https://turnstile.contoso.com",
                                             scope="api://contoso/Turnstile.Manage"),
                                token_provider=obtain, transport=httpx.MockTransport(respond))
    engine = Engine(backend, "2026-09")
    try:
        assert engine.read("whoami")["email"] == "a@contoso.com"
        principal[0] = "b@contoso.com"
        assert engine.read("whoami")["email"] == "b@contoso.com"
        assert acquired == ["a@contoso.com", "b@contoso.com"]
    finally:
        backend.close()


def test_http_old_principal_result_is_refused_after_identity_change():
    from claude_finops.turnstile import TurnstileBackend
    entered, release = threading.Event(), threading.Event()
    principal = ["a@contoso.com"]

    def respond(request):
        if request.url.path.endswith("/auth/me"):
            return httpx.Response(200, json={"id": principal[0], "email": principal[0], "role": "owner"})
        entered.set()
        assert release.wait(timeout=5)
        return httpx.Response(200, json={"principal": "a@contoso.com"})

    backend = TurnstileBackend(config.Config(backend="turnstile", url="https://turnstile.contoso.com",
                                             scope="api://contoso/Turnstile.Manage"),
                                token_provider=lambda: token(principal[0]), transport=httpx.MockTransport(respond))
    engine = Engine(backend, "2026-09")
    try:
        engine.read("whoami")
        with ThreadPoolExecutor(max_workers=1) as pool:
            old = pool.submit(engine.read, "budgets")
            assert entered.wait(timeout=5)
            try:
                principal[0] = "b@contoso.com"
                engine.read("whoami")
            finally:
                release.set()
            with pytest.raises(FinOpsError, match="sign-in changed"):
                old.result(timeout=5)
    finally:
        backend.close()


def a_only_snapshot():
    return {
        "catalog": {"organizations": [{"id": "only-a", "name": "A-only unit"}], "departments": []},
        "registry": [{"Id": "only-a", "TokensPerMonth": 100}],
        "parents": {}, "quota_org": 1000, "tiers": [{"id": "only-a", "tokens_per_day": 100}],
        "authority": "Gateway", "usd_supported": True,
        "reads": {key: {"items": [{"scope_id": "only-a"}]} for key in
                  ("usd_budgets", "usd_status", "usd_price_book")},
    }


@pytest.mark.parametrize("resource", ["catalog", "tiers", "usd_budgets", "usd_status", "usd_price_book"])
def test_old_cycle_cannot_rebind_cached_a_account_or_return_a_snapshot_after_b_verification(estate, resource):
    backend, state, _, _, _ = estate
    engine = Engine(backend, "2026-09")
    bridge_reads = []

    def bridge(action, **params):
        bridge_reads.append(state["principal"])
        if state["principal"] != "a@contoso.com":
            raise FinOpsError("Fresh B read denied", 4)
        assert action == "read"
        return deepcopy(a_only_snapshot())

    backend._bridge = bridge
    engine.read("whoami")
    with pytest.raises(FinOpsError, match="sign-in changed") as error:
        with backend.read_cycle():
            assert "only-a" in str(engine.read(resource))
            state["principal"] = "b@contoso.com"
            with ThreadPoolExecutor(max_workers=1) as pool:
                assert pool.submit(engine.read, "whoami").result(timeout=5)["email"] == "b@contoso.com"
            assert engine._identity["email"] == "b@contoso.com"
            engine.read(resource)
    assert error.value.code == 3
    assert bridge_reads == ["a@contoso.com"], "An obsolete cycle must not issue a replacement bridge read."
    with pytest.raises(FinOpsError, match="Fresh B read denied") as denied:
        engine.read("catalog")
    assert denied.value.code == 4
    assert bridge_reads == ["a@contoso.com", "b@contoso.com"]


@pytest.mark.parametrize("paused_at", ["bridge", "aggregate"])
def test_pending_a_budget_cannot_return_after_b_verifies_even_when_a_usage_already_completed(estate, paused_at):
    backend, state, _, requests, _ = estate
    engine = Engine(backend, "2026-09")
    engine.read("whoami")
    entered, release, usage_done = threading.Event(), threading.Event(), threading.Event()
    backend._client = httpx.Client(transport=httpx.MockTransport(lambda request: (
        requests.append(request.headers["Authorization"]) or httpx.Response(200, json={
            "tables": [{"columns": [{"name": "business_unit"}, {"name": "used_tokens"}],
                        "rows": [["only-a", 7]]}]}))))
    query = backend.query

    def completed_usage(kql):
        rows = query(kql)
        usage_done.set()
        return rows

    def pause():
        entered.set()
        assert release.wait(timeout=5)

    def bridge(action, **params):
        assert action == "read" and state["principal"] == "a@contoso.com"
        if paused_at == "bridge":
            pause()
        return deepcopy(a_only_snapshot())

    snapshot = backend._snapshot

    def completed_snapshot(resource="read"):
        result = snapshot(resource)
        if paused_at == "aggregate":
            pause()
        return result

    backend.query = completed_usage
    backend._bridge = bridge
    backend._snapshot = completed_snapshot
    with ThreadPoolExecutor(max_workers=1) as pool:
        old_budget = pool.submit(engine.read, "budgets")
        try:
            assert entered.wait(timeout=5) and usage_done.wait(timeout=5)
            assert len(requests) == 1, "A's HTTP query must finish before the principal switch."
            state["principal"] = "b@contoso.com"
            assert engine.read("whoami")["email"] == "b@contoso.com"
        finally:
            release.set()
        with pytest.raises(FinOpsError, match="sign-in changed") as error:
            old_budget.result(timeout=5)
        assert error.value.code == 3


def test_completed_cycle_rejects_an_aggregate_built_before_principal_change(estate):
    backend, state, _, _, _ = estate
    engine = Engine(backend, "2026-09")
    backend._bridge = lambda action, **params: deepcopy(a_only_snapshot())
    engine.read("whoami")

    def aggregate():
        with backend.read_cycle():
            catalog = engine.read("catalog")
            assert catalog["organizations"][0]["id"] == "only-a"
            state["principal"] = "b@contoso.com"
            with ThreadPoolExecutor(max_workers=1) as pool:
                assert pool.submit(engine.read, "whoami").result(timeout=5)["email"] == "b@contoso.com"
            return {"catalog": catalog}

    with pytest.raises(FinOpsError, match="sign-in changed"):
        aggregate()
