import asyncio
import json
from pathlib import Path
import re
from functools import partial

from textual import on, work
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.screen import ModalScreen
from textual.widgets import Button, DataTable, Input, Label, Select, Static, TextArea

from .errors import FinOpsError
from .output import chargeback_csv, safe_text
from .rules import allocation_left, apply_state, human, month_window, parse_tokens


class DetailScreen(ModalScreen):
    BINDINGS = [("escape", "dismiss", "Back")]

    def __init__(self, title, data):
        super().__init__()
        self.heading, self.data = title, data

    def compose(self):
        with Vertical(id="detail-dialog"):
            yield Label(self.heading, markup=False)
            yield TextArea(json.dumps(self.app.present(self.data), indent=2, ensure_ascii=True, default=str), read_only=True, id="detail-text")
            yield Button("Back (Esc)", id="close-detail")

    @on(Button.Pressed, "#close-detail")
    def close_detail(self):
        self.dismiss()


class MonthScreen(ModalScreen):
    BINDINGS = [("escape", "dismiss", "Cancel")]

    def compose(self):
        with Vertical(id="month-dialog"):
            yield Label("Choose month (YYYY-MM)")
            yield Input(self.app.engine.month, id="month-input")
            yield Static("", id="month-error", markup=False)
            with Horizontal(classes="buttons"):
                yield Button("Cancel", id="cancel-month")
                yield Button("Open month", id="set-month", variant="primary")

    @on(Button.Pressed, "#set-month")
    @on(Input.Submitted, "#month-input")
    def set_month(self):
        value = self.query_one(Input).value
        try:
            month_window(value)
        except FinOpsError as error:
            self.query_one("#month-error", Static).update(str(error))
            return
        self.app.engine.month = value
        self.dismiss()
        self.app.action_refresh()

    @on(Button.Pressed, "#cancel-month")
    def cancel(self):
        self.dismiss()


class LookupScreen(ModalScreen):
    BINDINGS = [("escape", "dismiss", "Back")]

    def compose(self):
        with Vertical(id="lookup-dialog"):
            yield Label("Find units, teams, models; people in the selected team", markup=False)
            yield Input(placeholder="Search; request:<id> for a request. Enter to search.", id="lookup-query")
            yield Static("People are searched on the server, never loaded in full.", id="lookup-status", markup=False)
            yield DataTable(id="lookup-results", cursor_type="row", zebra_stripes=True)

    @on(Input.Submitted, "#lookup-query")
    @work(exclusive=True)
    async def search(self):
        query = self.query_one(Input).value
        self.query_one("#lookup-status", Static).update("Searching...")
        try:
            self.results = await asyncio.to_thread(self.app.engine.lookup, query, self.app.team)
            table = self.query_one(DataTable)
            table.clear(columns=True)
            table.add_columns("Kind", "Identifier", "Name")
            for row in self.app.present(self.results):
                table.add_row(row["kind"], row["id"], row["name"])
            self.query_one("#lookup-status", Static).update(f"{len(self.results)} matches. Tab then Enter opens; Esc cancels.")
        except FinOpsError as error:
            self.query_one("#lookup-status", Static).update(str(error))

    @on(DataTable.RowSelected, "#lookup-results")
    def select_result(self, event):
        if not getattr(self, "results", []):
            return
        result = self.results[event.cursor_row]
        self.dismiss()
        self.app.open_lookup_result(result)


