import httpx
import pytest

from claude_finops.config import Config
from claude_finops.engine import Engine
from claude_finops.errors import FinOpsError
from claude_finops.fake import FakeBackend
from claude_finops.turnstile import TurnstileBackend
from claude_finops.rules import can_budget_write
from claude_finops.capabilities import enabled


@pytest.mark.parametrize("document", [
    None, [], {"schema_version": 1, "features": None},
    {"schema_version": 1, "features": []},
    {"schema_version": 1, "features": {"approvals": {"enabled": True, "actions": "read request"}}},
    {"schema_version": 1, "features": {"approvals": {"enabled": True, "actions": None}}},
])
def test_malformed_capability_documents_fail_closed(document):
    assert enabled(document, "approvals") is False


def test_malformed_advertisement_does_not_break_supported_reads():
    def respond(request):
        if request.url.path.endswith("/capabilities"):
            return httpx.Response(200, json={"schema_version": 1, "features": None})
        if request.url.path.endswith("/auth/me"):
            return httpx.Response(200, json={"role": "owner", "manager_scope": None})
        return httpx.Response(404)
    backend = TurnstileBackend(Config(url="https://api.contoso.com", scope="api://contoso/Manage"),
        token_provider=lambda: "test-only", transport=httpx.MockTransport(respond))
    caps = backend.read("capabilities")
    assert not enabled(caps, "approvals")
    assert enabled(caps, "budget_modes")


def test_cursor_pages_keep_timestamp_ties_without_client_slicing():
    engine = Engine(FakeBackend(features={"request_cursor": True}), "2026-09")
    rows, cursor = [], None
    for _ in range(3):
        response = engine.read("requests", limit=50, cursor=cursor)
        rows.extend(response["items"])
        cursor = response["page"]["next_cursor"]
    assert len(rows) == 120
    assert len({row["request_id"] for row in rows}) == 120
    assert cursor is None


def test_cursor_is_refused_until_advertised():
    with pytest.raises(FinOpsError, match="cursor"):
        Engine(FakeBackend(), "2026-09").read("requests", cursor="opaque", limit=50)


def test_if_match_is_sent_only_after_advertised_etag_read():
    seen = []
    def respond(request):
        seen.append(request)
        path = request.url.path
        if path.endswith("/auth/me"):
            return httpx.Response(200, json={"id": "owner", "role": "owner", "manager_scope": None})
        if path.endswith("/capabilities"):
            return httpx.Response(200, json={"schema_version": 1, "features": {
                "conditional_writes": {"enabled": True, "actions": ["write"]}}})
        if path.endswith("/enterprise-catalog"):
            return httpx.Response(200, json={"organizations": [], "departments": []}, headers={"ETag": '"revision-1"'})
        return httpx.Response(404)
    backend = TurnstileBackend(Config(url="https://api.contoso.com", scope="api://contoso/Manage"),
                               token_provider=lambda: "test-only", transport=httpx.MockTransport(respond))
    backend.read("catalog")
    backend.write("catalog", {"organizations": [{"id": "sales", "name": "Sales"}], "departments": []})
    assert seen[-1].headers["If-Match"] == '"revision-1"'


def test_advanced_read_never_exposes_credentials():
    backend = TurnstileBackend(Config(url="https://api.contoso.com", scope="api://contoso/Manage"),
        token_provider=lambda: "test-only", transport=httpx.MockTransport(
            lambda _: httpx.Response(200, json={"models": [], "config": {"api_key": "do-not-print"}})))
    assert backend.read("registry")["config"]["api_key"] == "[credential omitted]"


def test_manager_budget_permissions_follow_deployed_profile():
    identity = {"role": "member", "manager_scope": {
        "organizations": [{"id": "sales"}], "departments": [{"id": "sales-emea", "parent_id": "sales"}],
        "writable_department_ids": ["sales-emea"]}}
    assert can_budget_write(identity, "department", "sales-emea")
    assert can_budget_write(identity, "user", "dev@contoso.com", "sales-emea")
    assert not can_budget_write(identity, "organization", "sales")
    assert not can_budget_write(identity, "department", "engineering")


def test_viewer_does_not_get_approval_actions_from_fake_advertisement():
    engine = Engine(FakeBackend(role="member", features={"approvals": True}), "2026-09")
    assert not engine.has_feature("approvals", "approve")


def test_notification_and_boost_revocation_contracts():
    engine = Engine(FakeBackend(features={"notifications": True, "boosts": True}), "2026-09")
    notice = engine.read("notifications")["items"][0]
    assert engine.mark_notification(notice["id"])["preview"]
    boost = engine.boost("dev-001@contoso.com", "sales-emea", "1k", "2099-01-01", "extra capacity", apply=True)
    result = engine.revoke_boost(boost["result"]["id"], apply=True)
    assert result["result"]["state"] == "revoked"


