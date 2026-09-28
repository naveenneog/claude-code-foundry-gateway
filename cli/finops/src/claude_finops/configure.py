"""The local configuration wizard; Azure discovery is read-only."""

import json
import hashlib
from pathlib import Path
from contextlib import contextmanager, nullcontext
from dataclasses import replace
from datetime import datetime, timezone
from uuid import uuid4

import typer

from .discovery import discover
from .config import Config, profile_path
from .errors import FinOpsError
from .output import display
from .guarded_publication import guarded_publish


def backup_profile(path: Path) -> Path:
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    content = path.read_bytes()
    index = 0
    while True:
        suffix = f"-{index}" if index else ""
        backup = path.with_name(f"{path.stem}.{stamp}{suffix}.bak{path.suffix}")
        try:
            with backup.open("xb") as stream:
                stream.write(content)
            return backup
        except FileExistsError:
            index += 1


def profile_revision(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest() if path.exists() else ""


def replace_profile(path: Path, content: bytes):
    temporary = path.with_name(f".{path.name}.{uuid4().hex}.tmp")
    try:
        with temporary.open("xb") as stream:
            stream.write(content)
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def save_profile(path: Path, config: Config) -> Path | None:
    config.validate()
    path.parent.mkdir(parents=True, exist_ok=True)
    backup = backup_profile(path) if path.exists() else None
    replace_profile(path, (json.dumps(config.public(), indent=2) + "\n").encode("utf-8"))
    return backup


@contextmanager
def profile_transaction(path: Path, config: Config, revision: str):
    if profile_revision(path) != revision:
        raise FinOpsError("The profile changed since preview. Preview the connection again.", 6)
    backup = save_profile(path, config)
    written_revision = profile_revision(path)
    completed = False
    try:
        yield backup
        if profile_revision(path) != written_revision:
            raise FinOpsError("The profile changed while connecting; the newer file was not overwritten.", 6)
        completed = True
    finally:
        if not completed:
            try:
                if profile_revision(path) != written_revision:
                    raise FinOpsError(f"The profile changed while connecting; no newer file was overwritten. Backup: {backup or 'no previous file'}.", 6)
                if backup is None:
                    path.unlink()
                else:
                    replace_profile(path, backup.read_bytes())
            except OSError:
                raise FinOpsError(f"The previous profile could not be restored. Backup: {backup or 'no previous file'}. The previous live connection is unchanged.", 7) from None


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
        typer.echo(f"\nChoose {label}:")
        for index, row in enumerate(rows):
            shown = state["redactor"].present(row)
            extra = f" ({shown.get('location', '')}; {shown.get('sku', {}).get('name', '')})" if row.get("sku") else ""
            typer.echo(f"  {index + 1}. {shown.get('name', shown['id'])}{extra}")
        choice = typer.prompt("Number", default=default + 1, type=int)
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
            if output.exists() and not force:
                if not interactive:
                    raise FinOpsError("Profile exists. Choose another --config path, or use --force to replace it.", 6)
                confirmed = typer.confirm("Profile exists. Replace it and keep a timestamped backup?", default=False)
                if not confirmed:
                    raise FinOpsError("Profile exists. Choose another --config path, or use --force to replace it.", 6)
            backup = save_profile(output, Config(**result["config"]))
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
