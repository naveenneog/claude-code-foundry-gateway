"""The local configuration wizard; Azure discovery is read-only."""

from contextlib import nullcontext
from dataclasses import replace

import typer

from .discovery import discover
from .config import Config
from .errors import FinOpsError
from .output import display
from .guarded_publication import guarded_publish
from .publication_output import (
    confirm_profile_replace, preview_profile, profile_path, prompt_number, save_profile, write_text,
)


def connection_config(config: Config) -> Config:
    config.validate()
    if config.backend in {"aum-service", "turnstile"} and (config.url or config.scope):
        if not config.url or not config.scope:
            raise FinOpsError("An HTTP connection needs both URL and scope.", 2)
        return config
    if config.backend == "fake":
        return config
    result = discover(backend=config.backend, subscription=config.subscription or None,
                      resource_group=config.resource_group or None, apim_name=config.apim_name or None,
                      workspace=config.workspace_resource_id or None, interactive=False)
    return replace(config, **result["config"]).validate()


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
        if options["url"] or options["scope"]:
            selected = Config(backend=options["backend"] or "turnstile", url=options["url"] or "",
                              scope=options["scope"] or "", subscription=options["subscription"] or "",
                              resource_group=options["resource_group"] or "", apim_name=options["apim_name"] or "")
            if selected.backend not in {"aum-service", "turnstile"}:
                raise FinOpsError("URL and scope apply to AUM service or Turnstile connections.", 2)
            result = {"config": connection_config(selected).public(), "portal": {}}
        else:
            result = discover(backend=options["backend"], subscription=options["subscription"],
                              resource_group=options["resource_group"], apim_name=options["apim_name"],
                              workspace=workspace, service_app=service_app, interactive=interactive, picker=pick)
        output = profile_path(options["path"])
        saved = False
        backup = None
        if save and not state["what_if"]:
            config = Config(**result["config"])
            reviewed = preview_profile(config, output)
            with guarded_publish(nullcontext):
                if reviewed.before is not None and not force:
                    if not interactive or not confirm_profile_replace():
                        raise FinOpsError("Profile exists. Choose another --config path, or use --force to replace it.", 6)
                backup = save_profile(output, config, revision=reviewed.revision)
            saved = True
        result = dict(result, saved=saved, profile=output,
                      backup=backup if saved and backup else "",
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
