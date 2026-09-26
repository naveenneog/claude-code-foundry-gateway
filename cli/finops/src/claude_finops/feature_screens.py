import asyncio
import json
from pathlib import Path

from textual import on, work
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.screen import ModalScreen
from textual.widgets import Button, Input, Label, Select, Static

from .errors import FinOpsError


class FilterChips(Static, can_focus=True):
    BINDINGS = [("enter", "edit", "Edit filters")]

    def on_click(self):
        self.action_edit()

    def action_edit(self):
        self.app.action_scope_filters()


class ActionForm(ModalScreen):
    BINDINGS = [("escape", "cancel", "Cancel")]

    def __init__(self, title, fields, operation, *, mutation=True):
        super().__init__()
        self.heading, self.fields, self.operation = title, fields, operation
        self.mutation = mutation
        self.preview = None
        self.busy = False

    def compose(self):
        if self.mutation and self.app.engine.backend.requires_reason and not any(name == "reason" for name, *_ in self.fields):
            self.fields = [*self.fields, ("reason", "Audit reason (required by AUM service)", self.app.engine.change_reason, None)]
        with Vertical(id="change-dialog"):
            yield Label(self.heading, markup=False)
            with VerticalScroll(id="fields"):
                for name, label, default, options in self.fields:
                    yield Label(label, markup=False)
                    if options:
                        yield Select([(label, value) for value, label in options], value=default,
                                     allow_blank=False, id=f"field-{name}")
                    else:
                        yield Input(str(default or ""), id=f"field-{name}", password=self.app.redactor.enabled)
            yield Static("Preview first. Nothing has been changed.", id="action-status", markup=False)
            with Horizontal(classes="buttons"):
                yield Button("Cancel", id="action-cancel")
                yield Button("Preview", id="action-preview")
                yield Button("Apply" if self.mutation else "Open", id="action-apply", disabled=True, variant="primary")

    def values(self):
        values = {name: self.query_one(f"#field-{name}").value for name, *_ in self.fields}
        if self.app.engine.backend.requires_reason and "reason" in values:
            self.app.engine.change_reason = values["reason"]
        return values

    @on(Input.Changed)
    @on(Select.Changed)
    def invalidate(self):
        if self.is_mounted and not self.busy:
            self.preview = None
            self.query_one("#action-apply", Button).disabled = True

    @on(Button.Pressed, "#action-preview")
    @work(exclusive=True)
    async def show_preview(self):
        try:
            self.preview = await asyncio.to_thread(self.operation, self.values(), False)
            text = json.dumps(self.app.present({key: value for key, value in self.preview.items()
                              if key in {"action", "count", "before", "after", "changes", "note"}}),
                              indent=2, ensure_ascii=True)
            self.query_one("#action-status", Static).update(text or "Preview ready.")
            self.query_one("#action-apply", Button).disabled = bool(self.mutation and
                (self.app.preview_only or self.app.redactor.enabled))
        except (FinOpsError, ValueError) as error:
            self.query_one("#action-status", Static).update(self.app.redactor.text(str(error)))

    @on(Button.Pressed, "#action-apply")
    @work(exclusive=True)
    async def apply_action(self):
        if self.preview is None or self.busy or (self.mutation and (self.app.preview_only or self.app.redactor.enabled)):
            return
        self.busy = True
        self.query_one("#action-apply", Button).disabled = True
        try:
            latest = await asyncio.to_thread(self.operation, self.values(), False)
            if any(latest.get(key) != self.preview.get(key) for key in ("before", "after", "changes", "count")):
                raise FinOpsError("State changed since preview. Cancel and refresh.", 6)
            if latest.get("action") == "Bulk person budgets":
                from .bulk import apply_budget_plan
                result = dict(latest, preview=False, results=await asyncio.to_thread(apply_budget_plan, self.app.engine, latest))
            else:
                result = await asyncio.to_thread(self.operation, self.values(), True)
            if result.get("ui_action"):
                self.dismiss()
                if result["ui_action"] == "view":
                    self.app.restore_view(result["view"])
                elif result["ui_action"] == "compare":
                    self.app.set_comparison(result["month"])
                elif result["ui_action"] == "profile":
                    self.app.run_worker(self.app.activate_profile(result["config"]), group="profile", exclusive=True)
                elif result["ui_action"] == "signout":
                    self.app.exit()
                return
            state = "Saved." if self.mutation else "Opened."
            if result.get("status_code"):
                state = json.dumps(self.app.present({key: result.get(key) for key in
                    ("status_code", "headers", "usage", "error", "seconds")}), ensure_ascii=True, indent=2)
            if result.get("requested_at") and not self.app.engine.backend.immediate_writes:
                self.query_one("#action-status", Static).update("Saved; following apply status...")
                outcome = await asyncio.to_thread(self.app.engine.wait_for_apply, result["requested_at"])
                state = outcome["state"]
            self.query_one("#action-status", Static).update(self.app.redactor.text(state))
            self.query_one("#action-cancel", Button).label = "Done"
        except (FinOpsError, ValueError) as error:
            self.query_one("#action-status", Static).update(self.app.redactor.text(str(error)))
        finally:
            self.busy = False

    @on(Button.Pressed, "#action-cancel")
    def action_cancel(self):
        if not self.busy:
            self.dismiss()
            self.app.action_refresh()


