"""Final terminal, file and clipboard writes require a current publication."""

from pathlib import Path
from contextlib import contextmanager, nullcontext
from dataclasses import dataclass
from datetime import datetime, timezone
import errno
import hashlib
import json
import os
import subprocess
import sys
from uuid import uuid4

from rich.console import Console
from rich.console import RenderableType
import typer

from .config import Config, profile_path as selected_profile_path
from .guarded_publication import enclosing_publication, guarded_publish, publication_sink
from .errors import FinOpsError


def terminal_output():
    return sys.stdout.isatty()


def profile_path(path=None):
    return str(selected_profile_path(path))


def read_text(path):
    return Path(path).read_text(encoding="utf-8")


@publication_sink
def write_text(text: str, *, nl: bool = True, err: bool = False):
    typer.echo(text, nl=nl, err=err)


@publication_sink
def write_renderable(console: Console | None, value: RenderableType, *, no_color=False):
    target = console if console is not None else Console(no_color=no_color, highlight=False)
    target.print(value)


@publication_sink
def write_export(path: Path | str, content: str, *, create_parents=False, overwrite=False, directory=None):
    target = Path(directory) / path if directory is not None else Path(path)
    if create_parents or directory is not None:
        target.parent.mkdir(parents=True, exist_ok=True)
    with target.open("w" if overwrite else "x", encoding="utf-8", newline="") as stream:
        stream.write(content)


@publication_sink
def write_profile(path, document, *, force=False):
    try:
        write_export(path, json.dumps(document, indent=2) + "\n", create_parents=True, overwrite=force)
    except FileExistsError:
        raise FinOpsError("Profile exists. Choose another --config path, or use --force to replace it.", 6) from None


@publication_sink
def prompt_number(label: str, *, default: int):
    return typer.prompt(label, default=default, type=int)


@publication_sink
def copy_with_helper(command: list[str], text: str):
    return subprocess.run(command, input=text, text=True, capture_output=True, timeout=20)


@publication_sink
def confirm_profile_replace():
    return typer.confirm("Profile exists. Replace it and keep a timestamped backup?", default=False)


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
    path: str
    before: bytes | None
    content: bytes

    @property
    def revision(self) -> str:
        return content_revision(self.before)

    def configuration(self) -> Config:
        return Config(**json.loads(self.content)).validate()


def preview_profile(config: Config, path: str) -> ProfileChange:
    selected = profile_path(path)
    return ProfileChange(selected, read_profile(Path(selected)), profile_bytes(config))


@contextmanager
def _profile_publication(origin):
    failure = None
    with guarded_publish(origin):
        try:
            yield
        except FinOpsError as error:
            if error.code == 3:
                raise
            # Local validation must not clear a still-current principal's UI.
            failure = error
    if failure is not None:
        raise failure


@contextmanager
def profile_lock(path: Path, *, origin):
    with _profile_publication(origin):
        path.parent.mkdir(parents=True, exist_ok=True)
        handle = path.with_name(f".{path.name}.lock").open("a+b")
    try:
        with _profile_publication(origin):
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
        # Only the OS file lock spans verification; publication never spans an await.
        yield
    finally:
        handle.close()


def profile_conflict(path, revision: str, before: bytes | None, current: bytes | None) -> FinOpsError:
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


@publication_sink
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


@publication_sink
def replace_profile(path: Path, content: bytes):
    temporary = path.with_name(f".{path.name}.{uuid4().hex}.tmp")
    try:
        with temporary.open("xb") as stream:
            stream.write(content)
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


@publication_sink
def _save_profile_locked(path: Path, content: bytes, revision: str, before: bytes | None) -> Path | None:
    require_profile_revision(path, revision, before)
    backup = backup_profile(path) if path.exists() else None
    require_profile_revision(path, revision, before)
    replace_profile(path, content)
    return backup


@publication_sink
def save_profile(path: str | Path, config: Config, *, revision: str | None = None) -> str | None:
    path = Path(path)
    content = profile_bytes(config)
    with profile_lock(path, origin=enclosing_publication()):
        before = read_profile(path)
        expected = content_revision(before) if revision is None else revision
        backup = _save_profile_locked(path, content, expected, before)
        return str(backup) if backup is not None else None


def recovery_instructions(path: Path, backup: Path | None) -> str:
    action = (f"copy the backup {backup} over {path}" if backup is not None else
              f"remove the unverified new profile {path} (no previous file existed)")
    return (f"Backup: {backup or 'no previous file'}. Recovery: Close the application holding the profile; "
            f"{action}; then reopen AUM with the previous connection and verify whoami.")


@contextmanager
def profile_transaction(path: str | Path, config: Config, revision: str, *, origin,
                        reviewed: ProfileChange | None = None):
    path = Path(path)
    with _profile_publication(origin):
        content = reviewed.content if reviewed is not None else profile_bytes(config)
        written_revision = content_revision(content)
        before = reviewed.before if reviewed is not None else None
    with profile_lock(path, origin=origin):
        with _profile_publication(origin):
            backup = _save_profile_locked(path, content, revision, before)
        completed = False
        try:
            yield str(backup) if backup is not None else None
            with _profile_publication(origin):
                require_profile_revision(path, written_revision, content)
            completed = True
        finally:
            if not completed:
                # Restore only this transaction's address bytes, even if its source expired.
                with guarded_publish(nullcontext):
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
