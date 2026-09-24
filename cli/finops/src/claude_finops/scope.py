"""P46 /auth/me contract. Context parents never grant organization access."""

from .errors import FinOpsError

MANAGER_READS = frozenset({"overview", "distribution", "trends", "requests", "request",
                           "anomalies", "budgets", "people", "catalog", "tiers", "apply"})
ALL_TABS = frozenset({"overview", "budgets", "people", "governance", "usage", "trends",
                      "requests", "anomalies", "settings"})


def profile(identity):
    scope = identity.get("manager_scope")
    if scope is None:
        return None
    if not isinstance(scope, dict):
        raise FinOpsError("Not in your scope: the server returned an invalid manager scope. Refresh or ask an administrator.", 4)
    for key in ("organizations", "departments"):
        rows = scope.get(key)
        if not isinstance(rows, list) or any(not isinstance(row, dict) or not isinstance(row.get("id"), str)
                                             or not row["id"] for row in rows):
            raise FinOpsError("Not in your scope: management assignments could not be read. Refresh or ask an administrator.", 4)
    return scope


def visible_tabs(identity):
    try:
        scope = profile(identity)
    except FinOpsError:
        return {"settings"}
    if scope is not None and not scope["organizations"] and not scope["departments"]:
        return {"governance", "settings"}
    return set(ALL_TABS)


def require_read(identity, resource, params):
    scope = profile(identity)
    if scope is None:
        return
    if resource not in MANAGER_READS:
        raise FinOpsError("Not in your scope: this organization-wide view is not permitted for this sign-in.", 4)
    for parameter, collection in (("organization_id", "organizations"), ("department_id", "departments")):
        if params.get(parameter) and params[parameter] not in {row["id"] for row in scope[collection]}:
            raise FinOpsError("Not in your scope: choose a managed unit or team from Settings. Parent units shown for context do not grant access.", 4)
    if not scope["organizations"] and not scope["departments"] and resource not in {"catalog", "tiers", "apply"}:
        raise FinOpsError("Not in your scope: no units or teams are assigned. Ask an administrator to check your manager group.", 4)


def managed_catalog(identity, catalog, *, context=True):
    scope = profile(identity)
    if scope is None:
        return catalog
    units = {r["id"] for r in scope["organizations"]}
    teams = {r["id"] for r in scope["departments"]}
    parents = {r.get("parent_id") for r in scope["departments"]} if context else set()
    return dict(catalog,
                organizations=[dict(r, scope_context=r["id"] not in units) for r in catalog["organizations"]
                               if r["id"] in units | parents],
                departments=[r for r in catalog["departments"] if r["id"] in teams])


def scope_label(identity):
    try:
        scope = profile(identity)
    except FinOpsError:
        return "scope unavailable"
    if scope is None:
        return ""
    units = ", ".join(r["id"] for r in scope["organizations"])
    teams = ", ".join(r["id"] for r in scope["departments"])
    return ("units: " + units + "; " if units else "") + ("teams: " + teams if teams else "no managed teams")
