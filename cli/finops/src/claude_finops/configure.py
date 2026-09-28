"""The local configuration wizard; Azure discovery is read-only."""

import json
from pathlib import Path
from contextlib import nullcontext
from datetime import datetime, timezone

import typer

from .discovery import discover
from .errors import FinOpsError
from .output import display
from .guarded_publication import guarded_publish


def backup_profile(path: Path) -> Path:
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    backup = path.with_name(f"{path.stem}.{stamp}.bak{path.suffix}")
    index = 1
    while backup.exists():
        backup = path.with_name(f"{path.stem}.{stamp}-{index}.bak{path.suffix}")
        index += 1
    backup.write_text(path.read_text(encoding="utf-8"), encoding="utf-8")
    return backup


def configure(ctx: typer.Context, workspace: str | None = None, save: bool = False,
              force: bool = False, no_prompt: bool = False, service_app: str | None = None):
    """Discover accessible Azure targets; --save writes an address-only local profile."""
    state = ctx.obj
    options = state["configure"]
    interactive = state["tty"] and not (no_prompt or state["json"] or state["plain"])

    def pick(label, rows, default):
        typer.echo(f"\nChoose {label}:")
        for index, row in enumerate(rows):
            shown = state["redactor"].present(row)
            extra = f" ({shown.get('location', '')}; {shown.get('sku', {}).get('name', '')})" if row.get("sku") else ""
            typer.echo(f"  {index + 1}. {shown.get('name', shown['id'])}{extra}")
        choice = typer.prompt("Number", default=default + 1, type=int)
        return choice - 1

    try:
        result = discover(backend=options["backend"], subscription=options["subscription"],
                          resource_group=options["resource_group"], apim_name=options["apim_name"],
                          workspace=workspace, service_app=service_app, interactive=interactive, picker=pick)
        output = options["path"] or Path.home() / ".aum" / "config.json"
        saved = False
        backup = None
        if save and not state["what_if"]:
            if output.exists() and not force:
                if not interactive:
                    raise FinOpsError("Profile exists. Choose another --config path, or use --force to replace it.", 6)
                replace = typer.confirm("Profile exists. Replace it and keep a timestamped backup?", default=True)
                if not replace:
                    raise FinOpsError("Profile exists. Choose another --config path, or use --force to replace it.", 6)
            output.parent.mkdir(parents=True, exist_ok=True)
            backup = backup_profile(output) if output.exists() else None
            output.write_text(json.dumps(result["config"], indent=2) + "\n", encoding="utf-8")
            saved = True
        result.update(saved=saved, profile=str(output),
                      backup=str(backup) if saved and backup else "",
                      note="No Azure resource was changed. Use --save to write this local profile." if not saved
                      else "Saved addresses only. Run aum --config with this profile to verify whoami.")
        # Discovery publishes address metadata before any backend session exists.
        with guarded_publish(nullcontext):
            display(state["redactor"].present(result), as_json=state["json"], plain=state["plain"], no_color=state["no_color"])
    except (FinOpsError, OSError) as error:
        code = error.code if isinstance(error, FinOpsError) else 7
        text = str(error) if isinstance(error, FinOpsError) else "Cannot write the local profile. Choose a writable --config path."
        with guarded_publish(nullcontext):
            display(dict(error=text, exit_code=code), as_json=state["json"], plain=state["plain"], no_color=True)
        raise typer.Exit(code) from None
