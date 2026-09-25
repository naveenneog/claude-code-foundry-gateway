from copy import deepcopy
from datetime import datetime, timezone
from uuid import uuid4

from . import capabilities as cap
from .errors import FinOpsError
from .rules import identifier, month_window, parse_tokens, require_owner, scope_type


class FeatureEngine:
    def membership_url(self, team):
        from .config import az
        from uuid import UUID
        catalog = self.read("catalog")
        row = next((r for r in catalog["departments"] if r["id"] == team), None)
        if not row or not (row.get("external_ref") or "").startswith("entra-group:"):
            raise FinOpsError("The team has no Entra member-group reference.", 5)
        group = row["external_ref"].removeprefix("entra-group:")
        config = getattr(self.backend, "config", None)
        subscription = getattr(config, "subscription", "")
        selected = ("--subscription", subscription) if subscription else ()
        group_id = az("ad", "group", "show", "--group", group, "--query", "id", "-o", "tsv", *selected)
        try:
            group_id = str(UUID(group_id))
        except ValueError:
            raise FinOpsError("Entra did not return a valid group id. Verify existing directory read rights.", 7) from None
        tenant = getattr(config, "tenant_id", "")
        prefix = f"@{tenant}/" if tenant else ""
        return "https://portal.azure.com/#" + prefix + "view/Microsoft_AAD_IAM/GroupDetailsMenuBlade/~/Members/groupId/" + group_id

    def person_detail(self, person, team):
        people = self.read("people", department_id=identifier(team), query=identifier(person), offset=0, limit=50)
        row = next((item for item in people["items"] if item["scope_id"] == person), None)
        if row is None:
            raise FinOpsError("Person not found in this team.", 5)
        requests = self.read("requests", user_id=person, limit=1)["items"]
        latest = next((item for item in requests if item.get("user_id") == person), {})
        return dict(row, tier=latest.get("project_name"), unit=latest.get("organization_name"),
                    team=latest.get("department_name"), last_seen_in_window=latest.get("timestamp"),
                    basis="Latest request in the selected month; no all-time last-seen value is guessed.")

    def capabilities(self, refresh=False):
        if self._identity is None:
            self.read("whoami")
        if refresh or self._capabilities is None:
            self._capabilities = self.backend.read("capabilities", identity=self._identity)
        return self._capabilities

    def has_feature(self, name, action="read"):
        return cap.enabled(self.capabilities(), name, action)

    def require_feature(self, name, action="read"):
        cap.require(self.capabilities(), name, action)

    def mode_change(self, kind, key, mode, allowance=None, *, apply=False):
        require_owner(self.read("whoami"))
        kind = scope_type(kind)
        if kind not in {"organization", "department"} or mode not in {"strict", "allowance", "notify"}:
            raise FinOpsError("Choose a unit/team and strict, allowance or notify.")
        if mode == "allowance":
            if isinstance(allowance, bool) or not isinstance(allowance, int) or not 1 <= allowance <= 100:
                raise FinOpsError("Allowance must be a whole percentage from 1 to 100.")
        elif allowance is not None:
            raise FinOpsError("Allowance percent is valid only in allowance mode.")
        catalog = self.read("catalog")
        body = {k: deepcopy(catalog.get(k)) for k in ("organizations", "departments", "default_department_id")}
        for row in body["organizations"]:
            row.pop("parent_id", None)
        rows = body["organizations" if kind == "organization" else "departments"]
        row = next((item for item in rows if item["id"] == key), None)
        if row is None:
            raise FinOpsError("Scope not found. Refresh Governance.", 5)
        before = deepcopy(row.get("attributes", {}))
        row.setdefault("attributes", {})["enforcement"] = mode
        row["attributes"].pop("allowance_percent", None)
        if mode == "allowance":
            row["attributes"]["allowance_percent"] = allowance
        plan = dict(preview=not apply, action="Set budget mode", scope_type=kind, scope_id=key,
                    before=before, after=row["attributes"], effect="Configured mode; follow gateway apply before claiming effect.")
        if apply:
            plan["requested_at"] = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            if self.backend.name == "Direct":
                plan["result"] = self.backend.write("mode", dict(mode=mode, allowance_percent=allowance), scope_id=key)
            else:
                plan["result"] = self.backend.write("catalog", body)
        return plan

    def compare_trends(self, comparison, interval="day", group_by="none", **filters):
        month_window(comparison)
        current = self.read("trends", interval=interval, group_by=group_by, **filters)
        other = self.backend.read("trends", month=comparison, interval=interval, group_by=group_by, **filters)
        return dict(current_period=self.month, comparison_period=comparison, current=current, comparison=other,
                    basis="Compare actual returned buckets; missing buckets and costs remain unknown.")

    def _feature_change(self, resource, body=None, *, apply=False, action=None, **params):
        feature, required = cap.WRITE_FEATURES[resource]
        self.require_feature(feature, action or required)
        plan = dict(preview=not apply, action=resource, after=body)
        if apply:
            plan["result"] = self.backend.write(resource, body, month=self.month,
                                                idempotency_key=str(uuid4()), **params)
        return plan

    @staticmethod
    def _reason(reason):
        if not isinstance(reason, str) or not reason.strip() or len(reason) > 2000:
            raise FinOpsError("Enter a reason of 1 to 2,000 characters.")
        return reason.strip()

    def request_budget(self, kind, key, amount, reason, *, expires_at=None, apply=False):
        body = dict(scope_type=scope_type(kind), scope_id=identifier(key), period=self.month,
                    token_limit=parse_tokens(amount), reason=self._reason(reason), expires_at=expires_at)
        return self._feature_change("approval_create", body, apply=apply)

    def decide_request(self, key, decision, reason, *, apply=False):
        if decision not in {"approve", "reject", "escalate"}:
            raise FinOpsError("Choose approve, reject or escalate.")
        self.require_feature("approvals", decision)
        row = self.read("approval_request", id=identifier(key))
        if not row:
            raise FinOpsError("Request not found in your queue. Refresh Approvals.", 5)
        identity = self.read("whoami")
        if decision == "approve" and row["requester_id"] in {identity.get("id"), identity.get("email")}:
            raise FinOpsError("You cannot approve your own request. Ask the parent-scope approver.", 4)
        if decision not in row.get("allowed_actions", []):
            raise FinOpsError("Not in your scope: this decision is not permitted for this request.", 4)
        body = dict(reason=self._reason(reason), revision=row["revision"])
        resource = "approval_escalate" if decision == "escalate" else "approval_decide"
        if decision != "escalate":
            body["decision"] = decision
        return self._feature_change(resource, body, id=key, action=decision, apply=apply)

    def boost(self, person, team, amount, until, reason, *, window="monthly", apply=False):
        self.require_feature("boosts", "create")
        if window not in {"daily", "monthly"}:
            raise FinOpsError("Boost window must be daily or monthly.")
        try:
            expires = datetime.fromisoformat(until.replace("Z", "+00:00"))
            expires = expires.replace(tzinfo=timezone.utc) if expires.tzinfo is None else expires.astimezone(timezone.utc)
        except ValueError:
            raise FinOpsError("Use a UTC ISO expiry or YYYY-MM-DD.") from None
        if expires <= datetime.now(timezone.utc):
            raise FinOpsError("Boost expiry must be in the future.")
        tokens = parse_tokens(amount)
        people = self.read("people", department_id=identifier(team), query=identifier(person), offset=0, limit=50)
        row = next((r for r in people["items"] if r["scope_id"] == person), None)
        if not row:
            raise FinOpsError("Person not found in the selected team.", 5)
        headroom = people.get("department_available_tokens")
        if headroom is not None and tokens > headroom:
            raise FinOpsError("Boost exceeds parent headroom. Request the difference from the parent approver.", 6)
        body = dict(scope_type="user", scope_id=person, department_id=team, window=window,
                    extra_tokens=tokens, expires_at=expires.isoformat().replace("+00:00", "Z"), reason=self._reason(reason))
        return self._feature_change("boost_create", body, apply=apply)

    def revoke_boost(self, key, *, apply=False):
        return self._feature_change("boost_revoke", id=identifier(key), apply=apply)

    def disposition(self, key, status, reason, *, apply=False):
        if status not in {"acknowledged", "false_positive"}:
            raise FinOpsError("Choose acknowledged or false_positive.")
        return self._feature_change("disposition", dict(status=status, reason=self._reason(reason)),
                                    id=identifier(key), action="acknowledge" if status == "acknowledged" else status, apply=apply)

    def mark_notification(self, key, *, apply=False):
        return self._feature_change("notification_read", id=identifier(key), apply=apply)

    def ask(self, question, conversation_id=None, history=None):
        self.require_feature("assistant", "ask")
        if not isinstance(question, str) or not question.strip() or len(question) > 4000:
            raise FinOpsError("Ask a question of 1 to 4,000 characters.")
        return self.backend.write("assistant_ask", dict(question=question.strip(), history=(history or [])[-20:],
                                  conversation_id=conversation_id, timezone="UTC", locale="en"))

    def pin_chart(self, reply, chart_id, title, *, apply=False):
        chart = next((chart for chart in reply.get("charts", []) if chart["id"] == chart_id), None)
        if not chart:
            raise FinOpsError("Choose a chart returned by the assistant; chart data cannot be invented.", 5)
        body = dict(title=title, original_question=reply.get("question", "Assistant chart"),
                    description="", chart=deepcopy(chart))
        return self._feature_change("pin_chart", body, apply=apply)
