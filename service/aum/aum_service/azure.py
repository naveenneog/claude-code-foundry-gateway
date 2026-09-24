import re
import time

import requests

from .auth import object_id
from .errors import Conflict, ServiceError, invalid
from .queries import literal
from .registry import CONFIG_NAMES, checked_value


class AzureHttp:
    def __init__(self, credential, scope, session=None):
        self.credential, self.scope = credential, scope
        self.session = session or requests.Session()

    def call(self, method, url, body=None, headers=None):
        token = self.credential.get_token(self.scope).token
        response = self.session.request(
            method, url, json=body, headers={"Authorization": "Bearer " + token,
                                           "Content-Type": "application/json", **(headers or {})},
            timeout=(10, 60),
        )
        if response.status_code in (409, 412):
            raise Conflict("Azure resource changed during the write", "azure_conflict")
        if response.status_code == 429:
            raise ServiceError(429, "azure_throttled", "Azure throttled the request; retry reads later")
        if not response.ok:
            raise ServiceError(503, "azure_unavailable", f"Azure dependency returned HTTP {response.status_code}")
        return response.json() if response.content else {}, dict(response.headers)


class NamedValues:
    def __init__(self, apim_id, http):
        if not re.fullmatch(r"/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[A-Za-z0-9._()-]+/"
                            r"providers/Microsoft.ApiManagement/service/[A-Za-z0-9-]+", apim_id):
            raise invalid("AUM_APIM_RESOURCE_ID must identify one gateway")
        self.base = "https://management.azure.com" + apim_id
        self.http = http

    def url(self, name=None):
        return self.base + "/namedValues" + ("/" + name if name else "") + "?api-version=2024-05-01"

    def read(self):
        url, values = self.url(), {}
        for _ in range(100):
            payload, _ = self.http.call("GET", url)
            for row in payload.get("value", []):
                if row["name"] in CONFIG_NAMES:
                    if row["properties"].get("secret") or "value" not in row["properties"]:
                        raise ServiceError(503, "configuration_unreadable", "A gateway setting is secret or unreadable")
                    values[row["name"]] = {"value": row["properties"]["value"], "etag": row.get("etag")}
            url = payload.get("nextLink")
            if not url:
                return values
            if not url.startswith(self.base + "/namedValues?"):
                raise ServiceError(503, "invalid_continuation", "ARM returned an unexpected continuation address")
        raise ServiceError(503, "configuration_too_large", "ARM configuration paging exceeded its limit")

    def get(self, key):
        if key not in CONFIG_NAMES:
            raise invalid("Named value is not in the service allow-list")
        payload, headers = self.http.call("GET", self.url(key))
        etag = headers.get("ETag") or headers.get("etag") or payload.get("etag")
        if not etag:
            raise ServiceError(503, "etag_missing", "ARM did not return an ETag; refusing an unconditional write")
        return {"value": payload["properties"]["value"], "etag": etag}

    def put(self, key, value, etag):
        if key not in CONFIG_NAMES or not etag:
            raise invalid("A named-value write requires an allowed key and ETag")
        checked_value(value)
        payload, headers = self.http.call(
            "PUT", self.url(key),
            body={"properties": {"displayName": key, "value": value, "secret": False}},
            headers={"If-Match": etag},
        )
        poll = headers.get("Azure-AsyncOperation") or headers.get("azure-asyncoperation")
        if poll:
            if not poll.startswith(self.base + "/"):
                raise ServiceError(503, "invalid_poll_url", "ARM returned an unexpected operation address")
            for _ in range(24):
                operation, _ = self.http.call("GET", poll)
                if operation.get("status") == "Succeeded":
                    return self.get(key)
                if operation.get("status") in {"Failed", "Canceled"}:
                    raise ServiceError(502, "arm_operation_failed", "Named-value operation failed")
                time.sleep(2)
            raise ServiceError(504, "arm_operation_pending", "Write is still pending; inspect audit and gateway state")
        version = headers.get("ETag") or headers.get("etag") or payload.get("etag")
        if version and "value" in payload.get("properties", {}):
            return {"value": payload["properties"]["value"], "etag": version}
        return self.get(key)


class LogAnalytics:
    def __init__(self, workspace_id, http):
        self.url = f"https://api.loganalytics.azure.com/v1/workspaces/{object_id(workspace_id)}/query"
        self.http = http

    def query(self, query):
        result, _ = self.http.call("POST", self.url, body={"query": query},
                                  headers={"Prefer": "wait=60"})
        if result.get("error") or not isinstance(result.get("tables"), list):
            raise ServiceError(503, "analytics_incomplete", "Log Analytics did not return a complete result")
        tables = result["tables"]
        if not tables:
            raise ServiceError(503, "analytics_incomplete", "Log Analytics returned no result table")
        table = tables[0]
        columns = [c["name"] for c in table["columns"]]
        if len(table["rows"]) > 1000:
            raise ServiceError(503, "analytics_unbounded", "Query returned more than the bounded response limit")
        return [dict(zip(columns, row, strict=True)) for row in table["rows"]]

    def memberships(self, ids):
        if len(ids) > 200:
            raise invalid("Membership lookup must be bounded to 200 object ids")
        if not ids:
            return {}
        selected = ",".join(literal(object_id(id_)) for id_ in ids)
        query = (f"ClaudeCost(ago(93d), now())\n| where user_id in ({selected})"
                 "\n| summarize arg_max(day, business_unit) by user_id"
                 "\n| project id=user_id, parent_id=business_unit\n| take 201")
        return {r["id"]: r["parent_id"] for r in self.query(query)}
