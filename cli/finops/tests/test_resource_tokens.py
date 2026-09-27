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


def test_direct_queries_reuse_token_across_backend_instances_until_near_expiry(monkeypatch):
    acquisitions = []
    clock = [1000.0]
    monkeypatch.setattr(config.time, "time", lambda: clock[0])

    def run(*args, **kwargs):
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


def test_resource_contexts_never_share_tokens(monkeypatch):
    calls = []
    monkeypatch.setattr(config, "az", lambda *args, **kwargs: calls.append(args) or jwt(time.time() + 3600))
    config.resource_token(RESOURCE, SUB)
    config.resource_token(RESOURCE, SUB)
    config.resource_token("https://management.azure.com/", SUB)
    config.resource_token(RESOURCE, "00000000-0000-0000-0000-000000000072")
    config.resource_token(RESOURCE, SUB, tenant_id="00000000-0000-0000-0000-000000000073")
    assert len(calls) == 4
    assert all(call[call.index("--resource") + 1] in {RESOURCE, "https://management.azure.com/"} for call in calls)
    assert "--tenant" in calls[-1] and "--subscription" not in calls[-1]


def test_parallel_queries_acquire_only_one_token(monkeypatch):
    calls = []
    ready = threading.Barrier(8)

    def run(*args, **kwargs):
        calls.append(args)
        time.sleep(.04)
        return jwt(time.time() + 3600)

    monkeypatch.setattr(config, "az", run)

    def read():
        ready.wait(timeout=5)
        return config.resource_token(RESOURCE, SUB)

    with ThreadPoolExecutor(max_workers=8) as executor:
        results = list(executor.map(lambda _: read(), range(8)))
    assert len(calls) == 1 and len(set(results)) == 1


def test_empty_failed_or_expiring_tokens_are_not_cached(monkeypatch):
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
        config.resource_token(RESOURCE, SUB)
    with pytest.raises(FinOpsError, match="Sign-in refused"):
        config.resource_token(RESOURCE, SUB)
    config.resource_token(RESOURCE, SUB)
    config.resource_token(RESOURCE, SUB)
    config.resource_token(RESOURCE, SUB)
    assert len(calls) == 4


def test_force_refresh_and_signout_drop_cached_credentials(monkeypatch):
    import subprocess
    calls = []
    monkeypatch.setattr(config.shutil, "which", lambda _: "az")
    monkeypatch.setattr(config.subprocess, "run", lambda args, **kwargs:
                        calls.append(args) or subprocess.CompletedProcess(args, 0, jwt(time.time() + 3600), ""))
    config.resource_token(RESOURCE, SUB)
    config.resource_token(RESOURCE, SUB, force=True)
    config.az("logout")
    config.resource_token(RESOURCE, SUB)
    assert sum(call[1:3] == ["account", "get-access-token"] for call in calls) == 3


def test_opaque_token_cache_has_a_bounded_lifetime(monkeypatch):
    calls, clock = [], [1000.0]
    monkeypatch.setattr(config.time, "monotonic", lambda: clock[0])
    monkeypatch.setattr(config, "az", lambda *args, **kwargs: calls.append(args) or "opaque-test-only")
    config.resource_token(RESOURCE, SUB)
    config.resource_token(RESOURCE, SUB)
    assert len(calls) == 1
    clock[0] += 301
    config.resource_token(RESOURCE, SUB)
    assert len(calls) == 2


def test_known_expiry_is_reused_beyond_the_opaque_fallback_window(monkeypatch):
    calls, clock = [], [1000.0]
    monkeypatch.setattr(config.time, "monotonic", lambda: clock[0])
    monkeypatch.setattr(config.time, "time", lambda: clock[0])
    monkeypatch.setattr(config, "az", lambda *args, **kwargs: calls.append(args) or jwt(clock[0] + 3600))
    config.resource_token(RESOURCE, SUB)
    clock[0] += 400
    config.resource_token(RESOURCE, SUB)
    assert len(calls) == 1


def test_waiting_for_a_concurrent_token_obeys_the_callers_deadline(monkeypatch):
    acquired, release = threading.Event(), threading.Event()

    def run(*args, **kwargs):
        acquired.set()
        assert release.wait(timeout=3)
        return jwt(time.time() + 3600)

    monkeypatch.setattr(config, "az", run)
    with ThreadPoolExecutor(max_workers=2) as pool:
        first = pool.submit(config.resource_token, RESOURCE, SUB)
        assert acquired.wait(timeout=3)
        start = time.perf_counter()
        try:
            with pytest.raises(FinOpsError, match="token.*timed out"):
                config.resource_token(RESOURCE, SUB, timeout=.05)
            assert time.perf_counter() - start < .3
        finally:
            release.set()
        first.result(timeout=3)
