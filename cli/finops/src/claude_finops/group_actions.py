"""The same delegated group operations serve commands and terminal forms."""

from .errors import FinOpsError
from .groups import EntraGroups
from .rules import identifier, require_owner


def group_call(engine, operation, *args, **kwargs):
    require_owner(engine.read("whoami"))
    if engine.backend.name == "Example" and not hasattr(engine, "group_factory"):
        raise FinOpsError("Example group operations need an explicit fake Graph client; no live Graph fallback is allowed.", 5)
    factory = getattr(engine, "group_factory", None)
    client = factory() if factory else EntraGroups(config=getattr(engine.backend, "config", None))
    try:
        return getattr(client, operation)(*args, **kwargs)
    finally:
        client.close()


def membership_refresh(engine, scopes, *, apply=False, allow_reassignment=False):
    require_owner(engine.read("whoami"))
    if engine.backend.name != "Direct":
        raise FinOpsError("Membership refresh uses Direct delegated Graph access. Other authorities publish through their own apply/projection path.", 5)
    scopes = [identifier(scope) for scope in scopes]
    if not scopes:
        raise FinOpsError("Choose at least one existing scope to refresh.")
    return engine.backend._bridge("membership", scope_ids=scopes, apply=apply, allow_reassignment=allow_reassignment)


def publish_as_signed_in_admin(engine, config, *, apply=False):
    require_owner(engine.read("whoami"))
    if engine.backend.name != "Turnstile":
        raise FinOpsError("Delegated publication reads the selected Turnstile authority. Choose the Turnstile backend.", 5)
    plan = dict(preview=not apply, action="Publish Turnstile governance as signed-in Azure administrator",
                effect="Uses the repository writer with this person's existing Graph/ARM rights; no managed-identity permission grant. "
                       "Distinct from the server apply job. Can refresh membership and tiers; preview and retain originals.")
    if apply:
        from .direct import DirectBackend
        plan["result"] = DirectBackend(config)._bridge("delegated_publish")
    return plan