class ChangeScreen(ModalScreen):
    """All forms use the same preview invalidation and single-write workflow."""

    BINDINGS = [("escape", "cancel", "Cancel")]

    def __init__(self, engine, kind, row=None, rows=None, remove=False):
        super().__init__()
        self.engine, self.kind, self.row = engine, kind, row or {}
        self.rows, self.remove = rows or [], remove
        self.preview_plan = None
        self.applying = False
        self.saved = False

    def compose(self):
        title = ("Remove " if self.remove else "Edit ") + self.row.get("scope_id", self.row.get("id", self.kind))
        with Vertical(id="change-dialog"):
            yield Label(title, id="form-title", markup=False)
            with VerticalScroll(id="fields"):
                if self.kind == "budget" and not self.remove:
                    yield Label("Monthly tokens (1.5M or exact integer)")
                    yield Input(str(self.row.get("token_limit") or ""), id="amount")
                    yield Static("", id="headroom", markup=False)
                    yield Label("Warning threshold (%)")
                    yield Input(str(self.row.get("warning_threshold_percent", 80)), id="warning")
                elif self.kind == "tier" and not self.remove:
                    for key, label in (("tokens_per_minute", "Tokens per minute"), ("tokens_per_day", "Tokens per day")):
                        yield Label(label)
                        yield Input(str(self.row.get(key, "")), id=key.replace("_", "-"))
                    yield Label("Models (comma separated; empty means all)")
                    yield Input(",".join(self.row.get("models", [])), id="models")
                elif self.kind == "catalog" and not self.remove:
                    yield Select([("Unit", "unit"), ("Team", "team")], value=self.row.get("kind", "team"),
                                 id="scope-kind", allow_blank=False)
                    yield Input(self.row.get("id", ""), placeholder="Stable id, for example sales-emea", id="scope-id")
                    yield Input(self.row.get("name", ""), placeholder="Display name", id="scope-name")
                    yield Input((self.row.get("external_ref") or "").removeprefix("entra-group:"),
                                placeholder="Entra member group", id="scope-group")
                    yield Input(self.row.get("parent_id") or "", placeholder="Parent unit (teams only)", id="scope-parent")
                    yield Input(str(self.row.get("attributes", {}).get("manager_group_id", "")),
                                placeholder="Manager group's Entra object id; server decides scope", id="scope-manager")
                yield Input(placeholder="For removal / below-usage changes, type the identifier", id="confirm")
            yield Static("Review fields, Preview, then Apply. Nothing is written yet.", id="form-status", markup=False)
            with Horizontal(classes="buttons"):
                yield Button("Cancel", id="cancel-change")
                yield Button("Preview", id="preview", variant="default")
                yield Button("Apply", id="apply-change", variant="primary", disabled=True)

    def value(self, key, fallback=""):
        result = self.query(f"#{key}")
        return result.first(Input).value if result else fallback

    @on(Input.Changed)
    @on(Select.Changed)
    def invalidate(self):
        if self.applying or not self.is_mounted:
            return
        self.preview_plan = None
        self.query_one("#apply-change", Button).disabled = True
        if self.kind == "budget" and not self.remove:
            try:
                amount = parse_tokens(self.value("amount"))
                left = allocation_left(self.rows, self.row, amount)
                text = f"Parent unallocated after change: {human(left)} tokens."
            except FinOpsError as error:
                text = str(error)
            self.query_one("#headroom", Static).update(text)

    def operation(self, apply=False):
        confirm = self.value("confirm")
        if self.kind == "budget":
            try:
                warning = int(self.value("warning", "80"))
            except ValueError:
                raise FinOpsError("Warning threshold must be a whole percent.") from None
            return partial(self.engine.budget_change, self.row["scope_type"], self.row["scope_id"],
                           self.value("amount"), remove=self.remove, apply=apply, confirm=confirm, warning=warning,
                           department_id=self.row.get("parent_scope_id"))
        if self.kind == "tier":
            return partial(self.engine.tier_change, self.row["id"], self.value("tokens-per-minute"),
                           self.value("tokens-per-day"), self.value("models"), apply=apply)
        if self.kind == "catalog":
            kind = self.row.get("kind") if self.remove else self.query_one("#scope-kind", Select).value
            key = self.row.get("id") if self.remove else self.value("scope-id")
            return partial(self.engine.catalog_change, kind, key, name=self.value("scope-name"),
                           group=self.value("scope-group"), parent=self.value("scope-parent") or None,
                           manager_group=self.value("scope-manager") or None,
                           remove=self.remove, confirm=confirm, apply=apply)
        return partial(self.engine.apply, apply=apply)

    @on(Button.Pressed, "#preview")
    @work(exclusive=True, group="change")
    async def preview(self):
        self.query_one("#form-status", Static).update("Refreshing permissions and allocation...")
        try:
            self.preview_plan = await asyncio.to_thread(self.operation())
            if self.kind == "budget":
                plan = self.preview_plan
                summary = f"{human(plan['before'])} -> {human(plan['after'])}; parent free {human(plan['parent_headroom'])}."
            else:
                summary = self.preview_plan["action"]
            mode = " What-if: writes are disabled." if self.app.preview_only else " Preview ready. Apply commits; Esc cancels."
            self.query_one("#form-status", Static).update(summary + mode)
            self.query_one("#apply-change", Button).disabled = self.app.preview_only
        except FinOpsError as error:
            self.query_one("#form-status", Static).update(str(error))
            self.query_one("#apply-change", Button).disabled = True

    @on(Button.Pressed, "#apply-change")
    @work(exclusive=True, group="change")
    async def apply_change(self):
        if self.applying or not self.preview_plan or self.saved or self.app.preview_only:
            return
        self.applying = True
        self.query_one("#apply-change", Button).disabled = True
        self.query_one("#preview", Button).disabled = True
        self.query_one("#form-status", Static).update("Saving once. Do not close this terminal.")
        try:
            fresh = await asyncio.to_thread(self.operation())
            if any(fresh.get(key) != self.preview_plan.get(key) for key in ("before", "after", "parent_headroom")):
                raise FinOpsError("The server state changed since preview. Cancel, refresh and preview again.", 6)
            result = await asyncio.to_thread(self.operation(True))
            self.saved = True
            if self.kind == "budget" and self.row.get("scope_type") == "user":
                message = "Saved in Turnstile. Person budgets do not change gateway quotas."
            elif self.engine.backend.name == "Direct":
                message = "Gateway script completed; read-back verified. Refresh to inspect current values."
            else:
                self.query_one("#form-status", Static).update("Saved. Following gateway apply; usually about two minutes...")
                deadline = asyncio.get_running_loop().time() + 180
                while True:
                    status = await asyncio.to_thread(self.engine.read, "apply")
                    message = apply_state(status, result["requested_at"])
                    self.query_one("#form-status", Static).update(message)
                    if message.startswith(("Apply succeeded", "Failed", "Not configured", "Unknown")):
                        break
                    if asyncio.get_running_loop().time() >= deadline:
                        message = "Saved; still pending. Follow Governance. Do not repeat the save."
                        break
                    await asyncio.sleep(3)
            self.query_one("#form-status", Static).update(message)
            self.query_one("#cancel-change", Button).label = "Done"
        except FinOpsError as error:
            self.query_one("#form-status", Static).update(str(error) + " Refresh before retrying.")
        finally:
            self.applying = False

    @on(Button.Pressed, "#cancel-change")
    def action_cancel(self):
        if self.applying:
            self.query_one("#form-status", Static).update("A write is in progress. Wait for its result before closing.")
            return
        self.dismiss()
        self.app.action_refresh()


