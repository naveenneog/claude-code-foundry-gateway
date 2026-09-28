"""Backend-derived presentation sinks must execute through guarded_publish."""

import ast
import hashlib
import json
from pathlib import Path
import pytest


ROOT = Path(__file__).resolve().parents[1] / "src" / "claude_finops"
UI_FILES = tuple(sorted(path.name for path in ROOT.glob("*.py") if path.name in {
    "cli.py", "commands_local.py", "output.py", "feature_engine.py", "publication_output.py",
} or any(isinstance(node, ast.ImportFrom) and (node.module or "").startswith("textual")
         for node in ast.walk(ast.parse(path.read_text(encoding="utf-8"))))))
SINKS = {"update", "load_text", "add_row", "set_options", "copy_to_clipboard",
         "open_url", "write", "write_text", "display", "render", "print", "echo", "ask",
         "write_export", "write_renderable", "copy_with_helper"}
VALUE_WIDGETS = {"Label", "Static", "TextArea", "Input", "Select"}
SINK_PROPERTIES = {"value", "text", "label", "border_title", "placeholder", "tooltip"}
SCHEDULERS = {"call_later", "call_after_refresh", "set_timer", "set_interval",
              "run_worker", "post_message", "create_task", "call_soon"}

# Exact (file, qualified function, normalized call) exceptions for static/local
# presentation only. Each entry needs its own factual reason, not a handler-wide exemption.
STATIC_WRITES = {
    # Exact static widget-property assignments: fixed headings, resets and enum choices.
    ("dashboard.py", "DashboardPanel.__init__", "self.border_title = title"): "Dashboard constructor headings come from fixed local panel definitions.",
    ("tui.py", "FinOpsApp.on_mount", "self.query_one(f'#table-{tab}', DataTable).border_title = label if tab == 'advanced' else label[2:]"): "Initial table headings come only from the fixed TABS/EXTRA_TABS vocabulary.",
    ("tui.py", "FinOpsApp.action_clear_filter", "self.query_one('#quick-filter', Input).value = ''"): "Explicit empty-string reset of the local filter input.",
    ("screens.py", "MonthScreen.set_month", "self.app.query_one('#request-before', Input).value = ''"): "Explicit empty-string reset when the operator changes month.",
    ("ui_features.py", "FeatureUI.action_request_time_usage", "self.query_one('#dimension', Select).value = 'department'"): "Fixed local dimension selection for the ledger usage action.",
    # Application shell: fixed labels/options and the local selected theme, never server facts.
    ("tui.py", "FinOpsApp.compose", "Static(COMPACT, id='brand', markup=False)"): "Fixed product heading from the local brand module.",
    ("tui.py", "FinOpsApp.compose", "Static('Signing in through Azure CLI (estimate 3-5 s)...', id='identity', markup=False)"): "Static initial sign-in progress, before backend reads.",
    ("tui.py", "FinOpsApp.compose", "Select([], id='people-team', prompt='Choose a team')"): "Empty initial team picker; backend options are guarded later.",
    ("tui.py", "FinOpsApp.compose", "Select(DIMENSIONS, value='organization', allow_blank=False, id='dimension')"): "Fixed locally defined dimension vocabulary.",
    ("tui.py", "FinOpsApp.compose", "Static('Tokens + cache + estimated cost', classes='toolbar-note')"): "Fixed usage-toolbar explanation.",
    ("tui.py", "FinOpsApp.compose", "Select([('Daily', 'day'), ('Hourly', 'hour'), ('Weekly', 'week')], value='day', allow_blank=False, id='interval')"): "Fixed local interval choices before capability filtering.",
    ("tui.py", "FinOpsApp.compose", "Static('Enter a bucket for exact metrics', classes='toolbar-note')"): "Fixed keyboard-navigation instruction.",
    ("tui.py", "FinOpsApp.compose", "Select([('AUM', 'gateway'), ('High contrast', 'high-contrast'), ('No color', 'no-color'), ('Light', 'textual-light')], value=self.theme, id='theme-choice', allow_blank=False)"): "Fixed theme choices and the operator's local theme selection.",
    ("tui.py", "FinOpsApp.compose", "Static('Use --plain for a linear screen-reader view', classes='toolbar-note')"): "Fixed accessibility instruction.",
    ("tui.py", "FinOpsApp.compose", "Static('Loading...', id=f'note-{tab}', classes='context', markup=False)"): "Fixed loading label; only the local tab id varies.",
    ("tui.py", "FinOpsApp.compose", "Static('1-8 / 0 tabs | Tab / Shift+Tab focus | Enter details | ? one-screen tour', id='status', markup=False)"): "Fixed initial keyboard-navigation legend.",
    ("tui.py", "FinOpsApp.compose", "Static('', id='key-hints', markup=False)"): "Empty initial keyboard-hint placeholder.",
    # Optional-view shell and fixed non-data progress messages.
    ("ui_features.py", "FeatureUI.compose_feature", """TextArea("Ask uses the connected server's model and tool permissions.", id='ask-answer', read_only=True)"""): "Fixed assistant boundary explanation.",
    ("ui_features.py", "FeatureUI.compose_feature", "Select([('My requests', 'mine'), ('Waiting for me', 'waiting'), ('History', 'history'), ('Notifications', 'notifications')], value='mine', allow_blank=False, id='approval-view')"): "Fixed approval navigation choices.",
    ("ui_features.py", "FeatureUI.compose_feature", "Select([('Models', 'models'), ('Backend pools', 'pools'), ('Releases', 'releases'), ('Subscriptions', 'subscriptions')], value='models', allow_blank=False, id='advanced-view')"): "Fixed advanced-view navigation choices.",
    ("ui_features.py", "FeatureUI.ask_current", "self.query_one('#ask-answer', TextArea).load_text('Preview/read-only mode: the question was not sent. Asking can incur model cost and store a conversation.')"): "Fixed preview refusal; contains no response or prompt text.",
    ("ui_features.py", "FeatureUI.ask_current", "self.query_one('#ask-answer', TextArea).load_text('Asking the server. No chart data is generated by the client...')"): "Fixed pending-request status, not a server answer.",
    ("progressive.py", "ProgressiveRefresh.action_refresh", "note.update('Loading current data (estimate 3-5 s); sources appear as they arrive.')"): "Fixed progress label before any source result.",
    ("progressive.py", "ProgressiveRefresh.action_refresh", "self.query_one('#identity', Static).update('Direct | identity unavailable; read-only data')"): "Fixed identity-unavailable message without identity values.",
    # Local form chrome and static refusal/progress text; no row defaults are exempt.
    ("screens.py", "MonthScreen.compose", "Label('Choose month (YYYY-MM)')"): "Fixed date-format instruction.",
    ("screens.py", "MonthScreen.compose", "Input(self.app.engine.month, id='month-input')"): "Operator-selected local month, not backend-returned data.",
    ("screens.py", "MonthScreen.compose", "Static('', id='month-error', markup=False)"): "Empty local validation placeholder.",
    ("screens.py", "LookupScreen.compose", "Label('Find units, teams, models; people in the selected team', markup=False)"): "Fixed lookup instruction, not a source result.",
    ("screens.py", "LookupScreen.compose", "Select([], prompt='Choose a team for people (global search when advertised)', id='lookup-team')"): "Empty lookup picker; source choices require guarded publication.",
    ("screens.py", "LookupScreen.compose", "Static('People are searched on the server, never loaded in full.', id='lookup-status', markup=False)"): "Fixed paging/privacy explanation.",
    ("screens.py", "LookupScreen.search", "self.query_one('#lookup-status', Static).update('Searching...')"): "Fixed pending-search progress label.",
    ("screens.py", "ChangeScreen.preview", "self.query_one('#form-status', Static).update('Refreshing permissions and allocation...')"): "Fixed preview progress, with no cached allocation values.",
    ("screens.py", "ChangeScreen.apply_change", "self.query_one('#form-status', Static).update('Saving once. Do not close this terminal.')"): "Fixed single-write progress instruction.",
    ("screens.py", "ChangeScreen.apply_change", "self.query_one('#form-status', Static).update('Saved. Following gateway apply; usually about two minutes...')"): "Fixed apply-wait progress message, no response payload.",
    ("screens.py", "ChangeScreen.action_cancel", "self.query_one('#form-status', Static).update('A write is in progress. Wait for its result before closing.')"): "Fixed cancellation refusal while a write is active.",
    ("screens.py", "ExportScreen.export", "self.query_one('#export-status', Static).update('Use a CSV filename, without directory separators.')"): "Fixed filename-validation refusal.",
    ("screens.py", "ExportScreen.export", "self.query_one('#export-status', Static).update('Reading every catalog scope (estimate 3-30 s); not just the top ranking...')"): "Fixed estimated export progress, not scope names or results.",
    ("feature_screens.py", "ActionForm.apply_action", "self.query_one('#action-status', Static).update('Saved; following apply status...')"): "Fixed pending-apply message.",
    ("feature_screens.py", "TourScreen.compose", "Label('Welcome to AUM — one engine, terminal and commands')"): "Fixed first-run tour heading.",
    ("feature_screens.py", "TourScreen.compose", "Static('1-8 / 0 open views; 9 Approvals and a Ask appear only when permitted.\\n\\nTab moves between panels. Enter opens exact values. Esc returns.\\n\\n/ finds units, teams, people, models and request ids. f edits server filters.\\nCtrl+F filters visible rows. : finds every permitted action by name.\\n\\nBudget edits preview first, check parent headroom and require Apply.\\nRemoving or lowering below spend requires the scope name.\\n\\nSettings switches profile/backend and explains sign-out.\\nUse --plain or --screen-reader for linear output; ? shows current keys.', markup=False)"): "Fixed tour instructions with no interpolated backend fields.",
    ("dashboard.py", "Dashboard.clear", "panel.update('No current data. Refresh an authorized view.')"): "Fixed clearing message; old panel values are discarded.",
    ("dashboard.py", "Dashboard.begin_load", "panel.update('Loading current facts (estimate 3-5 s)...')"): "Fixed panel loading placeholder.",
    ("group_screens.py", "GroupPicker.compose", "Label('Select or create the Entra group for this scope', markup=False)"): "Fixed directory-picker instruction.",
    ("group_screens.py", "GroupPicker.compose", "Static('Bounded server search. Existing groups retain their owners; new security groups belong to you.', id='group-status', markup=False)"): "Fixed group ownership explanation.",
    ("group_screens.py", "GroupPicker.select", "self.query_one('#group-status', Static).update('Choose an assigned-membership, non-mail-enabled security group.')"): "Fixed group-type refusal without directory values.",
    ("developer_screens.py", "DeveloperPicker.compose", "Label('Add developer from Microsoft Entra directory', markup=False)"): "Fixed developer-picker heading.",
    ("developer_screens.py", "DeveloperPicker.compose", "Static('Bounded delegated directory search. Preview before any group membership write.', id='developer-status', markup=False)"): "Fixed directory-search and preview instruction.",
    # Command metadata exits never connect to a backend.
    ("cli.py", "root", "typer.echo(BANNER)"): "Fixed product banner before connecting.",
    ("cli.py", "root", "display(dict(product=PRODUCT, version=__version__), as_json=True)"): "Local package product/version metadata only.",
    ("cli.py", "root", "typer.echo(f'{PRODUCT} {__version__}')"): "Local package product/version metadata only.",
    ("cli.py", "legacy_main", "typer.echo('Deprecated: claude-finops is now aum (AUM - Azure Usage Management); this alias remains for one release.', err=True)"): "Fixed legacy-entry-point deprecation notice.",
}

