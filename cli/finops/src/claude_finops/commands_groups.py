import typer

from .group_actions import group_call, membership_refresh


def register(app, groups, emit):
    group = typer.Typer(rich_markup_mode=None, help="Delegated Entra security groups; existing admin rights, no consent changes.")
    app.add_typer(group, name="group")

    @groups["requests"].command("probe")
    def probe(ctx: typer.Context, model: str = "claude-sonnet-5", apply: bool = False):
        """Preview/send one tiny real request through the discovered gateway."""
        from .gateway_probe import tiny_request
        emit(ctx, lambda e: tiny_request(ctx.obj["config"], model, apply=apply and not ctx.obj["what_if"]))

    @group.command("find")
    def find(ctx: typer.Context, query: str, cursor: str | None = None, limit: int = typer.Option(50, min=1, max=100)):
        emit(ctx, lambda e: group_call(e, "search", query, limit=limit, cursor=cursor))

    @group.command("create")
    def create(ctx: typer.Context, name: str, description: str = "", apply: bool = False, confirm: str = ""):
        emit(ctx, lambda e: group_call(e, "create", name, description,
                                      apply=apply and not ctx.obj["what_if"], confirm=confirm))

    @group.command("delete")
    def delete(ctx: typer.Context, group_id: str, name: str, apply: bool = False, confirm: str = ""):
        emit(ctx, lambda e: group_call(e, "delete", group_id, name, apply=apply and not ctx.obj["what_if"], confirm=confirm))

    @group.command("member")
    def member(ctx: typer.Context, group_id: str, member_id: str | None = None, remove: bool = False, apply: bool = False):
        """Add/remove a member of a group you own. Omitted member means the signed-in person."""
        emit(ctx, lambda e: group_call(e, "member", group_id, member_id, remove=remove, apply=apply and not ctx.obj["what_if"]))

    @groups["governance"].command("refresh-membership")
    def refresh(ctx: typer.Context, scope: list[str] = typer.Option(...), apply: bool = False, allow_reassignment: bool = False):
        emit(ctx, lambda e: membership_refresh(e, scope, apply=apply and not ctx.obj["what_if"],
                                              allow_reassignment=allow_reassignment))

    @groups["governance"].command("publish-as-admin")
    def publish(ctx: typer.Context, apply: bool = False):
        """Explicit delegated Graph/ARM publication; not the background service's identity."""
        from .group_actions import publish_as_signed_in_admin
        emit(ctx, lambda e: publish_as_signed_in_admin(e, ctx.obj["config"], apply=apply and not ctx.obj["what_if"]))
