import base64
import json
import threading
import time
from concurrent.futures import ThreadPoolExecutor

import httpx
import pytest

from claude_finops import config
from claude_finops.direct import DirectBackend
from claude_finops.errors import FinOpsError


SUB = "00000000-0000-0000-0000-000000000071"
RESOURCE = "https://api.loganalytics.io"


def jwt(expiry):
    payload = base64.urlsafe_b64encode(json.dumps({"exp": expiry}).encode()).decode().rstrip("=")
    return "header." + payload + ".signature"


@pytest.fixture(autouse=True)
def clear_cache():
    if hasattr(config, "clear_resource_tokens"):
        config.clear_resource_tokens()
    yield
    if hasattr(config, "clear_resource_tokens"):
        config.clear_resource_tokens()


@pytest.fixture
def credential():
    return config.bind_resource_principal((SUB, "reader@contoso.com"), "test-session")


def account():
    return json.dumps({"id": SUB, "tenantId": SUB, "user": {"name": "reader@contoso.com"}})


def test_direct_queries_reuse_token_across_backend_instances_until_near_expiry(monkeypatch):
    acquisitions = []
    clock = [1000.0]
    monkeypatch.setattr(config.time, "time", lambda: clock[0])

    def run(*args, **kwargs):
        if args[:2] == ("account", "show"):
            return account()
        assert args[:2] == ("account", "get-access-token")
        acquisitions.append(args)
        return jwt(clock[0] + 3600)

    original = httpx.Client
    transport = httpx.MockTransport(lambda _: httpx.Response(200, json={
        "tables": [{"columns": [{"name": "tokens"}], "rows": [[42]]}]}))
    monkeypatch.setattr("claude_finops.direct.az", run)
    monkeypatch.setattr("claude_finops.direct.httpx.Client",
                        lambda *args, **kwargs: original(*args, transport=transport, **kwargs))
    settings = config.Config(backend="direct", subscription=SUB, resource_group="rg-contoso",
                             apim_name="apim-contoso", workspace=SUB)
    first, second = DirectBackend(settings), DirectBackend(settings)
    assert first.query("print tokens=42") == [{"tokens": 42}]
    assert second.query("print tokens=42") == [{"tokens": 42}]
    assert len(acquisitions) == 1
    clock[0] += 3481
    first.query("print tokens=42")
    assert len(acquisitions) == 2
    first.close()
    second.close()


def test_resource_contexts_never_share_tokens(monkeypatch, credential):
    calls = []
    monkeypatch.setattr(config, "az", lambda *args, **kwargs: calls.append(args) or jwt(time.time() + 3600))
    config.resource_token(RESOURCE, SUB, credential=credential)
    config.resource_token(RESOURCE, SUB, credential=credential)
    config.resource_token("https://management.azure.com/", SUB, credential=credential)
    config.resource_token(RESOURCE, "00000000-0000-0000-0000-000000000072", credential=credential)
    config.resource_token(RESOURCE, SUB, tenant_id="00000000-0000-0000-0000-000000000073", credential=credential)
    assert len(calls) == 4
    assert all(call[call.index("--resource") + 1] in {RESOURCE, "https://management.azure.com/"} for call in calls)
    assert "--tenant" in calls[-1] and "--subscription" not in calls[-1]


def test_parallel_queries_acquire_only_one_token(monkeypatch, credential):
    calls = []
    ready = threading.Barrier(8)

    def run(*args, **kwargs):
        calls.append(args)
        time.sleep(.04)
        return jwt(time.time() + 3600)

    monkeypatch.setattr(config, "az", run)

    def read():
        ready.wait(timeout=5)
        return config.resource_token(RESOURCE, SUB, credential=credential)

    with ThreadPoolExecutor(max_workers=8) as executor:
        results = list(executor.map(lambda _: read(), range(8)))
    assert len(calls) == 1 and len(set(results)) == 1


def test_empty_failed_or_expiring_tokens_are_not_cached(monkeypatch, credential):
    calls = []
    values = iter(["", FinOpsError("Sign-in refused", 3), jwt(time.time() + 60), jwt(time.time() + 3600)])

    def run(*args, **kwargs):
        calls.append(args)
        value = next(values)
        if isinstance(value, Exception):
            raise value
        return value

    monkeypatch.setattr(config, "az", run)
    with pytest.raises(FinOpsError, match="No access token"):
        config.resource_token(RESOURCE, SUB, credential=credential)
    with pytest.raises(FinOpsError, match="Sign-in refused"):
        config.resource_token(RESOURCE, SUB, credential=credential)
    config.resource_token(RESOURCE, SUB, credential=credential)
    config.resource_token(RESOURCE, SUB, credential=credential)
    config.resource_token(RESOURCE, SUB, credential=credential)
    assert len(calls) == 4


