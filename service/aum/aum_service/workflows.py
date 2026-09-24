from datetime import UTC, datetime, timedelta
import logging
from uuid import uuid4

from .auth import Identity
from .errors import AccessDenied, Conflict, invalid
from .registry import tokens
from .service import reason, utc


SYSTEM = Identity("system:boost-expiry", "AUM expiry timer", "", "admin", None, 0)


def parse_time(value):
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            raise ValueError()
        return parsed.astimezone(UTC)
    except (ValueError, AttributeError, TypeError) as error:
        raise invalid("Timestamp must be an ISO 8601 date-time with a timezone") from error


class Workflows:
    def __init__(self, service):
        self.service = service
        self.store = service.store

    def request(self, identity, body):
        identity.require_writer()
        why = reason(body)
        with self.store.lease() as lease:
            _, config, mappings, scope = self.service.prepare(identity, require_revision=False)
            kind, key = body.get("scope_type"), body.get("scope_id")
            config.require_target(kind, key)
            members = self.service.members(config, [key] if kind == "user" else [])
            if scope is not None:
                scope.require_read(kind, key, members.get(key))
            approver = (members.get(key) if kind == "user" else config.parents.get(key))
            if kind == "user" and approver not in config.by_id:
                raise Conflict("A person's parent cannot be established", "unknown_parent")
            record = {"id": str(uuid4()), "scope_type": kind, "scope_id": key,
                      "token_limit": tokens(body.get("token_limit"), 1), "reason": why,
                      "requester": identity.oid, "approver_scope": approver, "state": "pending",
                      "version": 1, "created_at": utc(self.service.clock())}
            def work():
                lease()
                self.store.put("requests", record["id"], record, create=True)
                return record
            audit, _ = self.service.audit_change(identity, "request.create", why, None, record, work)
            return {**record, "audit_id": audit}

    def can_approve(self, identity, record, mappings):
        if identity.oid == record["requester"]:
            return False
        if identity.is_admin:
            return True
        group = mappings.get(record.get("approver_scope"))
        return identity.access == "manager" and group is not None and group.lower() in identity.groups

    def decide(self, identity, id_, action, body):
        identity.require_writer()
        why = reason(body)
        if action not in {"approve", "reject", "escalate"}:
            raise invalid("Action must be approve, reject or escalate")
        override = body.get("admin_override", False)
        if type(override) is not bool:
            raise invalid("admin_override must be a boolean")
        if override:
            identity.require_admin()
        with self.store.lease() as lease:
            snapshot, config, mappings, scope = self.service.prepare(identity, require_revision=False)
            record = self.store.get("requests", id_)
            if not record:
                raise AccessDenied("Request is not accessible")
            if record["state"] != "pending" or type(body.get("version")) is not int or body["version"] != record["version"]:
                raise Conflict("Request changed; read it again", "stale_request")
            approver = self.can_approve(identity, record, mappings) or (identity.is_admin and override)
            if not approver and not (action == "escalate" and record["requester"] == identity.oid):
                raise AccessDenied("Only the next-level manager or an administrator may decide")
            after = {**record, "version": record["version"] + 1,
                     "decision_by": identity.oid, "decision_at": utc(self.service.clock()),
                     "decision_reason": why, "admin_override": override}
            if action == "escalate":
                if record["approver_scope"] is None:
                    raise Conflict("Request is already escalated to administrators")
                after["approver_scope"] = config.parents.get(record["approver_scope"])
            else:
                after["state"] = "approved" if action == "approve" else "rejected"
            def work():
                lease()
                if action == "approve":
                    self.service.apply_budget(identity, snapshot, config, scope,
                                              record["scope_type"], record["scope_id"],
                                              {"token_limit": record["token_limit"], "reason": why}, lease)
                self.store.put("requests", id_, after)
                return after
            audit, result = self.service.audit_change(identity, f"request.{action}", why, record, after, work)
        _, updated, mappings, _ = self.service.context(identity)
        return {"audit_id": audit, "result": result, "revision": updated.revision(mappings)}

    def boost(self, identity, body, expected):
        identity.require_writer()
        why = reason(body)
        expiry = parse_time(body.get("expires_at"))
        now = self.service.clock()
        if expiry <= now or expiry > now + timedelta(days=31):
            raise invalid("Boost expiry must be in the future and within 31 days")
        with self.store.lease() as lease:
            snapshot, config, mappings, scope = self.service.prepare(identity, expected)
            kind, key = body.get("scope_type"), body.get("scope_id")
            amount = tokens(body.get("token_limit"), 1)
            changes = self.service.plan_budget(identity, config, scope, kind, key, amount)
            previous = config.current_limit(kind, key)
            baseline = previous if previous is not None else max(
                config.tier(t)["tokens_per_day"] for t in ("standard", "premium")
            )
            if baseline <= 0 or amount <= baseline:
                raise invalid("A boost must increase a finite current budget")
            record = {"id": str(uuid4()), "scope_type": kind, "scope_id": key,
                      "token_limit": amount, "previous_limit": previous, "expires_at": utc(expiry),
                      "state": "pending", "requester": identity.oid, "reason": why,
                      "created_at": utc(now)}
            def work():
                lease()
                # Durable before ARM: a crash after a write still leaves an expirable record.
                self.store.put("boosts", record["id"], record, create=True)
                try:
                    from .transactions import apply_values
                    apply_values(self.service.arm, snapshot, changes, lease)
                except Exception:
                    # A write with an uncertain outcome must remain visible to the timer.
                    raise
                active = {**record, "state": "active"}
                self.store.put("boosts", record["id"], active)
                return active
            audit, result = self.service.audit_change(identity, "boost.create", why,
                                                     {"token_limit": previous}, record, work)
        _, updated, mappings, _ = self.service.context(identity)
        return {"audit_id": audit, "result": result, "revision": updated.revision(mappings)}

    def expire(self):
        records = self.store.due_boosts(utc(self.service.clock()))
        results = []
        for candidate in records:
            try:
                with self.store.lease() as lease:
                    record = self.store.get("boosts", candidate["id"])
                    if record["state"] not in {"active", "pending"} or parse_time(record["expires_at"]) > self.service.clock():
                        continue
                    snapshot, config, mappings, scope = self.service.prepare(SYSTEM, require_revision=False)
                    kind, key = record["scope_type"], record["scope_id"]
                    current = config.current_limit(kind, key)
                    state = "expired" if current in (record["token_limit"], record["previous_limit"]) else "superseded"
                    after = {**record, "state": state, "completed_at": utc(self.service.clock())}
                    def work():
                        if current == record["token_limit"]:
                            self.service.apply_budget(SYSTEM, snapshot, config, None, kind, key,
                                                      {"token_limit": record["previous_limit"],
                                                       "reason": "Boost expired"}, lease, restoring=True)
                        lease()
                        self.store.put("boosts", record["id"], after)
                        return after
                    self.service.audit_change(SYSTEM, "boost." + state, "Scheduled expiry", record, after, work)
                    results.append(after)
            except Exception:
                logging.warning("AUM boost expiry failed; durable record retained for next timer tick")
        return results
