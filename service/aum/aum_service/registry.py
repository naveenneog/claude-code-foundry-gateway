import hashlib
import json
import re

from .auth import object_id
from .errors import Conflict, invalid


MAX_TOKENS = 9223372036854775807
ID = re.compile(r"^[a-z0-9][a-z0-9-]*$")
MODE = re.compile(r"^(strict|notify|allowance:([1-9][0-9]?|100))$")
CONFIG_NAMES = frozenset({
    "bu-registry", "bu-parents", "bu-members", "bu-modes", "quota-overrides", "quota-org",
    "quota-standard", "quota-premium", "tpm-standard", "tpm-premium",
    "models-standard", "models-premium", "entitlement-source", "turnstile-integration",
})


def checked_value(value):
    if len(value.encode("utf-16-le")) // 2 > 4096:
        raise Conflict("Named value exceeds 4,096 characters; use projection-backed budgets at scale",
                       "named_value_capacity")
    return value


def tokens(value, minimum=0):
    if isinstance(value, str) and re.fullmatch(r"[0-9]+", value):
        value = int(value)
    if type(value) is not int or not minimum <= value <= MAX_TOKENS:
        raise invalid(f"Token limit must be an integer from {minimum} to {MAX_TOKENS}")
    return value


def entity_id(value):
    if not isinstance(value, str) or not ID.fullmatch(value) or len(value) > 100:
        raise invalid("Entity id must use lower-case letters, digits and hyphens")
    return value


def parse_map(value):
    if not isinstance(value, str):
        raise Conflict("Named value is missing or not readable", "invalid_configuration")
    checked_value(value)
    if not value.strip() or value == ",,":
        return {}
    if not value.startswith(",") or not value.endswith(","):
        raise Conflict("Named value must have sentinel commas", "invalid_configuration")
    result = {}
    for entry in value[1:-1].split(","):
        key, sep, val = entry.partition("=")
        if not sep or not key or not val or key in result:
            raise Conflict("Malformed or duplicate named-value entry", "invalid_configuration")
        result[key] = val
    return result


def render_map(values):
    if not values:
        return ",,"
    for key, value in values.items():
        if not isinstance(key, str) or not key or any(c in key for c in ",="):
            raise invalid("Invalid named-value map key")
        if str(value) == "" or "," in str(value):
            raise invalid("Invalid named-value map value")
    return checked_value("," + ",".join(f"{k}={v}" for k, v in values.items()) + ",")


def parse_registry(value):
    result = []
    for key, val in parse_map(value).items():
        group, sep, quota = val.rpartition(":")
        if not sep or not group:
            raise Conflict("Registry entry needs a group and token budget", "invalid_configuration")
        result.append({"Id": entity_id(key), "Group": group, "TokensPerMonth": tokens(quota)})
    return result


def render_registry(units):
    values = {}
    for unit in units:
        key = entity_id(unit["Id"])
        if key in values:
            raise invalid("Duplicate registry id")
        group = unit["Group"]
        if not isinstance(group, str) or not group or "," in group:
            raise invalid("Group must be non-empty and contain no comma")
        values[key] = f"{group}:{tokens(unit['TokensPerMonth'])}"
    return render_map(values)


def parse_modes(value):
    result = {}
    for key, mode in parse_map(value).items():
        entity_id(key)
        if not MODE.fullmatch(mode):
            raise invalid("Mode must be strict, notify, or allowance:1 through allowance:100")
        if mode != "strict":
            result[key] = mode
    return result


def render_modes(modes):
    return render_map(parse_modes(render_map(modes)))


