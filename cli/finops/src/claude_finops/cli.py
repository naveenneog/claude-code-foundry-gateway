"""Scriptable face; root options also work after a noun or verb."""

from pathlib import Path
import json
import os
import sys
from typing import Annotated

import typer
from typer.core import TyperGroup

from .backend import connect
from .config import load_config
from .engine import Engine
from .errors import FinOpsError
from .output import chargeback_csv, display
from .brand import BANNER, PRODUCT, show_banner
from . import __version__
from .redaction import Redactor


def terminal_output():
    return sys.stdout.isatty()


class EverywhereGroup(TyperGroup):
    def parse_args(self, ctx, args):
        ctx.meta["finops_help"] = "--help" in args
        flags = {"--json", "--plain", "--what-if", "--no-color", "--ascii", "--version", "--screen-reader", "--redact"}
        options = {"--backend", "--month", "--config", "--url", "--scope", "--theme",
                   "--resource-group", "--apim-name", "--subscription", "--reason"}
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


app = typer.Typer(cls=EverywhereGroup, invoke_without_command=True, no_args_is_help=False, rich_markup_mode=None,
                  help="AUM - Azure Usage Management. No command opens the terminal app. Changes preview until --apply.")
groups = {}
for noun in ("budget", "usd", "people", "developer", "governance", "tier", "requests", "anomalies", "report", "usage", "trends", "catalog"):
    groups[noun] = typer.Typer(help=f"{noun.capitalize()} views and actions.", rich_markup_mode=None)
    app.add_typer(groups[noun], name=noun)


def emit(ctx, operation, *, mutation=False):
    state = ctx.obj
    try:
        result = operation(state["engine"])
        if mutation and not result.get("preview", True) and result.get("requested_at"):
            if result.get("scope_type") != "user" and not state["engine"].backend.immediate_writes:
                result["apply_status"] = state["engine"].wait_for_apply(result["requested_at"])
        display(state["redactor"].present(result), as_json=state["json"], plain=state["plain"], no_color=state["no_color"])
        return result
    except FinOpsError as error:
        display(state["redactor"].present(dict(error=str(error), exit_code=error.code)),
                as_json=state["json"], plain=state["plain"], no_color=True)
        raise typer.Exit(error.code) from None


@app.callback()
def root(ctx: typer.Context,
         backend: Annotated[str | None, typer.Option(help="direct, aum-service, turnstile or fake")] = None,
         month: str | None = None,
         config: Path | None = None,
         url: str | None = None,
         scope: str | None = None,
         subscription: str | None = None,
         reason: Annotated[str | None, typer.Option(help="Audit reason for native AUM service budget/configuration changes.")] = None,
         resource_group: str | None = None,
         apim_name: str | None = None,
         theme: str | None = None,
         as_json: Annotated[bool, typer.Option("--json", help="Machine-readable output.")] = False,
         plain: bool = False,
         what_if: Annotated[bool, typer.Option("--what-if", help="Always preview; never write.")] = False,
         no_color: bool = False,
         version: Annotated[bool, typer.Option("--version", help="Show AUM version without connecting.")] = False,
         screen_reader: Annotated[bool, typer.Option("--screen-reader", help="Use linear output without banner or screen UI.")] = False,
         redact: Annotated[bool, typer.Option("--redact", help="Display Contoso pseudonyms; never alters API requests.")] = False,
         ascii_only: Annotated[bool, typer.Option("--ascii")] = False):
    if ctx.meta.get("finops_help"):
        return
    plain = plain or screen_reader
    if version:
        if show_banner(tty=terminal_output(), as_json=as_json, plain=plain, screen_reader=screen_reader):
            typer.echo(BANNER)
        if as_json:
            display(dict(product=PRODUCT, version=__version__), as_json=True)
        else:
            typer.echo(f"{PRODUCT} {__version__}")
        raise typer.Exit()
    redact = redact or os.environ.get("AUM_REDACT", "").lower() in {"1", "true", "yes"}
    if ctx.invoked_subcommand == "configure":
        ctx.obj = dict(configure=dict(backend=backend, subscription=subscription, resource_group=resource_group,
                                     apim_name=apim_name, path=config), tty=terminal_output(),
                       json=as_json, plain=plain, what_if=what_if, no_color=no_color, redactor=Redactor(redact))
        return
    try:
        settings = load_config(config, backend=backend, url=url, scope=scope, resource_group=resource_group,
                               apim_name=apim_name, subscription=subscription, theme=theme, ascii=True if ascii_only else None)
        engine = Engine(connect(settings), month)
        engine.change_reason = reason or ""
    except FinOpsError as error:
        display(dict(error=str(error), exit_code=error.code), as_json=as_json, plain=plain, no_color=True)
        raise typer.Exit(error.code) from None
    ctx.obj = dict(engine=engine, config=settings, json=as_json, plain=plain, what_if=what_if, no_color=no_color,
                   redactor=Redactor(redact))
    ctx.call_on_close(engine.backend.close)
    if ctx.invoked_subcommand is None:
        if plain or as_json or not terminal_output():
            ctx.obj["plain"] = plain or not terminal_output()
            emit(ctx, lambda e: dict(identity=e.read("whoami"), **e.status()))
        else:
            from .tui import FinOpsApp
            FinOpsApp(engine, settings, no_color=no_color, preview_only=what_if, redact=redact).run()


