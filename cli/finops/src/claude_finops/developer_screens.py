import asyncio
from contextlib import contextmanager

from textual import on, work
from textual.containers import Horizontal, Vertical
from textual.screen import ModalScreen
from .publication_widgets import Button, DataTable, Input, Label, Select, Static

from .developer_actions import developer_change, developer_find
from .errors import FinOpsError
from .feature_screens import ActionForm
from .guarded_publication import guarded_publish, published, guarded_deferred


class DeveloperPicker(ModalScreen):
    BINDINGS = [("escape", "dismiss", "Back")]

    def __init__(self, prefill_user="", prefill_unit="", *, remove=False):
        super().__init__()
        self.prefill_user = prefill_user
        self.prefill_unit = prefill_unit
        self.removing = remove
        self.rows, self.cursor, self.search_text = [], None, ""
        self.debounce = None

    @published(lambda self: self.app.safe_message_guard())
    def compose(self):
        with Vertical(id="detail-dialog"):
            if self.removing:
                yield Label("Remove person from gateway teams and tiers", markup=False)
            else:
                yield Label("Add developer from Microsoft Entra directory", markup=False)
            yield Input(placeholder="Email, UPN or display name; Enter searches Graph", id="developer-search",
                        password=self.app.redactor.enabled)
            yield Static("Bounded delegated directory search. Preview before any group membership write.",
                         id="developer-status", markup=False)
            yield DataTable(id="developer-results", cursor_type="row", zebra_stripes=True)
            with Horizontal(classes="buttons"):
                yield Button("Back", id="developer-back")
                yield Button("Next page", id="developer-next", disabled=True)

    @published(lambda self: self.app.safe_message_guard())
    def on_mount(self):
        if self.prefill_user:
            self.query_one("#developer-search", Input).value = self.prefill_user

    @on(Input.Changed, "#developer-search")
    def changed(self):
        self.cursor = None
        if self.debounce:
            self.debounce.stop()
        value = self.query_one("#developer-search", Input).value
        if len(value.strip()) >= 3:
            self.debounce = self.set_timer(0.35, guarded_deferred(self.app.current_guard(), self.search))

    @on(Input.Submitted, "#developer-search")
    def search(self):
        if self.debounce:
            self.debounce.stop()
        self.search_text = self.query_one("#developer-search", Input).value
        self.cursor = None
        self.load_developers()

    @work(exclusive=True)
    async def load_developers(self):
        with guarded_publish(self.app.safe_message_guard()):
            self.query_one("#developer-status", Static).update("Searching Entra (estimate 3-10 s)...")
        try:
            with self.app.engine.backend.read_cycle():
                result = await asyncio.to_thread(developer_find, self.app.engine, self.app.config, self.search_text, cursor=self.cursor)
                self.read_guard = self.app.current_guard()
                self.publish_developers(result)
        except FinOpsError as error:
            with guarded_publish(self.app.safe_message_guard()):
                self.query_one("#developer-status", Static).update(self.app.redactor.text(str(error)))

    @published(lambda self, result: self.read_guard)
    def publish_developers(self, result):
            self.rows, self.cursor = result["items"], result["next_cursor"]
            table = self.query_one("#developer-results", DataTable)
            table.clear(columns=True)
            table.add_columns("Name", "UPN/mail", "Type", "Tier", "Unit/team")
            for row in self.app.present(self.rows):
                table.add_row(row["display_name"], row["mail"] or row["user_principal_name"],
                              row.get("user_type", ""), row.get("current_tier", ""), row.get("current_unit", ""))
            self.query_one("#developer-next", Button).disabled = not self.cursor
            self.query_one("#developer-status", Static).update(f"{len(self.rows)} developers. Enter selects.")
            table.focus()

    @on(Button.Pressed, "#developer-next")
    def next_page(self):
        self.load_developers()

    @on(Button.Pressed, "#developer-back")
    def back(self):
        self.dismiss()

    @on(DataTable.RowSelected, "#developer-results")
    def select(self, event):
        event.stop()
        if event.cursor_row >= len(self.rows):
            return
        if self.removing:
            self.open_remove_form(self.rows[event.cursor_row], self.read_guard)
        else:
            self.open_add_form(self.rows[event.cursor_row], self.read_guard)

    def open_remove_form(self, row, directory_guard):
        app = self.app
        try:
            with directory_guard():
                pass
            if not app.check_action("remove_developer", ()):
                raise FinOpsError(app.membership_unavailable_text() if app.config.backend == "aum-service"
                                  else "Only owners can remove people from teams.", 4)

            def operation(values, apply):
                result = developer_change(app.engine, app.config, row["id"], remove=True,
                                          apply=apply, confirm=values["confirm"])
                result["before"] = {"id": result["developer"]["id"], "email": result["confirm_upn"]}
                result["after"] = {
                    "allow_lists": ["allow-standard", "allow-premium"],
                    "publication": ("Direct selected-scope membership refresh and tier allow-list sync"
                                    if app.engine.backend.name == "Direct" else
                                    "Turnstile delegated publish-as-admin"),
                }
                result["note"] = (
                    "Removes gateway access, not just the selected team. Every listed direct tier and "
                    "unit/team membership is removed if present; Entra groups are not deleted. "
                    "Direct permits an empty allow list only for a changed tier whose last member was removed. "
                    + result["token_note"])
                if apply:
                    result["message"] = (
                        f"Removed {result['confirm_upn']}. {result['publication_path']}. "
                        "Done refreshes People (estimate 3-10 s); observed usage can remain after removal.")
                return result

            with guarded_publish(directory_guard):
                app.switch_screen(ActionForm("Remove person from team", [
                    ("confirm", f"Type the resolved email/UPN: {row['user_principal_name']}", "", None),
                ], operation, read_guard=directory_guard))
        except FinOpsError as error:
            with guarded_publish(app.safe_message_guard()):
                self.query_one("#developer-status", Static).update(app._error_text(error))

    @work(exclusive=True, group="developer-catalog")
    async def open_add_form(self, row, directory_guard):
        try:
            with directory_guard():
                pass
            if not self.app.check_action("add_developer", ()):
                raise FinOpsError("Only owners can add people to teams.", 4)
            if "budgets" not in self.app.data:
                with guarded_publish(self.app.safe_message_guard()):
                    self.query_one("#developer-status", Static).update("Loading teams and units (estimate 3-10 s)...")
                with self.app.engine.backend.read_cycle():
                    catalog_guard = self.app.current_guard()
                    budgets = await asyncio.to_thread(self.app.engine.read, "budgets")
                    with guarded_publish(catalog_guard):
                        self.app.data["budgets"] = budgets
                        self.app._data_guards["budgets"] = (budgets, catalog_guard)
            else:
                budgets = self.app.data["budgets"]
                catalog_guard = self.app.cached_guard("budgets")

            @contextmanager
            def form_guard():
                with directory_guard(), catalog_guard():
                    yield

            units = [(item["scope_id"], item["scope_name"]) for item in budgets.get("items", [])
                     if item.get("scope_type") in {"organization", "department"}]
            default_unit = self.prefill_unit if self.prefill_unit in {unit for unit, _ in units} else ""
            fields = [
                ("user", "Resolved UPN or object id", row["user_principal_name"] or row["id"], None),
                ("tier", "Tier", "standard", [("standard", "standard"), ("premium", "premium")]),
                ("unit", "Unit/team id (blank for tier only)", default_unit, [("", "none"), *units]),
            ]

            def operation(values, apply):
                return developer_change(self.app.engine, self.app.config, values["user"], tier=values["tier"],
                                        unit=values["unit"] or None, apply=apply)

            with guarded_publish(form_guard):
                self.app.switch_screen(ActionForm("Add developer", fields, operation, read_guard=form_guard))
        except FinOpsError as error:
            with guarded_publish(self.app.safe_message_guard()):
                if self.query("#developer-status"):
                    self.query_one("#developer-status", Static).update(self.app._error_text(error))
                else:
                    self.app.notify(self.app._error_text(error), severity="error")