# The principal reset iterates a fixed tuple of cache field names, never widget
# methods. This is not an exception for a computed sink or arbitrary reflection.
DYNAMIC_ACCESSES = {
    ("principal_ui.py", "PrincipalUI._clear_principal_state", "getattr(screen, name)"):
        "Reads the fixed local cache-field tuple solely to avoid replacing callable methods during clearing.",
}


def call_name(node):
    if isinstance(node, ast.Name):
        return node.id
    if isinstance(node, ast.Attribute):
        return node.attr
    if isinstance(node, ast.Call) and call_name(node.func) == "getattr":
        if len(node.args) > 1 and isinstance(node.args[1], ast.Constant):
            return node.args[1].value
    return ""


def sinks(source, filename, allowed=None):
    allowed = STATIC_WRITES if allowed is None else allowed
    failures = []
    tree = ast.parse(source)

    class Check(ast.NodeVisitor):
        def __init__(self):
            self.scope = []
            self.guarded = False
            self.callbacks = set()
            self.deferred = False

        def report(self, node, detail=None):
            key = (filename, ".".join(self.scope), ast.unparse(node))
            if key not in allowed:
                failures.append(f"{filename}:{node.lineno}:{'.'.join(self.scope)}: {detail or ast.unparse(node)}")

        def escaping(self, node):
            if isinstance(node, ast.Call) and call_name(node.func) == "guarded_deferred":
                return False
            if isinstance(node, ast.Lambda):
                return True
            if isinstance(node, ast.Call) and call_name(node.func) == "partial":
                return True
            if ast.unparse(node) in self.callbacks:
                return True
            if isinstance(node, ast.Call):
                return self.escaping(node.func)
            return False

        def visit_ClassDef(self, node):
            self.scope.append(node.name)
            self.generic_visit(node)
            self.scope.pop()

        def visit_FunctionDef(self, node):
            if self.guarded:
                self.callbacks.add(node.name)
            previous = self.guarded
            callbacks = self.callbacks.copy()
            self.guarded = any(
                isinstance(item, ast.Call) and call_name(item.func) == "published" and item.args
                or isinstance(item, ast.Name) and item.id == "publication_sink"
                for item in node.decorator_list)
            self.scope.append(node.name)
            for statement in node.body:
                self.visit(statement)
            self.scope.pop()
            self.guarded = previous
            self.callbacks = callbacks

        visit_AsyncFunctionDef = visit_FunctionDef

        def visit_Lambda(self, node):
            previous = self.guarded
            self.guarded = self.deferred
            self.visit(node.body)
            self.guarded = previous

        def visit_With(self, node):
            previous = self.guarded
            if any(isinstance(item.context_expr, ast.Call) and isinstance(item.context_expr.func, ast.Name)
                   and item.context_expr.func.id == "guarded_publish" and item.context_expr.args
                   for item in node.items):
                self.guarded = True
            for item in node.items:
                self.visit(item.context_expr)
            for statement in node.body:
                self.visit(statement)
            self.guarded = previous

        def visit_Await(self, node):
            if self.guarded:
                failures.append(f"{filename}:{node.lineno}:{'.'.join(self.scope)}: publication scope spans await")
            self.generic_visit(node)

        def visit_Assign(self, node):
            if self.escaping(node.value):
                self.callbacks.update(ast.unparse(target) for target in node.targets)
            if not self.guarded and any(isinstance(target, ast.Attribute) and target.attr in {
                    "value", "text", "label", "border_title", "placeholder", "tooltip"} for target in node.targets):
                self.report(node)
            self.generic_visit(node)

        def visit_Call(self, node):
            name = call_name(node.func)
            if name == "guarded_deferred":
                previous, deferred = self.guarded, self.deferred
                self.guarded = self.deferred = True
                for argument in node.args:
                    self.visit(argument)
                self.guarded, self.deferred = previous, deferred
                return
            if name in SCHEDULERS and any(self.escaping(argument) for argument in node.args):
                self.report(node, "deferred callback requires guarded_deferred")
            if name == "getattr" and len(node.args) > 1 and not isinstance(node.args[1], ast.Constant):
                key = (filename, ".".join(self.scope), ast.unparse(node))
                if key not in DYNAMIC_ACCESSES:
                    self.report(node, "computed getattr can select a presentation sink")
            if name == "setattr" and len(node.args) > 1:
                attribute = node.args[1]
                if (not isinstance(attribute, ast.Constant) or attribute.value in SINK_PROPERTIES) and not self.guarded:
                    self.report(node)
            if name == "partial" and node.args and call_name(node.args[0]) in SINKS and not self.deferred:
                self.report(node, "partial of a sink requires guarded_deferred")
            sink = name in SINKS or (name in VALUE_WIDGETS and bool(node.args))
            if name == "run" and any(keyword.arg == "input" for keyword in node.keywords):
                sink = True
            if name == "write" and isinstance(node.func, ast.Attribute) and ast.unparse(node.func.value).endswith("backend"):
                sink = bool(node.args and isinstance(node.args[0], ast.Constant) and node.args[0].value == "assistant_ask")
            if name == "ask" and not (isinstance(node.func, ast.Attribute) and
                                      ast.unparse(node.func.value).endswith("engine")):
                sink = False
            if sink and not self.guarded:
                self.report(node)
            self.generic_visit(node)

    Check().visit(tree)
    return failures