class ExportScreen(ModalScreen):
    BINDINGS = [("escape", "dismiss", "Back")]

    def compose(self):
        with Vertical(id="month-dialog"):
            yield Label("Export complete chargeback (managed scopes only)")
            yield Input(f"chargeback-{self.app.engine.month}.csv", id="export-name")
            yield Static("Saved under finops-reports in the current folder. Existing files are never overwritten.",
                         id="export-status", markup=False)
            with Horizontal(classes="buttons"):
                yield Button("Cancel", id="cancel-export")
                yield Button("Export CSV", id="export-csv", variant="primary")

    @on(Button.Pressed, "#export-csv")
    @work(exclusive=True, group="export")
    async def export(self):
        name = self.query_one("#export-name", Input).value
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,100}\.csv", name):
            self.query_one("#export-status", Static).update("Use a CSV filename, without directory separators.")
            return
        button = self.query_one("#export-csv", Button)
        button.disabled = True
        self.query_one("#export-status", Static).update("Reading every catalog scope, not just the top ranking...")
        try:
            result = await asyncio.to_thread(self.app.engine.chargeback)
            folder = Path.cwd() / "finops-reports"
            folder.mkdir(exist_ok=True)
            with (folder / name).open("x", encoding="utf-8", newline="") as output:
                output.write(chargeback_csv(self.app.present(result["items"]), self.app.engine.month))
            self.query_one("#export-status", Static).update(f"Exported {len(result['items'])} scopes to finops-reports\\{name}.")
        except (OSError, FinOpsError) as error:
            message = str(error) if isinstance(error, FinOpsError) else "Cannot create that file. Choose a new name and a writable current folder."
            self.query_one("#export-status", Static).update(message)
            button.disabled = False

    @on(Button.Pressed, "#cancel-export")
    def cancel(self):
        self.dismiss()
