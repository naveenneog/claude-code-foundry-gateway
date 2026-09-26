from pathlib import Path
import json
import subprocess
import typer

from .errors import FinOpsError
from .bulk import budget_csv_plan
from .ledger import ledger_url
from .output import display


def register(app, groups, emit):
    mode = typer.Typer(rich_markup_mode=None, help="Owner-only enforcement modes.")
    requests = typer.Typer(rich_markup_mode=None, help="Capability-gated budget approvals.")
    boosts = typer.Typer(rich_markup_mode=None, help="Capability-gated expiring boosts.")
    notices = typer.Typer(rich_markup_mode=None, help="Capability-gated notifications.")
    ask = typer.Typer(rich_markup_mode=None, help="FinOps assistant, conversation history and chart pins.")
    advanced = typer.Typer(rich_markup_mode=None, help="Read-only configured model-gateway views.")
    for name, group in (("mode", mode), ("request", requests), ("boost", boosts),
                        ("notifications", notices), ("ask", ask), ("advanced", advanced)):
        app.add_typer(group, name=name)

    @mode.command("show")
    def mode_show(ctx: typer.Context):
        emit(ctx, lambda e: e.read("catalog"))

    @groups["governance"].command("audit")
    def governance_audit(ctx: typer.Context, cursor: str | None = None,
                         limit: int = typer.Option(50, min=1, max=200)):
        """Read the AUM service's server-authorized audit page."""
        emit(ctx, lambda e: e.read("audit", limit=limit, cursor=cursor))

    @mode.command("set")
    def mode_set(ctx: typer.Context, kind: str, key: str, value: str, allowance: int | None = None, apply: bool = False):
        emit(ctx, lambda e: e.mode_change(kind, key, value, allowance, apply=apply and not ctx.obj["what_if"]), mutation=True)

    @groups["budget"].command("import")
    def bulk_import(ctx: typer.Context, csv_file: Path, apply: bool = False):
        emit(ctx, lambda e: budget_csv_plan(e, csv_file, apply=apply and not ctx.obj["what_if"]))

    @groups["people"].command("show")
    def person_show(ctx: typer.Context, person: str, team: str = typer.Option(...)):
        emit(ctx, lambda e: e.person_detail(person, team))

    @groups["people"].command("membership")
    def person_membership(ctx: typer.Context, team: str):
        emit(ctx, lambda e: dict(url=e.membership_url(team), note="Entra enforces existing group-owner rights; AUM does not grant them."))

    @requests.command("list")
    def request_list(ctx: typer.Context, view: str = "mine", cursor: str | None = None):
        emit(ctx, lambda e: e.read("approval_requests", view=view, limit=50, cursor=cursor))

    @requests.command("budget")
    def request_budget(ctx: typer.Context, kind: str, key: str, amount: str, reason: str,
                       until: str | None = None, apply: bool = False):
        emit(ctx, lambda e: e.request_budget(kind, key, amount, reason, expires_at=until,
                                             apply=apply and not ctx.obj["what_if"]), mutation=True)

    for decision in ("approve", "reject", "escalate"):
        def command(ctx: typer.Context, request_id: str, reason: str, apply: bool = False, _decision=decision):
            emit(ctx, lambda e: e.decide_request(request_id, _decision, reason, apply=apply and not ctx.obj["what_if"]), mutation=True)
        # Default capture parameters must not become CLI options.
        import inspect
        command.__signature__ = inspect.signature(command).replace(
            parameters=[p for p in inspect.signature(command).parameters.values() if p.name != "_decision"])
        requests.command(decision)(command)

    @boosts.command("list")
    def boost_list(ctx: typer.Context, cursor: str | None = None):
        emit(ctx, lambda e: e.read("boosts", limit=50, cursor=cursor))

    @boosts.command("set")
    def boost_set(ctx: typer.Context, person: str, team: str, amount: str, until: str, reason: str,
                  window: str = "monthly", apply: bool = False):
        emit(ctx, lambda e: e.boost(person, team, amount, until, reason, window=window,
                                    apply=apply and not ctx.obj["what_if"]), mutation=True)

    @boosts.command("revoke")
    def boost_revoke(ctx: typer.Context, boost_id: str, apply: bool = False):
        emit(ctx, lambda e: e.revoke_boost(boost_id, apply=apply and not ctx.obj["what_if"]), mutation=True)

    @notices.command("list")
    def notification_list(ctx: typer.Context, cursor: str | None = None):
        emit(ctx, lambda e: e.read("notifications", limit=50, cursor=cursor))

    @notices.command("read")
    def notification_read(ctx: typer.Context, notification_id: str, apply: bool = False):
        emit(ctx, lambda e: e.mark_notification(notification_id, apply=apply and not ctx.obj["what_if"]))

    @groups["anomalies"].command("set-status")
    def anomaly_status(ctx: typer.Context, anomaly_id: str, status: str, reason: str, apply: bool = False):
        emit(ctx, lambda e: e.disposition(anomaly_id, status, reason, apply=apply and not ctx.obj["what_if"]))

    @ask.command("query")
    def ask_query(ctx: typer.Context, question: str, conversation: str | None = None):
        if ctx.obj["what_if"]:
            emit(ctx, lambda e: dict(preview=True, action="Ask assistant", question=question))
        else:
            emit(ctx, lambda e: e.ask(question, conversation))

    @ask.command("history")
    def ask_history(ctx: typer.Context):
        emit(ctx, lambda e: e.read("conversations"))

    @ask.command("show")
    def ask_show(ctx: typer.Context, conversation: str):
        emit(ctx, lambda e: e.read("conversation", id=conversation))

    @ask.command("pins")
    def ask_pins(ctx: typer.Context):
        emit(ctx, lambda e: e.read("pinned_charts"))

    @ask.command("settings")
    def ask_settings(ctx: typer.Context):
        emit(ctx, lambda e: e.read("assistant_settings"))

    @ask.command("configure")
    def ask_configure(ctx: typer.Context, model: str | None = None, auto_title: bool = False, apply: bool = False):
        emit(ctx, lambda e: e.configure_assistant(model, auto_title, apply=apply and not ctx.obj["what_if"]))

    @ask.command("pin")
    def ask_pin(ctx: typer.Context, conversation: str, chart: str, title: str, apply: bool = False):
        def run(engine):
            record = engine.read("conversation", id=conversation)
            exchanges = record.get("exchanges", [])
            if not exchanges:
                raise FinOpsError("Conversation has no chart reply to pin.", 5)
            reply = dict(exchanges[-1]["reply"], question=exchanges[-1]["question"])
            return engine.pin_chart(reply, chart, title, apply=apply and not ctx.obj["what_if"])
        emit(ctx, run)

    @advanced.command("show")
    def advanced_show(ctx: typer.Context, view: str = "models", key: str | None = None):
        resources = {"models": "registry", "pools": "backend_pool", "releases": "releases",
                     "release": "release", "diff": "release_diff", "subscriptions": "applications", "application": "application"}
        def run(engine):
            if view not in resources:
                raise FinOpsError("Choose models, pools, releases, release, diff, subscriptions or application.")
            if view in {"pools", "release", "diff", "application"} and not key:
                raise FinOpsError("This view needs --key from its parent list.")
            return engine.read(resources[view], **({"id": key} if key else {}))
        emit(ctx, run)

    @groups["requests"].command("ledger")
    def request_ledger(ctx: typer.Context, request_id: str):
        def run(engine):
            engine.read("request", request_id=request_id)
            config = ctx.obj["config"]
            return dict(url=ledger_url(config.workspace_resource_id, config.tenant_id, request_id, engine.month))
        emit(ctx, run)

    @groups["report"].command("generate")
    def generate_report(ctx: typer.Context, unit: list[str] = typer.Option(None),
                        output: str = "finops-reports", formats: str = "CSV,HTML",
                        month_to_date: bool = False, send: bool = False, apply: bool = False):
        from .reporting import report_plan
        emit(ctx, lambda e: report_plan(e, ctx.obj["config"], units=unit, output=output, formats=formats,
                                        month_to_date=month_to_date, send=send, apply=apply and not ctx.obj["what_if"]))