@pytest.mark.parametrize("decision", ["reject", "escalate"])
def test_request_transition_persists_and_records_idempotency_key(decision):
    from uuid import UUID
    backend = FakeBackend(features={"approvals": True})
    engine = Engine(backend, "2026-09")
    request = engine.request_budget("team", "sales-emea", "9M", "Capacity review", apply=True)["result"]
    result = engine.decide_request(request["id"], decision, "Reviewed", apply=True)["result"]
    assert result["state"] == {"reject": "rejected", "escalate": "escalated"}[decision]
    assert result["revision"] != request["revision"]
    assert engine.read("approval_request", id=request["id"])["state"] == result["state"]
    assert UUID(backend.writes[-1][1]["idempotency_key"])


def test_notification_mark_read_is_reflected_by_next_read():
    engine = Engine(FakeBackend(features={"notifications": True}), "2026-09")
    notice = engine.read("notifications")["items"][0]
    engine.mark_notification(notice["id"], apply=True)
    assert engine.read("notifications")["items"][0]["read_at"]


@pytest.mark.parametrize("status", [409, 412])
def test_conditional_write_conflict_never_retries(status):
    writes = []
    def respond(request):
        if request.method == "PUT":
            writes.append(request)
            return httpx.Response(status)
        if request.url.path.endswith("/auth/me"):
            return httpx.Response(200, json={"role": "owner", "manager_scope": None})
        if request.url.path.endswith("/capabilities"):
            return httpx.Response(200, json={"schema_version": 1, "features": {
                "conditional_writes": {"enabled": True, "actions": ["write"]}}})
        if request.url.path.endswith("/gateway-tiers"):
            return httpx.Response(200, json={"items": []}, headers={"ETag": '"old"'})
        return httpx.Response(404)
    backend = TurnstileBackend(Config(url="https://api.contoso.com", scope="api://contoso/Manage"),
        token_provider=lambda: "test-only", transport=httpx.MockTransport(respond))
    backend.read("tiers")
    with pytest.raises(FinOpsError):
        backend.write("tiers", {"tiers": []})
    assert len(writes) == 1 and writes[0].headers["If-Match"] == '"old"'


def test_advertised_conditional_write_without_etag_refuses_mutation():
    writes = []
    backend = TurnstileBackend(Config(url="https://api.contoso.com", scope="api://contoso/Manage"),
        token_provider=lambda: "test-only", transport=httpx.MockTransport(lambda request: writes.append(request)))
    backend._features = {"schema_version": 1, "features": {
        "conditional_writes": {"enabled": True, "actions": ["write"]}}}
    with pytest.raises(FinOpsError, match="ETag"):
        backend.write("catalog", {})
    assert not writes


def test_global_lookup_contract_needs_no_client_tab_field():
    backend = FakeBackend(features={"global_search": True})
    original = backend.read
    backend.read = lambda resource, **params: (
        {"items": [{"kind": "person", "id": "dev-001@contoso.com", "name": "Contoso person",
                    "department_id": "sales-emea"}]} if resource == "global_search"
        else original(resource, **params))
    result = Engine(backend, "2026-09").lookup("dev")
    assert result[0]["tab"] == "people"
    assert result[0]["department_id"] == "sales-emea"


def test_future_mutation_returns_gateway_apply_tracking_anchor():
    backend = FakeBackend(features={"approvals": True})
    backend.write = lambda *_, **__: {"id": "request-1", "apply": {"requested_at": "2026-09-24T12:00:00Z"}}
    result = Engine(backend, "2026-09").request_budget("team", "sales-emea", "9M", "Capacity", apply=True)
    assert result["requested_at"] == "2026-09-24T12:00:00Z"


def test_approval_history_is_paged_and_final_decisions_cannot_repeat():
    backend = FakeBackend(features={"approvals": True})
    engine = Engine(backend, "2026-09")
    for index in range(55):
        engine.request_budget("team", "sales-emea", "9M", f"Capacity {index}", apply=True)
    page = engine.read("approval_requests", view="mine", limit=50)
    assert len(page["items"]) == 50 and page["page"]["next_cursor"]
    last = engine.read("approval_requests", view="mine", limit=50, cursor=page["page"]["next_cursor"])
    assert len(last["items"]) == 5 and not last["page"]["next_cursor"]
    engine.decide_request(page["items"][0]["id"], "reject", "No capacity", apply=True)
    with pytest.raises(FinOpsError, match="not permitted"):
        engine.decide_request(page["items"][0]["id"], "reject", "Repeat", apply=True)
