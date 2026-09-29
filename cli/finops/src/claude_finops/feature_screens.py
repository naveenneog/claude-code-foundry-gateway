import asyncio
import json
from pathlib import Path

from textual import on, work
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.screen import ModalScreen
from .publication_widgets import Button, Input, Label, Select, Static

from .errors import FinOpsError
from .guarded_publication import guarded_publish, published


class FilterChips(Static, can_focus=True):
    BINDINGS = [("enter", "edit", "Edit filters")]

    def on_click(self):
        self.action_edit()

    def action_edit(self):
        self.app.action_scope_filters()


class QuitScreen(ModalScreen):
    BINDINGS = [("escape", "dismiss", "Stay"), ("q", "confirm", "Quit"), ("enter", "confirm", "Quit")]

    @published(lambda self: self.app.safe_message_guard())
    def compose(self):
        with Vertical(id="month-dialog"):
            yield Label("Quit AUM?", markup=False)
            yield Static(self.quit_message(), id="quit-message", markup=False)
            with Horizontal(classes="buttons"):
                yield Button("Quit", id="quit-confirm", variant="error", disabled=self.app.saving)
                yield Button("Stay", id="quit-stay")

    def quit_message(self):
        if self.app.saving:
            return "Saving; wait for the result (estimate 3-30 s; an asynchronous apply can take up to 3 minutes). Esc stays."
        return "Press q again or Enter to quit; Esc returns to the previous screen and its result."

    @published(lambda self: self.app.safe_message_guard())
    def refresh_saving(self):
        if self.query("#quit-confirm"):
            self.query_one("#quit-confirm", Button).disabled = self.app.saving
            self.query_one("#quit-message", Static).update(self.quit_message())

    @on(Button.Pressed, "#quit-confirm")
    def action_confirm(self):
        if self.app.saving:
            self.refresh_saving()
        else:
            self.app.exit()

    @on(Button.Pressed, "#quit-stay")
    def stay(self):
        self.dismiss()


