"""Scriptable face; root options also work after a noun or verb."""

from pathlib import Path
from typing import Annotated

import typer
from typer.core import TyperGroup

from .backend import connect
from .config import load_config
from .engine import Engine
from .errors import FinOpsError
from .output import chargeback_csv, display


class EverywhereGroup(TyperGroup):
    def parse_args(self, ctx, args):
        flags = {"--json", "--plain", "--what-if", "--no-color", "--ascii"}
        options = {"--backend", "--month", "--config", "--url", "--scope", "--theme",
                   "--resource-group", "--apim-name"}
        prefix, rest = [], []
        index = 0
        while index < len(args):
            arg = args[index]
            if arg == "--":
                rest += args[index:]
                break
            key = arg.split("=", 1)[0]
            if key in flags:
                prefix.append(arg)
            elif key in options:
                prefix.append(arg)
                if "=" not in arg and index + 1 < len(args):
                    index += 1
                    prefix.append(args[index])
            else:
                rest.append(arg)
            index += 1
        return super().parse_args(ctx, prefix + rest)


app = typer.Typer(cls=EverywhereGroup, invoke_without_command=True, no_args_is_help=False,
                  help="Claude gateway FinOps. No command opens the terminal app. Changes preview until --apply.")
groups = {}
for noun in ("budget", "people", "governance", "tier", "requests", "anomalies", "report", "usage", "trends", "catalog"):
    groups[noun] = typer.Typer(help=f"{noun.capitalize()} views and actions.")
    app.add_typer(groups[noun], name=noun)


def emit(ctx, operation, *, mutation=False):
    state = ctx.obj
    try:
        result = operation(state["engine"])
        if mutation and not result.get("preview", True) and result.get("requested_at"):
            if result.get("scope_type") != "user" and state["engine"].backend.name != "Direct":
                result["apply_status"] = state["engine"].wait_for_apply(result["requested_at"])
        display(result, as_json=state["json"], plain=state["plain"], no_color=state["no_color"])
        return result
    except FinOpsError as error:
        display(dict(error=str(error), exit_code=error.code), as_json=state["json"], plain=state["plain"], no_color=True)
        raise typer.Exit(error.code) from None


@app.callback()
def root(ctx: typer.Context,
         backend: Annotated[str | None, typer.Option(help="turnstile, direct or fake")] = None,
         month: str | None = None,
         config: Path | None = None,
         url: str | None = None,
         scope: str | None = None,
         resource_group: str | None = None,
         apim_name: str | None = None,
         theme: str | None = None,
         as_json: Annotated[bool, typer.Option("--json", help="Machine-readable output.")] = False,
         plain: bool = False,
         what_if: Annotated[bool, typer.Option("--what-if", help="Always preview; never write.")] = False,
         no_color: bool = False,
         ascii_only: Annotated[bool, typer.Option("--ascii")] = False):
    try:
        settings = load_config(config, backend=backend, url=url, scope=scope, resource_group=resource_group,
                               apim_name=apim_name, theme=theme, ascii=True if ascii_only else None)
        engine = Engine(connect(settings), month)
    except FinOpsError as error:
        display(dict(error=str(error), exit_code=error.code), as_json=as_json, plain=plain, no_color=True)
        raise typer.Exit(error.code) from None
    ctx.obj = dict(engine=engine, config=settings, json=as_json, plain=plain, what_if=what_if, no_color=no_color)
    ctx.call_on_close(engine.backend.close)
    if ctx.invoked_subcommand is None:
        if plain or as_json:
            emit(ctx, lambda e: dict(identity=e.read("whoami"), **e.status()))
        else:
            from .tui import FinOpsApp
            FinOpsApp(engine, settings, no_color=no_color).run()


@app.command()
def whoami(ctx: typer.Context):
    """Show authenticated identity, role and any server-provided management scope."""
    emit(ctx, lambda e: e.read("whoami"))


@app.command()
def status(ctx: typer.Context, unit: str | None = None):
    """Show month usage, budgets and gateway apply status."""
    def operation(engine):
        result = engine.status()
        if unit:
            result["budgets"]["items"] = [row for row in result["budgets"]["items"]
                                          if row["scope_id"] == unit or row.get("parent_scope_id") == unit]
            result["overview"] = engine.read("overview", organization_id=unit)
        return result
    emit(ctx, operation)


@groups["budget"].command("list")
def budget_list(ctx: typer.Context):
    emit(ctx, lambda e: e.read("budgets"))


@groups["budget"].command("set")
def budget_set(ctx: typer.Context, kind: str, name: str, amount: str, apply: bool = False,
               confirm: str | None = None, warning: int | None = None, team: str | None = None):
    """Set monthly tokens (2M, 1500). Preview by default; lowering below usage needs --confirm."""
    emit(ctx, lambda e: e.budget_change(kind, name, amount, apply=apply and not ctx.obj["what_if"],
                                       confirm=confirm, warning=warning, department_id=team), mutation=True)


