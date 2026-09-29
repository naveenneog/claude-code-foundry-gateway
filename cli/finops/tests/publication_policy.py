"""Closed capabilities for maintainer-written presentation code, not a Python sandbox."""

import ast
import builtins
import hashlib
from publication_attributes import APPROVED_ATTRIBUTES, EXCLUDED_ATTRIBUTES, ATTRIBUTE_EXCEPTIONS, ATTRIBUTE_CONTEXTS


PRESENTATION = {
    "accessibility.py", "brand.py", "cli.py", "commands_groups.py", "commands_local.py",
    "commands_v4.py", "configure.py", "dashboard.py", "dashboard_drill.py",
    "developer_screens.py", "feature_engine.py", "feature_screens.py", "feature_views.py",
    "group_screens.py", "output.py", "palette.py", "principal_ui.py", "progressive.py",
    "publication_output.py", "publication_widgets.py", "screens.py", "tui.py",
    "ui_features.py", "views.py",
}
NON_PRESENTATION = {
    "package": ("Package version metadata has no rendering or transport.", {"__init__.py"}),
    "backend": ("Authenticated provider and engine APIs own reads, writes and their authorization.", {
        "aum_service.py", "backend.py", "direct.py", "direct_analytics.py", "engine.py",
        "feature_routes.py", "http_backend.py", "service_models.py", "service_writes.py",
        "turnstile.py",
    }),
    "validation": ("Pure validation, accounting and redaction transform values without presentation.", {
        "capabilities.py", "errors.py", "ledger.py", "redaction.py", "rules.py", "scope.py", "usd.py",
    }),
    "operator": ("Explicit operator APIs own configuration, directory actions, reports and preferences.", {
        "bulk.py", "config.py", "developer_actions.py", "developers.py", "discovery.py",
        "gateway_probe.py", "group_actions.py", "groups.py", "preferences.py", "reporting.py",
        "usage_refresh.py",
    }),
    "boundaries": ("Credential, publication and process lifetime primitives are tested at their boundaries.", {
        "guarded_publication.py", "readiness.py", "windows_process.py",
    }),
    "fixtures": ("The fake backend provides deterministic test data, not terminal output.", {
        "fake.py", "fake_features.py",
    }),
    "capture": ("The screenshot-provenance tool is not imported by the terminal or command presentation layer.", {
        "publication.py",
    }),
}


def approval(reason, names):
    return reason, frozenset(names.split())


