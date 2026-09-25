"""Delegated Graph group administration. Never adds consent or app permissions."""

import base64
import hashlib
import json
import re
import time
from urllib.parse import urlsplit
from uuid import UUID

import httpx

from .config import az, token_needs_refresh
from .errors import FinOpsError
from .redaction import mask_identifiers

GRAPH = "https://graph.microsoft.com"


def object_id(value):
    try:
        return str(UUID(value))
    except (ValueError, TypeError):
        raise FinOpsError("Choose an Entra object id returned by group search.") from None


def encode_cursor(query, url):
    payload = dict(query=hashlib.sha256(query.encode()).hexdigest(), url=url)
    return base64.urlsafe_b64encode(json.dumps(payload).encode()).decode()


class EntraGroups:
    def __init__(self, token_provider=None, transport=None, config=None):
        selected = ("--tenant", config.tenant_id) if config and config.tenant_id else ()
        self.provider = token_provider or (lambda: az("account", "get-access-token", "--resource", GRAPH,
                                                     "--query", "accessToken", "-o", "tsv", *selected))
        self.client = httpx.Client(base_url=GRAPH, timeout=60, follow_redirects=False, transport=transport)
        self.token = None

    def close(self):
        self.token = None
        self.client.close()

    def request(self, method, path, params=None, body=None, allow_missing=False):
        url = urlsplit(path if path.startswith("http") else GRAPH + path)
        if url.scheme != "https" or url.netloc != "graph.microsoft.com" or not url.path.startswith("/v1.0/"):
            raise FinOpsError("Refusing a continuation outside Microsoft Graph.")
        if token_needs_refresh(self.token):
            self.token = self.provider()
        try:
            result = self.client.request(method, path, params=params, json=body,
                headers={"Authorization": "Bearer " + self.token, "ConsistencyLevel": "eventual"})
        except httpx.HTTPError:
            raise FinOpsError("Graph transport failed. Mutations are not retried; inspect the group before repeating.", 7) from None
        if result.status_code == 404 and allow_missing:
            return None
        if not result.is_success:
            try:
                error = result.json()["error"]
                detail = f"{error['code']}: {error['message']}"
            except (ValueError, KeyError, TypeError):
                detail = "Graph did not return a structured error."
            detail = mask_identifiers(detail.replace(self.token, "[token omitted]"))
            raise FinOpsError(f"Graph HTTP {result.status_code}: {detail}", 4 if result.status_code == 403 else 7)
        return result.json() if result.content else {"deleted": True}

    def me(self):
        return self.request("GET", "/v1.0/me", {"$select": "id,displayName,userPrincipalName"})

    def memberships(self):
        result, url = set(), "/v1.0/me/memberOf/microsoft.graph.group?$select=id&$top=100&$count=true"
        while url:
            page = self.request("GET", url)
            result.update(row["id"] for row in page["value"])
            url = page.get("@odata.nextLink")
        return sorted(result)

    def search(self, text, limit=50, cursor=None):
        if not isinstance(text, str) or not 1 <= len(text.strip()) <= 100 or not 1 <= limit <= 100:
            raise FinOpsError("Enter a group-name prefix (1-100 characters); page size is 1-100.")
        text = text.strip()
        if cursor:
            try:
                value = json.loads(base64.urlsafe_b64decode(cursor))
                if value["query"] != hashlib.sha256(text.encode()).hexdigest():
                    raise ValueError()
                path = value["url"]
                if urlsplit(path).path != "/v1.0/groups":
                    raise ValueError()
            except (ValueError, KeyError, TypeError):
                raise FinOpsError("Group cursor does not match this search. Start a new search.") from None
            result = self.request("GET", path)
        else:
            escaped = text.replace("'", "''")
            result = self.request("GET", "/v1.0/groups", {"$filter": f"startswith(displayName,'{escaped}')",
                "$select": "id,displayName,description,securityEnabled,mailEnabled,groupTypes", "$top": str(limit)})
        return dict(items=result["value"], next_cursor=encode_cursor(text, result["@odata.nextLink"])
                    if result.get("@odata.nextLink") else None)

    def owners(self, group):
        result, url = [], f"/v1.0/groups/{object_id(group)}/owners?$select=id&$top=100"
        while url:
            page = self.request("GET", url)
            result += [row["id"] for row in page["value"]]
            url = page.get("@odata.nextLink")
        return result

    def require_owner(self, group):
        me = self.me()["id"]
        if me not in self.owners(group):
            raise FinOpsError("The signed-in account is not an owner of this group. Choose a group you own; AUM will not grant broader permissions.", 4)
        return me

    def replicated_owners(self, group):
        for attempt in range(31):
            try:
                return self.owners(group)
            except FinOpsError as error:
                if "Graph HTTP 404:" not in str(error) or attempt == 30:
                    raise
                time.sleep(2)

    def wait_member(self, group, member, present):
        for attempt in range(31):
            value = self.request("GET", f"/v1.0/groups/{group}/members/{member}", allow_missing=True)
            if (value is not None) == present:
                return
            if attempt < 30:
                time.sleep(2)
        raise FinOpsError("Membership write could not be verified after propagation wait. Refresh before retrying.", 7)

    def create(self, name, description="", *, apply=False, confirm=None, on_created=None):
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._ -]{0,119}", name):
            raise FinOpsError("Use a group name of 1-120 letters, numbers, spaces, dot, underscore or hyphen.")
        if len(description) > 1000:
            raise FinOpsError("Description must not exceed 1,000 characters.")
        owner = self.me()["id"]
        existing = self.search(name)["items"]
        if any(row["displayName"].casefold() == name.casefold() for row in existing):
            raise FinOpsError("An exact-name group already exists. Select it instead of creating a duplicate.", 6)
        plan = dict(preview=not apply, action="Create Entra security group", name=name, description=description,
                    owner_id=owner, effect="The signed-in owner can manage group membership. No app role or consent is granted. "
                    "Gateway membership changes require the next membership refresh.")
        if not apply:
            return plan
        if confirm != name:
            raise FinOpsError("Type the complete group name to confirm creation.")
        nickname = re.sub(r"[^A-Za-z0-9._-]", "-", name)[:50] + "-" + hashlib.sha256(name.encode()).hexdigest()[:8]
        created = self.request("POST", "/v1.0/groups", body=dict(displayName=name, description=description,
            mailEnabled=False, mailNickname=nickname, securityEnabled=True, groupTypes=[]))
        key = created["id"]
        if on_created:
            on_created(created)
        try:
            # Graph automatically owns delegated non-admin creations; an admin
            # security-group creation needs an explicit owner if none was added.
            if owner not in self.replicated_owners(key):
                self.request("POST", f"/v1.0/groups/{object_id(key)}/owners/$ref",
                             body={"@odata.id": GRAPH + "/v1.0/users/" + object_id(owner)})
            for attempt in range(31):
                if owner in self.replicated_owners(key):
                    break
                if attempt == 30:
                    raise FinOpsError("Created group owner could not be verified.", 7)
                time.sleep(2)
        except FinOpsError:
            try:
                self.request("DELETE", f"/v1.0/groups/{object_id(key)}")
            except FinOpsError as error:
                raise FinOpsError(f"Group created but owner verification and cleanup failed; manual recovery for group {key}. {error}", 7) from None
            raise FinOpsError("Created group owner verification failed; the new group was removed.", 7) from None
        return dict(plan, result=created, owner_verified=True)

    def member(self, group, member=None, *, remove=False, apply=False):
        group = object_id(group)
        me = self.require_owner(group)
        member = object_id(member or me)
        current = self.request("GET", f"/v1.0/groups/{group}/members/{member}", allow_missing=True)
        plan = dict(preview=not apply, action="Remove group member" if remove else "Add group member",
                    group_id=group, member_id=member, already_member=current is not None,
                    effect="Directory membership changes now; gateway mapping changes only after membership refresh.")
        if apply and ((remove and current) or (not remove and not current)):
            if remove:
                self.request("DELETE", f"/v1.0/groups/{group}/members/{member}/$ref")
            else:
                self.request("POST", f"/v1.0/groups/{group}/members/$ref",
                             body={"@odata.id": GRAPH + "/v1.0/directoryObjects/" + member})
            self.wait_member(group, member, not remove)
        return plan

    def delete(self, group, name, *, apply=False, confirm=None):
        self.require_owner(group)
        plan = dict(preview=not apply, action="Delete owned Entra group", group_id=group, name=name)
        if apply:
            if confirm != name:
                raise FinOpsError("Type the complete group name to confirm deletion.")
            current = self.request("GET", f"/v1.0/groups/{object_id(group)}")
            if current["displayName"] != name:
                raise FinOpsError("Group name changed since preview. Refresh before deletion.", 6)
            self.request("DELETE", f"/v1.0/groups/{object_id(group)}")
            for attempt in range(31):
                if self.request("GET", f"/v1.0/groups/{object_id(group)}", allow_missing=True) is None:
                    break
                if attempt == 30:
                    raise FinOpsError("Group deletion could not be verified after propagation wait.", 7)
                time.sleep(2)
        return plan
