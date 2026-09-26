from pathlib import Path
import shutil
import subprocess
import typer

from .config import az
from .errors import FinOpsError
from .preferences import Preferences


def register(app, groups, emit):
    views = typer.Typer(rich_markup_mode=None, help="Saved views private to an identity and profile.")
    session = typer.Typer(rich_markup_mode=None, help="Profile information and explicit sign-out.")
    app.add_typer(views, name="view")
    app.add_typer(session, name="session")

    def prefs(ctx, engine):
        identity = engine.read("whoami")
        config = ctx.obj["config"]
        profile = f"{config.backend}|{config.url}|{config.subscription}|{config.apim_name}"
        return Preferences(identity.get("id") or identity.get("email", "unknown"), profile,
                           memory=config.backend == "fake")

    @views.command("list")
    def list_views(ctx: typer.Context):
        emit(ctx, lambda engine: prefs(ctx, engine).views())

    @views.command("save")
    def save_view(ctx: typer.Context, name: str, tab: str = "usage", unit: str | None = None,
                  team: str | None = None, person: str | None = None, model: str | None = None,
                  surface: str | None = None, tier: str | None = None, dimension: str = "organization",
                  interval: str = "day", compare: str | None = None, apply: bool = False):
        def run(engine):
            filters = {k: v for k, v in dict(organization_id=unit, department_id=team, user_id=person,
                                            model_id=model, runtime=surface, tier=tier).items() if v}
            view = dict(tab=tab, month=engine.month, filters=filters, dimension=dimension,
                        interval=interval, compare=compare or "")
            write = apply and not ctx.obj["what_if"]
            if write:
                prefs(ctx, engine).save_view(name, view)
            return dict(preview=not write, action="Save personal view", after=view)
        emit(ctx, run)

    @views.command("remove")
    def remove_view(ctx: typer.Context, name: str, apply: bool = False):
        def run(engine):
            write = apply and not ctx.obj["what_if"]
            if write:
                prefs(ctx, engine).remove_view(name)
            return dict(preview=not write, action="Remove personal view", name=name)
        emit(ctx, run)

    @views.command("load")
    def load_view(ctx: typer.Context, name: str):
        def run(engine):
            view = prefs(ctx, engine).views().get(name)
            if view is None:
                raise FinOpsError("Saved view not found for this identity/profile.", 5)
            engine.month = view.get("month", engine.month)
            filters = view.get("filters", {})
            tab = view.get("tab")
            if tab == "usage":
                return engine.read("distribution", dimension=view.get("dimension", "organization"), limit=100, **filters)
            if tab == "trends":
                if view.get("compare"):
                    return engine.compare_trends(view["compare"], interval=view.get("interval", "day"), **filters)
                return engine.read("trends", interval=view.get("interval", "day"), group_by="none", **filters)
            resource = {"overview": "overview", "requests": "requests", "anomalies": "anomalies"}.get(tab)
            return engine.read(resource, **filters) if resource else dict(view=view)
        emit(ctx, run)

    @session.command("show")
    def show_session(ctx: typer.Context):
        emit(ctx, lambda engine: dict(identity=engine.read("whoami"), config=ctx.obj["config"].public(),
                                      capabilities=engine.capabilities()))

    @session.command("signout")
    def signout(ctx: typer.Context, apply: bool = False, confirm: str = ""):
        def run(engine):
            write = apply and not ctx.obj["what_if"]
            if write:
                if confirm != "sign out":
                    raise FinOpsError('Use --confirm "sign out"; this clears the shared Azure CLI session.')
                if ctx.obj["config"].backend != "fake":
                    az("logout")
                engine.backend.close()
            return dict(preview=not write, action="Sign out", effect="Clears Azure CLI credentials, not only AUM memory.")
        emit(ctx, run)

    @groups["requests"].command("copy")
    def copy_request(ctx: typer.Context, request_id: str):
        def run(engine):
            row = engine.read("request", request_id=request_id)
            key = row["request_id"]
            if ctx.obj["what_if"]:
                return dict(preview=True, action="Copy request id", request_id=key)
            if ctx.obj["redactor"].enabled:
                raise FinOpsError("Turn redaction off to copy the actual request id.")
            if shutil.which("pwsh"):
                command = ["pwsh", "-NoProfile", "-Command", "Set-Clipboard -Value ([Console]::In.ReadToEnd())"]
            elif shutil.which("pbcopy"):
                command = ["pbcopy"]
            elif shutil.which("wl-copy"):
                command = ["wl-copy"]
            else:
                raise FinOpsError("No clipboard helper is available. Use requests show --json and copy request_id.")
            result = subprocess.run(command, input=key, text=True, capture_output=True, timeout=20)
            if result.returncode:
                raise FinOpsError("Clipboard copy failed. Use requests show --json.", 7)
            return dict(copied=True, request_id=key)
        emit(ctx, run)