class Config:
    def __init__(self, values):
        self.values = {k: v for k, v in values.items() if k in CONFIG_NAMES}
        self.units = parse_registry(values.get("bu-registry"))
        self.by_id = {u["Id"]: u for u in self.units}
        self.parents = parse_map(values.get("bu-parents"))
        self.members = parse_map(values.get("bu-members"))
        self.modes = parse_modes(values.get("bu-modes", ",,"))
        self.overrides = {object_id(k): tokens(v, 1) for k, v in
                          parse_map(values.get("quota-overrides")).items()}
        self.org_limit = tokens(values.get("quota-org"))
        for child, parent in self.parents.items():
            if child not in self.by_id or parent not in self.by_id or child == parent:
                raise Conflict("Parent map has a dangling id or cycle", "invalid_configuration")
            if parent in self.parents:
                raise Conflict("Only business units and teams (two levels) are supported",
                               "invalid_configuration")
        for leaf in self.members.values():
            if leaf not in self.by_id and leaf != "unassigned":
                raise Conflict("Membership points to an unknown unit", "invalid_configuration")
        if set(self.modes) - set(self.by_id):
            raise Conflict("Mode points to an unknown unit", "invalid_configuration")

    def revision(self, mappings=None):
        encoded = json.dumps([self.values, mappings or {}], sort_keys=True,
                             separators=(",", ":")).encode()
        return hashlib.sha256(encoded).hexdigest()

    def mode(self, key):
        mode = self.modes.get(key, "strict")
        name, _, allowance = mode.partition(":")
        return {"enforcement": name, "allowance_percent": int(allowance) if allowance else None}

    def entities(self):
        return [
            {"id": u["Id"], "name": u["Group"], "parent_id": self.parents.get(u["Id"]),
             "external_ref": "entra-group:" + u["Group"], "attributes": self.mode(u["Id"])}
            for u in self.units
        ]

    def require_target(self, kind, key):
        if kind == "user":
            try:
                object_id(key)
            except ValueError as error:
                raise invalid("Person id must be an Entra object id") from error
            return
        if kind not in {"organization", "department"} or key not in self.by_id:
            raise invalid("Unknown budget scope")
        expected = "department" if key in self.parents else "organization"
        if kind != expected:
            raise invalid("Scope type does not match the catalog")

    def current_limit(self, kind, key):
        self.require_target(kind, key)
        return self.overrides.get(key) if kind == "user" else self.by_id[key]["TokensPerMonth"]

    def tier(self, name):
        if name not in {"standard", "premium"}:
            raise invalid("Only standard and premium tiers are supported")
        models = self.values.get(f"models-{name}", ",,")
        checked_value(models)
        if not models.startswith(",") or not models.endswith(","):
            raise Conflict("Malformed tier model list", "invalid_configuration")
        return {"id": name, "name": name.title(),
                "tokens_per_day": tokens(self.values.get(f"quota-{name}"), 1),
                "tokens_per_minute": tokens(self.values.get(f"tpm-{name}"), 1),
                "models": [m for m in models.strip(",").split(",") if m]}


def validate_headroom(config, kind, key, amount, memberships, days):
    config.require_target(kind, key)
    amount = tokens(amount, 1)
    if not 28 <= days <= 31:
        raise invalid("Calendar month length is invalid")
    unknown = set(config.overrides) - set(memberships)
    if unknown:
        raise Conflict("Cannot establish membership for every existing person override",
                       "unknown_parent")
    reservations = {}
    for oid, daily in config.overrides.items():
        if kind == "user" and oid == key:
            continue
        leaf = memberships[oid]
        reservations[leaf] = reservations.get(leaf, 0) + daily * days

    if kind == "user":
        parent = memberships.get(key)
        if parent not in config.by_id:
            raise Conflict("Assign the person to a known parent with a budget first", "unknown_parent")
        candidate = amount * days
        siblings = reservations.get(parent, 0)
        if parent not in config.parents:
            siblings += sum(u["TokensPerMonth"] for u in config.units
                            if config.parents.get(u["Id"]) == parent)
        ceiling = config.by_id[parent]["TokensPerMonth"]
    elif kind == "department":
        parent = config.parents[key]
        candidate = amount
        siblings = sum(u["TokensPerMonth"] for u in config.units
                       if u["Id"] != key and config.parents.get(u["Id"]) == parent)
        siblings += reservations.get(parent, 0)
        ceiling = config.by_id[parent]["TokensPerMonth"]
    else:
        parent = None
        candidate = amount
        siblings = sum(u["TokensPerMonth"] for u in config.units
                       if u["Id"] != key and u["Id"] not in config.parents)
        ceiling = config.org_limit
    if ceiling <= 0:
        raise Conflict("Assign a finite parent budget before allocating children", "parent_unbounded")
    if candidate + siblings > ceiling:
        raise Conflict(f"Parent headroom is {max(0, ceiling - siblings)} monthly tokens",
                       "insufficient_headroom")
    if kind != "user":
        children = reservations.get(key, 0) + sum(
            u["TokensPerMonth"] for u in config.units if config.parents.get(u["Id"]) == key
        )
        if children > amount:
            raise Conflict(f"Budget cannot be below {children} allocated child tokens",
                           "insufficient_headroom")


def budget_changes(config, kind, key, amount):
    config.require_target(kind, key)
    if kind == "user":
        overrides = dict(config.overrides)
        if amount is None:
            overrides.pop(key, None)
        else:
            overrides[key] = tokens(amount, 1)
        return {"quota-overrides": render_map(overrides)}
    units = [{**u, "TokensPerMonth": (0 if amount is None else tokens(amount, 1))}
             if u["Id"] == key else u for u in config.units]
    return {"bu-registry": render_registry(units)}
