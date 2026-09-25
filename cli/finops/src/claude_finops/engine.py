from copy import deepcopy
from datetime import datetime, timezone
import time

from .errors import FinOpsError
from .rules import (allocation_left, apply_state, identifier, month_window, parse_tokens,
                    require_owner, require_budget_write, scope_type, validate_budget)
from .scope import managed_catalog, profile, require_read
from .feature_engine import FeatureEngine
from .capabilities import READ_FEATURES


class Engine(FeatureEngine):
    def __init__(self, backend, month=None):
        self.backend = backend
        self.month = month or datetime.now(timezone.utc).strftime("%Y-%m")
        self._identity = None
        self._capabilities = None
        month_window(self.month)

    def read(self, resource, **params):
        if resource == "whoami":
            previous = self._identity
            self._identity = self.backend.read(resource, month=self.month, **params)
            identity_keys = ("id", "email", "role", "manager_scope")
            if previous and tuple(previous.get(k) for k in identity_keys) != tuple(self._identity.get(k) for k in identity_keys):
                self._capabilities = None
            return self._identity
        if self._identity is None:
            self.read("whoami")
        if resource in READ_FEATURES:
            self.require_feature(READ_FEATURES[resource])
        else:
            require_read(self._identity, resource, params)
        if resource == "requests" and params.get("cursor"):
            self.require_feature("request_cursor")
        result = self.backend.read(resource, month=self.month, **params)
        return managed_catalog(self._identity, result) if resource == "catalog" else result

    def status(self):
        return dict(month=self.month, backend=self.backend.name, overview=self.read("overview"),
                    budgets=self.read("budgets"), apply=self.read("apply"))

    def governance(self):
        return dict(catalog=self.read("catalog"), tiers=self.read("tiers"), apply=self.read("apply"))

    def chargeback(self, dimension="organization"):
        if dimension not in {"organization", "department"}:
            raise FinOpsError("Complete chargeback supports organization or department. Use usage show for top-100 model/person rankings.")
        catalog = self.read("catalog")
        scoped = profile(self._identity)
        if scoped is not None:
            # Parent catalog rows may be context only. Department queries never widen a manager's scope.
            dimension = "department"
        rows = []
        collection = "organizations" if dimension == "organization" else "departments"
        for scope in catalog[collection]:
            totals = self.read("overview", **{f"{dimension}_id": scope["id"]})["totals"]
            rows.append(dict(id=scope["id"], name=scope["name"], **totals))
        return dict(period=self.month, dimension=dimension, items=rows,
                    note=("All managed teams only; context parent units are not queried. " if scoped is not None else
                          "All catalog scopes, not a top-N ranking. ") + "Cost is estimated, not an Azure invoice.")

    def budget_change(self, kind, key, amount=None, *, remove=False, apply=False,
                      confirm=None, warning=None, department_id=None):
        kind, key = scope_type(kind), identifier(key)
        require_budget_write(self.read("whoami"), kind, key, department_id)
        rows = self.read("budgets")["items"]
        if kind == "user":
            if not department_id:
                raise FinOpsError("Choose a team with --team before editing a person's budget.")
            people = self.read("people", department_id=department_id, query=key, limit=50, offset=0)
            rows += people["items"]
        row = next((item for item in rows if item["scope_type"] == kind and item["scope_id"] == key), None)
        if row is None:
            raise FinOpsError("Scope not found in this month and role. Refresh Budgets or search the person's team.", 5)
        if row.get("writable") is False:
            raise FinOpsError("This observed identity or scope is not writable. Check its object id and selected authority.", 4)
        daily = row.get("budget_period") == "day"
        proposed = None if remove else parse_tokens(amount)
        if proposed is not None:
            if not daily:
                validate_budget(rows, row, proposed)
            if kind == "user" and not daily and people.get("department_available_tokens") is not None:
                left = people["department_available_tokens"] + (row.get("token_limit") or 0) - proposed
                if left < 0:
                    raise FinOpsError(f"Parent headroom is short by {-left:,} tokens. Ask its Owner for allocation.")
        threshold = warning if warning is not None else row.get("warning_threshold_percent", 80)
        if not isinstance(threshold, int) or not 1 <= threshold <= 100:
            raise FinOpsError("Warning threshold must be between 1 and 100 percent.")
        destructive = remove or row.get("used_tokens") is None or (proposed is not None and proposed < row["used_tokens"])
        plan = dict(preview=not apply, action="remove" if remove else "set", scope_type=kind, scope_id=key,
                    period=self.month, before=row.get("token_limit"), after=proposed,
                    used_tokens=row["used_tokens"], warning_threshold_percent=threshold,
                    budget_period="day" if daily else "month",
                    parent_headroom=None if remove or daily else allocation_left(rows, row, proposed),
                    confirmation_required=destructive,
                    effect="Gateway daily person override; monthly unit limits still apply independently. Daily limits are not monthly allocations." if daily else
                    "Person budgets are Turnstile-only; not gateway quotas." if kind == "user"
                    else "Gateway apply normally takes about two minutes. A save is not proof of enforcement.")
        if apply:
            if destructive and confirm != key:
                raise FinOpsError(f"Destructive change requires confirmation: --confirm {key}")
            plan["requested_at"] = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            body = None if remove else dict(token_limit=proposed, warning_threshold_percent=threshold)
            plan["result"] = self.backend.write("budget_remove" if remove else "budget", body,
                                                scope_type=kind, scope_id=key, month=self.month)
        return plan

    def apply(self, *, apply=False):
        require_owner(self.read("whoami"))
        result = dict(preview=not apply, action="Apply current governance", effect="Usually about two minutes.")
        if apply:
            result["requested_at"] = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            result["result"] = self.backend.write("apply")
        return result

    def wait_for_apply(self, since, timeout=180, interval=3):
        deadline = time.monotonic() + timeout
        while True:
            status = self.read("apply")
            state = apply_state(status, since)
            if state.startswith("Apply succeeded"):
                return dict(state=state, status=status)
            if state.startswith(("Failed", "Not configured", "Unknown")):
                raise FinOpsError(state, 7)
            if time.monotonic() >= deadline:
                raise FinOpsError("Apply is still pending. Run governance show to follow it; do not resubmit the save.", 8)
            time.sleep(interval)

    def tier_change(self, key, per_minute=None, per_day=None, models=None, *, apply=False):
        require_owner(self.read("whoami"))
        before = self.read("tiers")["items"]
        tiers = deepcopy(before)
        target = next((row for row in tiers if row["id"] == key), None)
        if not target:
            raise FinOpsError("Tier not found. Run tier show.", 5)
        if all(value is None for value in (per_minute, per_day, models)):
            raise FinOpsError("Pass --per-minute, --per-day or --models.")
        for field, value, ceiling in (("tokens_per_minute", per_minute, 100000000),
                                      ("tokens_per_day", per_day, 1000000000000)):
            if value is not None:
                target[field] = parse_tokens(value)
                if target[field] > ceiling:
                    raise FinOpsError(f"{field} cannot exceed {ceiling:,}.")
        if models is not None:
            import re
            target["models"] = [item.strip() for item in models.split(",") if item.strip()]
            if len(target["models"]) > 100 or any(not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,99}", m)
                                                for m in target["models"]):
                raise FinOpsError("Use up to 100 comma-separated model deployment names.")
        return self._replace("tiers", {"tiers": tiers}, before, apply)

    def catalog_change(self, kind, key, *, name=None, group=None, manager_group=None,
                       parent=None, remove=False, confirm=None, apply=False):
        require_owner(self.read("whoami"))
        identifier(key)
        if kind not in {"unit", "team"}:
            raise FinOpsError("Catalog kind must be unit or team.")
        current = self.read("catalog")
        body = {key: deepcopy(current.get(key)) for key in ("organizations", "departments", "default_department_id")}
        for row in body["organizations"]:
            row.pop("parent_id", None)
        collection = body["organizations" if kind == "unit" else "departments"]
        row = next((item for item in collection if item["id"] == key), None)
        if remove:
            if not row:
                raise FinOpsError("Scope not found. Refresh Governance.", 5)
            if kind == "unit" and any(d["parent_id"] == key for d in body["departments"]):
                raise FinOpsError("Move or remove this unit's teams first.")
            if current.get("default_department_id") == key:
                raise FinOpsError("This is the default department. Change the default in Turnstile before removing it.")
            collection.remove(row)
            if apply and confirm != key:
                raise FinOpsError(f"Removal requires confirmation: --confirm {key}")
        else:
            if row is None:
                if not name or not group:
                    raise FinOpsError("New scopes need --name and --group.")
                row = dict(id=key, name=name, external_ref=None, attributes={"source": "claude-gateway"})
                collection.append(row)
            if name is not None:
                if not 1 <= len(name.strip()) <= 200:
                    raise FinOpsError("Name must contain 1 to 200 characters.")
                row["name"] = name.strip()
            if group is not None:
                if not group.strip() or len(group) > 256 or any(char in group for char in "\r\n&|<>^%!\""):
                    raise FinOpsError("Enter an Entra member group name or object id.")
                row["external_ref"] = "entra-group:" + group
            if manager_group is not None:
                from uuid import UUID
                try:
                    group_id = str(UUID(manager_group))
                except ValueError:
                    raise FinOpsError("Manager group must be its Entra object id, not a display name.") from None
                row.setdefault("attributes", {})["manager_group_id"] = group_id
            if kind == "team":
                row["parent_id"] = parent or row.get("parent_id")
                if row["parent_id"] not in {unit["id"] for unit in body["organizations"]}:
                    raise FinOpsError("Choose an existing unit with --parent.")
                budget_rows = self.read("budgets")["items"]
                team_budget = next((r for r in budget_rows if r["scope_type"] == "department"
                                    and r["scope_id"] == key), None)
                if team_budget and team_budget.get("token_limit"):
                    moved = dict(team_budget, parent_scope_id=row["parent_id"])
                    validate_budget(budget_rows, moved, team_budget["token_limit"])
                row.setdefault("attributes", {})["kind"] = "team"
        if not body["organizations"]:
            raise FinOpsError("Keep at least one business unit.")
        return self._replace("catalog", body, current, apply)

    def _replace(self, resource, body, before, apply):
        plan = dict(preview=not apply, action=f"Replace {resource}", before=before, after=body,
                    effect="Whole collection is saved; refresh before preview to avoid overwriting concurrent edits.")
        if apply:
            plan["requested_at"] = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            plan["result"] = self.backend.write(resource, body)
        return plan

    def lookup(self, text, department_id=None):
        text = text.strip()[:200]
        if not text:
            return []
        if self.has_feature("global_search"):
            tabs = {"unit": "budgets", "team": "budgets", "person": "people",
                    "model": "usage", "request": "requests"}
            return [dict(row, tab=tabs[row["kind"]])
                    for row in self.read("global_search", query=text, limit=50)["items"]
                    if row.get("kind") in tabs]
        catalog = self.read("catalog")
        catalog = managed_catalog(self._identity, catalog, context=False)
        result = []
        # Subsequence matching is useful for short scope names; people remain server-searched.
        def matches(value):
            it = iter(value.lower())
            return all(char in it for char in text.lower())
        for collection, kind in (("organizations", "unit"), ("departments", "team")):
            result += [dict(kind=kind, id=row["id"], name=row["name"], tab="budgets")
                       for row in catalog[collection] if matches(row["id"] + " " + row["name"])]
        observed = self.read("distribution", dimension="model", limit=50)["items"]
        result += [dict(kind="model", id=model["id"], name=model["name"], tab="usage")
                   for model in observed if matches(model["name"])]
        names = {model["name"] for model in observed}
        for tier in self.read("tiers")["items"]:
            result += [dict(kind="configured-model", id=model, name=model, tab="governance")
                       for model in tier["models"] if model not in names and matches(model)]
        if department_id:
            people = self.read("people", department_id=department_id, query=text, offset=0, limit=20)
            result += [dict(kind="person", id=row["scope_id"], name=row["scope_name"], tab="people")
                       for row in people["items"]]
        if text.startswith(("request:", "contoso-request-")) or (len(text) == 36 and text.count("-") == 4):
            key = text.removeprefix("request:")
            try:
                request = self.read("request", request_id=key)
                result.append(dict(kind="request", id=key, name=request["request_id"], tab="requests"))
            except FinOpsError as error:
                if error.code != 5:
                    raise
        unique = {(row["kind"], row["id"]): row for row in result}
        return list(unique.values())[:60]
