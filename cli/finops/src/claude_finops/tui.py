import asyncio
from datetime import datetime

from rich.text import Text
from textual import on, work
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal
from textual.theme import Theme
from textual.widgets import Button, DataTable, Input, Select, Static, TabbedContent, TabPane, TextArea

from .errors import FinOpsError
from .accessibility import AsciiFilter
from .brand import BANNER, COMPACT, PRODUCT
from .dashboard import Dashboard, DashboardPanel, enforcement_badge
from .output import safe_text
from .palette import FinOpsCommands
from .rules import can_edit, can_budget_write
from .redaction import Redactor
from .scope import scope_label, visible_tabs
from .screens import ChangeScreen, DetailScreen, ExportScreen, LookupScreen, MonthScreen
from .views import DIMENSIONS, TABS, view_rows
from .ui_features import FeatureUI, EXTRA_TABS
from .capabilities import enabled
from .feature_screens import FilterChips


class FinOpsApp(FeatureUI, App):
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
        Binding("ctrl+a", "apply", "Apply"),
        Binding("n", "next_page", "Next"),
        Binding("p", "previous_page", "Previous"),
        Binding("r", "refresh", "Refresh", show=False),
        Binding("question_mark", "help", "Help", key_display="?"),
        Binding("q", "quit", "Quit"),
    ]

    def __init__(self, engine, config, no_color=False, preview_only=False, redact=False, first_run=None):
        super().__init__()
        self.animation_level = "none"
        self.engine, self.config = engine, config
        self.preview_only = preview_only
        self.redactor = Redactor(redact)
        self.identity = {}
        self.editable = False
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

    def compose(self) -> ComposeResult:
        yield Static(COMPACT, id="brand", markup=False)
        yield Static("Signing in through Azure CLI...", id="identity", markup=False)
        yield FilterChips("", id="filter-chips", markup=False)
        yield Input(placeholder="Filter visible rows (Esc clears; / searches the server)", id="quick-filter",
                    password=self.redactor.enabled)
        with TabbedContent(initial="overview", id="main-tabs"):
            for tab, title in TABS + EXTRA_TABS:
                with TabPane(title, id=tab):
                    if tab in {"ask", "approvals", "advanced"}:
                        yield from self.compose_feature(tab)
                    if tab == "people":
                        with Horizontal(classes="toolbar"):
                            yield Select([], id="people-team", prompt="Choose a team")
                            yield Input(placeholder="Search people; Enter", id="people-query", password=self.redactor.enabled)
                            yield Button("Find", id="find-people")
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
                            yield Button("Profile / backend", id="settings-profile")
                            yield Button("Sign out", id="settings-signout")
                            yield Button("Tour", id="settings-tour")
                    yield Static("Loading...", id=f"note-{tab}", classes="context", markup=False)
                    if tab == "overview":
                        yield Dashboard(id="dashboard")
                    yield DataTable(id=f"table-{tab}", cursor_type="row", zebra_stripes=True,
                                    classes="all-metrics" if tab == "overview" else "titled-table")
        yield Static("1-8 / 0 tabs | Tab / Shift+Tab focus | Enter details | ? one-screen tour", id="status", markup=False)
        yield Static("", id="key-hints", markup=False)

    def on_mount(self):
        if self.config.ascii:
            self.add_class("ascii")
        for tab, label in TABS + EXTRA_TABS:
            self.query_one(f"#table-{tab}", DataTable).border_title = label if tab == "advanced" else label[2:]
        self.update_brand()
        self.update_key_hints()
        for tab, _ in EXTRA_TABS:
            self.query_one("#main-tabs").hide_tab(tab)

    def update_key_hints(self):
        if not self.query("#key-hints"):
            return
        keys = ["/ Find", ": Command", "f Filters", "m Month"]
        if self.check_action("edit", ()):
            keys.append("e Edit")
        if self.check_action("apply", ()):
            keys.append("Ctrl+A Apply")
        if self.check_action("next_page", ()):
            keys.append("n/p Page")
        keys.extend(["? Help", "q Quit"])
        self.query_one("#key-hints", Static).update("  ".join(f"<{key}>" for key in keys))

    def update_brand(self):
        if not self.query("#brand") or not self.query("#main-tabs"):
            return
        large = self.size.width >= 120 and self.size.height >= 38 and self.active == "overview"
        self.set_class(large, "wide-overview")
        heading = PRODUCT if large or self.config.ascii else COMPACT
        self.query_one("#brand", Static).update((BANNER + "\n" if large else "") + heading)

    def on_resize(self):
        self.update_brand()
        if self.data.get("overview"):
            self.call_after_refresh(self.render_tab, "overview", self.data["overview"])

    def get_line_filters(self):
        filters = list(super().get_line_filters())
        if getattr(self, "config", None) and self.config.ascii:
            filters.append(AsciiFilter())
        return filters

    def present(self, value):
        return self.redactor.present(value)

    @property
    def active(self):
        return self.query_one("#main-tabs", TabbedContent).active

    def check_action(self, action, parameters):
        if action == "tab":
            if len(self.screen_stack) > 1 or isinstance(self.focused, Input):
                return False
            if isinstance(self.focused, TextArea) and not self.focused.read_only:
                return False
            return bool(parameters) and parameters[0] in self.allowed_tabs
        if action == "export":
            return "overview" in self.allowed_tabs
        if action == "edit":
            if self.redactor.enabled:
                return False
            if "native_writes" in self.feature_caps.get("features", {}) and not enabled(self.feature_caps, "native_writes", "budget"):
                return False
            if self.active in {"budgets", "people"}:
                row = self.selected()
                if row.get("writable") is False:
                    return False
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

    @on(TabbedContent.TabActivated)
    def switched(self, event):
        self.update_brand()
        self.update_key_hints()
        self.query_one("#quick-filter", Input).display = False
        self.refresh_bindings()
        self.action_refresh()

    def update_access(self, identity):
        before = tuple(self.identity.get(key) for key in ("id", "email", "role", "manager_scope"))
        after = tuple(identity.get(key) for key in ("id", "email", "role", "manager_scope"))
        self.identity = identity
        if before == after:
            return
        self.editable = can_edit(identity) and not self.redactor.enabled
        self.allowed_tabs = visible_tabs(identity)
        if before != after:
            self.data.clear()
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

    @work(exclusive=True, group="view")
    async def action_refresh(self):
        tab = self.active
        self.query_one(f"#note-{tab}", Static).update("Loading current server data... (q still works)")
        try:
            identity = await asyncio.to_thread(self.engine.read, "whoami")
            self.update_access(identity)
            await self.refresh_features()
            if tab not in self.allowed_tabs:
                return
            data = await self.load_tab(tab)
            self.data[tab] = data
            self.render_tab(tab, data)
            stamp = "12:00 +00:00 example" if self.engine.backend.name == "Example" else datetime.now().astimezone().strftime("%H:%M:%S %z")
            display_identity = self.present(self.identity)
            who = display_identity.get("email", display_identity.get("name", "caller"))
            scope = scope_label(display_identity)
            prefix = f"{self.engine.month} | {self.engine.backend.name} | {self.identity.get('role', 'unknown')} | "
            suffix = f" | @ {stamp}"
            available = max(8, self.size.width - len(prefix) - len(suffix) - 2)
            if len(who) > available:
                who = who[:available - 3] + "..."
            identity = prefix + who + suffix
            if scope:
                identity += " | " + scope
            self.query_one("#identity", Static).update(safe_text(identity))
            mode = "[redacted/read-only] " if self.redactor.enabled else ""
            self.query_one("#status", Static).update(mode + "<Enter> details <Tab> panel </> lookup <r> refresh")
            if tab == "overview":
                self.query_one("#dash-kpis", DashboardPanel).focus()
            else:
                self.query_one(f"#table-{tab}", DataTable).focus()
            self.maybe_tour()
        except FinOpsError as error:
            self.data.pop(tab, None)
            self.records.pop(tab, None)
            self.query_one(f"#table-{tab}", DataTable).clear(columns=True)
            if tab == "overview":
                self.query_one(Dashboard).clear()
            self.query_one(f"#note-{tab}", Static).update(str(error))
            fix = "Check managed scope in Settings; r refreshes." if error.code == 4 else "r retries; ? explains sign-in."
            self.query_one("#status", Static).update(f"Read failed (exit {error.code}). {fix}")

    async def load_tab(self, tab):
        read = self.engine.read
        if tab in {"ask", "approvals", "advanced"}:
            return await self.load_feature_tab(tab)
        if tab == "overview":
            overview, budgets, ranking, teams, trends, anomalies, catalog = await asyncio.gather(
                asyncio.to_thread(read, "overview", **self.scope_filters), asyncio.to_thread(read, "budgets"),
                self.optional_dashboard_read("usage_breakdown", "distribution", dimension=self.ranking_dimension, limit=10, **self.scope_filters),
                self.optional_dashboard_read("usage_breakdown", "distribution", dimension="department", limit=10, **self.scope_filters),
                asyncio.to_thread(read, "trends", interval="day", group_by="none", **self.scope_filters),
                self.optional_dashboard_read("anomaly_findings", "anomalies", limit=10, **self.scope_filters),
                asyncio.to_thread(read, "catalog"))
            return dict(overview=overview, budgets=budgets, ranking=ranking, teams=teams,
                        trends=trends, anomalies=anomalies, catalog=catalog)
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
                departments = departments + [dict(row, name=row["name"] + " (unit, including teams)")
                    for row in catalog.get("organizations", []) if not row.get("scope_context")]
            labels = self.present(departments)
            select.set_options([(label["name"], row["id"]) for row, label in zip(departments, labels)])
            if self.team not in {row["id"] for row in departments}:
                self.team = ""
            if not self.team and departments:
                self.team = departments[0]["id"]
            if self.team:
                select.value = self.team
                paging = {"cursor": self.people_cursor} if enabled(self.feature_caps, "people_cursor") else {"offset": self.people_offset}
                return await asyncio.to_thread(read, "people", **self.engine.backend.people_filter(self.team),
                                                query=self.people_query, limit=50, **paging)
            return dict(items=[], note="No teams in your scope. Ask an Owner to check the catalog.")
        if tab == "governance":
            return await asyncio.to_thread(self.engine.governance)
        if tab == "usage":
            return await asyncio.to_thread(read, "distribution", dimension=self.dimension, limit=100, **(self.scope_filters | self.request_filters))
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
        return dict(**self.identity, backend=self.engine.backend.name, month=self.engine.month,
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
        utc = self.engine.backend.name == "Example"
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

    @on(Button.Pressed)
    def extra_button(self, event):
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
        if len(self.screen_stack) != 1 or not event.data_table.display or event.data_table.id != f"table-{self.active}":
            return
        row = self.selected()
        key = row.get("scope_id", row.get("request_id", row.get("id", "")))
        parent = row.get("parent_scope_id")
        path = f"AUM / {self.active}" + (f" / {parent}" if parent else "") + (f" / {key}" if key else "")
        values = {k: v for k, v in row.items() if k in {"used_tokens", "token_limit", "remaining_tokens", "total_tokens", "estimated_cost"}}
        prefix = "[redacted/read-only] " if self.redactor.enabled else ""
        self.query_one("#status", Static).update(self.redactor.text(prefix + path + "\n" + ", ".join(f"{k}={v}" for k, v in values.items())))

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
        table = self.query_one(f"#table-{self.active}", DataTable)
        rows = self.records.get(self.active, [])
        return rows[table.cursor_row] if rows and table.cursor_row < len(rows) else {}

    @on(DataTable.RowSelected)
    def show_detail(self, event):
        if len(self.screen_stack) != 1:
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

    @work(exclusive=True, group="detail")
    async def open_detail(self, row):
        try:
            if self.active == "requests":
                row = await asyncio.to_thread(self.engine.read, "request", request_id=row["request_id"])
            elif self.active == "people" and row.get("scope_id"):
                row = await asyncio.to_thread(self.engine.person_detail, row["scope_id"], row["parent_scope_id"])
            elif self.active == "advanced" and self.advanced_view in {"releases", "subscriptions"}:
                row = await asyncio.to_thread(self.engine.read, "release" if self.advanced_view == "releases" else "application", id=row["id"])
            self.push_screen(DetailScreen("Exact values | Esc returns", row))
        except FinOpsError as error:
            self.query_one("#status", Static).update(str(error))

    def action_lookup(self):
        self.push_screen(LookupScreen())

    def open_lookup_result(self, result):
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

    def action_edit(self):
        if not self.check_action("edit", ()):
            return
        row = self.selected()
        if not row:
            return
        kind = "budget" if self.active in {"budgets", "people"} else ("tier" if row.get("kind") == "tier" else "catalog")
        self.push_screen(ChangeScreen(self.engine, kind, row, self.data.get("budgets", {}).get("items", [])))

    def action_remove(self):
        if not self.check_action("edit", ()):
            self.action_tab("budgets")
            return
        row = self.selected()
        if row.get("kind") == "tier":
            self.notify("Tier removal is not supported by the gateway policy.")
            return
        kind = "budget" if self.active in {"budgets", "people"} else "catalog"
        self.push_screen(ChangeScreen(self.engine, kind, row, remove=True))

    def action_add(self):
        if self.editable:
            self.push_screen(ChangeScreen(self.engine, "catalog"))

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
                self.notify("End of server window. Set Before to see older requests.")
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
                    sign_in="Run az login. AADSTS50105: ask an admin to assign a Turnstile role.",
                    access="Viewers are read-only; managers edit only server-advertised writable budgets.")
        if self.editable:
            keys["owner_actions"] = "e edits selected row. Palette: add/remove scope, edit tiers, Apply now."
        self.push_screen(DetailScreen("AUM | tour and keys", keys))
