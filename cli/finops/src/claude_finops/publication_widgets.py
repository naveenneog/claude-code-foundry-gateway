"""Textual presentation sinks; framework input retains the widget's provenance."""

import asyncio
from collections.abc import Callable
from contextlib import AbstractContextManager, ExitStack, contextmanager
from dataclasses import dataclass, field
from functools import wraps
import inspect

from textual import events
from textual._context import active_app
from textual.app import App as TextualApp
from textual.notifications import Notification, Notify
from textual.strip import Strip
from textual.widgets._toast import Toast as TextualToast, ToastHolder, ToastRack
from textual.containers import (
    Horizontal as TextualHorizontal, Vertical as TextualVertical, VerticalScroll as TextualVerticalScroll,
)
from textual.screen import ModalScreen as TextualModalScreen
from textual.widget import Widget as TextualWidget
from textual.widgets import (
    Button as TextualButton, DataTable as TextualDataTable, Input as TextualInput,
    Label as TextualLabel, Select as TextualSelect, Static as TextualStatic,
    TabbedContent as TextualTabbedContent, TabPane as TextualTabPane, TextArea as TextualTextArea,
)

from .errors import FinOpsError
from .guarded_publication import (
    PublicationOrigin, guarded_deferred, guarded_publish, publication_active, publication_origin, publication_sink,
)

# Only these framework handlers copy keyboard/picker input into content. Layout,
# idle and application handlers do not acquire publication authority by dispatch.
FRAMEWORK_INPUT_HANDLERS = {
    (TextualInput, "_on_key"), (TextualInput, "_on_paste"),
    (TextualTextArea, "_on_key"), (TextualTextArea, "_on_paste"),
    (TextualSelect, "_on_mount"), (TextualSelect, "_update_selection"),
}


def _publication_refusal(error: BaseException | None) -> FinOpsError | None:
    seen = set()
    while isinstance(error, BaseException) and id(error) not in seen:
        if isinstance(error, FinOpsError):
            return error
        seen.add(id(error))
        error = error.__cause__ or error.__context__
    return None


@dataclass(frozen=True)
class _InputOrigin(PublicationOrigin):
    content_origin: Callable[[], AbstractContextManager]


@dataclass(kw_only=True)
class _OriginNotification(Notification):
    origin: Callable[[], AbstractContextManager] = field(repr=False, compare=False)


def widget_sink(operation):
    @publication_sink
    @wraps(operation)
    def write(widget, *args, **kwargs):
        source = publication_origin()
        result = operation(widget, *args, **kwargs)
        widget._publication_origin = source
        return result
    return write


class PublicationDispatch:
    async def _dispatch_message(self, message):
        try:
            await super()._dispatch_message(message)
        except Exception as error:
            if _publication_refusal(error) is None:
                raise
            self.app._handle_exception(error)


class PublicationWidget(PublicationDispatch):
    @publication_sink
    def __init__(self, *args, **kwargs):
        self._publication_origin = publication_origin()
        super().__init__(*args, **kwargs)

    def __setattr__(self, name, value):
        if name == "__class__":
            raise FinOpsError("Protected presentation widgets cannot change class.", 3)
        if name in {"content", "value", "text", "label", "border_title", "placeholder", "tooltip"}:
            self._set_presentation(name, value)
        else:
            super().__setattr__(name, value)

    @publication_sink
    def _set_presentation(self, name, value):
        super().__setattr__(name, value)
        if name in {"content", "value", "text", "label"}:
            self._publication_origin = publication_origin()

    def _publication_rejected(self, error):
        self.app._reject_publication(error)

    def input_origin(self):
        source = self._publication_origin
        if isinstance(source, _InputOrigin):
            source = source.content_origin
        current = self.app.current_guard()

        @contextmanager
        def guard():
            with source(), current():
                yield
        return _InputOrigin(guard, self._publication_rejected, source)

    def _get_dispatch_methods(self, method_name, message):
        for cls, operation in super()._get_dispatch_methods(method_name, message):
            if (cls, operation.__name__) in FRAMEWORK_INPUT_HANDLERS:
                source = self.input_origin() if isinstance(message, events.InputEvent) else self._publication_origin
                yield cls, self._framework_callback(source, operation)
            else:
                yield cls, operation

    def _framework_callback(self, source, operation):
        deferred = guarded_deferred(source, operation)
        if inspect.iscoroutinefunction(operation):
            @wraps(operation)
            async def run(*args, **kwargs):
                try:
                    return await deferred(*args, **kwargs)
                except FinOpsError as error:
                    self._publication_rejected(error)
            return run
        @wraps(operation)
        def run(*args, **kwargs):
            try:
                return deferred(*args, **kwargs)
            except FinOpsError as error:
                self._publication_rejected(error)
        return run