APPROVED = {
    "asyncio": approval("Async read coordination and scheduling retained-origin callbacks.",
                       "FIRST_COMPLETED as_completed create_task gather get_running_loop sleep to_thread wait"),
    "collections.abc": approval("Callable annotations describe the retained-origin interface.", "Callable"),
    "contextlib": approval("Explicit publication and local-message context lifetimes.",
                          "AbstractContextManager ExitStack contextmanager nullcontext"),
    "copy": approval("Deep copies preserve ordinary backend value objects, not raw widget classes.", "deepcopy"),
    "dataclasses": approval("Immutable provenance and input-origin data records.", "dataclass field"),
    "datetime": approval("Date values, UTC metadata and local display formatting.", "datetime timezone timedelta"),
    "functools": approval("Named callback binding and wrapper metadata preserve existing callable APIs.", "partial wraps"),
    "inspect": approval("Coroutine classification and fixed CLI signature metadata, not dynamic imports.",
                        "isawaitable iscoroutinefunction signature"),
    "json": approval("In-memory JSON serialization; no file or stream handles are supplied here.", "dumps loads"),
    "csv": approval("CSV formatting targets an in-memory StringIO before guarded file publication.", "DictWriter"),
    "io": approval("In-memory string buffers expose no filesystem writer capability.", "StringIO"),
    "os": approval("Only the operator's fixed environment options are read.", "environ"),
    "re": approval("Literal filename and input validation uses regular-expression matching.", "fullmatch"),
    "shutil": approval("Clipboard-helper discovery returns an executable name, not a process writer.", "which"),
    "time": approval("Monotonic elapsed-time labels do not block or publish backend data.", "monotonic"),
    "typing": approval("CLI argument annotations carry no output capability.", "Annotated"),
    "typer": approval("Command registration and argument/exit metadata exclude echo, prompt and raw output.",
                      "Argument Context Exit Option Typer"),
    "typer.core": approval("Root option parsing extends the command group, not its output functions.", "TyperGroup"),
    "uuid": approval("Identifiers and idempotency keys are data, not presentation capabilities.", "UUID uuid4"),
    "rich.cells": approval("Cell width calculations operate only on in-memory text.", "cell_len"),
    "rich.segment": approval("Accessibility filters transform in-memory terminal segments.", "Segment"),
    "rich.table": approval("Tables are in-memory renderables written only by a guarded sink.", "Table"),
    "rich.text": approval("Text is an in-memory renderable with no console or stream ownership.", "Text"),
    "textual": approval("Event decorators, worker declarations and event data are framework coordination.",
                        "events on work"),
    "textual.events": approval("Input and mount event types contain framework event data.", "InputEvent"),
    "textual.app": approval("The compose-result annotation is not the raw application class.", "ComposeResult"),
    "textual.binding": approval("Keyboard binding declarations contain fixed local actions.", "Binding"),
    "textual.command": approval("Command-palette descriptors contain fixed local action labels.", "DiscoveryHit Hit Provider"),
    "textual.filter": approval("The accessibility filter interface does not own a display widget.", "LineFilter"),
    "textual.theme": approval("Theme definitions describe local colors without rendering backend values.", "Theme"),
    ".": approval("Local version and capability metadata are explicitly named.", "__version__ capabilities"),
    ".accessibility": approval("The ASCII filter transforms already-guarded presentation.", "AsciiFilter"),
    ".backend": approval("Connection and read-cycle APIs retain provider authorization.", "connect in_read_cycle"),
    ".brand": approval("Product labels and banner selection are fixed local metadata.", "BANNER COMPACT PRODUCT show_banner"),
    ".bulk": approval("Bulk preview/apply owns validation and server authorization.", "apply_budget_plan budget_csv_plan"),
    ".capabilities": approval("The server's capability vocabulary controls permitted views and actions.",
                              "enabled require WRITE_FEATURES READ_FEATURES"),
    ".commands_groups": approval("Directory commands register with the guarded command emitter.", "register"),
    ".commands_local": approval("Local commands register with the guarded command emitter.", "register"),
    ".commands_v4": approval("Capability commands register with the guarded command emitter.", "register"),
    ".config": approval("Address configuration and explicit Azure operations use their existing boundary.", "Config az load_config"),
    ".configure": approval("The discovery command uses protected output and profile writers.", "configure"),
    ".dashboard": approval("Dashboard controls derive from approved protected widgets.", "Dashboard DashboardPanel enforcement_badge"),
    ".dashboard_drill": approval("Detail rows retain their originating panel's guard.", "DashboardRows"),
    ".developer_actions": approval("Directory action APIs validate input and preserve explicit apply semantics.", "developer_change developer_find"),
    ".developer_screens": approval("The developer picker uses protected widgets and scoped reads.", "DeveloperPicker"),
    ".discovery": approval("Read-only address discovery precedes a backend session.", "discover"),
    ".engine": approval("The engine retains provider authorization and immutable read generations.", "Engine"),
    ".errors": approval("Only safe, actionable domain errors are presented.", "FinOpsError"),
    ".feature_screens": approval("Forms and filters retain source guards before constructing protected children.",
                                 "ActionForm FilterChips FiltersScreen TourScreen"),
    ".feature_views": approval("Optional-view formatting returns ordinary value rows.", "feature_rows"),
    ".group_actions": approval("Explicit directory and gateway actions own their validation and authorization.",
                               "group_call membership_refresh probe_gateway publish_as_signed_in_admin"),
    ".group_screens": approval("Group forms use protected controls and the existing action boundary.",
                               "GroupPicker refresh_membership_form"),
    ".guarded_publication": approval("These are the explicit source and execution boundaries.",
                                     "PublicationOrigin enclosing_publication guarded_deferred guarded_publish publication_active publication_origin publication_sink published"),
    ".ledger": approval("Ledger links are values; opening them still uses the guarded application sink.", "ledger_url"),
    ".output": approval("Formatters delegate final output to protected publication functions.", "chargeback_csv display safe_text"),
    ".palette": approval("The command provider exposes the fixed local action vocabulary.", "FinOpsCommands"),
    ".preferences": approval("The identity/profile-scoped preference store is an existing operator API.", "Preferences"),
    ".principal_ui": approval("Principal transitions clear cached presentation before later input.", "PrincipalUI"),
    ".progressive": approval("Progressive refresh retains the originating generation at every result.", "ProgressiveRefresh"),
    ".publication_output": approval("Only these value-returning readers and guarded writers are exported to presentation.",
                                    "copy_with_helper profile_path prompt_number read_text terminal_output write_export write_profile write_renderable write_text"),
    ".publication_widgets": approval("Only the protected application, layout and display classes are presentation imports.",
                                     "Button DataTable Horizontal Input Label ModalScreen PublicationApp Select Static TabbedContent TabPane TextArea Vertical VerticalScroll Widget"),
    ".redaction": approval("Redaction transforms values before guarded publication.", "Redactor"),
    ".reporting": approval("The existing report operator API retains preview/apply semantics.", "report_plan"),
    ".rules": approval("Validation, formatting and authorization predicates return data.",
                       "allocation_left apply_state can_budget_write can_edit human identifier month_window parse_tokens query_window require_owner scope_type"),
    ".scope": approval("Scope labels and permitted-tab selection retain the backend's scope model.", "scope_label visible_tabs"),
    ".screens": approval("Core dialogs retain source guards and construct approved wrapped controls.",
                         "ChangeScreen DetailScreen ExportScreen LookupScreen MonthScreen"),
    ".tui": approval("The terminal app derives from the protected application boundary.", "FinOpsApp"),
    ".ui_features": approval("Optional UI actions use the same protected publication surfaces.", "EXTRA_TABS FeatureUI"),
    ".usage_refresh": approval("The explicit usage-refresh operator action keeps its existing authorization.", "refresh_usage"),
    ".views": approval("Core view formatting produces ordinary values, not output handles.", "DIMENSIONS TABS money view_rows"),
}

