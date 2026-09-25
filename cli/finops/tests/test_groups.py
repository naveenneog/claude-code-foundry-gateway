import json
import httpx
import pytest

from claude_finops.errors import FinOpsError


def graph(respond):
    from claude_finops.groups import EntraGroups
    return EntraGroups(token_provider=lambda: "test-only", transport=httpx.MockTransport(respond))


def test_group_search_is_server_filtered_bounded_and_pages():
    calls = []
    def respond(request):
        calls.append(request)
        return httpx.Response(200, json={"value": [{"id": "group-1", "displayName": "Contoso"}],
            "@odata.nextLink": "https://graph.microsoft.com/v1.0/groups?$skiptoken=next"})
    client = graph(respond)
    page = client.search("contoso", limit=50)
    assert calls[0].url.params["$filter"] == "startswith(displayName,'contoso')"
    assert calls[0].url.params["$top"] == "50"
    assert page["next_cursor"]
    client.search("contoso", cursor=page["next_cursor"])
    assert calls[-1].url.params["$skiptoken"] == "next"
    with pytest.raises(FinOpsError, match="search"):
        client.search("different", cursor=page["next_cursor"])


def test_create_group_is_preview_first_and_binds_signed_in_owner():
    calls, created = [], []
    def respond(request):
        calls.append(request)
        if request.url.path == "/v1.0/me":
            return httpx.Response(200, json={"id": "00000000-0000-0000-0000-000000000001"})
        if request.method == "POST":
            created.append(json.loads(request.content))
            return httpx.Response(201, json={"id": "00000000-0000-0000-0000-000000000002", "displayName": "aum-e2e-unit-test"})
        if request.url.path.endswith("/owners"):
            return httpx.Response(200, json={"value": [{"id": "00000000-0000-0000-0000-000000000001"}]})
        return httpx.Response(200, json={"value": []})
    client = graph(respond)
    plan = client.create("aum-e2e-unit-test", "Temporary test security group")
    assert plan["preview"] and not created
    result = client.create("aum-e2e-unit-test", "Temporary test security group", apply=True, confirm="aum-e2e-unit-test")
    assert result["owner_verified"]
    assert created[0]["mailEnabled"] is False and created[0]["securityEnabled"] is True
    assert plan["owner_id"] == "00000000-0000-0000-0000-000000000001"


def test_untrusted_next_link_is_refused_before_sending_bearer():
    from claude_finops.groups import encode_cursor
    calls = []
    client = graph(lambda request: calls.append(request))
    cursor = encode_cursor("x", "https://other.contoso.com/v1.0/groups")
    with pytest.raises(FinOpsError, match="Graph"):
        client.search("x", cursor=cursor)
    assert not calls


def test_group_mutation_refuses_nonowner_and_preserves_error_code():
    calls = []
    def respond(request):
        calls.append(request)
        if request.url.path.endswith("/me"):
            return httpx.Response(200, json={"id": "00000000-0000-0000-0000-000000000001"})
        return httpx.Response(200, json={"value": []})
    client = graph(respond)
    with pytest.raises(FinOpsError, match="owner"):
        client.delete("00000000-0000-0000-0000-000000000002", "test", apply=True, confirm="test")
    assert all(call.method == "GET" for call in calls)


def test_graph_error_never_includes_tokens_and_carries_exact_safe_message():
    client = graph(lambda _: httpx.Response(403, json={"error": {
        "code": "Authorization_RequestDenied", "message": "Insufficient privileges to complete the operation."}}))
    with pytest.raises(FinOpsError) as failure:
        client.search("aum")
    assert "Authorization_RequestDenied: Insufficient privileges to complete the operation." in str(failure.value)
    assert "test-only" not in str(failure.value)
