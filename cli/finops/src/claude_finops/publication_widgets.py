"""Textual presentation sinks; framework input retains the widget's provenance."""

import asyncio
from collections.abc import Callable
from contextlib import AbstractContextManager, ExitStack, contextmanager
from dataclasses import dataclass, field
from functools import partial, wraps
import inspect

from textual import events
from textual._context import active_app
from textual.app import App as TextualApp
from textual.message import Message
from textual.reactive import await_watcher
from textual.notifications import Notification, Notify
from textual.strip import Strip
from textual.css.query import NoMatches
from textual.command import CommandInput, CommandList, CommandPalette, SearchIcon
from textual.widgets._footer import FooterKey, FooterLabel, KeyGroup
from textual.widgets._header import HeaderClock, HeaderClockSpace, HeaderIcon, HeaderTitle
from textual.widgets._select import SelectCurrent, SelectOverlay
from textual.widgets._tabbed_content import ContentTab, ContentTabs
from textual.widgets._tabs import Underline
from textual.widgets._toast import Toast as TextualToast, ToastHolder, ToastRack
from textual.widgets._tooltip import Tooltip
from textual.containers import (
    Container, HorizontalGroup,
    Horizontal as TextualHorizontal, Vertical as TextualVertical, VerticalScroll as TextualVerticalScroll,
)
from textual.screen import Screen, ModalScreen as TextualModalScreen
from textual.widget import Widget as TextualWidget
from textual.widgets import (
    Button as TextualButton, DataTable as TextualDataTable, Input as TextualInput,
    Label as TextualLabel, Select as TextualSelect, Static as TextualStatic,
    TabbedContent as TextualTabbedContent, TabPane as TextualTabPane, TextArea as TextualTextArea,
    ContentSwitcher, Footer, Header, LoadingIndicator, OptionList, Tab, Tabs,
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
    (CommandPalette, "_input"), (CommandPalette, "_select_command"),
    (CommandPalette, "_select_or_command"),
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


@dataclass(slots=True, repr=False, eq=False, init=False)
class _PayloadFreeRepresentation:

    def __repr__(self):
        return f"{type(self).__name__}(payload=<omitted>)"

    def __rich_repr__(self):
        yield "payload", "<omitted>"


_MESSAGE_TYPES = {}


def _seal_message(message):
    if not isinstance(message, Message) or isinstance(message, _PayloadFreeRepresentation):
        return
    original = type(message)
    protected = _MESSAGE_TYPES.get(original)
    if protected is None:
        protected = type(original.__name__, (_PayloadFreeRepresentation, original), {
            "__slots__": (), "__module__": original.__module__, "__qualname__": original.__qualname__,
        }, bubble=original.bubble, verbose=original.verbose, no_dispatch=original.no_dispatch)
        protected.handler_name = original.handler_name
        _MESSAGE_TYPES[original] = protected
    message.__class__ = protected


@dataclass(kw_only=True, repr=False)
class _OriginNotification(_PayloadFreeRepresentation, Notification):
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


def _retained_framework_watcher(owner, callback):
    if not (isinstance(callback, partial) and callback.func is await_watcher
            and callback.args and callback.args[0] is owner):
        return callback
    origin = (publication_origin() if publication_active() else owner._publication_origin
              if isinstance(owner, PublicationWidget) else owner.safe_message_guard())
    return _RetainedWatcher(owner, callback, origin)


class _RetainedWatcher(_PayloadFreeRepresentation):
    def __init__(self, owner, callback, origin):
        self.owner, self.callback, self.origin = owner, callback, origin

    async def __call__(self):
        try:
            await guarded_deferred(self.origin, self.callback)()
        except FinOpsError as error:
            self.owner._publication_rejected(error)
        finally:
            self.close()

    def close(self):
        pending = self.callback.args[1]
        if inspect.iscoroutine(pending) and not pending.cr_running:
            pending.close()

    def __del__(self):
        self.close()


class PublicationDispatch:
    def call_next(self, callback, *args, **kwargs):
        return super().call_next(_retained_framework_watcher(self, callback), *args, **kwargs)

    def post_message(self, message):
        _seal_message(message)
        return super().post_message(message)

    async def _dispatch_message(self, message):
        _seal_message(message)
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
        if name in {"content", "value", "text", "label", "border_title", "border_subtitle",
                    "placeholder", "tooltip", "title", "sub_title", "icon", "time_format",
                    "key_display", "description"}:
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

    def _cached_publication_rejected(self, error):
        if not getattr(self, "_publication_render_refused", False):
            self._publication_render_refused = True
            self.app.publish_notification(
                "Read failed (exit 3): cached content expired. Refresh the current view.",
                origin=self.app.safe_message_guard(),
            )

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
            if ((cls, operation.__name__) in FRAMEWORK_INPUT_HANDLERS or
                    getattr(type(self), "_publication_native_type", None) is not None
                    and cls.__module__.startswith("textual.")
                    and operation.__name__ in {"_on_compose", "_on_mount", "on_mount"}):
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

    def get_child_by_type(self, expect_type):
        for child in self.children:
            actual = type(child)
            if actual is expect_type or getattr(actual, "_publication_native_type", None) is expect_type:
                return child
        raise NoMatches("No immediate child of the requested protected type.")


_NATIVE_TYPES = {}
_SUPPORTED_NATIVE_TYPES = {
    TextualWidget, TextualStatic, TextualLabel, TextualButton, TextualInput,
    TextualDataTable, TextualTextArea, TextualSelect, TextualTabbedContent, TextualTabPane,
    Container, HorizontalGroup, TextualHorizontal, TextualVertical, TextualVerticalScroll,
    Screen, ContentSwitcher, SelectCurrent, SelectOverlay, OptionList,
    Tab, Tabs, ContentTab, ContentTabs, Underline,
    Header, HeaderIcon, HeaderTitle, HeaderClock, HeaderClockSpace,
    Footer, FooterKey, FooterLabel, KeyGroup, ToastHolder, ToastRack, Tooltip,
    CommandPalette, CommandInput, CommandList, SearchIcon, LoadingIndicator,
}
_NATIVE_WRITES = {
    "update", "load_text", "edit", "add_row", "add_rows", "add_column", "add_columns",
    "update_cell", "update_cell_at", "set_options", "add_option", "add_options",
    "replace_option_prompt", "replace_option_prompt_at_index",
}


def _protect_native_widget(widget, origin):
    if isinstance(widget, PublicationWidget):
        return
    original = type(widget)
    if original not in _SUPPORTED_NATIVE_TYPES:
        raise FinOpsError("This native content widget is not supported by the publication boundary.", 3)
    protected = _NATIVE_TYPES.get(original)
    if protected is None:
        @publication_sink
        def initialize(owner, *args, **kwargs):
            owner._publication_origin = publication_origin()
            original.__init__(owner, *args, **kwargs)

        @publication_sink
        def set_presentation(owner, name, value):
            original.__setattr__(owner, name, value)
            owner._publication_origin = publication_origin()

        def render(owner):
            try:
                with guarded_publish(owner._publication_origin, on_rejected=owner._cached_publication_rejected):
                    owner._publication_render_refused = False
                    return original.render(owner)
            except FinOpsError:
                return ""

        def render_lines(owner, crop):
            try:
                with guarded_publish(owner._publication_origin, on_rejected=owner._cached_publication_rejected):
                    owner._publication_render_refused = False
                    return original.render_lines(owner, crop)
            except FinOpsError:
                return [Strip.blank(crop.width)] * crop.height

        def post_message(owner, message):
            _seal_message(message)
            return original.post_message(owner, message)

        def call_next(owner, callback, *args, **kwargs):
            return original.call_next(owner, _retained_framework_watcher(owner, callback), *args, **kwargs)

        def run_worker(owner, work, *args, **kwargs):
            if (original is CommandPalette and isinstance(work, partial)
                    and work.func is CommandPalette._gather_commands.__wrapped__
                    and work.args and work.args[0] is owner):
                origin = publication_origin() if publication_active() else owner._publication_origin
                work = guarded_deferred(origin, work)
                kwargs["description"] = "<guarded native command search>"
            return original.run_worker(owner, work, *args, **kwargs)

        async def dispatch(owner, message):
            _seal_message(message)
            try:
                await original._dispatch_message(owner, message)
            except Exception as error:
                if _publication_refusal(error) is None:
                    raise
                owner.app._handle_exception(error)

        def dispatch_methods(owner, method_name, message):
            for cls, operation in original._get_dispatch_methods(owner, method_name, message):
                if ((cls, operation.__name__) in FRAMEWORK_INPUT_HANDLERS or
                        cls.__module__.startswith("textual.")
                        and operation.__name__ in {"_on_compose", "_on_mount", "on_mount"}):
                    source = owner.input_origin() if isinstance(message, events.InputEvent) else owner._publication_origin
                    yield cls, owner._framework_callback(source, operation)
                else:
                    yield cls, operation

        members = {
            "__slots__": (), "__module__": __name__, "_publication_native_type": original,
            "__init__": initialize,
            "__setattr__": lambda owner, name, value: PublicationWidget.__setattr__(owner, name, value),
            "_set_presentation": set_presentation,
            "render": render,
            "render_lines": render_lines,
            "post_message": post_message,
            "call_next": call_next,
            "run_worker": run_worker,
            "_dispatch_message": dispatch,
            "_get_dispatch_methods": dispatch_methods,
            "get_child_by_type": PublicationWidget.get_child_by_type,
        }
        for name in _NATIVE_WRITES:
            operation = getattr(original, name, None)
            if callable(operation) and not inspect.iscoroutinefunction(operation):
                members[name] = widget_sink(operation)
        # Native-first inheritance preserves the layout required by __class__ assignment.
        protected = type(original.__name__, (original, PublicationWidget), members)
        _NATIVE_TYPES[original] = protected
    object.__setattr__(widget, "_publication_origin", origin)
    object.__setattr__(widget, "__class__", protected)


class PublicationApp(PublicationDispatch, TextualApp):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._publication_static_titles = True

    def __setattr__(self, name, value):
        if name in {"title", "sub_title"} and getattr(self, "_publication_static_titles", False):
            raise FinOpsError("Application titles are static; use guarded publication for data.", 3)
        super().__setattr__(name, value)

    def exit(self, result=None, return_code=0, message=None):
        if message is not None:
            raise FinOpsError("Exit text requires guarded publication before closing the terminal.", 3)
        return super().exit(result, return_code=return_code)

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
            origin = (publication_origin() if publication_active() else parent._publication_origin
                      if isinstance(parent, PublicationWidget) else self.safe_message_guard())
            pending, seen = list(widgets), set()
            while pending:
                widget = pending.pop()
                if id(widget) in seen:
                    continue
                seen.add(id(widget))
                if isinstance(widget, TextualWidget):
                    _protect_native_widget(widget, origin)
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
    @publication_sink
    def publication_scroll_home(self):
        with guarded_publish(self.input_origin()):
            super().scroll_home(animate=False, immediate=True)


class TabbedContent(PublicationWidget, TextualTabbedContent):
    pass


class TabPane(PublicationWidget, TextualTabPane):
    pass


class ModalScreen(PublicationWidget, TextualModalScreen):
    def __init__(self, *args, **kwargs):
        source = publication_origin() if publication_active() else self.app.safe_message_guard()
        with guarded_publish(source):
            super().__init__(*args, **kwargs)