def test_all_presentation_modules_use_the_choke_point():
    violations = []
    for name in UI_FILES:
        violations.extend(sinks((ROOT / name).read_text(encoding="utf-8"), name))
    assert not violations, "\n".join(violations)


def test_direct_handler_sink_is_detected_even_inside_a_guarded_parent():
    code = """
class Example:
    def handler(self, value):
        self.query_one('#status').update(value)
    def parent(self, origin):
        with guarded_publish(origin):
            def callback():
                self.copy_to_clipboard(self.row)
"""
    found = sinks(code, "example.py", {})
    assert len(found) == 2
    assert "handler" in found[0] and "callback" in found[1]


def test_checking_a_guard_elsewhere_does_not_authorize_the_sink():
    code = """
def handler(self):
    with self.cached_guard()():
        pass
    self.query_one('#status').update(self.row)
"""
    assert len(sinks(code, "example.py", {})) == 1


def test_choke_point_dominates_widget_and_assistant_sinks():
    code = """
def handler(self, origin):
    with guarded_publish(origin):
        self.query_one('#status').update(self.row)
        self.engine.ask(self.question, self.conversation, self.history)
"""
    assert sinks(code, "example.py", {}) == []


def test_allowlist_entries_are_exact_and_explained():
    encoded = json.dumps(sorted((list(key), value) for key, value in STATIC_WRITES.items()),
                         ensure_ascii=True, separators=(",", ":")).encode()
    assert len(STATIC_WRITES) == 51
    assert hashlib.sha256(encoded).hexdigest() == "64449781c059924cfb7bfbdc35866b4be7e3baa864761f8e070cfb11640911df"
    for key, reason in STATIC_WRITES.items():
        assert len(key) == 3 and len(reason.strip()) >= 20
        file, function, call = key
        statement = ast.parse(call).body[0]
        assert file in UI_FILES and function
        assert isinstance(statement, ast.Assign) or (
            isinstance(statement, ast.Expr) and isinstance(statement.value, ast.Call))
        assert call in ast.unparse(ast.parse((ROOT / file).read_text(encoding="utf-8")))


