"""The local configuration wizard; Azure discovery is read-only."""

import json
import hashlib
import errno
import os
from pathlib import Path
from contextlib import contextmanager, nullcontext
from dataclasses import dataclass, replace
from datetime import datetime, timezone
from uuid import uuid4

import typer

from .discovery import discover
from .config import Config, profile_path
from .errors import FinOpsError
from .output import display
from .guarded_publication import guarded_publish


def profile_bytes(config: Config) -> bytes:
    return (json.dumps(config.validate().public(), indent=2) + "\n").encode("utf-8")


def read_profile(path: Path) -> bytes | None:
    try:
        return path.read_bytes()
    except FileNotFoundError:
        return None


def content_revision(content: bytes | None) -> str:
    return hashlib.sha256(content).hexdigest() if content is not None else ""


@dataclass(frozen=True)
class ProfileChange:
    path: Path
    before: bytes | None
    content: bytes

    @property
    def revision(self) -> str:
        return content_revision(self.before)

    def configuration(self) -> Config:
        return Config(**json.loads(self.content)).validate()


@contextmanager
def profile_lock(path: Path):
    path.parent.mkdir(parents=True, exist_ok=True)
    # The inode stays in place; closing the OS handle releases the writer lock.
    with path.with_name(f".{path.name}.lock").open("a+b") as handle:
        try:
            if os.name == "nt":
                import msvcrt
                handle.seek(0)
                msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as error:
            if error.errno in {errno.EACCES, errno.EAGAIN, errno.EDEADLK}:
                raise FinOpsError("Another AUM process is changing this profile. No file was replaced; retry after it finishes (usually 3-10 s).", 6) from None
            raise
        yield


def profile_conflict(path: Path, revision: str, before: bytes | None, current: bytes | None) -> FinOpsError:
    actual = content_revision(current)
    changed = "file bytes"
    try:
        prior, latest = json.loads(before or b"{}"), json.loads(current or b"{}")
        if isinstance(prior, dict) and isinstance(latest, dict):
            fields = [field for field in Config.__dataclass_fields__ if prior.get(field) != latest.get(field)]
            changed = ", ".join(fields) or "formatting or other file bytes"
        else:
            changed = "JSON shape"
    except (ValueError, UnicodeError):
        changed = "JSON encoding or content"
    return FinOpsError(f"The profile changed since preview: {path}. Changed fields: {changed}. "
                       f"Reviewed revision: {revision or 'missing'}; current revision: {actual or 'missing'}. "
                       "No newer file was overwritten. Preview the connection again.", 6)


def require_profile_revision(path: Path, revision: str, before: bytes | None = None):
    current = read_profile(path)
    if content_revision(current) != revision:
        raise profile_conflict(path, revision, before, current)


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
    return content_revision(read_profile(path))


def replace_profile(path: Path, content: bytes):
    temporary = path.with_name(f".{path.name}.{uuid4().hex}.tmp")
    try:
        with temporary.open("xb") as stream:
            stream.write(content)
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def _save_profile_locked(path: Path, content: bytes, revision: str, before: bytes | None) -> Path | None:
    require_profile_revision(path, revision, before)
    backup = backup_profile(path) if path.exists() else None
    require_profile_revision(path, revision, before)
    replace_profile(path, content)
    return backup


def save_profile(path: Path, config: Config, *, revision: str | None = None) -> Path | None:
    content = profile_bytes(config)
    with profile_lock(path):
        before = read_profile(path)
        expected = content_revision(before) if revision is None else revision
        return _save_profile_locked(path, content, expected, before)


def recovery_instructions(path: Path, backup: Path | None) -> str:
    action = (f"copy the backup {backup} over {path}" if backup is not None else
              f"remove the unverified new profile {path} (no previous file existed)")
    return (f"Backup: {backup or 'no previous file'}. Recovery: Close the application holding the profile; "
            f"{action}; then reopen AUM with the previous connection and verify whoami.")


@contextmanager
def profile_transaction(path: Path, config: Config, revision: str, *, reviewed: ProfileChange | None = None):
    content = reviewed.content if reviewed is not None else profile_bytes(config)
    written_revision = content_revision(content)
    before = reviewed.before if reviewed is not None else None
    with profile_lock(path):
        backup = _save_profile_locked(path, content, revision, before)
        completed = False
        try:
            yield backup
            require_profile_revision(path, written_revision, content)
            completed = True
        finally:
            if not completed:
                try:
                    if profile_revision(path) != written_revision:
                        raise FinOpsError(f"The profile changed while connecting; no newer file was overwritten. "
                                          f"Backup: {backup or 'no previous file'}. The previous live connection is unchanged.", 6)
                    if backup is None:
                        path.unlink()
                    else:
                        replace_profile(path, backup.read_bytes())
                except OSError:
                    raise FinOpsError("The previous profile could not be restored. "
                                      + recovery_instructions(path, backup)
                                      + " The previous live connection is unchanged.", 7) from None


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
            revision = profile_revision(output)
            if output.exists() and not force:
                if not interactive:
                    raise FinOpsError("Profile exists. Choose another --config path, or use --force to replace it.", 6)
                confirmed = typer.confirm("Profile exists. Replace it and keep a timestamped backup?", default=False)
                if not confirmed:
                    raise FinOpsError("Profile exists. Choose another --config path, or use --force to replace it.", 6)
            backup = save_profile(output, Config(**result["config"]), revision=revision)
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
