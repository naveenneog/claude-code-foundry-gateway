"""Final terminal, file and clipboard writes require a current publication."""

from pathlib import Path
import subprocess

from rich.console import Console
from rich.console import RenderableType
import typer

from .guarded_publication import publication_sink


@publication_sink
def write_text(text: str, *, nl: bool = True, err: bool = False):
    typer.echo(text, nl=nl, err=err)


@publication_sink
def write_renderable(console: Console, value: RenderableType):
    console.print(value)


@publication_sink
def write_export(path: Path, content: str):
    with path.open("x", encoding="utf-8", newline="") as stream:
        stream.write(content)


@publication_sink
def copy_with_helper(command: list[str], text: str):
    return subprocess.run(command, input=text, text=True, capture_output=True, timeout=20)