@groups["budget"].command("remove")
def budget_remove(ctx: typer.Context, kind: str, name: str, apply: bool = False,
                  confirm: str | None = None, team: str | None = None):
    emit(ctx, lambda e: e.budget_change(kind, name, remove=True, apply=apply and not ctx.obj["what_if"],
                                       confirm=confirm, department_id=team), mutation=True)


@groups["people"].command("find")
def people_find(ctx: typer.Context, query: Annotated[str, typer.Argument()] = "", team: Annotated[str, typer.Option()] = "",
                offset: Annotated[int, typer.Option(min=0)] = 0,
                limit: Annotated[int, typer.Option(min=1, max=200)] = 50):
    """Search one team's people on the server. Never downloads the directory."""
    def operation(engine):
        if not team:
            raise FinOpsError("Choose --team <team-id>. Run governance show to find a team.")
        if len(query) > 200:
            raise FinOpsError("Search text must not exceed 200 characters.")
        return engine.read("people", department_id=team, query=query, offset=offset, limit=limit)
    emit(ctx, operation)


@groups["governance"].command("show")
def governance_show(ctx: typer.Context):
    emit(ctx, lambda e: e.governance())


@groups["governance"].command("apply")
def governance_apply(ctx: typer.Context, apply: bool = False):
    """Preview or start the configured apply job and follow its execution."""
    emit(ctx, lambda e: e.apply(apply=apply and not ctx.obj["what_if"]), mutation=True)


@groups["tier"].command("show")
def tier_show(ctx: typer.Context):
    emit(ctx, lambda e: e.read("tiers"))


@groups["tier"].command("set")
def tier_set(ctx: typer.Context, name: str, per_minute: str | None = None, per_day: str | None = None,
             models: str | None = None, apply: bool = False):
    emit(ctx, lambda e: e.tier_change(name, per_minute, per_day, models, apply=apply and not ctx.obj["what_if"]), mutation=True)


@groups["catalog"].command("set")
def catalog_set(ctx: typer.Context, kind: str, key: str, name: str | None = None,
                group: str | None = None, manager_group: str | None = None, parent: str | None = None,
                apply: bool = False):
    """Add or edit a unit/team, preserving the rest of the complete catalog."""
    emit(ctx, lambda e: e.catalog_change(kind, key, name=name, group=group, manager_group=manager_group,
                                         parent=parent, apply=apply and not ctx.obj["what_if"]), mutation=True)


@groups["catalog"].command("remove")
def catalog_remove(ctx: typer.Context, kind: str, key: str, apply: bool = False, confirm: str | None = None):
    emit(ctx, lambda e: e.catalog_change(kind, key, remove=True, confirm=confirm,
                                         apply=apply and not ctx.obj["what_if"]), mutation=True)


@groups["requests"].command("list")
def requests_list(ctx: typer.Context, limit: Annotated[int, typer.Option(min=1, max=200)] = 50,
                  before: str | None = None, unit: str | None = None, team: str | None = None,
                  model: str | None = None, person: str | None = None):
    """List a bounded request window; --before selects older requests."""
    emit(ctx, lambda e: e.read("requests", limit=limit, before=before, organization_id=unit,
                               department_id=team, model_id=model, user_id=person))


@groups["requests"].command("show")
def requests_show(ctx: typer.Context, request_id: str):
    emit(ctx, lambda e: e.read("request", request_id=request_id))


@groups["anomalies"].command("list")
def anomalies_list(ctx: typer.Context, limit: Annotated[int, typer.Option(min=1, max=200)] = 50):
    emit(ctx, lambda e: e.read("anomalies", limit=limit))


@groups["usage"].command("show")
def usage_show(ctx: typer.Context, dimension: str = "organization", split_by: str | None = None):
    """Pivot organization, department, user, model or runtime; optionally split a row."""
    emit(ctx, lambda e: e.read("distribution", dimension=dimension, split_by=split_by, limit=100))


@groups["trends"].command("show")
def trends_show(ctx: typer.Context, interval: str = "day", group_by: str = "none"):
    emit(ctx, lambda e: e.read("trends", interval=interval, group_by=group_by))


@groups["report"].command("chargeback")
def report_chargeback(ctx: typer.Context, csv: Annotated[bool, typer.Option("--csv")] = False,
                     dimension: str = "organization"):
    """Export estimated cost, tokens and cache. Not an Azure invoice."""
    if csv and not ctx.obj["json"]:
        try:
            rows = ctx.obj["engine"].read("distribution", dimension=dimension, limit=100)["items"]
            typer.echo(chargeback_csv(rows, ctx.obj["engine"].month), nl=False)
        except FinOpsError as error:
            typer.echo(str(error), err=True)
            raise typer.Exit(error.code) from None
    else:
        emit(ctx, lambda e: e.read("distribution", dimension=dimension, limit=100))


def main():
    app()


if __name__ == "__main__":
    main()
