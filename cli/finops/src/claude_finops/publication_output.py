"""Final terminal, file and clipboard writes require a current publication."""

from pathlib import Path
import json
import subprocess
import sys

from rich.console import Console
from rich.console import RenderableType
import typer

from .guarded_publication import publication_sink
from .errors import FinOpsError


def terminal_output():
    return sys.stdout.isatty()


def profile_path(path=None):
    return str(Path(path) if path is not None else Path.home() / ".aum" / "config.json")


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
