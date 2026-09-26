import asyncio

from textual import on, work
from textual.containers import Horizontal, Vertical
from textual.screen import ModalScreen
from textual.widgets import Button, DataTable, Input, Label, Select, Static

from .developer_actions import developer_change, developer_find
from .errors import FinOpsError
from .feature_screens import ActionForm


class DeveloperPicker(ModalScreen):
    BINDINGS = [("escape", "dismiss", "Back")]

    def __init__(self):
        super().__init__()
        self.rows, self.cursor, self.search_text = [], None, ""
        self.debounce = None

    def compose(self):
        with Vertical(id="detail-dialog"):
            yield Label("Add developer from Microsoft Entra directory", markup=False)
            yield Input(placeholder="Email, UPN or display name; Enter searches Graph", id="developer-search",
                        password=self.app.redactor.enabled)
            yield Static("Bounded delegated directory search. Preview before any group membership write.",
                         id="developer-status", markup=False)
            yield DataTable(id="developer-results", cursor_type="row", zebra_stripes=True)
            with Horizontal(classes="buttons"):
                yield Button("Back", id="developer-back")
                yield Button("Next page", id="developer-next", disabled=True)

    @on(Input.Changed, "#developer-search")
    def changed(self):
        self.cursor = None
        if self.debounce:
            self.debounce.stop()
        value = self.query_one("#developer-search", Input).value
        if len(value.strip()) >= 3:
            self.debounce = self.set_timer(0.35, self.search)

    @on(Input.Submitted, "#developer-search")
    def search(self):
        self.search_text = self.query_one("#developer-search", Input).value
        self.cursor = None
        self.load_developers()

    @work(exclusive=True)
    async def load_developers(self):
        try:
            result = await asyncio.to_thread(developer_find, self.app.engine, self.app.config, self.search_text, cursor=self.cursor)
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
        except FinOpsError as error:
            self.query_one("#developer-status", Static).update(self.app.redactor.text(str(error)))

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
        row = self.rows[event.cursor_row]
        catalog = self.app.data.get("budgets", {}).get("items", [])
        units = [(item["scope_id"], item["scope_name"]) for item in catalog if item.get("scope_type") in {"organization", "department"}]
        fields = [
            ("user", "Resolved UPN or object id", row["user_principal_name"] or row["id"], None),
            ("tier", "Tier", "standard", [("standard", "standard"), ("premium", "premium")]),
            ("unit", "Unit/team id (blank for tier only)", "", [("", "none"), *units]),
        ]

        def operation(values, apply):
            return developer_change(self.app.engine, self.app.config, values["user"], tier=values["tier"],
                                    unit=values["unit"] or None, apply=apply)

        self.app.push_screen(ActionForm("Add developer", fields, operation))
