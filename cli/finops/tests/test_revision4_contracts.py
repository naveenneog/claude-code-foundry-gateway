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
