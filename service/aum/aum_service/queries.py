import base64
import hashlib
import json
import re
from datetime import timedelta

from .auth import object_id
from .errors import invalid
from .registry import entity_id
from .service import utc
from .workflows import parse_time


def literal(value):
    return json.dumps(str(value), ensure_ascii=True)


def encode_cursor(value):
    return base64.urlsafe_b64encode(json.dumps(value, separators=(",", ":")).encode()).decode()


def decode_cursor(value):
    try:
        if not isinstance(value, str) or len(value) > 2048:
            raise ValueError()
        result = json.loads(base64.b64decode(value, altchars=b"-_", validate=True))
        if not isinstance(result, dict) or not all(k in result for k in ("after", "query_hash", "from", "to")):
            raise ValueError()
        if not isinstance(result["after"], list) or not all(
            isinstance(s, str) and len(s) <= 200 for s in result["after"]
        ):
            raise ValueError()
        return result
    except (ValueError, TypeError, UnicodeDecodeError) as error:
        raise invalid("Cursor is invalid; start a new query") from error


def page_size(params):
    try:
        limit = int(params.get("limit", 100))
        if not 1 <= limit <= 200:
            raise ValueError()
        return limit
    except (ValueError, TypeError) as error:
        raise invalid("limit must be from 1 to 200") from error


class QueryBuilder:
    def __init__(self, service):
        self.service = service

    def build(self, kind, identity, params):
        allowed = {"from", "to", "organization_id", "department_id", "user_id", "search", "limit", "cursor"}
        if set(params) - allowed:
            raise invalid("Unknown query parameter")
        limit = page_size(params)
        _, config, _, scope = self.service.context(identity)
        filters = {}
        for name, scope_type in (("organization_id", "organization"), ("department_id", "department"),
                                 ("user_id", "user")):
            key = params.get(name)
            if not key:
                continue
            if scope_type == "user":
                try:
                    key = object_id(key)
                except ValueError as error:
                    raise invalid("user_id must be an object id") from error
            else:
                entity_id(key)
                config.require_target(scope_type, key)
            if scope is not None:
                leaf = self.service.members(config, [key]).get(key) if scope_type == "user" else None
                scope.require_read(scope_type, key, leaf)
            filters[name] = key
        search = params.get("search", "")
        if not isinstance(search, str) or len(search) > 100:
            raise invalid("search must be at most 100 characters")
        fingerprint = hashlib.sha256(json.dumps(
            [kind, identity.oid, sorted(scope.organization_ids | scope.department_ids) if scope else None,
             filters, search, params.get("from"), params.get("to")], sort_keys=True,
        ).encode()).hexdigest()
        cursor = decode_cursor(params["cursor"]) if params.get("cursor") else None
        if cursor and cursor["query_hash"] != fingerprint:
            raise invalid("Cursor no longer matches this identity, scope or filter")
        now = self.service.clock()
        start = parse_time(cursor["from"] if cursor else params.get("from", utc(now.replace(
            day=1, hour=0, minute=0, second=0, microsecond=0))))
        end = parse_time(cursor["to"] if cursor else params.get("to", utc(now)))
        if end <= start or end - start > timedelta(days=93) or end > now + timedelta(minutes=1):
            raise invalid("Query window must be positive, no more than 93 days, and not in the future")
        source = "ClaudeChargeback" if kind == "requests" else "ClaudeCost"
        kql = f"{source}(datetime({utc(start)}), datetime({utc(end)}))"
        leaves = None
        if scope is not None:
            leaves = set(scope.organization_ids | scope.department_ids)
        if filters.get("organization_id"):
            unit = filters["organization_id"]
            selected = {unit} | {k for k, parent in config.parents.items() if parent == unit}
            leaves = selected if leaves is None else leaves & selected
        if filters.get("department_id"):
            selected = {filters["department_id"]}
            leaves = selected if leaves is None else leaves & selected
        if leaves is not None:
            kql += "\n| where " + ("business_unit in (" + ",".join(literal(x) for x in sorted(leaves)) + ")"
                                  if leaves else "false")
        if filters.get("user_id"):
            kql += "\n| where user_id == " + literal(filters["user_id"])
        aggregate = ("requests=sum(requests), prompt_tokens=sum(prompt_tokens), "
                     "completion_tokens=sum(completion_tokens), cache_read_tokens=sum(cache_read_tokens), "
                     "usd=sum(usd), unpriced_rows=countif(priced_ok == false)")
        if kind == "usage":
            kql += "\n| summarize " + aggregate
        elif kind == "trends":
            kql += "\n| summarize " + aggregate + " by day\n| order by day asc\n| take 94"
        elif kind == "people":
            if search:
                kql += "\n| where actor contains " + literal(search) + " or user_id startswith " + literal(search)
            kql += ("\n| where isnotempty(user_id)\n| summarize arg_max(day, actor, business_unit, business_unit_parent) by user_id"
                    "\n| project id=user_id, name=actor, parent_id=business_unit, "
                    "organization_id=iff(isempty(business_unit_parent), business_unit, business_unit_parent), "
                    "department_id=iff(isempty(business_unit_parent), '', business_unit)")
            if cursor:
                if len(cursor["after"]) != 1:
                    raise invalid("Invalid people cursor")
                kql += "\n| where id > " + literal(cursor["after"][0])
            kql += f"\n| order by id asc\n| take {limit + 1}"
        elif kind == "requests":
            if cursor:
                if len(cursor["after"]) != 2:
                    raise invalid("Invalid requests cursor")
                timestamp = cursor["after"][0]
                if not re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?Z", timestamp):
                    raise invalid("Invalid request timestamp cursor")
                parse_time(timestamp)
                rid = literal(cursor["after"][1])
                kql += (f"\n| where timestamp < datetime({timestamp}) or "
                        f"(timestamp == datetime({timestamp}) and request_id > {rid})")
            kql += f"\n| order by timestamp desc, request_id asc\n| take {limit + 1}"
        else:
            raise invalid("Unknown analytics view")
        return kql, limit, {"from": utc(start), "to": utc(end), "query_hash": fingerprint}

    def read(self, kind, identity, params):
        query, limit, cursor = self.build(kind, identity, params)
        rows = self.service.analytics.query(query)
        if kind == "usage":
            return {**(rows[0] if rows else {}), "cost_is_estimate": True,
                    "cache_write_known": False, "as_of": utc(self.service.clock())}
        if kind == "trends":
            return {"items": rows, "next_cursor": None, "cost_is_estimate": True}
        more = len(rows) > limit
        items = rows[:limit]
        next_cursor = None
        if more:
            last = items[-1]
            after = [str(last["id"])] if kind == "people" else [str(last["timestamp"]), str(last["request_id"])]
            next_cursor = encode_cursor({**cursor, "after": after})
        return {"items": items, "next_cursor": next_cursor}
