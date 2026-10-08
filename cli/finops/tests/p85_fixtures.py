"""Offline transports for the real Direct/Turnstile adapters and existing engine."""

from contextlib import nullcontext
from copy import deepcopy
from datetime import datetime, timezone
import json

import httpx
from textual.widgets import Input

from claude_finops.config import Config
from claude_finops.direct import DirectBackend
from claude_finops.engine import Engine
from claude_finops.fake import FakeBackend, budget
from claude_finops.guarded_publication import guarded_publish
from claude_finops.tui import FinOpsApp
from claude_finops.turnstile import READ_ROUTES, TurnstileBackend
from test_developers import FakeDeveloperClient, PREMIUM, STANDARD, UNIT, USER


EMAIL = "dev@contoso.com"
TEAM = "00000000-0000-0000-0000-000000000013"
PICKED_GROUP = "00000000-0000-0000-0000-000000000095"
GROUPS = {
    "contoso-standard": STANDARD, "contoso-premium": PREMIUM,
    "contoso-sales": UNIT, "contoso-sales-emea": TEAM,
    "contoso-sales-apac": "00000000-0000-0000-0000-000000000014",
    "contoso-engineering": "00000000-0000-0000-0000-000000000015",
}


class Directory(FakeDeveloperClient):
    def __init__(self, member):
        direct = {STANDARD, UNIT, TEAM} if member else set()
        super().__init__(direct=direct, group_members={group: {USER} for group in direct})

    def group_id(self, value):
        return GROUPS.get(value, value)

    def search_developers(self, query, *, limit=50, cursor=None, state=None):
        assert query in {EMAIL, USER, "dev"}
        return dict(items=[self.resolve_exact(query, state=state)], next_cursor=None)

    def search(self, query, **params):
        assert query == "contoso"
        return dict(items=[dict(id=PICKED_GROUP, displayName="Contoso scope",
                               securityEnabled=True, mailEnabled=False, groupTypes=[])],
                    next_cursor=None)


class ManagementFixture:
    def __init__(self, role="owner", member=True):
        self.fake = FakeBackend(role)
        self.directory = Directory(member)
        self.calls = []
        self.http_calls = []
        self.people_reads = 0
        self.observe_person(member)
        self.usd = dict(schema_version=1, currency="USD", revision="revision-1",
                        price_book_date="2026-09-16", items=[
                            dict(scope_type="organization", scope_id="sales",
                                 amount_usd="1", period="month", writable=True)])

    def observe_person(self, present):
        self.fake.people = [budget("user", USER, EMAIL, "sales-emea", 100000, 1000)] if present else []

    def snapshot(self, resource="read"):
        if resource == "usd_budgets":
            return deepcopy(self.usd)
        if resource == "usd_status":
            return dict(enabled=True, fresh=True, items={})
        assert resource == "read", resource
        return dict(
            authority="Gateway", catalog=deepcopy(self.fake.catalog), tiers=deepcopy(self.fake.tiers),
            registry=[dict(Id=row["scope_id"], TokensPerMonth=row["token_limit"])
                      for row in self.fake.rows],
            parents={row["scope_id"]: row["parent_scope_id"] for row in self.fake.rows
                     if row["parent_scope_id"]},
            quota_org=100000000, overrides={}, person_budgets_supported=True, usd_supported=True,
            entitlements={"standard": list(self.directory.group_members.get(STANDARD, set())),
                          "premium": list(self.directory.group_members.get(PREMIUM, set()))},
            memberships={USER: "sales-emea"} if TEAM in self.directory.direct else {},
        )

    def bridge(self, action, body=None, **params):
        if action == "read":
            return self.snapshot()
        self.calls.append((action, deepcopy(body), deepcopy(params)))
        if action == "catalog":
            self.fake.catalog.update(deepcopy(body))
        elif action == "budget":
            rows = self.fake.people if params["scope_type"] == "user" else self.fake.rows
            next(row for row in rows if row["scope_id"] == params["scope_id"])["token_limit"] = body["token_limit"]
        elif action == "usd_budget":
            self.usd["items"] = [dict(scope_type=params["scope_type"], scope_id=params["scope_id"],
                                      amount_usd=body["amount_usd"], period=body["period"])]
        elif action == "developer_publish":
            if USER in self.directory.group_members.get(PREMIUM, set()):
                return dict(verified=True, published=True, audit_id="audit-1", revision="revision-2",
                            published_tier="premium")
            if USER in self.directory.group_members.get(STANDARD, set()):
                return dict(verified=True, published=True, audit_id="audit-1", revision="revision-2",
                            published_tier="standard")
            return dict(verified=True, published=True, audit_id="audit-1", revision="revision-2",
                        published_tier="none")
        else:
            assert action in {"developer_publish", "delegated_publish"}, action
        return dict(verified=True, published=True, audit_id="audit-1", revision="revision-2")

    def query(self, kql):
        if "row_number()" in kql:
            self.people_reads += 1
            return [dict(person_id=row["scope_id"], user_id=row["scope_id"], actor=row["scope_name"],
                         tier="standard", used_tokens=row["used_tokens"], window_tokens=4000)
                    for row in self.fake.people]
        if "summarize used_tokens=sum(total_tokens) by business_unit" in kql:
            return [dict(business_unit=row["scope_id"], used_tokens=row["used_tokens"])
                    for row in self.fake.rows if row["scope_type"] == "department"]
        return []

    def respond(self, request):
        self.http_calls.append(request)
        path = request.url.path
        if request.method == "GET":
            if path == "/api/v1/finops/capabilities":
                return httpx.Response(200, json=self.fake.read("capabilities"))
            resource = next((key for key, route in READ_ROUTES.items() if route == path), None)
            if resource is None:
                return httpx.Response(404)
            params = dict(request.url.params)
            params["month"] = params.pop("period", datetime.now(timezone.utc).strftime("%Y-%m"))
            for key in ("offset", "limit"):
                if key in params:
                    params[key] = int(params[key])
            if resource == "people":
                self.people_reads += 1
            return httpx.Response(200, json=self.fake.read(resource, **params))
        body = json.loads(request.content) if request.content else None
        if path == READ_ROUTES["catalog"]:
            assert request.method == "PUT"
            result = self.fake.write("catalog", body)
        elif path.startswith("/api/v1/budgets/"):
            assert request.method == "PUT"
            kind, key = path.rsplit("/", 2)[-2:]
            result = self.fake.write("budget", body, scope_type=kind, scope_id=key,
                                     month=request.url.params["period"])
        else:
            raise AssertionError(f"Unexpected write: {request.method} {path}")
        return httpx.Response(200, json=result)