# Only these small boundary modules may import native output implementations.
# Their reviewed AST hashes prevent filename-based laundering of new code.
BOUNDARIES = {
    "publication_output.py": ("Final effects validate the active origin; readers return values, never writer handles.", "8fb60520df95b9c747468b12473a656ba6139fa8452f903b7bbfdd50a19c30be", {
        "pathlib": {"Path"}, "rich.console": {"Console", "RenderableType"},
        "subprocess": {"run"}, "sys": {"stdout"}, "typer": {"echo", "prompt"},
    }),
    "publication_widgets.py": ("Native framework classes are wrapped here before presentation can import them.", "500b135726d1edacbeaaad2f8908e50775f9eb4b4cdebb47fb73bfbe19d13cbc", {
        "textual._context": {"active_app"}, "textual.app": {"App"}, "textual.widget": {"Widget"},
        "textual.containers": {"Horizontal", "Vertical", "VerticalScroll"},
        "textual.screen": {"ModalScreen"},
        "textual.widgets": {"Button", "DataTable", "Input", "Label", "Select", "Static", "TabPane", "TabbedContent", "TextArea"},
        "textual.notifications": {"Notification", "Notify"},
        "textual.strip": {"Strip"},
        "textual.widgets._toast": {"Toast", "ToastHolder", "ToastRack"},
    }),
}

APPROVED_MEMBERS = {
    "os.environ.get", "datetime.datetime.now", "datetime.datetime.fromisoformat",
    "datetime.datetime.strptime", "datetime.timezone.utc", "rich.text.Text.from_markup",
    ".brand.BANNER.splitlines",
    ".publication_widgets.Button.Pressed", ".publication_widgets.Input.Changed",
    ".publication_widgets.Input.Submitted", ".publication_widgets.Select.Changed",
    ".publication_widgets.Select.BLANK", ".publication_widgets.DataTable.RowSelected",
    ".publication_widgets.DataTable.RowHighlighted", ".publication_widgets.DataTable.CellSelected",
    ".publication_widgets.TabbedContent.TabActivated",
}
SAFE_BUILTINS = {
    "BaseException", "Exception", "FileExistsError", "OSError", "ValueError", "__name__",
    "all", "any", "bool", "callable", "dict", "enumerate", "float", "getattr", "hasattr",
    "id", "int", "isinstance", "iter", "len", "list", "map", "max", "min", "next", "ord",
    "property", "range", "round", "set", "setattr", "delattr", "sorted", "staticmethod",
    "str", "sum", "super", "tuple", "type", "zip",
}

