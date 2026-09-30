"""Local report file naming helpers."""

import os
from pathlib import Path

from .publication_output import write_export


def default_report_folder() -> Path:
    home = Path.home()
    if os.name == "nt":
        return home / "Documents" / "AUM"
    return home / "aum-reports"


def unique_path(folder: Path, name: str) -> Path:
    path = folder / name
    if not path.exists():
        return path
    stem, suffix = path.stem, path.suffix
    index = 1
    while True:
        candidate = folder / f"{stem}-{index}{suffix}"
        if not candidate.exists():
            return candidate
        index += 1


def chargeback_folder() -> str:
    return str(default_report_folder().expanduser().resolve())


def chargeback_export_path(month: str, folder: str | Path | None = None) -> str:
    folder = Path(folder) if folder is not None else default_report_folder()
    return str(unique_path(folder.expanduser().resolve(), f"chargeback-{month}.csv"))


def save_chargeback_csv(month: str, content: str, folder: str | Path | None = None, *, name: str | None = None) -> str:
    folder = Path(folder) if folder is not None else default_report_folder()
    folder = folder.expanduser().resolve()
    while True:
        path = unique_path(folder, name or f"chargeback-{month}.csv")
        try:
            write_export(path, content, create_parents=True)
            return str(path)
        except FileExistsError:
            continue
