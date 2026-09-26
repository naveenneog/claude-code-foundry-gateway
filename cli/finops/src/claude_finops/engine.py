from copy import deepcopy
from datetime import datetime, timezone
from decimal import Decimal
import time

from .errors import FinOpsError
from .rules import (allocation_left, apply_state, identifier, month_window, parse_tokens,
                    require_owner, require_budget_write, scope_type, validate_budget)
from .scope import managed_catalog, profile, require_read
from .feature_engine import FeatureEngine
from .capabilities import READ_FEATURES
from .usd import parse_usd, usd_key, usd_row, can_usd_write


class Engine(FeatureEngine):
    def __init__(self, backend, month=None):
        self.backend = backend
        self.month = month or datetime.now(timezone.utc).strftime("%Y-%m")
        self._identity = None
        self._capabilities = None
        self.change_reason = ""
        month_window(self.month)

    def mutation_metadata(self):
        if not self.backend.requires_reason:
            return {}
        reason = self.change_reason
        if not isinstance(reason, str) or not 1 <= len(reason.strip()) <= 500:
            raise FinOpsError("AUM service requires an audit reason. Pass --reason (1-500 characters) or fill the form.")
        return {"reason": reason.strip()}

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
        if resource == "people" and params.get("cursor"):
            self.require_feature("people_cursor")
        result = self.backend.read(resource, month=self.month, **params)
        return managed_catalog(self._identity, result) if resource == "catalog" else result

    def status(self):
        budgets = self.read("budgets")
        if self.has_feature("usd_budgets"):
            try:
                from .usd import merge_usd_into_budgets
                budgets = merge_usd_into_budgets(budgets, self.read("usd_budgets"), self.read("usd_status"))
            except FinOpsError:
                pass
        return dict(month=self.month, backend=self.backend.name, overview=self.read("overview"),
                    budgets=budgets, apply=self.read("apply"))

    def governance(self):
        return dict(catalog=self.read("catalog"), tiers=self.read("tiers"), apply=self.read("apply"))

    def chargeback(self, dimension="organization"):
        if dimension not in {"organization", "department"}:
            raise FinOpsError("Complete chargeback supports organization or department. Use usage show for top-100 model/person rankings.")
        catalog = self.read("catalog")
        scoped = profile(self._identity)
        if scoped is not None and not self.backend.unit_direct_departments:
            units = {row["id"] for row in scoped["organizations"]}
            targets = [("organization", row) for row in catalog["organizations"] if row["id"] in units]
            targets += [("department", row) for row in catalog["departments"] if row.get("parent_id") not in units]
            rows = [dict(id=row["id"], name=row["name"], scope_type=kind,
                         **self.read("overview", **{f"{kind}_id": row["id"]})["totals"]) for kind, row in targets]
            return dict(period=self.month, dimension="managed-scope", items=rows,
                        note="Actually managed units (including direct members) plus independent teams; no context-parent query or double counting. Estimated cost, not an invoice.")
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
        metadata = self.mutation_metadata()
        if warning is not None and not self.backend.budget_warning_threshold:
            raise FinOpsError("Direct has no stored warning threshold. Use the AUM service or omit --warning.")
        kind, key = scope_type(kind), identifier(key)
        identity = self.read("whoami")
        native_user = kind == "user" and self.backend.native_user_budget_records
        if native_user:
            self.require_feature("native_writes", "budget")
        else:
            require_budget_write(identity, kind, key, department_id)
        rows = self.read("budgets")["items"]
        if kind == "user":
            existing = next((row for row in rows if row["scope_type"] == "user" and row["scope_id"] == key), None)
            if not department_id and not (native_user and existing):
                raise FinOpsError("Choose a team with --team before editing a person's budget.")
            people = {}
            if department_id:
                people = self.read("people", **self.backend.people_filter(department_id), query=key, limit=50, offset=0)
                rows = [row for row in rows if not (row["scope_type"] == "user" and row["scope_id"] == key)] + people["items"]
        row = next((item for item in rows if item["scope_type"] == kind and item["scope_id"] == key), None)
        if row is None:
            raise FinOpsError("Scope not found in this month and role. Refresh Budgets or search the person's team.", 5)
        if row.get("writable") is False or (native_user and row.get("writable") is not True):
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
        if not self.backend.budget_warning_threshold:
            plan.pop("warning_threshold_percent")
        if self.backend.immediate_writes and not daily:
            plan["effect"] = "Verified control-plane write; no separate apply job. Gateway propagation can lag."
        if apply:
            if destructive and confirm != key:
                raise FinOpsError(f"Destructive change requires confirmation: --confirm {key}")
            if not self.backend.immediate_writes:
                plan["requested_at"] = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            body = None if remove else dict(token_limit=proposed, warning_threshold_percent=threshold)
            if body and not self.backend.budget_warning_threshold:
                body.pop("warning_threshold_percent")
            plan["result"] = self.backend.write("budget_remove" if remove else "budget", body,
                                                scope_type=kind, scope_id=key, month=self.month, **metadata)
        return plan

    def usd_budget_change(self, kind, key, amount=None, *, period="month", remove=False,
                          apply=False, confirm=None):
        self.require_feature("usd_budgets", "write")
        metadata = self.mutation_metadata()
        kind, key = usd_key(kind, key)
        identity = self.read("whoami")
        definitions = self.read("usd_budgets")
        rows = self.read("budgets")["items"]
        budget_row = next((row for row in rows if row["scope_type"] == kind and row["scope_id"] == key), None)
        definition = usd_row(definitions, kind, key)
        if budget_row is None and definition is None:
            raise FinOpsError("Scope not found for this sign-in. Refresh Budgets or choose an authorized scope.", 5)
        if not can_usd_write(identity, kind, key, budget_row or definition or {}):
            raise FinOpsError("Read-only for this USD scope. Ask its Owner or parent-scope manager to make this change.", 4)
        if kind != "user" and period != "month":
            raise FinOpsError("Unit and team USD budgets are monthly.")
        if period not in {"day", "month"}:
            raise FinOpsError("USD period must be day or month.")
        after = None if remove else parse_usd(amount)
        before = definition.get("amount_usd") if definition else None
        destructive = remove or after == "0" or (before is not None and after is not None and Decimal(after) < Decimal(before))
        plan = dict(preview=not apply, action="clear" if remove else "set", scope_type=kind, scope_id=key,
                    before=before, after=after, period=period, price_book_date=definitions.get("price_book_date"),
                    confirmation_required=bool(remove), effect="Saved; awaiting reconciliation.",
                    reconciliation="Run aum usd reconcile --apply or wait for the AUM service timer.")
        if apply:
            if remove and confirm != key:
                raise FinOpsError(f"Clear requires typed confirmation: --confirm {key}")
            if destructive and remove is False and confirm not in {None, "", key}:
                raise FinOpsError(f"Unexpected confirmation value; omit it or use --confirm {key}.")
            price_book_date = definitions.get("price_book_date")
            if not price_book_date:
                raise FinOpsError("Initialize the USD price book before setting dollar budgets.")
            body = {"amount_usd": after, "period": period,
                    "price_book_date": price_book_date, **metadata}
            plan["result"] = self.backend.write("usd_budget_remove" if remove else "usd_budget",
                                                None if remove else body, scope_type=kind, scope_id=key,
                                                month=self.month, **metadata)
        return plan

    def usd_status(self):
        self.require_feature("usd_budgets")
        return self.read("usd_status")

    def usd_reconcile(self, *, apply=False):
        self.require_feature("usd_budgets", "reconcile")
        plan = dict(preview=not apply, action="Reconcile USD budgets",
                    effect="Uses the gateway USD reconciler. Saved state can take time to propagate.")
        if apply:
            plan["result"] = self.backend.write("usd_reconcile", {}, month=self.month)
        return plan

    def usd_price_book_change(self, price_book, *, apply=False):
        self.require_feature("usd_budgets", "price_book_write")
        metadata = self.mutation_metadata()
        plan = dict(preview=not apply, action="Replace USD price book",
                    before=self.read("usd_price_book").get("price_book"), after=price_book,
                    effect="Active USD budgets pin their tariff; the server refuses silent repricing.")
        if apply:
            plan["result"] = self.backend.write("usd_price_book", {"price_book": price_book, **metadata},
                                                month=self.month, **metadata)
        return plan

    def apply(self, *, apply=False):
        require_owner(self.read("whoami"))
        if self.backend.immediate_writes:
            raise FinOpsError("This backend has no separate apply job. Changes return their own verified receipt.", 5)
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
        metadata = self.mutation_metadata()
        plan = dict(preview=not apply, action=f"Replace {resource}", before=before, after=body,
                    effect="Whole collection is saved; refresh before preview to avoid overwriting concurrent edits.")
        if self.backend.immediate_writes:
            plan["effect"] = "Verified native writer; no separate apply job. Refresh after a conflict or compensation error."
        if apply:
            if not self.backend.immediate_writes:
                plan["requested_at"] = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            plan["result"] = self.backend.write(resource, body, **metadata)
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
            people = self.read("people", **self.backend.people_filter(department_id), query=text, offset=0, limit=20)
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