class FiltersScreen(ModalScreen):
    BINDINGS = [("escape", "dismiss", "Cancel")]

    def compose(self):
        with Vertical(id="change-dialog"):
            yield Label("Server filters — the server still enforces your scope")
            with VerticalScroll(id="fields"):
                for key, label in (("organization_id", "Unit"), ("department_id", "Team"),
                                   ("user_id", "Person id"), ("model_id", "Model id"),
                                   ("runtime", "Surface"), ("tier", "Tier"),
                                   ("from", "Range start ISO time + offset"), ("to", "Range end ISO time + offset")):
                    supported = self.app.feature_caps.get("features", {}).get("filter_fields")
                    if supported and key not in supported["actions"]:
                        continue
                    yield Label(label)
                    yield Input(str(self.app.scope_filters.get(key, "")), id=f"filter-{key.replace('_', '-')}",
                                password=self.app.redactor.enabled)
            yield Static("Blank removes a filter. No directory is downloaded.", id="filter-status", markup=False)
            with Horizontal(classes="buttons"):
                yield Button("Cancel", id="filter-cancel")
                yield Button("Apply filters", id="filter-save", variant="primary")

    @on(Button.Pressed, "#filter-save")
    def save_filters(self):
        values = {}
        for field in self.query(Input):
            key = field.id.removeprefix("filter-").replace("-", "_")
            if field.value.strip():
                values[key] = field.value.strip()
        from .rules import query_window
        try:
            query_window(self.app.engine.month, values.get("from"), values.get("to"))
        except FinOpsError as error:
            self.query_one("#filter-status", Static).update(str(error))
            return
        self.app.scope_filters = values
        self.app.request_page = self.app.people_offset = 0
        self.app.request_cursor = None
        self.app.cursor_stack = []
        self.app.update_filter_chips()
        self.dismiss()
        self.app.action_refresh()

    @on(Button.Pressed, "#filter-cancel")
    def cancel_filters(self):
        self.dismiss()


class TourScreen(ModalScreen):
    BINDINGS = [("escape", "finish", "Start")]

    def compose(self):
        with Vertical(id="detail-dialog"):
            yield Label("Welcome to AUM — one engine, terminal and commands")
            yield Static(
                "1-8 / 0 open views; 9 Approvals and a Ask appear only when permitted.\n\n"
                "Tab moves between panels. Enter opens exact values. Esc returns.\n\n"
                "/ finds units, teams, people, models and request ids. f edits server filters.\n"
                "Ctrl+F filters visible rows. : finds every permitted action by name.\n\n"
                "Budget edits preview first, check parent headroom and require Apply.\n"
                "Removing or lowering below spend requires the scope name.\n\n"
                "Settings switches profile/backend and explains sign-out.\n"
                "Use --plain or --screen-reader for linear output; ? shows current keys.",
                markup=False)
            yield Button("Start using AUM", id="tour-start", variant="primary")

    @on(Button.Pressed, "#tour-start")
    def action_finish(self):
        self.app.preferences.mark_toured()
        self.dismiss()
