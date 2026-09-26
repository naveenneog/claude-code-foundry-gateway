import json

import httpx
import pytest

from claude_finops.developers import EntraDevelopers
from claude_finops.errors import FinOpsError


USER = "00000000-0000-0000-0000-000000000001"
STANDARD = "00000000-0000-0000-0000-000000000010"
PREMIUM = "00000000-0000-0000-0000-000000000011"
UNIT = "00000000-0000-0000-0000-000000000012"


def graph(respond):
    return EntraDevelopers(token_provider=lambda: "test-token", transport=httpx.MockTransport(respond))


def test_developer_search_uses_advanced_directory_query_and_enriches_entitlement():
    calls = []

    def respond(request):
        calls.append(request)
        assert request.headers["ConsistencyLevel"] == "eventual"
        return httpx.Response(200, json={"value": [{
            "id": USER, "displayName": "Contoso Dev", "userPrincipalName": "dev@contoso.com",
            "mail": "dev@contoso.com", "userType": "Member"}]})

    result = graph(respond).search_developers("dev", state={"entitlements": {"standard": [USER]}, "memberships": {USER: "sales"}})
    assert result["items"][0]["current_tier"] == "standard"
    assert result["items"][0]["current_unit"] == "sales"
    assert calls[0].url.path == "/v1.0/users"
    assert calls[0].url.params["$count"] == "true"
    assert "mail:dev" in calls[0].url.params["$search"]


def test_developer_search_exact_email_uses_filter_when_search_index_misses_mail():
    filters = []

    def respond(request):
        filters.append(request.url.params.get("$filter", ""))
        if filters[-1].startswith("mail eq"):
            return httpx.Response(200, json={"value": [{
                "id": USER, "displayName": "Contoso Dev", "userPrincipalName": "dev@contoso.com",
                "mail": "dev@contoso.com", "userType": "Member"}]})
        return httpx.Response(200, json={"value": []})

    result = graph(respond).search_developers("dev@contoso.com")
    assert result["items"][0]["mail"] == "dev@contoso.com"
    assert all("$search" not in value for value in filters)


def test_exact_resolution_checks_mail_upn_other_mails_and_encoded_ext_guest():
    seen = []

    def respond(request):
        seen.append(str(request.url))
        filter_value = request.url.params.get("$filter", "")
        if filter_value.startswith("mail eq") or filter_value.startswith("userPrincipalName eq") or filter_value.startswith("otherMails"):
            return httpx.Response(200, json={"value": []})
        if filter_value.startswith("startswith"):
            return httpx.Response(200, json={"value": [{
                "id": USER, "displayName": "Guest", "userPrincipalName": "guest_contoso.com#EXT#@tenant.onmicrosoft.com",
                "mail": None, "otherMails": ["guest@contoso.com"], "userType": "Guest"}]})
        return httpx.Response(404)

    result = graph(respond).resolve_exact("guest@contoso.com")
    assert result["user_type"] == "Guest"
    assert "%23EXT%23" not in seen[-1]
    assert "guest" in seen[-1]


def test_exact_resolution_encodes_raw_ext_upn_object_lookup():
    calls = []

    def respond(request):
        calls.append(str(request.url))
        return httpx.Response(200, json={"value": []})

    with pytest.raises(FinOpsError):
        graph(respond).resolve_exact("guest_contoso.com#EXT#@tenant.onmicrosoft.com")
    assert "%23EXT%23" in calls[0] or "%23EXT%23" in "".join(calls)


def test_ambiguous_resolution_refuses_and_redacts_candidates():
    def respond(request):
        if request.url.params.get("$filter", "").startswith("mail eq"):
            return httpx.Response(200, json={"value": [
                {"id": USER, "userPrincipalName": "one@contoso.com"},
                {"id": "00000000-0000-0000-0000-000000000002", "userPrincipalName": "two@contoso.com"},
            ]})
        return httpx.Response(200, json={"value": []})

    with pytest.raises(FinOpsError, match="matches several accounts") as failure:
        graph(respond).resolve_exact("shared@contoso.com")
    assert "shared@contoso.com" not in str(failure.value)


def test_membership_write_is_not_retried_and_is_verified(monkeypatch):
    import claude_finops.developers as developers
    monkeypatch.setattr(developers.time, "sleep", lambda _: None)
    posts = []
    member_reads = 0

    def respond(request):
        nonlocal member_reads
        if request.url.path == f"/v1.0/users/{USER}/memberOf":
            member_reads += 1
            value = [] if member_reads == 1 else [{"id": STANDARD}]
            return httpx.Response(200, json={"value": value})
        if request.method == "POST":
            posts.append(json.loads(request.content))
            return httpx.Response(204)
        return httpx.Response(200, json={"value": []})

    assert graph(respond).apply_membership(USER, STANDARD, True)
    assert len(posts) == 1
    assert posts[0]["@odata.id"].endswith(USER)


def test_group_403_reports_required_rights_without_owner_precheck():
    def respond(request):
        if request.url.path == f"/v1.0/users/{USER}/memberOf":
            return httpx.Response(200, json={"value": []})
        return httpx.Response(403, json={"error": {"code": "Authorization_RequestDenied",
                                                   "message": "Insufficient privileges to complete the operation."}})

    with pytest.raises(FinOpsError, match="Graph HTTP 403"):
        graph(respond).apply_membership(USER, PREMIUM, True)
