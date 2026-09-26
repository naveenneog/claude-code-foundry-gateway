"""Delegated directory developer discovery and gateway entitlement changes."""

import base64
import hashlib
import json
import re
import time
from uuid import UUID
from urllib.parse import urlsplit

from .errors import FinOpsError
from .groups import EntraGroups, GRAPH, object_id
from .redaction import mask_identifiers


def encode_user_cursor(query, url):
    payload = dict(query=hashlib.sha256(query.encode()).hexdigest(), url=url)
    return base64.urlsafe_b64encode(json.dumps(payload).encode()).decode()


def _quote(value):
    return str(value).replace("'", "''")


def _candidate(row, state=None):
    state = state or {}
    oid = row.get("id", "")
    entitlements = state.get("entitlements", {})
    memberships = state.get("memberships", {})
    tier = "premium" if oid in entitlements.get("premium", []) else "standard" if oid in entitlements.get("standard", []) else ""
    unit = memberships.get(oid, "")
    address = row.get("mail") or (row.get("otherMails") or [""])[0] or row.get("userPrincipalName", "")
    return dict(id=oid, display_name=row.get("displayName", ""), user_principal_name=row.get("userPrincipalName", ""),
                mail=address, user_type=row.get("userType", ""), current_tier=tier, current_unit=unit)


class EntraDevelopers(EntraGroups):
    """User-oriented Graph operations. Uses the same Azure CLI delegated token as group ops."""

    user_select = "id,displayName,userPrincipalName,mail,otherMails,userType"

    def _paged(self, path, params=None, limit=50):
        items, url = [], path
        while url and len(items) < limit:
            page = self.request("GET", url, params=params if url == path else None)
            items.extend(page.get("value", []))
            url = page.get("@odata.nextLink")
            params = None
        return items[:limit], url

    def search_developers(self, text, limit=50, cursor=None, state=None):
        if not isinstance(text, str) or not 1 <= len(text.strip()) <= 100 or not 1 <= limit <= 100:
            raise FinOpsError("Enter 1-100 characters; page size is 1-100.")
        text = text.strip()
        if cursor:
            try:
                value = json.loads(base64.urlsafe_b64decode(cursor))
                if value["query"] != hashlib.sha256(text.encode()).hexdigest():
                    raise ValueError()
                path = value["url"]
                if urlsplit(path).path != "/v1.0/users":
                    raise ValueError()
            except (ValueError, KeyError, TypeError):
                raise FinOpsError("Developer cursor does not match this search. Start a new search.") from None
            page = self.request("GET", path)
            rows = page.get("value", [])
            next_link = page.get("@odata.nextLink")
        else:
            rows = []
            next_link = None
            if "@" in text:
                for expression in (
                    f"mail eq '{_quote(text)}'",
                    f"userPrincipalName eq '{_quote(text)}'",
                    f"otherMails/any(m:m eq '{_quote(text)}')",
                    f"startswith(userPrincipalName,'{_quote(re.split(r'[@#]', text, maxsplit=1)[0])}')",
                ):
                    rows.extend(self._users_filter(expression, top=limit))
                rows = list({row.get("id"): row for row in rows if row.get("id")}.values())[:limit]
            if not rows:
                terms = text.replace('"', '\\"')
                search = f'"displayName:{terms}" OR "mail:{terms}" OR "userPrincipalName:{terms}"'
                params = {"$search": search, "$select": self.user_select, "$top": str(limit), "$count": "true"}
                page = self.request("GET", "/v1.0/users", params=params)
                rows = page.get("value", [])
                next_link = page.get("@odata.nextLink")
        return dict(items=[_candidate(row, state) for row in rows],
                    next_cursor=encode_user_cursor(text, next_link) if next_link else None,
                    note="Directory search uses the signed-in admin's delegated Microsoft Graph token; no consent or app permission is requested.")

    def _users_filter(self, filter_value, top=6):
        return self.request("GET", "/v1.0/users", {"$filter": filter_value, "$select": self.user_select,
                                                    "$top": str(top), "$count": "true"}).get("value", [])

    def resolve_exact(self, query, *, state=None):
        if not isinstance(query, str) or not 1 <= len(query.strip()) <= 200:
            raise FinOpsError("Enter an email, UPN or object id.")
        query = query.strip()
        candidates = []
        try:
            UUID(query)
            row = self.request("GET", f"/v1.0/users/{query}", {"$select": self.user_select}, allow_missing=True)
            if row:
                return _candidate(row, state)
        except ValueError:
            pass
        for expression in (
            f"mail eq '{_quote(query)}'",
            f"userPrincipalName eq '{_quote(query)}'",
            f"otherMails/any(m:m eq '{_quote(query)}')",
        ):
            rows = self._users_filter(expression)
            if len(rows) == 1:
                return _candidate(rows[0], state)
            candidates.extend(rows)
        if "@" in query:
            stem = re.split(r"[@#]", query, maxsplit=1)[0]
            rows = self._users_filter(f"startswith(userPrincipalName,'{_quote(stem)}')", top=10)
            ext_rows = [row for row in rows if "#EXT#" in row.get("userPrincipalName", "")]
            if len(ext_rows) == 1:
                return _candidate(ext_rows[0], state)
            candidates.extend(ext_rows)
        unique = {row.get("id"): row for row in candidates if row.get("id")}
        if len(unique) > 1:
            shown = ", ".join(mask_identifiers(row.get("userPrincipalName") or row.get("mail") or row["id"])
                              for row in unique.values())
            raise FinOpsError(f"The requested developer matches several accounts: {shown}. Pass the object id.", 5)
        raise FinOpsError(f"No account matches '{mask_identifiers(query)}' by object id, mail, otherMails or UPN.", 5)

    def group_id(self, value):
        try:
            return object_id(value)
        except FinOpsError:
            rows = self.request("GET", "/v1.0/groups", {"$filter": f"displayName eq '{_quote(value)}'",
                                  "$select": "id,displayName", "$top": "3", "$count": "true"}).get("value", [])
            if len(rows) == 1:
                return rows[0]["id"]
            if len(rows) > 1:
                raise FinOpsError(f"Group name '{value}' is ambiguous. Use the group object id.", 5)
            raise FinOpsError(f"No Entra group '{value}'.", 5)

    def direct_memberships(self, user_id):
        result, url = set(), f"/v1.0/users/{object_id(user_id)}/memberOf?$select=id&$top=999"
        while url:
            page = self.request("GET", url)
            result.update(row["id"] for row in page.get("value", []))
            url = page.get("@odata.nextLink")
        return result

    def wait_membership(self, user_id, group_id, present):
        for attempt in range(31):
            current = self.direct_memberships(user_id)
            if (group_id in current) == present:
                return
            if attempt < 30:
                time.sleep(2)
        raise FinOpsError("Membership write could not be verified after propagation wait. Refresh before retrying.", 7)

    def apply_membership(self, user_id, group_id, want):
        user_id, group_id = object_id(user_id), object_id(group_id)
        is_member = group_id in self.direct_memberships(user_id)
        if is_member == want:
            return False
        if want:
            self.request("POST", f"/v1.0/groups/{group_id}/members/$ref",
                         body={"@odata.id": GRAPH + "/v1.0/directoryObjects/" + user_id})
        else:
            self.request("DELETE", f"/v1.0/groups/{group_id}/members/{user_id}/$ref")
        self.wait_membership(user_id, group_id, want)
        return True