def test_all_textual_modules_and_output_formatters_are_covered():
    presentation = {"output.py"}
    for path in ROOT.glob("*.py"):
        tree = ast.parse(path.read_text(encoding="utf-8"))
        if any(isinstance(node, ast.ImportFrom) and (node.module or "").startswith("textual")
               for node in ast.walk(tree)):
            presentation.add(path.name)
    assert presentation <= set(UI_FILES)


def test_alias_name_cannot_hide_a_widget_update():
    code = """
def handler(self):
    result = self.query_one('#status')
    result.update(self.cached_row)
"""
    assert len(sinks(code, "example.py", {})) == 1


def test_clipboard_subprocess_and_assistant_backend_request_are_sinks():
    code = """
def handler(self):
    subprocess.run(['clipboard'], input=self.cached_id)
    self.backend.write('assistant_ask', {'history': self.history})
"""
    assert len(sinks(code, "example.py", {})) == 2


def test_widget_value_assignment_is_a_publication_sink():
    code = """
def handler(self):
    self.query_one('#person').value = self.cached_person
"""
    assert len(sinks(code, "example.py", {})) == 1


def test_publication_scope_cannot_span_an_await():
    code = """
async def handler(self, origin):
    with guarded_publish(origin):
        await self.read_more()
        self.query_one('#status').update(self.row)
"""
    assert len(sinks(code, "example.py", {})) == 1


