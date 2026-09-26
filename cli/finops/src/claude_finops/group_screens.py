import asyncio

from textual import on, work
from textual.containers import Horizontal, Vertical
from textual.screen import ModalScreen
from textual.widgets import Button, DataTable, Input, Label, Static

from .errors import FinOpsError
from .feature_screens import ActionForm
from .group_actions import group_call, membership_refresh
from .screens import ChangeScreen


class GroupPicker(ModalScreen):
    BINDINGS = [("escape", "dismiss", "Back")]

    def __init__(self, scope_kind="team"):
        super().__init__()
        self.scope_kind = scope_kind
        self.rows, self.cursor, self.search_text = [], None, ""

    def compose(self):
        with Vertical(id="detail-dialog"):
            yield Label("Select or create the Entra group for this scope", markup=False)
            yield Input(placeholder="Group-name prefix; Enter searches Graph", id="group-search",
                        password=self.app.redactor.enabled)
            yield Static("Bounded server search. Existing groups retain their owners; new security groups belong to you.",
                         id="group-status", markup=False)
            yield DataTable(id="group-results", cursor_type="row", zebra_stripes=True)
            with Horizontal(classes="buttons"):
                yield Button("Back", id="group-back")
                yield Button("Next page", id="group-next", disabled=True)
                yield Button("Create new", id="group-create")

    @on(Input.Submitted, "#group-search")
    def search(self):
        self.search_text = self.query_one("#group-search", Input).value
        self.cursor = None
        self.load_groups()

    @work(exclusive=True)
    async def load_groups(self):
        try:
            result = await asyncio.to_thread(group_call, self.app.engine, "search", self.search_text, cursor=self.cursor)
            self.rows, self.cursor = result["items"], result["next_cursor"]
            table = self.query_one("#group-results", DataTable)
            table.clear(columns=True)
            table.add_columns("Group", "Security group", "Object id")
            for row in self.app.present(self.rows):
                table.add_row(row["displayName"], str(row.get("securityEnabled", False)), row["id"])
            self.query_one("#group-next", Button).disabled = not self.cursor
            self.query_one("#group-status", Static).update(f"{len(self.rows)} groups. Enter selects; existing ownership is unchanged.")
            table.focus()
        except FinOpsError as error:
            self.query_one("#group-status", Static).update(self.app.redactor.text(str(error)))

    @on(Button.Pressed, "#group-next")
    def next_page(self):
        self.load_groups()

    @on(Button.Pressed, "#group-back")
    def back(self):
        self.dismiss()

    @on(DataTable.RowSelected, "#group-results")
    def select(self, event):
        event.stop()
        if event.cursor_row >= len(self.rows):
            return
        group = self.rows[event.cursor_row]
        if not group.get("securityEnabled") or group.get("mailEnabled") or group.get("groupTypes"):
            self.query_one("#group-status", Static).update("Choose an assigned-membership, non-mail-enabled security group.")
            return
        self.dismiss()
        self.app.push_screen(ChangeScreen(self.app.engine, "catalog", row={
            "kind": self.scope_kind, "id": "", "name": group["displayName"], "external_ref": "entra-group:" + group["id"]}))

    @on(Button.Pressed, "#group-create")
    def create(self):
        def operation(values, apply):
            result = group_call(self.app.engine, "create", values["name"], values["description"],
                                apply=apply, confirm=values["confirm"])
            if not apply:
                result["after"] = {key: result[key] for key in ("name", "owner_id", "effect")}
            return result
        self.app.push_screen(ActionForm("Create group, owned by this sign-in", [
            ("name", "Security group name", "", None),
            ("description", "Description / purpose", "", None),
            ("confirm", "Type the full name to confirm creation", "", None)], operation))


def refresh_membership_form(app):
    row = app.selected()
    key = row.get("id", row.get("scope_id", ""))
    app.push_screen(ActionForm("Refresh selected Entra membership", [
        ("scopes", "Scope ids (comma-separated; include parent and team)", key, None),
        ("reassign", "Allow replacing an existing unit assignment", "no", [("no", "No"), ("yes", "Yes, reviewed")])],
        lambda values, apply: membership_refresh(app.engine, [v.strip() for v in values["scopes"].split(",") if v.strip()],
            apply=apply, allow_reassignment=values["reassign"] == "yes")))
