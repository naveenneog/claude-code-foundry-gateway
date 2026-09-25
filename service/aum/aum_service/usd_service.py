from copy import deepcopy
from datetime import datetime
from decimal import Decimal

from .errors import Conflict, invalid
from .service import reason
from .transactions import apply_values
from .usd_budgets import (
    calculate_state, check_authority, decode_state, dollars, encode_document,
    parse_budgets, price_row, source_revision,
)


class UsdBudgets:
    def __init__(self, service):
        self.service = service

    def visible(self, identity, config, scope, items):
        people = [k.split(":", 1)[1] for k in items if k.startswith("user:")]
        members = self.service.members(config, people)
        return {key: item for key, item in items.items()
                if scope is None or scope.contains_leaf(
                    members.get(key.split(":", 1)[1]) if key.startswith("user:") else key.split(":", 1)[1])}

    def read(self, identity):
        _, config, mappings, scope = self.service.context(identity)
        doc = parse_budgets(config.values.get("usd-budgets"))
        items = self.visible(identity, config, scope, doc.get("items", {}))
        return {"schema_version": 1, "currency": "USD", "revision": config.revision(mappings),
                "price_book_date": doc.get("price_book", {}).get("date"), "items": [
                    {"scope_type": key.split(":")[0], "scope_id": key.split(":")[1], **item,
                     "writable": identity.is_admin or (identity.access == "manager" and (
                         key.startswith("user:") or key.split(":")[1] in scope.writable_department_ids))}
                    for key, item in items.items()]}

    def status(self, identity):
        _, config, _, scope = self.service.context(identity)
        state = decode_state(config.values.get("usd-budget-state"))
        fresh = bool(state and state.get("source_revision") == source_revision(config.values)
                     and datetime.fromisoformat(state["valid_until"].replace("Z", "+00:00")) > self.service.clock())
        return {"enabled": bool(parse_budgets(config.values.get("usd-budgets")).get("items")), "fresh": fresh,
                "reconcile_interval_seconds": 300, "state_max_age_seconds": 900,
                **{k: v for k, v in state.items() if k != "items"},
                "items": self.visible(identity, config, scope, state.get("items", {}))}

    def book(self, identity):
        _, config, mappings, _ = self.service.context(identity)
        doc = parse_budgets(config.values.get("usd-budgets"))
        return {"price_book": doc.get("price_book"), "revision": config.revision(mappings)}

    def set_book(self, identity, body, expected):
        identity.require_admin()
        with self.service.store.lease() as lease:
            snapshot, config, mappings, _ = self.service.prepare(identity, expected)
            check_authority(config.values)
            doc = parse_budgets(config.values.get("usd-budgets"))
            if doc.get("items") and doc.get("price_book") != body["price_book"]:
                raise Conflict("Active budgets pin their tariff; clear them explicitly before replacing the price book",
                               "usd_price_book_pinned")
            doc = {"schema_version": 1, "price_book": body["price_book"], "items": doc.get("items", {})}
            parse_budgets(encode_document(doc))
            for model in doc["price_book"]["models"]:
                price_row({"deployment": model, **{k + "_tokens": 0 for k in (
                    "prompt", "completion", "cache_read", "cache_write_5m", "cache_write_1h")}}, doc["price_book"])
            changes = {"usd-budgets": encode_document(doc)}
            audit_id, _ = self.service.audit_change(
                identity, "usd.price_book", reason(body), config.values.get("usd-budgets"), changes["usd-budgets"],
                lambda: apply_values(self.service.arm, snapshot, changes, lease))
        return {"audit_id": audit_id, **self.book(identity)}

    def headroom(self, config, doc):
        reservations = {}
        people = [key.split(":", 1)[1] for key in doc["items"] if key.startswith("user:")]
        members = self.service.members(config, people)
        for key, item in doc["items"].items():
            kind, target = key.split(":", 1)
            parent = members.get(target) if kind == "user" else config.parents.get(target)
            if kind == "user" and not parent:
                raise Conflict("Person's parent is unknown; cannot reserve USD headroom", "unknown_parent")
            while parent:
                parent_kind = "department" if parent in config.parents else "organization"
                if parent_kind + ":" + parent in doc["items"]:
                    break
                parent = config.parents.get(parent)
            if parent:
                reservation = dollars(item["amount_usd"]) * (31 if item["period"] == "day" else 1)
                reservations[parent] = reservations.get(parent, Decimal(0)) + reservation
        for parent, used in reservations.items():
            kind = "department" if parent in config.parents else "organization"
            limit = doc["items"].get(kind + ":" + parent)
            if limit and used > dollars(limit["amount_usd"]):
                raise Conflict("Dollar allocations exceed their parent's USD budget", "insufficient_headroom")

    def set_budget(self, identity, kind, key, body, expected, clear=False):
        identity.require_writer()
        with self.service.store.lease() as lease:
            snapshot, config, mappings, scope = self.service.prepare(identity, expected)
            check_authority(config.values)
            config.require_target(kind, key)
            members = self.service.members(config, [key] if kind == "user" else [])
            if scope is not None:
                scope.require_write(kind, key, members.get(key))
            doc = deepcopy(parse_budgets(config.values.get("usd-budgets")))
            if not doc:
                raise Conflict("An administrator must initialize the USD price book first", "usd_price_book_missing")
            target = kind + ":" + key
            if clear:
                doc["items"].pop(target, None)
            else:
                dollars(body.get("amount_usd"))
                doc["items"][target] = {k: body[k] for k in ("amount_usd", "period", "price_book_date")}
            encoded = encode_document(doc)
            parse_budgets(encoded)
            self.headroom(config, doc)
            calculate_state({**config.values, "usd-budgets": encoded}, [], self.service.clock())
            audit_id, _ = self.service.audit_change(
                identity, "usd.budget." + target, reason(body), config.values.get("usd-budgets"), encoded,
                lambda: apply_values(self.service.arm, snapshot, {"usd-budgets": encoded}, lease))
        _, updated, mappings, _ = self.service.context(identity)
        return {"audit_id": audit_id, "revision": updated.revision(mappings),
                "result": {"scope_type": kind, "scope_id": key, **doc["items"].get(target, {"cleared": True})}}