@app.command()
def whoami(ctx: typer.Context):
    """Show authenticated identity, role and any server-provided management scope."""
    emit(ctx, lambda e: e.read("whoami"))


@app.command()
def lookup(ctx: typer.Context, query: str, team: str | None = None):
    """Find units, teams, models and request ids; select a team for bounded people lookup."""
    emit(ctx, lambda e: dict(items=e.lookup(query, team)))


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


@groups["usd"].command("list")
def usd_list(ctx: typer.Context):
    """List authored USD budgets. Unsupported backends fail closed."""
    emit(ctx, lambda e: e.read("usd_budgets"))


@groups["usd"].command("status")
def usd_status(ctx: typer.Context):
    """Show reconciled USD spend, completeness and stop state."""
    emit(ctx, lambda e: e.usd_status())


@groups["usd"].command("set")
def usd_set(ctx: typer.Context, kind: str, name: str, amount: str,
            period: Annotated[str, typer.Option(help="month for units/teams; day or month for people")] = "month",
            apply: bool = False, confirm: str | None = None):
    """Set a dollar budget. Preview by default; zero is a real stop."""
    emit(ctx, lambda e: e.usd_budget_change(kind, name, amount, period=period,
                                            apply=apply and not ctx.obj["what_if"], confirm=confirm),
         mutation=True)


@groups["usd"].command("clear")
def usd_clear(ctx: typer.Context, kind: str, name: str, apply: bool = False,
              confirm: str | None = None):
    """Clear a dollar budget after typed confirmation."""
    emit(ctx, lambda e: e.usd_budget_change(kind, name, remove=True,
                                            apply=apply and not ctx.obj["what_if"], confirm=confirm),
         mutation=True)


@groups["usd"].command("reconcile")
def usd_reconcile(ctx: typer.Context, apply: bool = False):
    """Run the gateway USD reconciler on demand. Preview by default."""
    emit(ctx, lambda e: e.usd_reconcile(apply=apply and not ctx.obj["what_if"]), mutation=True)


price_book = typer.Typer(help="USD price-book administration.", rich_markup_mode=None)
groups["usd"].add_typer(price_book, name="price-book")


@price_book.command("show")
def usd_price_book_show(ctx: typer.Context):
    emit(ctx, lambda e: e.read("usd_price_book"))


@price_book.command("set")
def usd_price_book_set(ctx: typer.Context, file: Path, apply: bool = False):
    """Replace the price book from a JSON file. Active budgets pin their tariff."""
    def operation(engine):
        try:
            book = json.loads(file.read_text(encoding="utf-8"))
        except (OSError, ValueError) as error:
            raise FinOpsError("Read a JSON price-book file before applying.") from error
        return engine.usd_price_book_change(book, apply=apply and not ctx.obj["what_if"])
    emit(ctx, operation, mutation=True)


@groups["people"].command("find")
def people_find(ctx: typer.Context, query: Annotated[str, typer.Argument()] = "", team: Annotated[str, typer.Option()] = "",
                offset: Annotated[int, typer.Option(min=0)] = 0,
                limit: Annotated[int, typer.Option(min=1, max=200)] = 50, cursor: str | None = None):
    """Search one team's people on the server. Never downloads the directory."""
    def operation(engine):
        if not team and not engine.has_feature("people_cursor"):
            raise FinOpsError("Choose --team <team-id>. Run governance show to find a team.")
        if len(query) > 200:
            raise FinOpsError("Search text must not exceed 200 characters.")
        return engine.read("people", **engine.backend.people_filter(team), query=query, offset=offset, limit=limit, cursor=cursor)
    emit(ctx, operation)


@groups["developer"].command("find")
def developer_find(ctx: typer.Context, query: str, cursor: str | None = None,
                   limit: Annotated[int, typer.Option(min=1, max=100)] = 50):
    """Search the Entra directory for a developer by email, UPN or display name."""
    from .developer_actions import developer_find as find
    emit(ctx, lambda e: find(e, ctx.obj["config"], query, limit=limit, cursor=cursor))