@pytest.mark.parametrize("body", [
    "with guarded_publish(origin):\n        callback = lambda: widget.update(self.cached_row)\n        self.call_later(callback)",
    "getattr(widget, 'update')(self.cached_row)",
    "setattr(widget, 'value', self.cached_row)",
    "with guarded_publish(origin):\n        callback = functools.partial(widget.update, self.cached_row)\n        self.call_later(callback)",
])
def test_round_six_indirect_and_deferred_probes_are_rejected(body):
    source = "def handler(self, widget, origin):\n    " + body + "\n"
    assert sinks(source, "example.py", {}), source


@pytest.mark.parametrize("scheduler", [
    "self.call_later", "self.call_after_refresh", "self.set_timer", "self.set_interval",
    "self.run_worker", "self.post_message", "asyncio.create_task", "loop.call_soon",
])
def test_nested_callback_created_under_guard_cannot_escape_to_scheduler(scheduler):
    source = f"""
def handler(self, origin):
    with guarded_publish(origin):
        def callback():
            return self.render_private_row(self.cached_row)
        {scheduler}(callback)
"""
    assert sinks(source, "example.py", {}), scheduler


def test_computed_getattr_in_presentation_code_is_not_silently_trusted():
    assert sinks("def handler(widget, method, value):\n    getattr(widget, method)(value)\n", "example.py", {})


