from copy import deepcopy

from .capabilities import current_capabilities
from .errors import FinOpsError

STAMP = "2026-09-24T12:00:00Z"


class FakeFeatures:
    def feature_capabilities(self, identity):
        document = current_capabilities(identity)
        actions = {
            "approvals": ["read", "request", "approve", "reject", "escalate"],
            "boosts": ["read", "create", "revoke"], "notifications": ["read", "mark_read"],
            "request_cursor": ["read"], "conditional_writes": ["write"],
            "anomaly_dispositions": ["read", "acknowledge", "false_positive"],
            "assistant": ["read", "ask", "pin", "manage", "configure"],
            "advanced": ["read"],
            "global_search": ["read"],
        }
        for name, active in self.features.items():
            document["features"][name] = {"enabled": bool(active), "actions": actions.get(name, ["read"])}
        if identity.get("role") != "owner" and identity.get("manager_scope") is None:
            for name in ("approvals", "boosts", "anomaly_dispositions"):
                document["features"][name] = {"enabled": False, "actions": []}
        if identity.get("role") != "owner" and "assistant" in document["features"]:
            document["features"]["assistant"]["actions"].remove("configure")
        if identity.get("manager_scope") is not None:
            for name in ("assistant", "advanced"):
                document["features"][name] = {"enabled": False, "actions": []}
        document["advertised"] = True
        return document

    def read_feature(self, resource, params):
        if resource == "approval_requests":
            rows = self.feature_store["requests"]
            if params.get("id"):
                rows = [row for row in rows if row["id"] == params["id"]]
            return {"items": deepcopy(rows), "page": {"next_cursor": None, "has_more": False}}
        if resource == "approval_request":
            row = next((r for r in self.feature_store["requests"] if r["id"] == params["id"]), None)
            if not row:
                raise FinOpsError("Request not found.", 5)
            return deepcopy(row)
        if resource == "global_search":
            query = params.get("query", "").lower()
            return {"items": [dict(kind="person", id=row["scope_id"], name=row["scope_name"], tab="people",
                                   department_id=row["parent_scope_id"]) for row in self.people
                              if query in (row["scope_id"] + row["scope_name"]).lower()][:params.get("limit", 50)]}
        if resource == "boosts":
            return {"items": deepcopy(self.feature_store["boosts"]), "page": {"next_cursor": None}}
        if resource == "notifications":
            return {"items": [dict(id="notice-1", title="Budget warning", body="Review Sales EMEA",
                                   severity="warning", created_at=STAMP, read_at=None)], "page": {"next_cursor": None}}
        if resource == "assistant_settings":
            return dict(model_available=True, effective_model_name="Example assistant", available_models=[], auto_title=False)
        if resource in {"conversations", "pinned_charts"}:
            return {"items": deepcopy(self.feature_store.get(resource, []))}
        if resource == "registry":
            return dict(gateways=[dict(id="example-gateway", name="Contoso gateway", enabled=True)],
                        models=[dict(id="example-model", name="Example model", enabled=True)], providers=[], runtimes=[])
        if resource == "backend_pool":
            return dict(model_id=params["id"], members=[dict(id="example-backend", priority=1, weight=100)])
        if resource in {"releases", "applications"}:
            return dict(items=[dict(id="example-" + resource, name="Contoso " + resource, status="active")])
        if resource in {"release", "release_diff", "application", "conversation", "pinned_chart"}:
            return dict(id=params["id"], name="Contoso detail", subscriptions=[], exchanges=[], charts=[])
        raise FinOpsError("Example feature not found.", 5)

    def write_feature(self, resource, body, params):
        self.writes.append((resource, deepcopy(params), deepcopy(body)))
        if resource == "approval_create":
            row = dict(body, id=f"request-{len(self.feature_store['requests']) + 1}", requester_id=self.actor_id,
                       state="pending", revision="1", allowed_actions=["approve", "reject", "escalate"], created_at=STAMP)
            self.feature_store["requests"].append(row)
            return deepcopy(row)
        if resource in {"approval_decide", "approval_escalate"}:
            row = next(r for r in self.feature_store["requests"] if r["id"] == params["id"])
            if resource == "approval_decide" and body["decision"] == "approve" and row["requester_id"] == self.actor_id:
                raise FinOpsError("Cannot approve your own request.", 4)
            row["state"] = "escalated" if resource == "approval_escalate" else (
                "approved" if body["decision"] == "approve" else "rejected")
            row["revision"] = str(int(row["revision"]) + 1)
            return deepcopy(row)
        if resource == "boost_create":
            row = dict(body, id=f"boost-{len(self.feature_store['boosts']) + 1}", state="active")
            self.feature_store["boosts"].append(row)
            return deepcopy(row)
        if resource == "boost_revoke":
            row = next(r for r in self.feature_store["boosts"] if r["id"] == params["id"])
            row["state"] = "revoked"
            return deepcopy(row)
        if resource in {"notification_read", "disposition"}:
            return dict(id=params["id"], **(body or {}), changed_at=STAMP)
        if resource == "assistant_ask":
            chart = dict(id="tokens-chart", kind="bar", title="Token usage", time_range_label="2026-09",
                         basis="Example server query", unit="tokens", category_key="scope", category_label="Scope",
                         series=[dict(key="tokens", label="Tokens")], rows=[dict(scope="sales", tokens=11000000)],
                         generated_at=STAMP, query=dict(tool="distribution", arguments=dict(dimension="organization")))
            return dict(conversation_id="example-conversation", question=body["question"],
                        message="Sales accounts for the larger share of token usage.", charts=[chart], steps=[],
                        latency_ms=20, total_tokens=100, model="Example assistant")
        if resource == "pin_chart":
            row = dict(id=f"pin-{len(self.feature_store['pinned_charts']) + 1}", **body)
            self.feature_store["pinned_charts"].append(row)
            return deepcopy(row)
        if resource == "bulk_budget":
            selected = [p for p in self.people if p["scope_id"] in body["user_ids"]]
            for row in selected:
                row["token_limit"] = body["token_limit"]
            return dict(updated_count=len(selected), token_limit_per_user=body["token_limit"])
        return dict(saved=True)