def management_app(monkeypatch, tmp_path, kind="direct", *, role="owner", member=True,
                   preview_only=False, redact=False):
    state = ManagementFixture(role, member)
    monkeypatch.setenv("AUM_STATE_DIR", str(tmp_path))
    config = Config(backend=kind, resource_group="rg-contoso", apim_name="apim-contoso",
                    url="" if kind == "direct" else "https://finops.contoso.com",
                    scope="" if kind == "direct" else "api://example/Manage")
    monkeypatch.setattr(DirectBackend, "_bridge",
                        lambda self, action, body=None, **params: state.bridge(action, body, **params))
    if kind == "direct":
        backend = DirectBackend(config)
        monkeypatch.setattr(backend, "read_cycle", nullcontext)
        monkeypatch.setattr(backend, "prepare_read", lambda resource: None)
        monkeypatch.setattr(backend, "_account", lambda: dict(
            id="00000000-0000-0000-0000-000000000099", user={"name": "admin@contoso.com"}))
        monkeypatch.setattr(backend, "_az", lambda *args: json.dumps({
            "value": [{"actions": ["*"] if state.fake.role == "owner" else [], "notActions": []}]}))
        monkeypatch.setattr(backend, "_snapshot", state.snapshot)
        monkeypatch.setattr(backend, "query", state.query)
    else:
        assert kind == "turnstile"
        backend = TurnstileBackend(config, token_provider=lambda: "test-only",
                                   transport=httpx.MockTransport(state.respond))
    engine = Engine(backend)
    engine.developer_factory = engine.group_factory = lambda: state.directory
    app = FinOpsApp(engine, config, first_run=False, preview_only=preview_only, redact=redact)
    return app, state


async def settle(app, pilot):
    await pilot.pause()
    await app.workers.wait_for_complete()
    await pilot.pause()


async def fill(app, pilot, selector, value):
    with guarded_publish(app.current_guard()):
        app.screen.query_one(selector, Input).value = value
    await pilot.pause()


async def select_developer(app, pilot):
    await pilot.pause()
    await fill(app, pilot, "#developer-search", EMAIL)
    app.screen.query_one("#developer-search", Input).focus()
    await pilot.press("enter")
    await settle(app, pilot)
    await pilot.press("enter")
    await settle(app, pilot)


def membership_writes(state, remove):
    if remove:
        groups = [STANDARD, PREMIUM, UNIT, GROUPS["contoso-engineering"], TEAM, GROUPS["contoso-sales-apac"]]
        return [(USER, group, False) for group in groups]
    return [(USER, STANDARD, True), (USER, PREMIUM, False), (USER, TEAM, True)]


async def choose_record(app, pilot, tab, key):
    app.action_tab(tab)
    await settle(app, pilot)
    row = next(index for index, item in enumerate(app.records[tab])
               if item.get("scope_id", item.get("id")) == key)
    table = app.query_one(f"#table-{tab}")
    table.move_cursor(row=row)
    table.focus()
    await pilot.pause()
