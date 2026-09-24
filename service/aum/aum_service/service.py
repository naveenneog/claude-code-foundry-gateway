import calendar
from copy import deepcopy
from datetime import UTC, datetime
import re
from uuid import uuid4

from .auth import object_id
from .errors import AccessDenied, Conflict, ServiceError, invalid
from .registry import (
    Config, budget_changes, checked_value, entity_id, render_map, render_modes,
    render_registry, tokens, validate_headroom,
)
from .scope import resolve_scope
from .transactions import apply_values


def reason(body):
    value = body.get("reason")
    if not isinstance(value, str) or not 1 <= len(value.strip()) <= 500:
        raise invalid("A reason of 1 to 500 characters is required")
    return value.strip()


def utc(value):
    return value.astimezone(UTC).isoformat().replace("+00:00", "Z")


class AumService:
    def __init__(self, arm, store, analytics, clock=None):
        self.arm, self.store, self.analytics = arm, store, analytics
        self.clock = clock or (lambda: datetime.now(UTC))

    def context(self, identity):
        snapshot = self.arm.read()
        config = Config({k: v["value"] for k, v in snapshot.items()})
        mappings = self.store.mappings()
        scope = resolve_scope(identity.groups, config.entities(), mappings)
        return snapshot, config, mappings, scope

    def members(self, config, extra=()):
        result = dict(config.members)
        missing = (set(config.overrides) | set(extra)) - set(result)
        if missing:
            result.update(self.analytics.memberships(sorted(missing)))
        return result

    def me(self, identity):
        _, _, _, scope = self.context(identity)
        return {"id": identity.oid, "name": identity.name, "email": identity.email,
                "role": "owner" if identity.is_admin else "member",
                "access": identity.access, "method": "entra",
                "session_expires_at": utc(datetime.fromtimestamp(identity.expires_at, UTC)),
                "manager_scope": scope.profile() if scope is not None else None}

    def capabilities(self, identity):
        _, _, _, scope = self.context(identity)
        writer = identity.access in {"admin", "manager"}
        assigned = scope is None or bool(scope.organization_ids or scope.department_ids)
        return {"schema_version": 1, "backend": "aum-service", "capabilities": {
            "usage_read": True, "budgets_read": True, "budget_write": writer and assigned,
            "manager_budget_write": identity.access == "manager" and assigned,
            "catalog_write": identity.is_admin, "tiers_write": identity.is_admin,
            "modes_write": identity.is_admin, "budget_requests": writer and assigned,
            "approvals": writer and assigned, "boosts": writer and assigned,
            "notifications": True, "audit_read": identity.is_admin, "email_delivery": False,
        }, "limits": {"page_size": 200, "named_value_characters": 4096, "analytics_window_days": 93}}

    def catalog(self, identity):
        _, config, mappings, scope = self.context(identity)
        entities = scope.catalog() if scope is not None else config.entities()
        if identity.is_admin:
            entities = [{**e, "attributes": {**e["attributes"], "manager_group_id": mappings.get(e["id"])}}
                        for e in entities]
        return {"organizations": [e for e in entities if not e["parent_id"]],
                "departments": [e for e in entities if e["parent_id"]],
                "revision": config.revision(mappings)}

    def budgets(self, identity):
        _, config, mappings, scope = self.context(identity)
        members = self.members(config)
        items = []
        for unit in config.units:
            key = unit["Id"]
            kind = "department" if key in config.parents else "organization"
            if scope is not None and not scope.contains_leaf(key):
                continue
            writable = identity.is_admin or (scope is not None and key in scope.writable_department_ids)
            metadata = self.store.get("budgets", kind + ":" + key) or {}
            items.append({"scope_type": kind, "scope_id": key, "token_limit": unit["TokensPerMonth"] or None,
                          "period": "month", "writable": writable, **config.mode(key),
                          "warning_threshold_percent": metadata.get("warning_threshold_percent", 80)})
        for key, limit in config.overrides.items():
            if scope is not None and not scope.contains_leaf(members.get(key)):
                continue
            metadata = self.store.get("budgets", "user:" + key) or {}
            items.append({"scope_type": "user", "scope_id": key, "token_limit": limit,
                          "period": "day", "writable": identity.access != "viewer",
                          "enforcement": "strict", "allowance_percent": None,
                          "warning_threshold_percent": metadata.get("warning_threshold_percent", 80)})
        return {"items": items, "revision": config.revision(mappings)}

    def prepare(self, identity, expected=None, require_revision=True):
        identity.require_writer()
        snapshot, config, mappings, scope = self.context(identity)
        integration = config.values.get("turnstile-integration", "")
        if re.search(r"(?:^|;)(?:governanceAuthority|budgetAuthority)=Turnstile(?:;|$)", integration):
            raise Conflict("Turnstile owns gateway writes; choose one authority before enabling AUM writes",
                           "other_authority")
        if require_revision and (not expected or expected.strip('"') != config.revision(mappings)):
            raise Conflict("Configuration changed; read budgets and preview again", "stale_revision")
        return snapshot, config, mappings, scope

    def plan_budget(self, identity, config, scope, kind, key, amount, restoring=False):
        identity.require_writer()
        config.require_target(kind, key)
        members = self.members(config, [key] if kind == "user" else [])
        if scope is not None:
            scope.require_write(kind, key, members.get(key))
        if not restoring and self.store.active_boost(kind, key):
            raise Conflict("An active boost owns this budget until expiry", "active_boost")
        if amount is None:
            if kind != "user":
                raise Conflict("A finite parent cannot contain an unlimited child; remove it from catalog instead",
                               "insufficient_headroom")
            # A cleared override must fit even if the person is in the higher tier.
            amount_for_check = max(config.tier(t)["tokens_per_day"] for t in ("standard", "premium"))
        else:
            amount_for_check = tokens(amount, 1)
        days = calendar.monthrange(self.clock().year, self.clock().month)[1]
        validate_headroom(config, kind, key, amount_for_check, members, days)
        parent = members.get(key) if kind == "user" else config.parents.get(key)
        if parent and not restoring:
            parent_kind = "department" if parent in config.parents else "organization"
            boost = self.store.active_boost(parent_kind, parent)
            if boost:
                baseline = deepcopy(config.values)
                baseline.update(budget_changes(config, parent_kind, parent, boost["previous_limit"]))
                validate_headroom(Config(baseline), kind, key, amount_for_check, members, days)
        return budget_changes(config, kind, key, amount)

    def audit_change(self, identity, what, why, before, after, work):
        audit_id = str(uuid4())
        event = {"id": audit_id, "who": identity.oid, "what": what, "reason": why,
                 "before": before, "after": after, "when": utc(self.clock()), "outcome": "intent"}
        self.store.audit(event)
        try:
            result = work()
        except Exception as error:
            self.store.audit({**event, "when": utc(self.clock()), "outcome": "failed",
                              "error_code": getattr(error, "code", "backend_failure")})
            raise
        self.store.audit({**event, "when": utc(self.clock()), "outcome": "succeeded"})
        return audit_id, result

    def apply_budget(self, identity, snapshot, config, scope, kind, key, body, lease, restoring=False):
        why = reason(body)
        amount = body.get("token_limit")
        changes = self.plan_budget(identity, config, scope, kind, key, amount, restoring)
        threshold = body.get("warning_threshold_percent", 80)
        if type(threshold) is not int or not 1 <= threshold <= 100:
            raise invalid("warning_threshold_percent must be an integer from 1 to 100")
        def work():
            receipt = apply_values(self.arm, snapshot, changes, lease)
            self.store.put("budgets", kind + ":" + key, {"warning_threshold_percent": threshold})
            return {k: v["value"] for k, v in receipt.items()}
        return self.audit_change(identity, f"budget.{kind}.{key}", why,
                                 {k: snapshot[k]["value"] for k in changes}, changes, work)

    def set_budget(self, identity, kind, key, body, expected):
        with self.store.lease() as lease:
            snapshot, config, mappings, scope = self.prepare(identity, expected)
            audit_id, result = self.apply_budget(identity, snapshot, config, scope, kind, key, body, lease)
        _, updated, mappings, _ = self.context(identity)
        return {"audit_id": audit_id, "revision": updated.revision(mappings), "result": result}

    def configure(self, identity, kind, key, body, expected):
        identity.require_admin()
        why = reason(body)
        with self.store.lease() as lease:
            snapshot, config, mappings, scope = self.prepare(identity, expected)
            if kind == "manager":
                entity_id(key)
                if key not in config.by_id:
                    raise invalid("Unknown catalog id")
                try:
                    group = object_id(body["manager_group_id"]) if body.get("manager_group_id") else None
                except ValueError as error:
                    raise invalid("manager_group_id must be an Entra object id or null") from error
                def work():
                    lease()
                    self.store.put("managers", key, {"manager_group_id": group})
                    return {"manager_group_id": group}
                audit_id, result = self.audit_change(identity, f"manager.{key}", why,
                                                     mappings.get(key), group, work)
            else:
                changes = self.config_changes(config, kind, key, body)
                audit_id, result = self.audit_change(
                    identity, f"config.{kind}.{key}", why,
                    {k: snapshot[k]["value"] for k in changes}, changes,
                    lambda: apply_values(self.arm, snapshot, changes, lease),
                )
        _, updated, mappings, _ = self.context(identity)
        return {"audit_id": audit_id, "revision": updated.revision(mappings), "result": result}

    def config_changes(self, config, kind, key, body):
        if kind == "mode":
            if key not in config.by_id:
                raise invalid("Unknown catalog id")
            mode = body.get("enforcement")
            allowance = body.get("allowance_percent")
            if mode == "allowance":
                if type(allowance) is not int or not 1 <= allowance <= 100:
                    raise invalid("allowance_percent must be an integer from 1 to 100")
                mode = f"allowance:{allowance}"
            elif allowance is not None:
                raise invalid("allowance_percent is only valid with allowance")
            modes = {**config.modes, key: mode}
            return {"bu-modes": render_modes(modes)}
        if kind == "tier":
            config.tier(key)
            models = body.get("models")
            if not isinstance(models, list) or any(
                not isinstance(m, str) or not re.fullmatch(r"[A-Za-z0-9._-]{1,150}", m) for m in models
            ):
                raise invalid("models must be a list of deployment names")
            return {f"quota-{key}": str(tokens(body.get("tokens_per_day"), 1)),
                    f"tpm-{key}": str(tokens(body.get("tokens_per_minute"), 1)),
                    f"models-{key}": checked_value("," + ",".join(models) + "," if models else ",,")}
        if kind != "catalog":
            raise invalid("Unknown configuration type")
        entities = body.get("entities")
        if not isinstance(entities, list) or len(entities) > 256:
            raise invalid("entities must be a bounded list of catalog rows")
        units, parents = [], {}
        for entity in entities:
            key = entity_id(entity.get("id"))
            group = entity.get("external_ref", "")
            if not isinstance(group, str) or not group.startswith("entra-group:"):
                raise invalid("external_ref must be entra-group:<group display name>")
            group = group[len("entra-group:"):]
            if not group or any(c in group for c in ",:"):
                raise invalid("Group display name must be non-empty and have no comma or colon")
            parent = entity.get("parent_id")
            if parent:
                parents[key] = entity_id(parent)
            old = config.by_id.get(key)
            if old and config.parents.get(key) != parent and self.store.active_boost(
                "department" if key in config.parents else "organization", key
            ):
                raise Conflict("Cannot move a budget with an active boost")
            units.append({"Id": key, "Group": group, "TokensPerMonth": old["TokensPerMonth"] if old else 0})
        removed = set(config.by_id) - {u["Id"] for u in units}
        if removed & set(config.members.values()):
            raise Conflict("Move members before removing their catalog entry")
        for removed_id in removed:
            if self.store.active_boost("department" if removed_id in config.parents else "organization", removed_id):
                raise Conflict("Cannot remove a budget with an active boost")
        changes = {"bu-registry": render_registry(units), "bu-parents": render_map(parents),
                   "bu-modes": render_modes({k: v for k, v in config.modes.items() if k not in removed})}
        candidate = Config({**config.values, **changes})
        members = self.members(candidate)
        days = calendar.monthrange(self.clock().year, self.clock().month)[1]
        for unit in candidate.units:
            if unit["TokensPerMonth"] > 0:
                validate_headroom(candidate, "department" if unit["Id"] in parents else "organization",
                                  unit["Id"], unit["TokensPerMonth"], members, days)
        return changes