@groups["developer"].command("add")
def developer_add(ctx: typer.Context, user: str, tier: Annotated[str, typer.Option()] = "",
                  unit: Annotated[str, typer.Option(help="Gateway unit or team id.")] = "",
                  apply: bool = False):
    """Add a developer to one discovered tier group and optional unit/team group."""
    from .developer_actions import developer_change
    emit(ctx, lambda e: developer_change(e, ctx.obj["config"], user, tier=tier, unit=unit or None,
                                        apply=apply and not ctx.obj["what_if"]), mutation=True)


@groups["developer"].command("remove")
def developer_remove(ctx: typer.Context, user: str, apply: bool = False, confirm: str = ""):
    """Remove direct tier and catalog unit/team memberships; type resolved UPN to apply."""
    from .developer_actions import developer_change
    emit(ctx, lambda e: developer_change(e, ctx.obj["config"], user, remove=True,
                                        apply=apply and not ctx.obj["what_if"], confirm=confirm), mutation=True)


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
                  model: str | None = None, person: str | None = None, cursor: str | None = None):
    """List a bounded request window; --before selects older requests."""
    emit(ctx, lambda e: e.read("requests", limit=limit, before=before, organization_id=unit,
                               department_id=team, model_id=model, user_id=person, cursor=cursor))


@groups["requests"].command("show")
def requests_show(ctx: typer.Context, request_id: str):
    emit(ctx, lambda e: e.read("request", request_id=request_id))


@groups["anomalies"].command("list")
def anomalies_list(ctx: typer.Context, limit: Annotated[int, typer.Option(min=1, max=200)] = 50,
                   unit: str | None = None, team: str | None = None, person: str | None = None,
                   model: str | None = None, surface: str | None = None, tier: str | None = None):
    emit(ctx, lambda e: e.read("anomalies", limit=limit, organization_id=unit, department_id=team,
                               user_id=person, model_id=model, runtime=surface, tier=tier))


@groups["usage"].command("show")
def usage_show(ctx: typer.Context, dimension: str = "organization", split_by: str | None = None,
               unit: str | None = None, team: str | None = None, person: str | None = None,
               model: str | None = None, surface: str | None = None, tier: str | None = None,
               basis: str | None = None):
    """Pivot organization, department, user, model, runtime or tier; optionally split a row."""
    def read(engine):
        if basis and (engine.backend.name != "Direct" or basis not in {"ledger", "priced"}):
            raise FinOpsError("Explicit basis is Direct-only: ledger or priced.")
        return engine.read("distribution", dimension=dimension, split_by=split_by, limit=100,
                               organization_id=unit, department_id=team, user_id=person,
                               model_id=model, runtime=surface, tier=tier, **({"basis": basis} if basis else {}))
    emit(ctx, read)


@groups["trends"].command("show")
def trends_show(ctx: typer.Context, interval: str = "day", group_by: str = "none",
                compare: str | None = None, start: str | None = None, end: str | None = None,
                unit: str | None = None, team: str | None = None, person: str | None = None,
                model: str | None = None, surface: str | None = None, tier: str | None = None):
    filters = dict(organization_id=unit, department_id=team, user_id=person, model_id=model, runtime=surface, tier=tier)
    emit(ctx, lambda e: e.compare_trends(compare, interval=interval, group_by=group_by, **filters) if compare else
         e.read("trends", interval=interval, group_by=group_by, **filters, **{"from": start, "to": end}))


@groups["report"].command("chargeback")
def report_chargeback(ctx: typer.Context, csv: Annotated[bool, typer.Option("--csv")] = False,
                     dimension: str = "organization"):
    """Export estimated cost, tokens and cache. Not an Azure invoice."""
    if csv and not ctx.obj["json"]:
        try:
            rows = ctx.obj["engine"].chargeback(dimension)["items"]
            typer.echo(chargeback_csv(ctx.obj["redactor"].present(rows), ctx.obj["engine"].month), nl=False)
        except FinOpsError as error:
            typer.echo(str(error), err=True)
            raise typer.Exit(error.code) from None
    else:
        emit(ctx, lambda e: e.chargeback(dimension))


def main():
    app()


from .configure import configure
app.command()(configure)
from .commands_v4 import register
register(app, groups, emit)
from .commands_local import register as register_local
register_local(app, groups, emit)
from .commands_groups import register as register_groups
register_groups(app, groups, emit)


def legacy_main():
    typer.echo("Deprecated: claude-finops is now aum (AUM - Azure Usage Management); this alias remains for one release.", err=True)
    main()


if __name__ == "__main__":
    main()
