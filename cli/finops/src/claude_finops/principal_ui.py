"""Principal transitions invalidate all current presentation before input dispatch."""

from contextlib import contextmanager, nullcontext

from textual import events
from .publication_widgets import DataTable, Input, Select, Static, TextArea

from .dashboard import Dashboard
from .errors import FinOpsError
from .guarded_publication import guarded_publish, published, PublicationOrigin, guarded_deferred
from .screens import ChangeScreen


class PrincipalUI:
    def present(self, value):
        return self.redactor.present(value)

    def cached_guard(self, tab=None):
        cached = self._data_guards.get(tab or self.active)
        if cached is None:
            raise FinOpsError("Current data has no verified source. Refresh before using it.", 3)
        return cached[1]

    def open_cached_change(self, kind, row, *, rows=None, remove=False):
        try:
            guard = self.cached_guard()
            with guarded_publish(guard):
                self.push_screen(ChangeScreen(self.engine, kind, row, rows, remove=remove, read_guard=guard))
        except FinOpsError as error:
            self.publish_notification(self._error_text(error), origin=self.safe_message_guard(), severity="error")

    def _principal_verified(self, engine, identity, revision):
        if engine is self.engine and revision != self._principal_revision:
            self._pending_principal = (dict(identity), revision)
            if self.is_running:
                self.call_later(guarded_deferred(self.safe_message_guard(), self._synchronize_principal))

    def _bind_engine(self, engine):
        previous = getattr(self, "engine", None)
        if previous is not None and self._principal_verified in previous.identity_listeners:
            previous.identity_listeners.remove(self._principal_verified)
        self.engine = engine
        self._principal_revision = engine.identity_revision
        self._pending_principal = None
        engine.identity_listeners.append(self._principal_verified)

    def current_guard(self):
        engine, revision = self.engine, self.engine.identity_revision
        source = engine.backend.read_guard()
        @contextmanager
        def origin():
            with source():
                if engine is not self.engine or revision != engine.identity_revision:
                    raise FinOpsError("The sign-in changed. Previous UI data is no longer current.", 3)
                yield
        return PublicationOrigin(origin, self._reject_publication)

    def _reject_publication(self, error):
        if self.is_running and not self._clearing_principal:
            self._synchronize_principal()
            self._clear_principal_state(dict(self.engine._identity or self.identity))
            self._show_read_error(self.active, error)

    def _synchronize_principal(self):
        if self._clearing_principal or not self.is_running or not self.screen_stack or not self.query("#main-tabs"):
            return
        pending = self._pending_principal
        if pending is None and self.engine.identity_revision != self._principal_revision:
            pending = (dict(self.engine._identity or {}), self.engine.identity_revision)
        if pending is None:
            return
        identity, revision = pending
        self._pending_principal = None
        self._principal_revision = revision
        self._principal_notice = True
        self._clear_principal_state(identity)

    @published(lambda self, identity: self.safe_message_guard())
    def _clear_principal_state(self, identity):
        self._clearing_principal = True
        try:
            self.clear_publication_notifications()
            self._refresh_serial += 1
            self._waiting.clear()
            self.data.clear()
            self.records.clear()
            self._data_guards.clear()
            self.pending_selection = None
            self.feature_caps = {}
            self.preferences = None
            self.editable = False
            self.clear_query_context()
            for table in self.query(DataTable):
                table.clear(columns=True)
            for field in self.query(Input):
                field.value = ""
            for picker in self.query(Select):
                if picker.id in {"people-team", "lookup-team"}:
                    picker.set_options([])
                    picker.value = Select.BLANK
            for note in self.query(".context"):
                note.update("The sign-in changed. Previous data was cleared; refresh this view.")
            for text in self.query(TextArea):
                with guarded_publish(self.safe_message_guard()):
                    text.load_text("The sign-in changed. Previous data was cleared.")
            for screen in list(self.screen_stack)[1:]:
                for name, empty in (("data", {}), ("row", {}), ("rows", []), ("results", []),
                                    ("fields", []), ("preview", None), ("preview_plan", None)):
                    if hasattr(screen, name) and not callable(getattr(screen, name)):
                        setattr(screen, name, empty)
            while len(self.screen_stack) > 1:
                self.pop_screen()
            self.query_one(Dashboard).clear()
            self.update_access(identity)
            self.editable = False
            self._show_read_error(self.active, FinOpsError("The sign-in changed. Previous data was cleared; refresh for this identity.", 3))
            self.query_one("#status", Static).update("The sign-in changed. Previous data was cleared; r refreshes.")
        finally:
            self._clearing_principal = False

    async def on_event(self, event):
        self._synchronize_principal()
        if isinstance(event, events.InputEvent):
            self._principal_notice = False
        await super().on_event(event)

    @staticmethod
    def safe_message_guard():
        return nullcontext
