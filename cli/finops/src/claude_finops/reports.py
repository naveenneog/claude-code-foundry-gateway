"""Local report file naming helpers."""

import os
from pathlib import Path


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
    return unique_path(folder or default_report_folder(), f"chargeback-{month}.csv")
