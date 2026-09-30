import asyncio

from rich.text import Text
from textual import on, work
from textual.app import ComposeResult
from textual.binding import Binding
from textual.theme import Theme
from .publication_widgets import (
    Button, DataTable, Horizontal, Input, Select, Static, TabbedContent, TabPane, TextArea, PublicationApp,
)

from .errors import FinOpsError
from .publication_output import profile_path as selected_profile_path
from .accessibility import AsciiFilter
from .brand import BANNER, COMPACT, PRODUCT
from .dashboard import Dashboard, DashboardPanel, enforcement_badge
from .output import safe_text
from .palette import FinOpsCommands
from .rules import can_edit, can_budget_write
from .redaction import Redactor
from .scope import visible_tabs
from .screens import ChangeScreen, DetailScreen, ExportScreen, LookupScreen, MonthScreen
from .views import DIMENSIONS, TABS, view_rows
from .ui_features import FeatureUI, EXTRA_TABS
from .capabilities import enabled
from .usd import can_usd_write
from .feature_screens import FilterChips
from .progressive import ProgressiveRefresh
from .guarded_publication import guarded_publish, published, guarded_deferred
from .principal_ui import PrincipalUI


class FinOpsApp(PrincipalUI, ProgressiveRefresh, FeatureUI, PublicationApp):
    TITLE = PRODUCT
    CSS_PATH = "terminal.tcss"
    COMMANDS = {FinOpsCommands}
    BINDINGS = [
        *[Binding(label[0], f"tab('{tab}')", label[2:], show=False, priority=True) for tab, label in TABS],
        Binding("/", "lookup", "Lookup"),
        Binding("ctrl+f", "filter", "Filter rows", show=False),
        Binding("f", "scope_filters", "Filters", show=False),
        Binding("v", "load_view", "Views", show=False),
        Binding("9", "tab('approvals')", "Approvals", show=False, priority=True),
        Binding("a", "tab('ask')", "Ask", show=False, priority=True),
        Binding("c", "copy_request", "Copy id", show=False),
        Binding("o", "open_ledger", "Ledger", show=False),
        Binding("d", "exact_detail", "Exact detail", show=False),
        Binding("escape", "clear_filter", "Clear filter", show=False),
        Binding("colon", "command_palette", "Commands", key_display=":"),
        Binding("m", "month", "Month"),
        Binding("e", "edit", "Edit"),
        Binding("g", "add_developer", "Add person to team", show=False),
        Binding("u", "usd_edit", "Set USD budget", show=False),
        Binding("x", "chargeback", "Chargeback report", show=False),
        Binding("ctrl+a", "apply", "Apply"),
        Binding("n", "next_page", "Next"),
        Binding("p", "previous_page", "Previous"),
        Binding("r", "refresh", "Refresh", show=False),
        Binding("question_mark", "help", "Help", key_display="?"),
        Binding("q", "quit", "Quit"),
    ]

    def __init__(self, engine, config, no_color=False, preview_only=False, redact=False, first_run=None,
                 profile_path=None):
        super().__init__()
        self.animation_level = "none"
        self.config = config
        self.profile_path = selected_profile_path(profile_path)
        self._bind_engine(engine)
        self._clearing_principal = False
        self._principal_notice = False
        self.preview_only = preview_only
        self.redactor = Redactor(redact)
        self.identity = {}
        self.editable = False
        self.verifying_identity = False
        self._refresh_serial = 0
        self._waiting = set()
        self.allowed_tabs = visible_tabs({})
        self.team = ""
        self.people_query = ""
        self.people_offset = 0
        self.request_page = 0
        self.request_before = ""
        self.request_filters = {}
        self.dimension = "organization"
        self.interval = "day"
        self.data = {}
        self._data_guards = {}
        self.records = {}
        self.pending_selection = None
        self.filters = {}
        self.budget_parent = None
        self.breadcrumbs = []
        self.initialize_features(first_run)
        self.register_theme(Theme(name="gateway", primary="#F2A007", accent="#F2A007", secondary="#8FADEC",
                                  foreground="#F2F4FA", background="#0D1117", surface="#161D2D", panel="#1E2761",
                                  warning="#F2A007", error="#FF9292", success="#8DE0AA", dark=True))
        self.register_theme(Theme(name="high-contrast", primary="#FFFF00", accent="#FFFF00",
                                  foreground="#FFFFFF", background="#000000", surface="#000000",
                                  panel="#000000", dark=True))
        self.register_theme(Theme(name="no-color", primary="#FFFFFF", accent="#FFFFFF",
                                  foreground="#FFFFFF", background="#000000", surface="#000000",
                                  panel="#000000", warning="#FFFFFF", error="#FFFFFF", success="#FFFFFF", dark=True))
        self.theme = "no-color" if no_color else (config.theme if config.theme in self.available_themes else "gateway")

    @published(lambda self: self.safe_message_guard())
    def compose(self) -> ComposeResult:
        yield Static(COMPACT, id="brand", markup=False)
        yield Static("Signing in through Azure CLI (estimate 3-5 s)...", id="identity", markup=False)
        yield FilterChips("", id="filter-chips", markup=False)
        yield Input(placeholder="Filter visible rows (Esc clears; / searches the server)", id="quick-filter",
                    password=self.redactor.enabled)
        with TabbedContent(initial="overview", id="main-tabs"):
            for tab, title in TABS + EXTRA_TABS:
                with TabPane(title, id=tab):
                    if tab in {"ask", "approvals", "advanced"}:
                        yield from self.compose_feature(tab)
                    if tab == "budgets":
                        with Horizontal(classes="toolbar actions"):
                            yield Button("Add person to team", id="action-add-person")
                            yield Button("Set budget", id="action-set-budget")
                            yield Button("Set USD budget", id="action-set-usd-budget")
                            yield Button("Chargeback report", id="action-chargeback")
                    if tab == "people":
                        with Horizontal(classes="toolbar"):
                            yield Select([], id="people-team", prompt="Choose a team")
                            yield Input(placeholder="Search people; Enter", id="people-query", password=self.redactor.enabled)
                            yield Button("Find", id="find-people")
                        with Horizontal(classes="toolbar actions"):
                            yield Button("Add person to team", id="action-add-person")
                            yield Button("Set budget", id="action-set-budget")
                            yield Button("Set USD budget", id="action-set-usd-budget")
                            yield Button("Chargeback report", id="action-chargeback")
                    elif tab == "usage":
                        with Horizontal(classes="toolbar"):
                            yield Select(DIMENSIONS, value="organization", allow_blank=False, id="dimension")
                            yield Static("Tokens + cache + estimated cost", classes="toolbar-note")
                    elif tab == "trends":
                        with Horizontal(classes="toolbar"):
                            yield Select([("Daily", "day"), ("Hourly", "hour"), ("Weekly", "week")],
                                         value="day", allow_blank=False, id="interval")
                            yield Static("Enter a bucket for exact metrics", classes="toolbar-note")
                    elif tab == "requests":
                        with Horizontal(classes="toolbar"):
                            yield Input(placeholder="Filter model (exact id)", id="request-model", password=self.redactor.enabled)
                            yield Input(placeholder="Before ISO time (UTC)", id="request-before")
                            yield Button("Filter", id="filter-requests")
                    elif tab == "settings":
                        with Horizontal(classes="toolbar"):
                            yield Select([("AUM", "gateway"), ("High contrast", "high-contrast"),
                                          ("No color", "no-color"), ("Light", "textual-light")],
                                         value=self.theme, id="theme-choice", allow_blank=False)
                            yield Static("Use --plain for a linear screen-reader view", classes="toolbar-note")
                        with Horizontal(classes="toolbar"):
                            yield Button("Change connection", id="settings-profile")
                            yield Button("Sign out", id="settings-signout")
                            yield Button("Tour", id="settings-tour")
                        yield Static("", id="settings-connection", classes="context connection-summary", markup=False)
                    yield Static("Loading...", id=f"note-{tab}", classes="context", markup=False)
                    if tab == "overview":
                        yield Dashboard(id="dashboard")
                    yield DataTable(id=f"table-{tab}", cursor_type="row", zebra_stripes=True,
                                    classes="all-metrics" if tab == "overview" else "titled-table")
        yield Static("1-8 / 0 tabs | Tab / Shift+Tab focus | Enter details | ? one-screen tour", id="status", markup=False)
        yield Static("", id="key-hints", markup=False)

    @published(lambda self: self.safe_message_guard())
    def on_mount(self):
        if self.config.ascii:
            self.add_class("ascii")
        for tab, label in TABS + EXTRA_TABS:
            self.query_one(f"#table-{tab}", DataTable).border_title = label if tab == "advanced" else label[2:]
        self.update_brand()
        self.update_key_hints()
        for tab, _ in EXTRA_TABS:
            self.query_one("#main-tabs").hide_tab(tab)

    @published(lambda self: self.safe_message_guard())
    def update_key_hints(self):
        if not self.query("#key-hints"):
            return
        actions_visible = self.active in {"people", "budgets"}
        keys = [] if actions_visible else ["/ Find", ": Command", "f Filters", "m Month"]
        if actions_visible:
            if self.identity.get("role") == "owner" and not self.redactor.enabled:
                keys.append("g Add person to team" if self.check_action("add_developer", ()) else "Add person to team")
            keys.extend(["e Set budget", "u Set USD budget", "x Chargeback report"])
        elif self.check_action("edit", ()):
            keys.append("e Edit")
        if self.check_action("apply", ()):
            keys.append("Ctrl+A Apply")
        action_line = " | ".join(keys) if actions_visible else ""
        if actions_visible:
            keys = [": Command"]
        if self.check_action("next_page", ()):
            keys.append("n/p Page")
        keys.extend(["? Help", "q Quit"])
        self.query_one("#key-hints", Static).update(
            action_line + "\n" + " | ".join(keys) if actions_visible else
            "  ".join(f"<{key}>" for key in keys))

    @published(lambda self: self.safe_message_guard())
    def update_brand(self):
        self._synchronize_principal()
        if not self.query("#brand") or not self.query("#main-tabs"):
            return
        show_art = self.size.width >= 80 and self.size.height >= 24
        self.set_class(show_art, "banner-header")
        heading = PRODUCT if self.config.ascii else COMPACT
        if not show_art:
            self.query_one("#brand", Static).update(heading)
            return
        identity = str(self.query_one("#identity", Static).render()).strip()
        lines = BANNER.splitlines()
        right_width = max(8, self.size.width - len(lines[1]) - 4)
        if len(identity) > right_width:
            identity = identity[:right_width - 3] + "..."
        header = [
            f"{lines[0]}  {PRODUCT}",
            f"{lines[1]}  {identity}" if identity else lines[1],
            lines[2],
            lines[3],
        ]
        self.query_one("#brand", Static).update("\n".join(header))

    def on_resize(self):
        self.update_brand()
        if self.data.get("overview"):
            self.call_after_refresh(guarded_deferred(self.cached_guard("overview"), self.render_tab),
                                    "overview", self.data["overview"])

    def get_line_filters(self):
        filters = list(super().get_line_filters())
        if getattr(self, "config", None) and self.config.ascii:
            filters.append(AsciiFilter())
        return filters

    @property
    def active(self):
        return self.query_one("#main-tabs", TabbedContent).active

    def check_action(self, action, parameters):
        if action in {"edit", "usd_edit", "apply"} and self.verifying_identity:
            return False
        if action == "tab":
            if len(self.screen_stack) > 1 or isinstance(self.focused, Input):
                return False
            if isinstance(self.focused, TextArea) and not self.focused.read_only:
                return False
            return bool(parameters) and parameters[0] in self.allowed_tabs
        if action in {"export", "chargeback"}:
            return "overview" in self.allowed_tabs
        if action == "add_developer":
            return (self.config.backend != "aum-service" and self.identity.get("role") == "owner"
                    and not self.redactor.enabled and not self.verifying_identity)
        if action == "usd_edit":
            if (self.active not in {"people", "budgets"} or self.redactor.enabled
                    or not enabled(self.feature_caps, "usd_budgets", "write")):
                return False
            row = self.selected()
            return bool(row) and can_usd_write(self.identity, row.get("scope_type"), row.get("scope_id"), row)
        if action == "edit":
            if self.redactor.enabled:
                return False
            if "native_writes" in self.feature_caps.get("features", {}) and not enabled(self.feature_caps, "native_writes", "budget"):
                return False
            if self.active in {"budgets", "people"}:
                row = self.selected()
                if row.get("writable") is False:
                    return False
                if self.engine.backend.native_user_budget_records and row.get("scope_type") == "user":
                    return row.get("writable") is True
                return can_budget_write(self.identity, row.get("scope_type"), row.get("scope_id"),
                                        row.get("parent_scope_id"))
            return self.editable and self.active == "governance"
        if action == "apply":
            return self.editable and self.active == "governance" and not self.engine.backend.immediate_writes
        if action in {"next_page", "previous_page"}:
            return self.active in {"people", "requests", "approvals"}
        if action in {"copy_request", "open_ledger"}:
            return self.active == "requests" and not self.redactor.enabled
        return True

    def action_tab(self, tab):
        if len(self.screen_stack) != 1 or tab not in self.allowed_tabs:
            return
        self.query_one("#main-tabs", TabbedContent).active = tab
        if tab not in {"ask", "approvals", "advanced"}:
            self.set_focus(self.query_one("#dash-kpis" if tab == "overview" else f"#table-{tab}"))

    @on(TabbedContent.TabActivated)
    def switched(self, event):
        if not self.query("#main-tabs") or event.pane.id != self.active or self._principal_notice:
            return
        self.update_brand()
        self.update_key_hints()
        self.query_one("#quick-filter", Input).display = False
        self.refresh_bindings()
        self.action_refresh()

    def update_access(self, identity, preserve_current=False):
        before = tuple(self.identity.get(key) for key in ("id", "email", "role", "manager_scope"))
        after = tuple(identity.get(key) for key in ("id", "email", "role", "manager_scope"))
        self.identity = identity
        self.editable = can_edit(identity) and not self.redactor.enabled
        if before == after:
            self.update_action_buttons()
            return
        self.allowed_tabs = visible_tabs(identity)
        if before != after and not preserve_current:
            self.data.clear()
            self._data_guards.clear()
            self.records.clear()
            self.clear_query_context()
            for tab, _ in TABS + EXTRA_TABS:
                self.query_one(f"#table-{tab}", DataTable).clear(columns=True)
            self.query_one(Dashboard).clear()
        tabs = self.query_one("#main-tabs", TabbedContent)
        if tabs.active not in self.allowed_tabs:
            tabs.active = "settings"
        for tab, _ in TABS:
            if tab in self.allowed_tabs:
                tabs.show_tab(tab)
            else:
                tabs.hide_tab(tab)
        self.refresh_bindings()
        self.update_key_hints()
        self.update_action_buttons()

    @published(lambda self: self.safe_message_guard())
    def update_action_buttons(self):
        if not self.query(Button):
            return
        selected = self.active in {"people", "budgets"} and bool(self.selected())
        can_usd = enabled(self.feature_caps, "usd_budgets", "write")
        can_add = self.check_action("add_developer", ())
        for button in self.query(Button):
            if button.id == "action-add-person":
                button.disabled = not can_add
                button.tooltip = (self.membership_unavailable_text() if self.config.backend == "aum-service" else
                                  "" if can_add else "Only owners can add people to teams.")
            elif button.id == "action-set-budget":
                button.disabled = not selected or not self.check_action("edit", ())
                button.tooltip = "" if selected else "Select a person or scope first."
            elif button.id == "action-set-usd-budget":
                button.disabled = not selected or not self.check_action("usd_edit", ())
                button.tooltip = "" if can_usd else self.usd_unavailable_text()
            elif button.id == "action-chargeback":
                button.disabled = not self.check_action("export", ())

    async def load_tab(self, tab):
        read = self.engine.read
        if tab in {"ask", "approvals", "advanced"}:
            return await self.load_feature_tab(tab)
        if tab == "overview":
            return await self.load_overview()
        if tab == "budgets":
            budgets, catalog = await asyncio.gather(asyncio.to_thread(read, "budgets"), asyncio.to_thread(read, "catalog"))
            modes = {row["id"]: enforcement_badge(row) for key in ("organizations", "departments") for row in catalog[key]}
            rows = budgets["items"]
            if self.budget_parent:
                rows = [row for row in rows if row["scope_id"] == self.budget_parent or row.get("parent_scope_id") == self.budget_parent]
            return dict(budgets, items=rows, enforcement_modes=modes)
        if tab == "people":
            catalog = await asyncio.to_thread(read, "catalog")
            select = self.query_one("#people-team", Select)
            departments = catalog.get("departments", [])
            if self.config.backend == "aum-service":
                departments = [dict(id="__authorized__", name="All authorized observed people")] + departments + [dict(row, name=row["name"] + " (unit, including teams)")
                    for row in catalog.get("organizations", []) if not row.get("scope_context")]
            labels = self.present(departments)
            if self.team not in {row["id"] for row in departments}:
                self.team = ""
            if not self.team and departments:
                self.team = departments[0]["id"]
            with guarded_publish(self.current_guard()), select.prevent(Select.Changed):
                select.set_options([(label["name"], row["id"]) for row, label in zip(departments, labels)])
                if self.team:
                    select.value = self.team
            if self.team:
                paging = {"cursor": self.people_cursor} if enabled(self.feature_caps, "people_cursor") else {"offset": self.people_offset}
                return await asyncio.to_thread(read, "people", **self.engine.backend.people_filter(self.team),
                                                query=self.people_query, limit=50, **paging)
            return dict(items=[], note="No teams in your scope. Ask an Owner to check the catalog.")
        if tab == "governance":
            return await asyncio.to_thread(self.engine.governance)
        if tab == "usage":
            basis = {"basis": self.usage_basis} if self.engine.backend.name == "Direct" else {}
            return await asyncio.to_thread(read, "distribution", dimension=self.dimension, limit=100, **basis, **(self.scope_filters | self.request_filters))
        if tab == "trends":
            if self.compare_period:
                return await asyncio.to_thread(self.engine.compare_trends, self.compare_period,
                                               interval=self.interval, group_by="none", **self.scope_filters)
            return await asyncio.to_thread(read, "trends", interval=self.interval, group_by="none", **self.scope_filters)
        if tab == "requests":
            if enabled(self.feature_caps, "request_cursor"):
                data = await asyncio.to_thread(read, "requests", limit=50, cursor=self.request_cursor,
                                               before=self.request_before or None, **(self.scope_filters | self.request_filters))
                return dict(data, all_items=data.get("items", []),
                            note=f"Server cursor page {len(self.cursor_stack) + 1}; tied timestamps are retained by the server.")
            data = await asyncio.to_thread(read, "requests", limit=200, before=self.request_before or None,
                                           **(self.scope_filters | self.request_filters))
            data["all_items"] = data.get("items", [])
            data["items"] = data["all_items"][self.request_page * 50:(self.request_page + 1) * 50]
            data["note"] = f"Page {self.request_page + 1} | newest {len(data['all_items'])} in window (server cap 200). Set Before for older."
            return data
        if tab == "anomalies":
            return await asyncio.to_thread(read, "anomalies", limit=100, **self.scope_filters)
        return dict(connection=self.connection_label(), backend=self.engine.backend.name, month=self.engine.month,
                    **self.identity,
                    **({"access_note": "Direct: Azure RBAC administrator access, not unit-scoped.\nManagers/viewers: AUM service or Turnstile.",
                        "governance_authority": self.feature_caps.get("authority", "Gateway")}
                       if self.config.backend == "direct" else {"access_note": "AUM service enforces its own app roles and scoped authority; no Turnstile dependency."}
                       if self.config.backend == "aum-service" else {}),
                    url="(not used by Direct)" if self.config.backend == "direct" else self.config.url or "(not used)",
                    config="~/.aum/config.json (legacy config supported)",
                    theme=self.theme, ascii=self.config.ascii,
                    sign_in="az login", sign_out="az logout (outside this app)",
                    accessibility="--plain, --no-color, --ascii; Tab/Shift+Tab; all states have words")

    def render_tab(self, tab, data):
        previous = self._data_guards.get(tab)
        if previous is not None and previous[0] is not data:
            return
        guard = previous[1] if previous is not None else self.current_guard()
        try:
            with guarded_publish(guard, on_rejected=lambda error: self._show_read_error(tab, error)):
                self._render_tab(tab, data)
        except FinOpsError as error:
            self._show_read_error(tab, error)

    @published(lambda self, tab, data: self.cached_guard(tab) if tab in self._data_guards else self.current_guard())
    def _render_tab(self, tab, data):
        utc = self.engine.backend.name == "Example"
        if tab == "settings":
            self.query_one("#settings-connection", Static).update(
                safe_text(self.present(data).get("connection", "Connection details unavailable; refresh Settings.")))
        _, _, records, _ = view_rows(tab, data, ascii_only=self.config.ascii, utc=utc)
        columns, rows, _, note = view_rows(tab, self.present(data), ascii_only=self.config.ascii, utc=utc)
        query = self.filters.get(tab, "")
        if tab == "overview":
            self.query_one(Dashboard).update_data(self.present(data), data, query)
            generated = data.get("overview", {}).get("generated_at")
            note = f"Source as of {generated or 'unknown'} | UTC month | Enter panel: exact facts; estimates are not invoices."
        elif query:
            matches = [(row, record) for row, record in zip(rows, records) if query.casefold() in " ".join(map(str, row)).casefold()]
            rows, records = [row for row, _ in matches], [record for _, record in matches]
            label = "Filter applied" if self.redactor.enabled else f"Filter: {query}"
            note = f"{label} | {len(rows)} visible matches | Esc clears"
        if tab == "people" and self.people_query and not data.get("items"):
            if self.check_action("add_developer", ()) and "@" in self.people_query and self.team:
                note = f"No matching person in this team. Add {safe_text(self.people_query)} to {safe_text(self.team)}."
            else:
                note = "No matching person in this team. Owners can add people after a directory search."
        if tab in {"people", "budgets"} and not enabled(self.feature_caps, "usd_budgets", "write"):
            note = (self.usd_unavailable_text() + " " + note if tab == "budgets" else
                    (note + " " if note else "") + self.usd_unavailable_text())
        if tab in {"people", "budgets"} and self.config.backend == "aum-service":
            note = self.membership_unavailable_text() + " " + note
        self.records[tab] = records
        table = self.query_one(f"#table-{tab}", DataTable)
        table.clear(columns=True)
        table.add_columns(*columns)
        for row in rows:
            table.add_row(*(Text(safe_text(cell)) for cell in row))
        self.query_one(f"#note-{tab}", Static).update(safe_text(note))
        if self.pending_selection:
            for index, row in enumerate(records):
                if row.get("scope_id", row.get("id")) == self.pending_selection:
                    table.move_cursor(row=index)
                    break
            self.pending_selection = None
        self.update_action_buttons()

    def connection_kind(self):
        return {"direct": "Direct", "aum-service": "AUM service", "turnstile": "Turnstile",
                "fake": "Example"}[self.config.backend]

    def connection_label(self):
        address = self.config.url or "not configured"
        if self.config.backend == "direct":
            address = (f"APIM {self.config.apim_name}; resource group {self.config.resource_group}; "
                       f"subscription {self.config.subscription}" if self.config.apim_name
                       else "Azure CLI; gateway discovered from the selected profile")
        return f"via {self.connection_kind()}: {address}"

    @staticmethod
    def usd_unavailable_text():
        return "USD budget writes need Direct or the AUM service. P81 brings USD to Turnstile."

    @staticmethod
    def membership_unavailable_text():
        return "Add person unavailable on AUM service: no membership writer."

    @on(Button.Pressed)
    def extra_button(self, event):
        actions = {
            "action-add-person": self.action_add_developer,
            "action-set-budget": self.action_edit,
            "action-set-usd-budget": self.action_usd_edit,
            "action-chargeback": self.action_chargeback,
        }
        if event.button.id in actions:
            actions[event.button.id]()
            event.stop()
            return
        if self.feature_button(event.button.id):
            event.stop()

    @on(Select.Changed, "#approval-view")
    @on(Select.Changed, "#advanced-view")
    def extra_select(self, event):
        self.feature_select(event)

    @on(Input.Submitted, "#ask-question")
    def ask_submitted(self):
        self.run_worker(self.ask_current(), group="ask", exclusive=True)

    @on(DataTable.RowHighlighted)
    def exact_on_focus(self, event):
        self._synchronize_principal()
        if len(self.screen_stack) != 1 or not event.data_table.display or event.data_table.id != f"table-{self.active}":
            return
        row = self.selected()
        if not row and self.active not in self.data:
            return
        try:
            with guarded_publish(self.cached_guard(), on_rejected=lambda error: self._show_read_error(self.active, error)):
                self._publish_highlight(row)
        except FinOpsError:
            return

    @published(lambda self, row: self.cached_guard())
    def _publish_highlight(self, row):
        key = row.get("scope_id", row.get("request_id", row.get("id", "")))
        parent = row.get("parent_scope_id")
        path = f"AUM / {self.active}" + (f" / {parent}" if parent else "") + (f" / {key}" if key else "")
        values = {k: v for k, v in row.items() if k in {"used_tokens", "token_limit", "remaining_tokens", "total_tokens", "estimated_cost"}}
        prefix = "[redacted/read-only] " if self.redactor.enabled else ""
        self.query_one("#status", Static).update(self.redactor.text(prefix + path + "\n" + ", ".join(f"{k}={v}" for k, v in values.items())))
        self.refresh_bindings()
        self.update_action_buttons()
        self.update_key_hints()

    @published(lambda self: self.current_guard())
    def action_filter(self):
        field = self.query_one("#quick-filter", Input)
        field.display = True
        field.value = self.filters.get(self.active, "")
        field.focus()

    @on(Input.Changed, "#quick-filter")
    def filter_changed(self, event):
        self.filters[self.active] = event.value[:200]
        if self.active in self.data:
            self.render_tab(self.active, self.data[self.active])

    @on(Input.Submitted, "#quick-filter")
    def filter_submitted(self):
        self.query_one("#quick-filter", Input).display = False
        self.query_one("#dash-kpis" if self.active == "overview" else f"#table-{self.active}").focus()

    def action_clear_filter(self):
        with guarded_publish(self.safe_message_guard()):
            self.query_one("#quick-filter", Input).value = ""
        self.query_one("#quick-filter", Input).display = False
        self.filters.pop(self.active, None)
        if self.breadcrumbs:
            tab, parent = self.breadcrumbs.pop()
            self.budget_parent = parent
            self.action_tab(tab)
            self.action_refresh()
            return
        if self.active in self.data:
            self.render_tab(self.active, self.data[self.active])
        self.query_one("#dash-kpis" if self.active == "overview" else f"#table-{self.active}").focus()

    @on(Input.Submitted, "#people-query")
    @on(Button.Pressed, "#find-people")
    def find_people(self):
        self.people_query = self.query_one("#people-query", Input).value[:200]
        self.reset_people_page()
        self.action_refresh()

    @on(Select.Changed, "#people-team")
    def team_changed(self, event):
        if event.value is not Select.BLANK and event.value != self.team:
            self.team = str(event.value)
            self.reset_people_page()
            self.action_refresh()

    @on(Select.Changed, "#dimension")
    def dimension_changed(self, event):
        if event.value is not Select.BLANK and event.value != self.dimension:
            self.dimension = str(event.value)
            self.action_refresh()

    @on(Select.Changed, "#interval")
    def interval_changed(self, event):
        if event.value is not Select.BLANK and event.value != self.interval:
            self.interval = str(event.value)
            self.action_refresh()

    @on(Select.Changed, "#theme-choice")
    def theme_changed(self, event):
        if event.value is not Select.BLANK:
            self.theme = str(event.value)

    @on(Button.Pressed, "#filter-requests")
    def filter_requests(self):
        self.request_filters = {"model_id": self.query_one("#request-model", Input).value or None}
        self.request_before = self.query_one("#request-before", Input).value
        self.reset_paging()
        self.action_refresh()

    def selected(self):
        self._synchronize_principal()
        table = self.query_one(f"#table-{self.active}", DataTable)
        rows = self.records.get(self.active, [])
        return rows[table.cursor_row] if rows and table.cursor_row < len(rows) else {}

    @on(DataTable.RowSelected)
    def show_detail(self, event):
        if len(self.screen_stack) != 1 or event.data_table.id != f"table-{self.active}":
            return
        row = self.selected()
        if row:
            if self.active == "budgets" and row.get("scope_type") == "organization" and not self.budget_parent:
                self.breadcrumbs.append(("budgets", None))
                self.budget_parent = row["scope_id"]
                self.action_refresh()
                return
            if self.active == "budgets" and row.get("scope_type") == "department":
                self.breadcrumbs.append(("budgets", self.budget_parent))
                self.team = row["scope_id"]
                self.action_tab("people")
                return
            self.open_detail(row)

    def action_exact_detail(self):
        row = self.selected()
        if row:
            self.open_detail(row)

    def open_detail(self, row, *, read_guard=None):
        tab = self.active
        cached = self._data_guards.get(tab)
        source_guard = read_guard if read_guard is not None else cached[1] if cached else None
        return self._open_detail(row, tab, source_guard)

    @work(exclusive=True, group="detail")
    async def _open_detail(self, row, tab, source_guard):
        try:
            with self.engine.backend.read_cycle():
                if source_guard:
                    with source_guard():
                        pass
                guard = source_guard
                if tab == "requests":
                    row = await asyncio.to_thread(self.engine.read, "request", request_id=row["request_id"])
                    guard = self.current_guard()
                elif tab == "people" and row.get("scope_id"):
                    row = await asyncio.to_thread(self.engine.person_detail, row["scope_id"], row["parent_scope_id"])
                    guard = self.current_guard()
                elif tab == "advanced" and self.advanced_view in {"releases", "subscriptions"}:
                    row = await asyncio.to_thread(self.engine.read, "release" if self.advanced_view == "releases" else "application", id=row["id"])
                    guard = self.current_guard()
                if guard is None:
                    raise FinOpsError("Current detail has no verified source. Refresh before opening it.", 3)
                with guarded_publish(guard):
                    self.push_screen(DetailScreen("Exact values | Esc returns", row, read_guard=guard))
        except FinOpsError as error:
            with guarded_publish(self.safe_message_guard()):
                self.query_one("#status", Static).update(str(error))

    def action_lookup(self):
        self.push_screen(LookupScreen())

    @published(lambda self, result, *, read_guard: read_guard)
    def open_lookup_result(self, result, *, read_guard):
        if result["kind"] == "team":
            self.team = result["id"]
        elif result["kind"] == "person":
            self.team = result.get("department_id") or self.team
            self.people_query = result["id"]
            self.query_one("#people-query", Input).value = result["id"]
        elif result["kind"] == "model":
            self.dimension = "model"
            self.query_one("#dimension", Select).value = "model"
            self.request_filters = {"model_id": result["id"]}
        self.pending_selection = result["id"]
        self.action_tab(result["tab"])
        if result["kind"] == "request":
            self.open_detail({"request_id": result["id"]})
        else:
            self.action_refresh()

    def action_month(self):
        self.push_screen(MonthScreen())

    def action_export(self):
        if self.check_action("export", ()):
            self.push_screen(ExportScreen())

    def action_chargeback(self):
        if self.check_action("export", ()):
            self.push_screen(ExportScreen(auto_export=True))

    def action_edit(self):
        if not self.check_action("edit", ()):
            return
        row = self.selected()
        if not row:
            return
        kind = "budget" if self.active in {"budgets", "people"} else ("tier" if row.get("kind") == "tier" else "catalog")
        self.open_cached_change(kind, row, rows=self.data.get("budgets", {}).get("items", []))

    def action_usd_edit(self):
        if not self.check_action("usd_edit", ()):
            return
        row = self.selected()
        if not row or self.active not in {"budgets", "people"}:
            return
        self.open_cached_change("usd_budget", row, rows=self.data.get("budgets", {}).get("items", []))

    def action_usd_reconcile(self):
        if enabled(self.feature_caps, "usd_budgets", "reconcile"):
            self.push_screen(ChangeScreen(self.engine, "usd_reconcile"))

    def action_remove(self):
        if not self.check_action("edit", ()):
            self.action_tab("budgets")
            return
        row = self.selected()
        if row.get("kind") == "tier":
            self.publish_notification("Tier removal is not supported by the gateway policy.", origin=self.safe_message_guard())
            return
        kind = "budget" if self.active in {"budgets", "people"} else "catalog"
        self.open_cached_change(kind, row, remove=True)

    def action_add(self):
        if self.editable:
            from .group_screens import GroupPicker
            self.push_screen(GroupPicker())

    def action_add_developer(self, prefill_user="", prefill_unit=""):
        if self.check_action("add_developer", ()):
            from .developer_screens import DeveloperPicker
            if self.active == "people":
                prefill_user = prefill_user or self.people_query
                prefill_unit = prefill_unit or self.team
            elif self.active == "budgets":
                prefill_unit = prefill_unit or self.selected().get("scope_id", "")
            self.push_screen(DeveloperPicker(prefill_user=prefill_user, prefill_unit=prefill_unit))

    def action_apply(self):
        if self.editable and not self.engine.backend.immediate_writes:
            self.push_screen(ChangeScreen(self.engine, "apply"))

    def action_next_page(self):
        if self.active == "approvals":
            return self.page_feature()
        if self.active == "people":
            if enabled(self.feature_caps, "people_cursor"):
                return self.page_people()
            data = self.data.get("people", {})
            if len(data.get("items", [])) < 50:
                return
            self.people_offset += 50
        elif self.active == "requests":
            if enabled(self.feature_caps, "request_cursor"):
                cursor = self.data.get("requests", {}).get("page", {}).get("next_cursor")
                if cursor:
                    self.cursor_stack.append(self.request_cursor)
                    self.request_cursor = cursor
                    self.action_refresh()
                return
            if (self.request_page + 1) * 50 >= len(self.data.get("requests", {}).get("all_items", [])):
                self.publish_notification("End of server window. Set Before to see older requests.", origin=self.cached_guard("requests"))
                return
            self.request_page += 1
        self.action_refresh()

    def action_previous_page(self):
        if self.active == "approvals":
            return self.page_feature(previous=True)
        if self.active == "people":
            if enabled(self.feature_caps, "people_cursor"):
                return self.page_people(previous=True)
            self.people_offset = max(0, self.people_offset - 50)
        elif self.active == "requests":
            if enabled(self.feature_caps, "request_cursor"):
                if self.cursor_stack:
                    self.request_cursor = self.cursor_stack.pop()
                    self.action_refresh()
                return
            self.request_page = max(0, self.request_page - 1)
        self.action_refresh()

    def action_help(self):
        keys = dict(tabs=", ".join(label for tab, label in TABS + EXTRA_TABS if tab in self.allowed_tabs),
                    navigation="Tab / Shift+Tab changes focus; arrows move; Enter opens exact values; Esc goes back.",
                    lookup="/ searches scopes, people, models and request:<id>; Ctrl+F filters rows; f sets server filters.",
                    commands=": opens the command palette; m changes month; r refreshes; q quits.",
                    current_view=self.active, role=self.identity.get("role", "unknown"),
                    pagination="n next / p previous; cursor pages when advertised, otherwise 200 requests per window.",
                    safety="Preview first, then Apply. Removing or lowering below usage requires the identifier.",
                    freshness="Header time is fetch time, not ingestion time. Request ledger can lag.",
                    limitations=("Person limits are gateway DAILY overrides; units/teams remain monthly."
                                 if self.engine.backend.person_budget_period == "day"
                                 else "Person monthly budgets are Turnstile records, not gateway quotas.") + " Cost is estimated, not an invoice.",
                    sign_in="Run az login for the selected backend. AADSTS50105: check that backend's existing app-role assignment.",
                    access="Direct is Azure RBAC admin access; optional servers enforce viewer/manager roles and writable scope.")
        keys["actions"] = ("g Add person to team (owners); e Set budget; "
                           "u Set USD budget (when permitted); x Chargeback report. "
                           "People and Budgets show the same actions. Settings: Change connection.")
        if self.config.backend == "aum-service":
            keys["actions"] = ("Add person to team unavailable; e Set budget; "
                               "u Set USD budget (when permitted); x Chargeback report. Settings: Change connection.")
            keys["membership_availability"] = self.membership_unavailable_text()
        if not enabled(self.feature_caps, "usd_budgets", "write"):
            keys["usd_availability"] = self.usd_unavailable_text()
        if self.editable:
            keys["owner_actions"] = "e edits selected row. Palette: add/remove scope, edit tiers, Apply now."
        self.push_screen(DetailScreen("AUM | tour and keys", keys))
