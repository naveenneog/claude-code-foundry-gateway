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


def chargeback_export_path(month: str, folder: Path | None = None) -> Path:
    return unique_path((folder or default_report_folder()).expanduser().resolve(), f"chargeback-{month}.csv")


def save_chargeback_csv(month: str, content: str, folder: Path | None = None, *, name: str | None = None) -> Path:
    folder = (folder or default_report_folder()).expanduser().resolve()
    folder.mkdir(parents=True, exist_ok=True)
    while True:
        path = unique_path(folder, name or f"chargeback-{month}.csv")
        try:
            write_export(path, content)
            return path
        except FileExistsError:
            continue
