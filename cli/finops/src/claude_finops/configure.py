"""The local configuration wizard; Azure discovery is read-only."""

from contextlib import nullcontext

import typer

from .discovery import discover
from .errors import FinOpsError
from .output import display
from .guarded_publication import guarded_publish
from .publication_output import profile_path, prompt_number, write_profile, write_text


def configure(ctx: typer.Context, workspace: str | None = None, save: bool = False,
              force: bool = False, no_prompt: bool = False, service_app: str | None = None):
    """Discover accessible Azure targets; --save writes an address-only local profile."""
    state = ctx.obj
    options = state["configure"]
    interactive = state["tty"] and not (no_prompt or state["json"] or state["plain"])

    def pick(label, rows, default):
        with guarded_publish(nullcontext):
            write_text(f"\nChoose {label}:")
            for index, row in enumerate(rows):
                shown = state["redactor"].present(row)
                extra = f" ({shown.get('location', '')}; {shown.get('sku', {}).get('name', '')})" if row.get("sku") else ""
                write_text(f"  {index + 1}. {shown.get('name', shown['id'])}{extra}")
            choice = prompt_number("Number", default=default + 1)
        return choice - 1

    try:
        result = discover(backend=options["backend"], subscription=options["subscription"],
                          resource_group=options["resource_group"], apim_name=options["apim_name"],
                          workspace=workspace, service_app=service_app, interactive=interactive, picker=pick)
        output = profile_path(options["path"])
        saved = False
        if save and not state["what_if"]:
            with guarded_publish(nullcontext):
                write_profile(output, result["config"], force=force)
            saved = True
        result = dict(result, saved=saved, profile=output,
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