META_EXCEPTIONS = {
    ("publication_widgets.py", "_publication_refusal", "error.__cause__"):
        "Reads only a chained exception to find the safe refusal before any traceback rendering.",
    ("publication_widgets.py", "_publication_refusal", "error.__context__"):
        "Reads only a chained exception to find the safe refusal before any traceback rendering.",
    ("principal_ui.py", "PrincipalUI._clear_principal_state", "getattr(screen, name)"):
        "Reads only the fixed cache-field tuple to avoid replacing methods while clearing old presentation.",
    ("principal_ui.py", "PrincipalUI._clear_principal_state", "setattr(screen, name, empty)"):
        "Clears only the same fixed non-callable cache fields before closing obsolete dialogs.",
    ("publication_widgets.py", "PublicationWidget.__setattr__", "super().__setattr__(name, value)"):
        "Class changes are refused first; presentation fields use the guarded setter before this non-content branch.",
    ("publication_widgets.py", "PublicationWidget._set_presentation", "super().__setattr__(name, value)"):
        "The synchronous sink validates the source before this native setter and retains content provenance.",
    ("publication_widgets.py", "PublicationWidget._get_dispatch_methods", "operation.__name__"):
        "Matches only the fixed framework input-handler registry before applying its retained-origin wrapper.",
    ("publication_widgets.py", "PublicationApp._dispatch_action", "type(namespace).__mro__"):
        "Locates the framework's input action implementation without altering any class.",
    ("publication_widgets.py", "PublicationApp._dispatch_action", "cls.__dict__.get('action_' + action_name)"):
        "Reads a framework action, then verifies its module and binds a guarded input callback.",
    ("publication_widgets.py", "PublicationApp._dispatch_action", "cls.__module__"):
        "Restricts the action adapter to native Textual input implementations.",
    ("publication_widgets.py", "PublicationApp._dispatch_action", "method.__get__(namespace, cls)"):
        "Binds the verified framework action before the retained-origin input wrapper runs.",
    ("commands_v4.py", "register", "command.__signature__ = inspect.signature(command).replace(parameters=[p for p in inspect.signature(command).parameters.values() if p.name != '_decision'])"):
        "Removes only the fixed closure-capture parameter from CLI metadata; it does not replace executable code.",
}
META_CONTEXTS = {
    ("publication_widgets.py", "_publication_refusal"): "107fdfc3030e7d9a8199aee158d31b90d86d04150748717cab1ae7e0b2479bf8",
    ("principal_ui.py", "PrincipalUI._clear_principal_state"): "cdb93970fa0d2e3c5755b9717d1222ca8ef7a14dba27cc6ecb2d913d7c9ae585",
    ("publication_widgets.py", "PublicationWidget.__setattr__"): "42a9888f5ce632625e1ca2f6ba408bdfe127ec9fafc88614fc895c97f255b289",
    ("publication_widgets.py", "PublicationWidget._set_presentation"): "82fc2c3430ecef1cd23d1f13be6ed3de39c173aabec21d140aa74369fe90c850",
    ("publication_widgets.py", "PublicationWidget._get_dispatch_methods"): "e39aef5ed0e04460ced7564b108c2cce2651ea732b880500eec077faf96ad18d",
    ("publication_widgets.py", "PublicationApp._dispatch_action"): "b1dadd3415f4d1237c5297abfc2002390df965668a4b2556612b26f6d97eec4d",
    ("commands_v4.py", "register"): "ea2480863f81f3dc165d61dea27046d8872a959b6dc2b4c990927707e4ed35bc",
}
META_EXCEPTIONS.update(ATTRIBUTE_EXCEPTIONS)
META_CONTEXTS.update(ATTRIBUTE_CONTEXTS)


def digest(node):
    return hashlib.sha256(ast.dump(node, include_attributes=False).encode()).hexdigest()


def inventory_failures(root):
    declared = PRESENTATION | set().union(*(names for _, names in NON_PRESENTATION.values()))
    actual = {path.name for path in root.glob("*.py")}
    return [f"Unclassified source module: {name}" for name in sorted(actual - declared)] + [
        f"Declared module is missing: {name}" for name in sorted(declared - actual)]