class PublicationApp(PublicationDispatch, TextualApp):
    def notify(self, message, **kwargs):
        raise FinOpsError("Notifications require publish_notification with the originating guard.", 3)

    def publish_notification(self, message, *, origin, title="", severity="information", timeout=None):
        with guarded_publish(origin):
            notification = _OriginNotification(
                message=message, title=title, severity=severity,
                timeout=self.NOTIFICATION_TIMEOUT if timeout is None else timeout,
                markup=False, origin=origin,
            )
            if not self.post_message(Notify(notification)):
                raise FinOpsError("The terminal is closing; the notification was not delivered.", 7)

    def _on_notify(self, event):
        event.stop()
        notification = event.notification
        if not isinstance(notification, _OriginNotification):
            raise FinOpsError("An unguarded notification was refused. Refresh the current view.", 3)
        with guarded_publish(notification.origin):
            self._notifications.add(notification)
            self._refresh_notifications()

    def _refresh_notifications(self):
        if self.is_running and not self._disable_notifications:
            self.call_later(self._deliver_notifications)

    def _deliver_notifications(self):
        if not self.screen_stack:
            return
        racks = self.screen.query(ToastRack)
        if not racks:
            return
        rack = racks.first()
        notifications = list(self._notifications)
        with ExitStack() as guards:
            for notification in notifications:
                if not isinstance(notification, _OriginNotification):
                    raise FinOpsError("An unguarded notification was refused. Refresh the current view.", 3)
                guards.enter_context(guarded_publish(notification.origin))
            current_ids = {rack._toast_id(notification) for notification in notifications}
            for holder in rack.query(ToastHolder):
                if holder.id not in current_ids:
                    holder.display = False
                    holder.remove()
            existing_ids = {holder.id for holder in rack.query(ToastHolder)}
            for notification in notifications:
                identity = rack._toast_id(notification)
                if identity not in existing_ids:
                    with guarded_publish(notification.origin):
                        rack.mount(ToastHolder(_PublicationToast(notification), id=identity))
            rack.display = bool(notifications)
            if notifications:
                rack.call_later(rack.scroll_end, animate=False, force=True)

    def clear_publication_notifications(self):
        self._notifications.clear()
        for screen in self.screen_stack:
            for holder in screen.query(ToastHolder):
                holder.display = False
                holder.remove()
        self._refresh_notifications()

    def _register(self, parent, *widgets, **kwargs):
        with ExitStack() as guards:
            pending, seen = list(widgets), set()
            while pending:
                widget = pending.pop()
                if id(widget) in seen:
                    continue
                seen.add(id(widget))
                if isinstance(widget, PublicationWidget):
                    guards.enter_context(guarded_publish(widget._publication_origin))
                if isinstance(widget, TextualWidget):
                    pending.extend(widget.children)
                    pending.extend(widget._pending_children)
            return super()._register(parent, *widgets, **kwargs)

    def _handle_exception(self, error: Exception) -> None:
        refusal = _publication_refusal(error)
        if refusal is not None:
            self._publication_rejected(refusal)
            return
        super()._handle_exception(error)

    async def _process_messages(self, *args, **kwargs):
        loop = asyncio.get_running_loop()
        previous = loop.get_exception_handler()

        def handle(loop, context):
            error = context.get("exception")
            if self.is_running and active_app.get(None) is self and _publication_refusal(error) is not None:
                self._handle_exception(error)
            elif previous is not None:
                previous(loop, context)
            else:
                loop.default_exception_handler(context)

        loop.set_exception_handler(handle)
        try:
            return await super()._process_messages(*args, **kwargs)
        finally:
            if loop.get_exception_handler() is handle:
                loop.set_exception_handler(previous)

    @publication_sink
    def copy_to_clipboard(self, text):
        return super().copy_to_clipboard(text)

    @publication_sink
    def open_url(self, url, *, new_tab=True):
        return super().open_url(url, new_tab=new_tab)

    def _publication_rejected(self, error):
        self._reject_publication(error)

    async def _dispatch_action(self, namespace, action_name, params):
        if isinstance(namespace, PublicationWidget):
            for cls in type(namespace).__mro__:
                method = cls.__dict__.get("action_" + action_name)
                if method is not None:
                    if cls.__module__.startswith("textual.widgets."):
                        callback = namespace._framework_callback(namespace.input_origin(), method.__get__(namespace, cls))
                        result = callback(*params)
                        if inspect.isawaitable(result):
                            await result
                        return True
                    break
        return await super()._dispatch_action(namespace, action_name, params)


class _PublicationToast(PublicationWidget, TextualToast):
    def _discard(self, error):
        self.display = False
        self.app._handle_exception(error)

    def render(self):
        try:
            with guarded_publish(self._publication_origin):
                return super().render()
        except FinOpsError as error:
            self._discard(error)
            return ""

    def render_lines(self, crop):
        try:
            with guarded_publish(self._publication_origin):
                return super().render_lines(crop)
        except FinOpsError as error:
            self._discard(error)
            return [Strip.blank(crop.width)] * crop.height


class Static(PublicationWidget, TextualStatic):
    update = widget_sink(TextualStatic.update)


class Label(PublicationWidget, TextualLabel):
    update = widget_sink(TextualLabel.update)


class Button(PublicationWidget, TextualButton):
    pass


class Input(PublicationWidget, TextualInput):
    pass


class Select(PublicationWidget, TextualSelect):
    set_options = widget_sink(TextualSelect.set_options)


class TextArea(PublicationWidget, TextualTextArea):
    load_text = widget_sink(TextualTextArea.load_text)
    edit = widget_sink(TextualTextArea.edit)


class DataTable(PublicationWidget, TextualDataTable):
    add_row = widget_sink(TextualDataTable.add_row)
    add_column = widget_sink(TextualDataTable.add_column)
    update_cell = widget_sink(TextualDataTable.update_cell)
    update_cell_at = widget_sink(TextualDataTable.update_cell_at)


class Widget(PublicationWidget, TextualWidget):
    pass


class Horizontal(PublicationWidget, TextualHorizontal):
    pass


class Vertical(PublicationWidget, TextualVertical):
    pass


class VerticalScroll(PublicationWidget, TextualVerticalScroll):
    pass


class TabbedContent(PublicationWidget, TextualTabbedContent):
    pass


class TabPane(PublicationWidget, TextualTabPane):
    pass


class ModalScreen(PublicationWidget, TextualModalScreen):
    def __init__(self, *args, **kwargs):
        source = publication_origin() if publication_active() else self.app.safe_message_guard()
        with guarded_publish(source):
            super().__init__(*args, **kwargs)
