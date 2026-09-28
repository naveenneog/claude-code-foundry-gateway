import asyncio
from concurrent.futures import ThreadPoolExecutor
from copy import deepcopy
import json

import httpx
import pytest
from textual.widgets import Static
from types import SimpleNamespace
import typer

from claude_finops.cli import emit, report_chargeback
from claude_finops.config import Config
from claude_finops.engine import Engine
from claude_finops.errors import FinOpsError
from claude_finops.redaction import Redactor
from claude_finops.tui import FinOpsApp
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


@pytest.mark.parametrize("delivery", ["partial", "final"])
async def test_direct_completed_sources_cannot_publish_after_b_verifies(estate, delivery):
    backend, state, _, _, _ = estate
    engine = Engine(backend, "2026-09")
    backend._bridge = lambda *args, **kwargs: deepcopy(a_only_snapshot())
    backend._client = httpx.Client(transport=httpx.MockTransport(lambda request: httpx.Response(
        200, json={"tables": [{"columns": [{"name": "total_tokens"}, {"name": "marker"}],
                              "rows": [[771, "A_ONLY"]]}]}
        if "| summarize " in json.loads(request.content)["query"] and " by " not in json.loads(request.content)["query"]
        else {"tables": [{"columns": [], "rows": []}]})))
    app = FinOpsApp(engine, Config(backend="fake"), first_run=False)
    sources = ("overview", "budgets", "ranking", "teams", "trends", "anomalies", "catalog")
    ready = {key: asyncio.Event() for key in sources}
    release = {key: asyncio.Event() for key in sources}
    final_ready, final_release = asyncio.Event(), asyncio.Event()
    original_tracked, original_load, original_render = app._tracked_read, app.load_tab, app.render_tab
    published, publication_seen = [], asyncio.Event()

    async def hold_arrival(key, operation, serial, tab):
        result = await original_tracked(key, operation, serial, tab)
        if delivery == "partial" and key in sources:
            ready[key].set()
            await release[key].wait()
        return result

    async def hold_final(tab):
        result = await original_load(tab)
        if delivery == "final" and tab == "overview":
            final_ready.set()
            await final_release.wait()
        return result

    def rendered(tab, data):
        if state["principal"] == "b@contoso.com" and "A_ONLY" in str(data):
            published.append(data)
            publication_seen.set()
        original_render(tab, data)

    app._tracked_read, app.load_tab, app.render_tab = hold_arrival, hold_final, rendered
    async with app.run_test(size=(100, 30)) as pilot:
        try:
            if delivery == "partial":
                await asyncio.wait_for(asyncio.gather(*(event.wait() for event in ready.values())), 8)
            else:
                await asyncio.wait_for(final_ready.wait(), 8)
            state["principal"] = "b@contoso.com"
            identity = await asyncio.to_thread(engine.read, "whoami")
            assert identity["email"] == "b@contoso.com"
            if delivery == "partial":
                release["overview"].set()
            else:
                final_release.set()
            for _ in range(20):
                await pilot.pause(.03)
                if publication_seen.is_set() or "sign-in changed" in str(app.query_one("#note-overview", Static).render()):
                    break
            assert not published, "A completed A-only source was rendered after B was verified."
            assert "overview" not in app.data, "Obsolete arrivals must be discarded before entering the current UI cache."
            assert "sign-in changed" in str(app.query_one("#note-overview", Static).render())
        finally:
            final_release.set()
            for event in release.values():
                event.set()
            await app.workers.wait_for_complete()


def test_completed_http_result_cannot_reach_json_after_b_verifies(http_estate, capsys):
    engine, principal, _ = http_estate
    ctx = SimpleNamespace(obj={"engine": engine, "redactor": Redactor(), "json": True,
                               "plain": True, "no_color": True})

    def completed(engine):
        result = engine.read("trends")
        verify_b(engine, principal)
        return result

    with pytest.raises(typer.Exit) as failure:
        emit(ctx, completed)
    assert failure.value.exit_code == 3
    output = json.loads(capsys.readouterr().out)
    assert output["exit_code"] == 3 and "a-only" not in str(output)


def test_completed_capabilities_are_not_cached_after_b_verifies(http_estate):
    engine, principal, _ = http_estate
    original = engine.backend.read

    def delayed(resource, **params):
        result = original(resource, **params)
        if resource == "capabilities":
            assert result["features"]["private"] == "a"
            verify_b(engine, principal)
        return result

    engine.backend.read = delayed
    with pytest.raises(FinOpsError, match="sign-in changed"):
        engine.capabilities(refresh=True)
    assert engine._capabilities is None


def test_completed_http_identity_cannot_reach_json_after_new_identity_verifies(http_estate, capsys):
    engine, principal, _ = http_estate
    ctx = SimpleNamespace(obj={"engine": engine, "redactor": Redactor(), "json": True,
                               "plain": True, "no_color": True})

    def completed(engine):
        result = engine.read("whoami")
        verify_b(engine, principal)
        return result

    with pytest.raises(typer.Exit) as failure:
        emit(ctx, completed)
    assert failure.value.exit_code == 3
    output = json.loads(capsys.readouterr().out)
    assert output["exit_code"] == 3 and "a@contoso.com" not in str(output)


def test_completed_chargeback_cannot_reach_csv_after_b_verifies(http_estate, capsys):
    engine, principal, _ = http_estate
    ctx = SimpleNamespace(obj={"engine": engine, "redactor": Redactor(), "json": False})

    def chargeback(dimension):
        source = engine.read("trends")
        verify_b(engine, principal)
        return {"items": [{"id": source["source"], "total_tokens": 7}]}

    engine.chargeback = chargeback
    with pytest.raises(typer.Exit) as failure:
        report_chargeback(ctx, csv=True)
    assert failure.value.exit_code == 3
    assert capsys.readouterr().out == ""


def test_turnstile_completed_feature_document_is_not_cached_after_b_verifies(http_estate):
    engine, principal, _ = http_estate
    original = engine.backend._request

    def after_response(method, path, *args, **kwargs):
        result = original(method, path, *args, **kwargs)
        if path.endswith("/model-management"):
            verify_b(engine, principal)
        return result

    engine.backend._request = after_response
    with pytest.raises(FinOpsError, match="sign-in changed"):
        engine.capabilities(refresh=True)
    assert engine.backend._features is None


def test_aum_service_completed_catalog_is_not_cached_after_identity_change():
    from claude_finops.aum_service import AumServiceBackend
    principal = ["a"]

    def respond(request):
        if request.url.path.endswith("/me"):
            return httpx.Response(200, json={"id": principal[0], "role": "owner"})
        return httpx.Response(200, json={"revision": "one", "organizations": [
            {"id": principal[0] + "-only", "name": principal[0]}], "departments": []})

    backend = AumServiceBackend(Config(backend="aum-service", url="https://aum.contoso.com",
                                      scope="api://contoso/AUM.Access"), token_provider=lambda: "test-only",
                                transport=httpx.MockTransport(respond))
    engine = Engine(backend, "2026-09")
    engine.read("whoami")
    original = backend._get

    def after_get(path, *args, **kwargs):
        result = original(path, *args, **kwargs)
        if path == "catalog":
            verify_b(engine, principal)
        return result

    backend._get = after_get
    try:
        with pytest.raises(FinOpsError, match="sign-in changed"):
            engine.read("catalog")
        assert backend._catalog is None
    finally:
        backend.close()