def functions(tree):
    result = {}

    def visit(node, scope=()):
        for child in ast.iter_child_nodes(node):
            if isinstance(child, (ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)):
                path = (*scope, child.name)
                if not isinstance(child, ast.ClassDef):
                    result[".".join(path)] = child
                visit(child, path)
            else:
                visit(child, scope)
    visit(tree)
    return result


def normalize(module):
    if module == "claude_finops":
        return "."
    if module.startswith("claude_finops."):
        return "." + module.removeprefix("claude_finops.")
    return module


def qualify(module, member):
    return ("." if module == "." else module + ".") + member


def violations(tree, filename):
    errors = []
    parents = {child: node for node in ast.walk(tree) for child in ast.iter_child_nodes(node)}
    scopes = functions(tree)
    boundary = BOUNDARIES.get(filename)
    trusted = bool(boundary and len(boundary[0]) >= 20 and digest(tree) == boundary[1])
    raw_imports = boundary[2] if trusted else {}
    approved = {qualify(module, member) for module, (_, members) in APPROVED.items() for member in members}
    approved |= APPROVED_MEMBERS
    approved |= {qualify(module, member) for module, members in raw_imports.items() for member in members}
    module_names = set(APPROVED) | set(raw_imports)

    class Check(ast.NodeVisitor):
        def __init__(self):
            self.scope = []
            self.bindings = {}
            self.classes = set()
            self.module_bindings = set()

        def report(self, node, reason):
            errors.append(f"{filename}:{node.lineno}:{'.'.join(self.scope)}: {reason}")

        def resolved(self, node):
            if isinstance(node, ast.Name):
                return self.bindings.get(node.id, node.id)
            if isinstance(node, ast.Attribute):
                base = self.resolved(node.value)
                return base + "." + node.attr if base else ""
            if isinstance(node, ast.Call) and self.resolved(node.func) == "getattr" and len(node.args) > 1:
                if isinstance(node.args[1], ast.Constant) and isinstance(node.args[1].value, str):
                    base = self.resolved(node.args[0])
                    return base + "." + node.args[1].value if base else ""
            return ""

        def exceptional(self, node):
            scope = ".".join(self.scope)
            key = (filename, scope, ast.unparse(node))
            reason = META_EXCEPTIONS.get(key)
            function = scopes.get(scope)
            return bool(reason and len(reason) >= 20 and function is not None
                        and digest(function) == META_CONTEXTS.get((filename, scope)))

        def is_module(self, name):
            return name in module_names or any(module.startswith(name + ".") for module in module_names)

        def imported(self, node):
            while isinstance(node, ast.Attribute):
                node = node.value
            return isinstance(node, ast.Name) and node.id in self.bindings

        def class_target(self, node):
            if isinstance(node, ast.Name) and node.id in self.classes:
                return True
            if isinstance(node, ast.Call) and self.resolved(node.func) in {"type", "builtins.type"}:
                return True
            name = self.resolved(node)
            return self.imported(node) and (self.is_module(name) or name.rsplit(".", 1)[-1][:1].isupper())

        def visit_ClassDef(self, node):
            self.classes.add(node.name)
            self.scope.append(node.name)
            self.generic_visit(node)
            self.scope.pop()

        def visit_FunctionDef(self, node):
            self.scope.append(node.name)
            self.generic_visit(node)
            self.scope.pop()

        visit_AsyncFunctionDef = visit_FunctionDef

        def visit_Import(self, node):
            for alias in node.names:
                module = normalize(alias.name)
                if module not in module_names:
                    self.report(node, f"Unapproved presentation import: {module}")
                local = alias.asname or alias.name.split(".")[0]
                self.bindings[local] = module if alias.asname else normalize(alias.name.split(".")[0])
                self.module_bindings.add(local)

        def visit_ImportFrom(self, node):
            module = normalize("." * node.level + (node.module or ""))
            for alias in node.names:
                name = qualify(module, alias.name)
                if alias.name == "*" or name not in approved:
                    self.report(node, f"Unapproved presentation import: {name}")
                local = alias.asname or alias.name
                self.bindings[local] = name
                if self.is_module(name):
                    self.module_bindings.add(local)

        def visit_Name(self, node):
            if node.id.startswith("__") and node.id.endswith("__") and node.id != "__name__" and node.id not in self.bindings:
                self.report(node, "Unapproved interpreter namespace access")
            if not isinstance(node.ctx, ast.Load):
                return
            if self.resolved(node) == "super":
                parent = parents.get(node)
                if not (isinstance(parent, ast.Call) and parent.func is node):
                    self.report(node, "The superclass builtin cannot escape a checked forwarding call")
            if node.id in vars(builtins) and node.id not in SAFE_BUILTINS:
                self.report(node, f"Unapproved presentation builtin: {node.id}")
            if node.id in self.module_bindings:
                parent = parents.get(node)
                if not (isinstance(parent, ast.Attribute) and parent.value is node):
                    self.report(node, "Imported modules cannot escape their approved member interface")

        def visit_Attribute(self, node):
            if self.exceptional(node):
                return
            if isinstance(node.ctx, ast.Load) and (
                    node.attr.startswith("_") or node.attr in EXCLUDED_ATTRIBUTES
                    or node.attr not in APPROVED_ATTRIBUTES):
                self.report(node, f"Unapproved presentation attribute: {node.attr}")
            if node.attr.startswith("__") and node.attr.endswith("__"):
                constructor = (node.attr == "__init__" and isinstance(node.value, ast.Call)
                               and self.resolved(node.value.func) == "super")
                if not constructor:
                    self.report(node, "Unapproved descriptor or raw-state attribute")
            name = self.resolved(node)
            if name == "sys.modules":
                self.report(node, "Module-registry access is not a presentation API")
            if self.imported(node):
                parent = parents.get(node)
                module_qualifier = self.is_module(name) and isinstance(parent, ast.Attribute) and parent.value is node
                if name not in approved and not module_qualifier and not trusted:
                    self.report(node, f"Unapproved imported member: {name}")
                if self.is_module(name) and not module_qualifier:
                    self.report(node, "Imported modules cannot escape their approved member interface")
            self.generic_visit(node)

        def assignment(self, node, targets, value=None):
            if self.exceptional(node):
                return
            for target in targets:
                for child in ast.walk(target):
                    if isinstance(child, ast.Attribute) and self.class_target(child.value):
                        self.report(node, "Presentation classes and imported namespaces are immutable")
                if isinstance(target, ast.Name) and value is not None:
                    if self.class_target(value):
                        self.classes.add(target.id)
                    resolved = self.resolved(value)
                    if resolved and (self.imported(value) or resolved in {"type", "builtins.type"}):
                        self.bindings[target.id] = resolved
                        if self.is_module(resolved):
                            self.module_bindings.add(target.id)
            self.generic_visit(node)

        def visit_Assign(self, node):
            self.assignment(node, node.targets, node.value)

        def visit_AnnAssign(self, node):
            self.assignment(node, [node.target], node.value)

        visit_AugAssign = visit_AnnAssign

        def visit_Delete(self, node):
            self.assignment(node, node.targets)

        def visit_Call(self, node):
            if self.exceptional(node):
                for argument in [*node.args, *(item.value for item in node.keywords)]:
                    self.visit(argument)
                return
            name = self.resolved(node.func)
            if name == "super" and (node.args or node.keywords or not trusted):
                self.report(node, "Superclass access requires a checked zero-argument forwarding context")
            if name in {"getattr", "hasattr", "setattr", "delattr"}:
                attribute = node.args[1] if len(node.args) > 1 else None
                if not isinstance(attribute, ast.Constant) or not isinstance(attribute.value, str):
                    self.report(node, "Computed reflection requires an exact checked justification")
                elif attribute.value.startswith("__") and attribute.value.endswith("__"):
                    self.report(node, "Raw-state reflection is not a presentation API")
                elif name in {"getattr", "hasattr"} and (
                        attribute.value.startswith("_") or attribute.value in EXCLUDED_ATTRIBUTES
                        or attribute.value not in APPROVED_ATTRIBUTES):
                    self.report(node, f"Unapproved reflected presentation attribute: {attribute.value}")
                if name in {"setattr", "delattr"} and node.args and self.class_target(node.args[0]):
                    self.report(node, "Presentation classes and imported namespaces are immutable")
                if name == "getattr" and self.resolved(node) == "sys.modules":
                    self.report(node, "Module-registry access is not a presentation API")
            self.generic_visit(node)

    Check().visit(tree)
    return errors