@pytest.mark.parametrize("callback", [
    "lambda: widget.update(self.cached_row)",
    "partial(widget.update, self.cached_row)",
    "functools.partial(getattr(widget, 'update'), self.cached_row)",
])
def test_explicit_deferred_wrapper_is_the_only_callback_escape(callback):
    source = f"""
def handler(self, widget, origin):
    self.call_later(guarded_deferred(origin, {callback}))
"""
    assert sinks(source, "example.py", {}) == []


def test_callback_alias_does_not_erase_its_deferred_origin_requirement():
    source = """
def handler(self, origin):
    with guarded_publish(origin):
        def callback():
            return self.render_private_row(self.cached_row)
        alias = callback
    self.call_after_refresh(alias)
"""
    assert sinks(source, "example.py", {})


def test_lambda_body_never_inherits_the_creation_scope():
    source = """
def handler(self, widget, origin):
    with guarded_publish(origin):
        self.callback = lambda: widget.update(self.cached_row)
"""
    assert sinks(source, "example.py", {})


def test_partial_sink_reference_requires_explicit_deferral_without_a_scheduler():
    source = """
def handler(self, widget, origin):
    with guarded_publish(origin):
        self.callback = partial(widget.update, self.cached_row)
"""
    assert sinks(source, "example.py", {})
