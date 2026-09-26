"""AUM developer add/remove actions shared by CLI and terminal screens."""

from .developers import EntraDevelopers
from .direct import DirectBackend
from .errors import FinOpsError
from .group_actions import publish_as_signed_in_admin
from .rules import require_owner


def _authority_bridge(engine, config):
    if engine.backend.name == "Direct":
        return engine.backend
    if engine.backend.name == "Turnstile":
        return DirectBackend(config)
    raise FinOpsError("Developer membership writes require Direct or Turnstile-backed gateway configuration.", 5)


def _read_state(engine, config):
    return _authority_bridge(engine, config)._bridge("read")


def _tier_groups(state):
    groups = {row["id"]: row.get("entra_group", "") for row in state.get("tiers", [])}
    if not groups.get("standard") or not groups.get("premium"):
        raise FinOpsError("Tier group names are not configured for this gateway. Record standardGroup and premiumGroup or pass explicit script parameters.", 6)
    return groups


def _scope_groups(state):
    catalog = state.get("catalog", {})
    rows = list(catalog.get("organizations", [])) + [row for row in catalog.get("departments", [])
                                                      if row.get("attributes", {}).get("kind") != "unit-direct"]
    result = {}
    for row in rows:
        ref = row.get("external_ref") or ""
        if ref.startswith("entra-group:"):
            result[row["id"]] = ref.removeprefix("entra-group:")
    return result


def _client(engine):
    factory = getattr(engine, "developer_factory", None) or getattr(engine, "group_factory", None)
    return factory() if factory else EntraDevelopers(config=getattr(engine.backend, "config", None))


def developer_find(engine, config, query, *, limit=50, cursor=None):
    require_owner(engine.read("whoami"))
    state = _read_state(engine, config)
    client = _client(engine)
    try:
        return client.search_developers(query, limit=limit, cursor=cursor, state=state)
    finally:
        client.close()


def developer_change(engine, config, target, *, tier=None, unit=None, remove=False, apply=False, confirm=""):
    require_owner(engine.read("whoami"))
    state = _read_state(engine, config)
    tiers = _tier_groups(state)
    scope_groups = _scope_groups(state)
    if remove and (tier or unit):
        raise FinOpsError("Remove clears tier and unit/team direct memberships; do not also pass --tier or --unit.", 2)
    if not remove and tier not in {"standard", "premium"}:
        raise FinOpsError("Choose --tier standard or --tier premium.", 2)
    if unit and unit not in scope_groups:
        raise FinOpsError("Unit/team not found in the gateway catalog.", 5)

    client = _client(engine)
    try:
        person = client.resolve_exact(target, state=state)
        group_ids = {name: client.group_id(value) for name, value in tiers.items()}
        scope_ids = {name: client.group_id(value) for name, value in scope_groups.items()}
        changes = []
        if remove:
            for name in ("standard", "premium"):
                changes.append(dict(group=tiers[name], group_id=group_ids[name], present=False, reason=f"remove {name} tier"))
            for name, group in scope_groups.items():
                changes.append(dict(group=group, group_id=scope_ids[name], present=False, reason=f"remove {name} unit/team"))
        else:
            other = "premium" if tier == "standard" else "standard"
            changes.append(dict(group=tiers[tier], group_id=group_ids[tier], present=True, reason=f"add {tier} tier"))
            changes.append(dict(group=tiers[other], group_id=group_ids[other], present=False, reason=f"remove {other} tier"))
            if unit:
                changes.append(dict(group=scope_groups[unit], group_id=scope_ids[unit], present=True, reason=f"add {unit} unit/team"))
        plan = dict(preview=not apply, action="Remove developer" if remove else "Add developer",
                    developer=person, changes=changes, confirm_upn=person["user_principal_name"],
                    token_note=("Already-issued Entra access tokens remain valid until they expire; "
                                "publication stops new gateway requests after the allow-list refresh."))
        if not apply:
            return plan
        if remove and confirm != person["user_principal_name"]:
            raise FinOpsError("Type the resolved UPN with --confirm before removing a developer.", 2)
        changed = []
        for change in changes:
            if client.apply_membership(person["id"], change["group_id"], change["present"]):
                changed.append(change)
        plan["changed"] = changed
        bridge = _authority_bridge(engine, config)
        if engine.backend.name == "Turnstile":
            plan["publication"] = publish_as_signed_in_admin(engine, config, apply=True).get("result", {})
            plan["publication_path"] = "Turnstile delegated publish-as-admin"
        else:
            plan["publication"] = bridge._bridge("developer_publish", standard_group=tiers["standard"],
                                                 premium_group=tiers["premium"], allow_empty=remove)
            plan["publication_path"] = "Direct selected-scope membership refresh and tier allow-list sync"
        plan["preview"] = False
        plan["gateway_ready"] = "The developer can call the gateway after APIM named-value publication and gateway cache propagation."
        return plan
    finally:
        client.close()
