import asyncio
import json
from pathlib import Path

from textual.containers import Horizontal
from textual.widgets import Button, Input, Select, Static, TextArea, DataTable

from .backend import connect
from .bulk import budget_csv_plan
from .capabilities import enabled
from .config import Config, load_config, az
from .engine import Engine
from .errors import FinOpsError
from .feature_screens import ActionForm, FiltersScreen, TourScreen
from .ledger import ledger_url
from .preferences import Preferences
from .screens import DetailScreen

EXTRA_TABS = [("approvals", "9 Approvals"), ("ask", "a Ask"), ("advanced", "Advanced")]


class FeatureUI:
    def initialize_features(self, first_run=None):
        self.scope_filters = {}
        self.compare_period = ""
        self.feature_caps = {}
        self.preferences = None
        self.first_run = first_run
        self.ask_reply = None
        self.ask_history = []
        self.ask_conversation = None
        self.approvals_view = "mine"
        self.advanced_view = "models"
        self.advanced_model = None
        self.request_cursor = None
        self.cursor_stack = []
        self.ranking_dimension = "organization"

    def compose_feature(self, tab):
        if tab == "ask":
            with Horizontal(classes="toolbar"):
                yield Input(placeholder="Ask about spend, usage or budgets", id="ask-question", password=self.redactor.enabled)
                yield Button("Ask", id="ask-send")
                yield Button("Pin", id="ask-pin")
            yield TextArea("Ask uses the connected server's model and tool permissions.", id="ask-answer", read_only=True)
        elif tab == "approvals":
            with Horizontal(classes="toolbar"):
                yield Select([("My requests", "mine"), ("Waiting for me", "waiting"), ("History", "history"),
                              ("Notifications", "notifications")], value="mine", allow_blank=False, id="approval-view")
                yield Button("Request", id="approval-request")
        elif tab == "advanced":
            with Horizontal(classes="toolbar"):
                yield Select([("Models", "models"), ("Backend pools", "pools"), ("Releases", "releases"),
                              ("Subscriptions", "subscriptions")], value="models", allow_blank=False, id="advanced-view")
                yield Input(placeholder="Model id for backend pool", id="advanced-model", password=self.redactor.enabled)
                yield Button("Open", id="advanced-load")

    async def refresh_features(self):
        self.feature_caps = await asyncio.to_thread(self.engine.capabilities)
        if self.preferences is None:
            identity = self.identity.get("id") or self.identity.get("email", "unknown")
            profile = f"{self.config.backend}|{self.config.url}|{self.config.subscription}|{self.config.apim_name}"
            self.preferences = Preferences(identity, profile, memory=self.config.backend == "fake")
        tabs = self.query_one("#main-tabs")
        for tab, feature in (("ask", "assistant"), ("approvals", "approvals"), ("advanced", "advanced")):
            allowed = enabled(self.feature_caps, feature)
            if tab == "approvals" and self.identity.get("role") != "owner" and self.identity.get("manager_scope") is None:
                allowed = False
            if allowed:
                self.allowed_tabs.add(tab)
                if not tabs.get_tab(tab).display:
                    tabs.show_tab(tab)
            else:
                self.allowed_tabs.discard(tab)
                if tabs.get_tab(tab).display:
                    tabs.hide_tab(tab)
        self.update_filter_chips()
        options = [("My requests", "mine"), ("Waiting for me", "waiting"), ("History", "history")]
        if enabled(self.feature_caps, "notifications"):
            options.append(("Notifications", "notifications"))
        selector = self.query_one("#approval-view", Select)
        with selector.prevent(Select.Changed):
            selector.set_options(options)
            selector.value = self.approvals_view if self.approvals_view in {value for _, value in options} else "mine"

    def maybe_tour(self):
        if self.first_run is False or (self.first_run is None and self.config.backend == "fake"):
            return
        if self.preferences and not self.preferences.toured and len(self.screen_stack) == 1:
            self.push_screen(TourScreen())

    def update_filter_chips(self):
        if not self.query("#filter-chips"):
            return
        labels = [f"[month {self.engine.month}]"]
        aliases = {"organization_id": "unit", "department_id": "team", "user_id": "person",
                   "model_id": "model", "runtime": "surface", "tier": "tier", "from": "from", "to": "to"}
        labels += [f"[{aliases[key]} {self.redactor.text(value)}]" for key, value in self.scope_filters.items() if value]
        if self.compare_period:
            labels.append(f"[vs {self.compare_period}]")
        self.query_one("#filter-chips", Static).update(" ".join(labels) + "  f filters | v saved views")

    def action_scope_filters(self):
        self.push_screen(FiltersScreen())

    def reset_paging(self):
        self.request_page = self.people_offset = 0
        self.request_cursor = None
        self.cursor_stack = []

    def clear_query_context(self):
        self.reset_paging()
        self.scope_filters = {}
        self.request_filters = {}
        self.filters = {}
        self.request_before = self.people_query = self.team = ""
        self.budget_parent = None
        self.breadcrumbs = []
        self.ask_history = []
        self.ask_reply = self.ask_conversation = None
        for selector in ("#request-model", "#request-before", "#people-query", "#ask-question"):
            self.query_one(selector, Input).value = ""
        self.query_one("#ask-answer", TextArea).load_text("Ask about the current authorized scope.")
        self.update_filter_chips()

    def action_save_view(self):
        def run(values, apply):
            view = dict(tab=self.active, month=self.engine.month, filters=self.scope_filters,
                        dimension=self.dimension, interval=self.interval, compare=self.compare_period)
            plan = dict(preview=not apply, action="Save view for this identity and profile", after=view)
            if apply:
                self.preferences.save_view(values["name"], view)
            return plan
        self.push_screen(ActionForm("Save current view", [("name", "View name", "", None)], run, mutation=False))

    def action_load_view(self):
        views = self.preferences.views()
        if not views:
            self.notify("No saved views yet. Choose Save current view from the command palette.")
            return
        def run(values, apply):
            view = views[values["name"]]
            if apply:
                return dict(ui_action="view", view=view)
            return dict(preview=not apply, action="Open saved view", after=view)
        self.push_screen(ActionForm("Open saved view", [("name", "View", next(iter(views)),
                                [(name, name) for name in views])], run, mutation=False))

    def restore_view(self, view):
        self.engine.month = view.get("month", self.engine.month)
        self.scope_filters = view.get("filters", {})
        self.dimension = view.get("dimension", self.dimension)
        self.interval = view.get("interval", self.interval)
        self.compare_period = view.get("compare", "")
        self.update_filter_chips()
        self.action_tab(view.get("tab", "overview"))
        self.request_page = self.people_offset = 0
        self.request_cursor = None
        self.cursor_stack = []
        with self.query_one("#dimension", Select).prevent(Select.Changed):
            self.query_one("#dimension", Select).value = self.dimension
        with self.query_one("#interval", Select).prevent(Select.Changed):
            self.query_one("#interval", Select).value = self.interval
        self.action_refresh()

    def action_compare(self):
        def run(values, apply):
            from .rules import month_window
            month_window(values["month"])
            if apply:
                return dict(ui_action="compare", month=values["month"])
            return dict(preview=not apply, action="Compare periods", after=values["month"])
        self.push_screen(ActionForm("Compare Trends", [("month", "Comparison month YYYY-MM", self.engine.month, None)], run, mutation=False))

    def set_comparison(self, month):
        self.compare_period = month
        self.scope_filters.pop("from", None)
        self.scope_filters.pop("to", None)
        self.update_filter_chips()
        self.action_tab("trends")
        self.action_refresh()

    def action_mode(self):
        if not self.editable:
            return
        row = self.selected()
        kind = "unit" if row.get("kind") == "unit" or row.get("scope_type") == "organization" else "team"
        key = row.get("scope_id", row.get("id", ""))
        def run(values, apply):
            allowance = int(values["allowance"]) if values["allowance"] else None
            return self.engine.mode_change(values["kind"], values["scope"], values["mode"], allowance, apply=apply)
        self.push_screen(ActionForm("Set enforcement mode", [
            ("kind", "Scope kind", kind, [("unit", "Unit"), ("team", "Team")]),
            ("scope", "Stable scope id", key, None),
            ("mode", "Mode", "strict", [(m, m.title()) for m in ("strict", "allowance", "notify")]),
            ("allowance", "Allowance percent (only allowance)", "", None)], run))

    def action_bulk(self):
        if not enabled(self.feature_caps, "bulk_budget", "write") or self.redactor.enabled:
            return
        self.push_screen(ActionForm("Import person budgets from CSV", [("file", "CSV: team, person, tokens, warning", "", None)],
            lambda values, apply: budget_csv_plan(self.engine, values["file"], apply=apply)))

    def action_request_budget(self, amount="", row=None):
        if not enabled(self.feature_caps, "approvals", "request"):
            return
        row = row or (self.selected() if self.active in {"budgets", "people"} else {})
        kind = {"organization": "unit", "department": "team", "user": "person"}.get(row.get("scope_type"), "team")
        self.push_screen(ActionForm("Request budget from the parent approver", [
            ("kind", "Scope", kind, [(k, k.title()) for k in ("unit", "team", "person")]),
            ("scope", "Scope id", row.get("scope_id", ""), None),
            ("amount", "Requested monthly tokens", amount, None),
            ("reason", "Reason", "", None)],
            lambda values, apply: self.engine.request_budget(values["kind"], values["scope"], values["amount"],
                                                              values["reason"], apply=apply)))

    def action_decide(self, decision):
        if not enabled(self.feature_caps, "approvals", decision):
            return
        key = self.selected().get("id", "")
        self.push_screen(ActionForm(decision.title() + " request", [
            ("request", "Request id", key, None), ("reason", "Reason", "", None)],
            lambda values, apply: self.engine.decide_request(values["request"], decision, values["reason"], apply=apply)))

    def action_boost(self):
        if not enabled(self.feature_caps, "boosts", "create"):
            return
        row = self.selected() if self.active == "people" else {}
        self.push_screen(ActionForm("Temporary person boost", [
            ("person", "Person id", row.get("scope_id", ""), None),
            ("team", "Team", self.team, None), ("amount", "Additional tokens", "", None),
            ("until", "Expires at (UTC ISO date/time)", "", None), ("reason", "Reason", "", None)],
            lambda values, apply: self.engine.boost(values["person"], values["team"], values["amount"],
                                                     values["until"], values["reason"], apply=apply)))

    def action_disposition(self, status):
        action = "acknowledge" if status == "acknowledged" else "false_positive"
        if not enabled(self.feature_caps, "anomaly_dispositions", action):
            return
        self.push_screen(ActionForm("Set anomaly disposition", [
            ("id", "Finding id", self.selected().get("id", ""), None), ("reason", "Reason", "", None)],
            lambda values, apply: self.engine.disposition(values["id"], status, values["reason"], apply=apply)))

    def action_copy_request(self):
        if self.active != "requests" or self.redactor.enabled:
            return
        key = self.selected().get("request_id")
        if key:
            self.copy_to_clipboard(key)
            self.notify("Copied request id using the terminal clipboard protocol.")

    def action_open_ledger(self):
        if self.active != "requests" or self.redactor.enabled:
            return
        key = self.selected().get("request_id")
        if key:
            try:
                self.open_url(ledger_url(self.config.workspace_resource_id, self.config.tenant_id, key, self.engine.month))
            except FinOpsError as error:
                self.notify(str(error), severity="error")

    def action_profile(self):
        def run(values, apply):
            config = load_config(Path(values["path"]), backend=values["backend"] or None)
            if apply:
                return dict(ui_action="profile", config=config)
            return dict(preview=not apply, action="Switch profile/backend", after=config.public())
        self.push_screen(ActionForm("Switch profile or backend", [
            ("path", "Profile JSON path", str(Path.home() / ".aum" / "config.json"), None),
            ("backend", "Backend", self.config.backend, [(b, b.title()) for b in ("turnstile", "direct", "fake")])],
            run, mutation=False))

    async def activate_profile(self, config):
        backend = None
        try:
            backend = connect(config)
            engine = Engine(backend, self.engine.month)
            identity = await asyncio.to_thread(engine.read, "whoami")
        except (FinOpsError, OSError, ValueError) as error:
            if backend is not None:
                backend.close()
            self.notify(self.redactor.text(str(error)), severity="error")
            return
        self.engine.backend.close()
        self.engine, self.config = engine, config
        self.identity = {}
        self.preferences = None
        self.data.clear()
        self.records.clear()
        self.clear_query_context()
        if len(self.screen_stack) > 1:
            self.pop_screen()
        self.update_access(identity)
        self.action_refresh()

    def action_sign_out(self):
        def run(values, apply):
            if values["confirm"] != "sign out":
                raise FinOpsError("Type sign out to confirm clearing the Azure CLI session.")
            if apply:
                if self.config.backend != "fake":
                    az("logout")
                self.engine.backend.close()
                return dict(ui_action="signout")
            return dict(preview=not apply, action="Sign out", after="Clear Azure CLI credentials; affects other CLI tools.")
        self.push_screen(ActionForm("Sign out of Azure CLI", [("confirm", "Type sign out (affects other CLI tools)", "", None)], run))

    async def ask_current(self):
        if self.preview_only or self.redactor.enabled:
            self.query_one("#ask-answer", TextArea).load_text(
                "Preview/read-only mode: the question was not sent. Asking can incur model cost and store a conversation.")
            return
        question = self.query_one("#ask-question", Input).value
        self.query_one("#ask-answer", TextArea).load_text("Asking the server. No chart data is generated by the client...")
        try:
            reply = await asyncio.to_thread(self.engine.ask, question, self.ask_conversation, self.ask_history)
            self.ask_reply = dict(reply, question=question)
            self.ask_conversation = reply["conversation_id"]
            self.ask_history = (self.ask_history + [{"role": "user", "content": question},
                               {"role": "assistant", "content": reply["message"]}])[-20:]
            shown = self.present(reply)
            text = shown["message"] + "\n\n" + "\n\n".join(json.dumps(c, indent=2, ensure_ascii=True) for c in shown.get("charts", []))
            self.query_one("#ask-answer", TextArea).load_text(text)
            self.query_one("#ask-answer", TextArea).focus()
        except FinOpsError as error:
            self.query_one("#ask-answer", TextArea).load_text(str(error))

    def action_pin_chart(self):
        if not self.ask_reply or not self.ask_reply.get("charts"):
            self.notify("Ask a question that returns a chart first.")
            return
        charts = self.ask_reply["charts"]
        self.push_screen(ActionForm("Pin server-authored chart", [
            ("chart", "Chart", charts[0]["id"], [(c["id"], self.redactor.text(c["title"])) for c in charts]),
            ("title", "Report title", "Usage report", None)],
            lambda values, apply: self.engine.pin_chart(self.ask_reply, values["chart"], values["title"], apply=apply)))

    async def load_feature_tab(self, tab):
        if tab == "ask":
            settings = await asyncio.to_thread(self.engine.read, "assistant_settings")
            if not settings.get("model_available"):
                self.query_one("#ask-answer", TextArea).load_text(
                    "The assistant API exists, but no model is available. An Owner can choose an advertised model.")
            return {"items": [{"setting": key, "value": value} for key, value in settings.items()], "note": "Server model, tools and cost; no client-invented chart rows."}
        if tab == "approvals":
            resource = "notifications" if self.approvals_view == "notifications" else "approval_requests"
            params = {} if resource == "notifications" else {"view": self.approvals_view}
            return await asyncio.to_thread(self.engine.read, resource, limit=50, **params)
        if self.advanced_view == "models":
            response = await asyncio.to_thread(self.engine.read, "registry")
            return dict(response, items=response.get("models", []), note="Read-only model registry. Enter shows exact configuration; credentials are omitted.")
        if self.advanced_view == "pools":
            key = self.query_one("#advanced-model", Input).value
            if not key:
                return dict(items=[], note="Enter a model id from the Models view, then Open.")
            response = await asyncio.to_thread(self.engine.read, "backend_pool", id=key)
            return dict(response, items=response.get("members", []), note="Read-only backend pool.")
        resource = "releases" if self.advanced_view == "releases" else "applications"
        return await asyncio.to_thread(self.engine.read, resource)

    def feature_button(self, button_id):
        actions = {"ask-send": lambda: self.run_worker(self.ask_current(), group="ask", exclusive=True),
                   "ask-pin": self.action_pin_chart, "approval-request": self.action_request_budget,
                   "advanced-load": self.action_refresh, "settings-profile": self.action_profile,
                   "settings-signout": self.action_sign_out, "settings-tour": lambda: self.push_screen(TourScreen())}
        if button_id in actions:
            actions[button_id]()
            return True
        return False

    def feature_select(self, event):
        if event.select.id == "approval-view":
            self.approvals_view = str(event.value)
        elif event.select.id == "advanced-view":
            self.advanced_view = str(event.value)
        else:
            return
        self.action_refresh()

    def action_advanced(self, view):
        if enabled(self.feature_caps, "advanced"):
            self.advanced_view = view
            self.query_one("#advanced-view", Select).value = view
            self.action_tab("advanced")

    def action_assistant_history(self):
        async def load():
            try:
                data = await asyncio.to_thread(self.engine.read, "conversations")
                self.push_screen(DetailScreen("Assistant conversations", data))
            except FinOpsError as error:
                self.notify(str(error), severity="error")
        self.run_worker(load(), group="history", exclusive=True)

    def action_assistant_pins(self):
        async def load():
            try:
                data = await asyncio.to_thread(self.engine.read, "pinned_charts")
                self.push_screen(DetailScreen("Pinned reports", data))
            except FinOpsError as error:
                self.notify(str(error), severity="error")
        self.run_worker(load(), group="pins", exclusive=True)

    def action_overview_rank(self, dimension):
        self.ranking_dimension = dimension
        self.action_tab("overview")
        self.action_refresh()

    def action_revoke_boost(self):
        if not enabled(self.feature_caps, "boosts", "revoke"):
            return
        self.push_screen(ActionForm("Revoke boost", [("id", "Boost id", "", None)],
            lambda values, apply: self.engine.revoke_boost(values["id"], apply=apply)))

    def action_read_notification(self):
        if not enabled(self.feature_caps, "notifications", "mark_read"):
            return
        key = self.selected().get("id", "") if self.active == "approvals" else ""
        self.push_screen(ActionForm("Mark notification read", [("id", "Notification id", key, None)],
            lambda values, apply: self.engine.mark_notification(values["id"], apply=apply)))

    def action_show_boosts(self):
        async def load():
            try:
                data = await asyncio.to_thread(self.engine.read, "boosts", limit=50)
                self.push_screen(DetailScreen("Active and expired boosts", data))
            except FinOpsError as error:
                self.notify(str(error), severity="error")
        self.run_worker(load(), group="boosts", exclusive=True)

    def action_assistant_configure(self):
        if not self.editable:
            return
        async def load():
            try:
                settings = await asyncio.to_thread(self.engine.read, "assistant_settings")
                choices = [("", "Automatic selection")] + [
                    (row["id"], f"{row['display_name']} (input {row.get('input_cost_per_million')}/M, output {row.get('output_cost_per_million')}/M)")
                    for row in settings.get("available_models", [])]
                def operation(values, apply):
                    self.engine.require_feature("assistant", "configure")
                    body = dict(model_id=values["model"] or None, auto_title=values["title"] == "yes")
                    result = dict(preview=not apply, action="Configure assistant", before=settings, after=body)
                    if apply:
                        result["result"] = self.engine.backend.write("assistant_settings", body)
                    return result
                self.push_screen(ActionForm("Assistant model and cost", [
                    ("model", "Model", settings.get("model_id") or "", choices),
                    ("title", "Auto-title conversations", "yes" if settings.get("auto_title") else "no",
                     [("yes", "Yes"), ("no", "No")])], operation))
            except FinOpsError as error:
                self.notify(str(error), severity="error")
        self.run_worker(load(), group="assistant-settings", exclusive=True)

    def action_report_generate(self):
        if not self.editable:
            return
        from .reporting import report_plan
        self.push_screen(ActionForm("Generate reconciled chargeback report", [
            ("month", "Month YYYY-MM", self.engine.month, None),
            ("unit", "Unit id (blank means all authorized units)", "", None),
            ("output", "Local output folder", "finops-reports", None),
            ("formats", "Formats", "CSV,HTML", [("CSV,HTML", "CSV and HTML"), ("CSV", "CSV"), ("HTML", "HTML")])],
            lambda values, apply: report_plan(self.engine, self.config, month=values["month"],
                units=[values["unit"]] if values["unit"] else [], output=values["output"],
                formats=values["formats"], apply=apply)))

    def action_notifications(self):
        async def load():
            try:
                records = await asyncio.to_thread(self.engine.read, "notifications", limit=50)
                self.push_screen(DetailScreen("Your notifications", records))
            except FinOpsError as error:
                self.notify(str(error), severity="error")
        self.run_worker(load(), group="notifications", exclusive=True)

    def action_membership(self):
        if self.active != "people" or self.redactor.enabled:
            return
        async def load():
            try:
                link = await asyncio.to_thread(self.engine.membership_url, self.team)
                self.open_url(link)
                self.notify("Move members in Entra with existing group-owner rights, then refresh the gateway projection.")
            except FinOpsError as error:
                self.notify(str(error), severity="error")
        self.run_worker(load(), group="membership", exclusive=True)

    def action_remove_view(self):
        views = self.preferences.views()
        if not views:
            self.notify("There are no saved views for this identity/profile.")
            return
        def operation(values, apply):
            if apply:
                self.preferences.remove_view(values["name"])
            return dict(preview=not apply, action="Remove saved view", after=values["name"])
        self.push_screen(ActionForm("Remove saved view", [("name", "Saved view", next(iter(views)),
            [(name, name) for name in views])], operation, mutation=False))

    def action_budget_history(self):
        async def load():
            try:
                result = await asyncio.to_thread(self.engine.read, "budgets")
                self.push_screen(DetailScreen("Budget audit history", result.get("history", [])))
            except FinOpsError as error:
                self.notify(str(error), severity="error")
        self.run_worker(load(), group="budget-history", exclusive=True)