def test_force_refresh_and_signout_drop_cached_credentials(monkeypatch, credential):
    import subprocess
    calls = []
    monkeypatch.setattr(config.shutil, "which", lambda _: "az")
    monkeypatch.setattr(config.subprocess, "run", lambda args, **kwargs:
                        calls.append(args) or subprocess.CompletedProcess(args, 0, jwt(time.time() + 3600), ""))
    config.resource_token(RESOURCE, SUB, credential=credential)
    config.resource_token(RESOURCE, SUB, force=True, credential=credential)
    config.az("logout")
    credential = config.bind_resource_principal((SUB, "reader@contoso.com"), "test-session")
    config.resource_token(RESOURCE, SUB, credential=credential)
    assert sum(call[1:3] == ["account", "get-access-token"] for call in calls) == 3


def test_opaque_token_cache_has_a_bounded_lifetime(monkeypatch, credential):
    calls, clock = [], [1000.0]
    monkeypatch.setattr(config.time, "monotonic", lambda: clock[0])
    monkeypatch.setattr(config, "az", lambda *args, **kwargs: calls.append(args) or "opaque-test-only")
    config.resource_token(RESOURCE, SUB, credential=credential)
    config.resource_token(RESOURCE, SUB, credential=credential)
    assert len(calls) == 1
    clock[0] += 301
    config.resource_token(RESOURCE, SUB, credential=credential)
    assert len(calls) == 2


def test_known_expiry_is_reused_beyond_the_opaque_fallback_window(monkeypatch, credential):
    calls, clock = [], [1000.0]
    monkeypatch.setattr(config.time, "monotonic", lambda: clock[0])
    monkeypatch.setattr(config.time, "time", lambda: clock[0])
    monkeypatch.setattr(config, "az", lambda *args, **kwargs: calls.append(args) or jwt(clock[0] + 3600))
    config.resource_token(RESOURCE, SUB, credential=credential)
    clock[0] += 400
    config.resource_token(RESOURCE, SUB, credential=credential)
    assert len(calls) == 1


def test_waiting_for_a_concurrent_token_obeys_the_callers_deadline(monkeypatch, credential):
    acquired, release = threading.Event(), threading.Event()

    def run(*args, **kwargs):
        acquired.set()
        assert release.wait(timeout=3)
        return jwt(time.time() + 3600)

    monkeypatch.setattr(config, "az", run)
    with ThreadPoolExecutor(max_workers=2) as pool:
        first = pool.submit(config.resource_token, RESOURCE, SUB, credential=credential)
        assert acquired.wait(timeout=3)
        start = time.perf_counter()
        try:
            with pytest.raises(FinOpsError, match="token.*timed out"):
                config.resource_token(RESOURCE, SUB, timeout=.05, credential=credential)
            assert time.perf_counter() - start < .3
        finally:
            release.set()
        first.result(timeout=3)


def test_direct_queries_share_one_http_client_and_close_it(monkeypatch):
    clients = []
    original = httpx.Client
    transport = httpx.MockTransport(lambda _: httpx.Response(200, json={
        "tables": [{"columns": [], "rows": []}]}))

    def client(*args, **kwargs):
        result = original(*args, transport=transport, **kwargs)
        clients.append(result)
        return result

    monkeypatch.setattr("claude_finops.direct.az", lambda *args, **kwargs:
                        account() if args[:2] == ("account", "show") else jwt(time.time() + 3600))
    monkeypatch.setattr(httpx, "Client", client)
    backend = DirectBackend(config.Config(backend="direct", subscription=SUB, resource_group="rg-contoso",
                                         apim_name="apim-contoso", workspace=SUB))
    backend.query("print tokens=42")
    backend.query("print tokens=42")
    assert len(clients) == 1 and not clients[0].is_closed
    backend.close()
    assert clients[0].is_closed


@pytest.mark.parametrize("lock_seconds", [.08, .1])
def test_lock_and_acquisition_share_one_monotonic_deadline(monkeypatch, lock_seconds):
    clock, requested = [1000.0], []

    class DelayedLock:
        def acquire(self, *, timeout):
            assert timeout == pytest.approx(.1)
            clock[0] += lock_seconds
            return True

        def release(self):
            pass

    def acquire(*args, timeout, **kwargs):
        requested.append(timeout)
        clock[0] += min(.08, timeout)
        if timeout < .08:
            raise FinOpsError("Azure token acquisition timed out.", 7)
        return jwt(time.time() + 3600)

    monkeypatch.setattr(config, "_resource_token_lock", DelayedLock())
    monkeypatch.setattr(config.time, "monotonic", lambda: clock[0])
    with pytest.raises(FinOpsError, match="timed out"):
        config.resource_token(RESOURCE, SUB, runner=acquire, timeout=.1)
    assert clock[0] - 1000 <= .100001
    if lock_seconds < .1:
        assert requested == [pytest.approx(.02)]
    else:
        assert requested == [], "An exhausted deadline must not launch Azure CLI."
