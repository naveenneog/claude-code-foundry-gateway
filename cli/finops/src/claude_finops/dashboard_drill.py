from textual import on
from textual.containers import Vertical
from textual.screen import ModalScreen
from textual.widgets import Button, DataTable, Label

from .screens import DetailScreen


class DashboardRows(ModalScreen):
    BINDINGS = [("escape", "dismiss", "Back"), ("d", "detail", "Exact row")]

    def __init__(self, panel):
        super().__init__()
        self.heading = str(panel.border_title)
        self.rows = []
        if panel.id == "dash-rank":
            distribution = panel.detail.get("units") or {}
            self.rows = [(distribution.get("dimension", "organization"), row)
                         for row in distribution.get("items", [])]
            if distribution.get("dimension") != "department":
                self.rows += [("department", row) for row in (panel.detail.get("teams") or {}).get("items", [])]
        elif panel.id == "dash-risks":
            budget = panel.detail
            self.rows = [("budget", row) for row in (budget.get("risk_items") or
                [row for row in budget.get("items", []) if row.get("status") in {"warning", "exceeded"}])]
        else:
            self.rows = [("anomaly", row) for row in panel.detail.get("items", [])]

    def compose(self):
        with Vertical(id="detail-dialog"):
            yield Label(self.heading + " | Enter opens row; d exact values; Esc back", markup=False)
            yield DataTable(id="dashboard-rows", cursor_type="row", zebra_stripes=True)
            yield Button("Back", id="dashboard-back")

    def on_mount(self):
        table = self.query_one(DataTable)
        table.add_columns("Kind", "Scope / finding", "Exact tokens", "Status")
        labels = {"organization": "Unit", "department": "Team", "user": "Person",
                  "runtime": "Surface", "project": "Tier"}
        for kind, raw in self.rows:
            row = self.app.present(raw)
            amount = row.get("total_tokens", row.get("used_tokens"))
            table.add_row(labels.get(kind, kind.title()),
                          str(row.get("name", row.get("scope_name", row.get("title", row.get("id", "Finding"))))),
                          f"{amount:,}" if isinstance(amount, (int, float)) else "Unknown",
                          str(row.get("status", row.get("severity", ""))))
        if not self.rows:
            table.add_row("No rows returned", "", "", "")
        table.focus()

    def selected(self):
        index = self.query_one(DataTable).cursor_row
        return self.rows[index] if index < len(self.rows) else None

    def action_detail(self):
        selected = self.selected()
        if selected:
            self.app.push_screen(DetailScreen("Exact source row", selected[1]))

    @on(Button.Pressed, "#dashboard-back")
    def back(self):
        self.dismiss()

    @on(DataTable.RowSelected, "#dashboard-rows")
    def open_row(self, event):
        event.stop()
        selected = self.selected()
        if not selected:
            return
        kind, row = selected
        scope = self.app.identity.get("manager_scope")
        if kind == "organization" and isinstance(scope, dict) and row["id"] not in {
                unit["id"] for unit in scope.get("organizations", [])}:
            self.app.push_screen(DetailScreen("Context parent — no unit-wide access", row))
            return
        self.dismiss()
        if kind == "budget":
            self.app.budget_parent = None
            self.app.pending_selection = row.get("scope_id")
            self.app.action_tab("budgets")
        elif kind == "anomaly":
            self.app.action_tab("anomalies")
            self.app.open_detail(row)
        else:
            field = {"organization": "organization_id", "department": "department_id", "user": "user_id",
                     "model": "model_id", "runtime": "runtime", "tier": "tier", "project": "tier"}[kind]
            value = row["id"].removeprefix("tier-") if field == "tier" else row["id"]
            self.app.scope_filters[field] = value
            self.app.reset_paging()
            self.app.update_filter_chips()
            self.app.action_tab("usage")
        self.app.action_refresh()