class ActionForm(ModalScreen):
    BINDINGS = [("escape", "cancel", "Cancel")]

    def __init__(self, title, fields, operation, *, mutation=True, read_guard=None, local_write=False,
                 apply_label=None, commit_preview=False):
        super().__init__()
        self.heading, self.fields, self.operation = title, fields, operation
        self.mutation = mutation
        self.local_write = local_write
        self.apply_label = apply_label
        self.commit_preview = commit_preview
        self.read_guard = read_guard if read_guard is not None else self.app.current_guard()
        self.preview = None
        self.busy = False

    def compose(self):
        try:
            with guarded_publish(self.read_guard):
                yield from self.form_widgets()
        except FinOpsError as error:
            self.fields = []
            with guarded_publish(self.app.safe_message_guard()):
                with Vertical(id="change-dialog"):
                    yield Label("Action unavailable", markup=False)
                    yield Static(self.app._error_text(error), id="action-status", markup=False)
                    yield Button("Cancel", id="action-cancel")

    @published(lambda self: self.read_guard)
    def form_widgets(self):
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
            with VerticalScroll(id="action-feedback"):
                yield Static("Preview first. Nothing has been changed.", id="action-status", markup=False)
            with Horizontal(classes="buttons"):
                yield Button("Cancel", id="action-cancel")
                yield Button("Preview", id="action-preview")
                yield Button(self.apply_label or ("Apply" if self.mutation else "Open"),
                             id="action-apply", disabled=True, variant="primary")

    def values(self):
        with self.read_guard():
            pass
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
        if self.busy:
            return
        try:
            if self.local_write:
                with guarded_publish(self.app.safe_message_guard()):
                    self.query_one("#action-status", Static).update("Preparing connection preview (estimate 3-30 s)...")
            else:
                with guarded_publish(self.app.safe_message_guard()):
                    self.query_one("#action-status", Static).update("Preparing preview (estimate 3-10 s)...")
            self.preview = await asyncio.to_thread(self.operation, self.values(), False)
            text = json.dumps(self.app.present({key: value for key, value in self.preview.items()
                              if key in {"action", "count", "before", "after", "changes", "note"}}),
                              indent=2, ensure_ascii=True)
            with guarded_publish(self.read_guard):
                self.query_one("#action-status", Static).update(text or "Preview ready.")
            self.query_one("#action-apply", Button).disabled = bool((self.mutation or self.local_write) and
                (self.app.preview_only or self.app.redactor.enabled))
        except (FinOpsError, ValueError, OSError) as error:
            with guarded_publish(self.app.safe_message_guard()):
                message = "Cannot read the local profile. Check its path and permissions." if isinstance(error, OSError) else str(error)
                self.query_one("#action-status", Static).update(self.app.redactor.text(message))

    @on(Button.Pressed, "#action-apply")
    @work(exclusive=True)
    async def apply_action(self):
        if self.preview is None or self.busy or ((self.mutation or self.local_write) and
                                               (self.app.preview_only or self.app.redactor.enabled)):
            return
        self.busy = True
        reviewed_plan = self.preview
        operation = self.commit_action(reviewed_plan)
        if self.mutation or self.local_write:
            await self.app.run_mutation(operation)
        else:
            await operation

    async def commit_action(self, reviewed_plan):
        self.query_one("#action-apply", Button).disabled = True
        self.query_one("#action-preview", Button).disabled = True
        with guarded_publish(self.app.safe_message_guard()):
            self.query_one("#action-status", Static).update("Saving once (estimate 3-30 s)...")
        try:
            latest = await asyncio.to_thread(self.operation, self.values(), False)
            if any(latest.get(key) != reviewed_plan.get(key) for key in ("before", "after", "changes", "count")):
                if self.commit_preview and "profile_change" in reviewed_plan and "profile_change" in latest:
                    from .configure import profile_conflict
                    reviewed, current = reviewed_plan["profile_change"], latest["profile_change"]
                    if reviewed.revision != current.revision:
                        raise profile_conflict(reviewed.path, reviewed.revision, reviewed.before, current.before)
                raise FinOpsError("State changed since preview. Cancel and refresh.", 6)
            if latest.get("action") == "Bulk person budgets":
                from .bulk import apply_budget_plan
                result = dict(latest, preview=False, results=await asyncio.to_thread(apply_budget_plan, self.app.engine, latest))
            else:
                result = await asyncio.to_thread(self.operation, reviewed_plan if self.commit_preview else self.values(), True)
            if result.get("ui_action"):
                if result["ui_action"] == "profile":
                    await self.app.activate_profile(result["config"], profile=Path(result["profile"]),
                                                    revision=result["profile_revision"], reviewed=result["profile_change"])
                    return
                if result["ui_action"] == "signout":
                    with guarded_publish(self.app.safe_message_guard()):
                        self.query_one("#action-status", Static).update(
                            "Signed out. AUM exits after pending operations finish "
                            "(estimate 3-30 s; an asynchronous apply can take up to 3 minutes).")
                    return "signout"
                self.dismiss()
                if result["ui_action"] == "view":
                    self.app.restore_view(result["view"], read_guard=self.read_guard)
                elif result["ui_action"] == "compare":
                    self.app.set_comparison(result["month"])
                return
            state = result.get("message") or ("Saved." if self.mutation else "Opened.")
            if result.get("status_code"):
                state = json.dumps(self.app.present({key: result.get(key) for key in
                    ("status_code", "headers", "usage", "error", "seconds")}), ensure_ascii=True, indent=2)
            if result.get("requested_at") and not self.app.engine.backend.immediate_writes:
                with guarded_publish(self.app.safe_message_guard()):
                    self.query_one("#action-status", Static).update("Saved; following apply status...")
                outcome = await asyncio.to_thread(self.app.engine.wait_for_apply, result["requested_at"])
                state = outcome["state"]
            with guarded_publish(self.read_guard):
                self.query_one("#action-status", Static).update(self.app.redactor.text(state))
                self.query_one("#action-cancel", Button).label = "Done"
        except (FinOpsError, ValueError, OSError) as error:
            with guarded_publish(self.app.safe_message_guard()):
                message = "Cannot read the local profile. Check its path and permissions." if isinstance(error, OSError) else str(error)
                self.query_one("#action-status", Static).update(self.app.redactor.text(message))
        finally:
            self.busy = False
            if self.query("#action-preview"):
                self.query_one("#action-preview", Button).disabled = False

    @on(Button.Pressed, "#action-cancel")
    def action_cancel(self):
        if not self.busy:
            self.dismiss()
            self.app.action_refresh()


class FiltersScreen(ModalScreen):
    BINDINGS = [("escape", "dismiss", "Cancel")]

    @published(lambda self: self.app.current_guard())
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
            with guarded_publish(self.app.safe_message_guard()):
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

    @published(lambda self: self.app.safe_message_guard())
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
