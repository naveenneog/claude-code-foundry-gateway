import csv
import json
from pathlib import Path
from types import SimpleNamespace

import pytest
from textual.widgets import Button, Input, Static
from typer.testing import CliRunner

from claude_finops.cli import app as cli_app
from claude_finops.config import Config
from claude_finops.engine import Engine
from claude_finops.fake import FakeBackend
from claude_finops.guarded_publication import guarded_publish
from claude_finops.tui import FinOpsApp


async def settle(app, pilot):
    await pilot.pause()
    await app.workers.wait_for_complete()
    await pilot.pause()


@pytest.fixture
def complete_month(monkeypatch):
    rows = [dict(id=f"unit-{index}", name=f"Unit {index}", total_tokens=index + 1,
                 cache_read_tokens=2, total_requests=1, estimated_cost="0.25") for index in range(137)]
    monkeypatch.setattr(Engine, "chargeback", lambda self, *args, **kwargs: dict(items=rows))
    return rows


@pytest.fixture
def report_folder(tmp_path, monkeypatch):
    from claude_finops import reports

    folder = tmp_path / "reports"
    monkeypatch.setattr(reports, "default_report_folder", lambda: folder)
    return folder


@pytest.mark.parametrize("system,parts", [("nt", ("Documents", "AUM")), ("posix", ("aum-reports",))])
def test_report_default_folder_is_platform_specific(tmp_path, monkeypatch, system, parts):
    from claude_finops import reports

    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    monkeypatch.setattr(reports, "os", SimpleNamespace(name=system))
    assert reports.default_report_folder() == tmp_path.joinpath(*parts)


@pytest.mark.parametrize("tab", ["people", "budgets"])
async def test_one_chargeback_click_saves_the_complete_month_and_full_path(tab, complete_month, report_folder):
    report_folder.mkdir()
    existing = report_folder / "chargeback-2026-09.csv"
    existing.write_text("original", encoding="utf-8")
    app = FinOpsApp(Engine(FakeBackend(), "2026-09"), Config(backend="fake"), first_run=False)
    async with app.run_test(size=(100, 32)) as pilot:
        await settle(app, pilot)
        app.action_tab(tab)
        await settle(app, pilot)
        await pilot.click(f"#{tab} #action-chargeback")
        await settle(app, pilot)
        path = report_folder / "chargeback-2026-09-1.csv"
        assert path.exists(), "The named action must save without a second Export click"
        assert existing.read_text(encoding="utf-8") == "original"
        with path.open(encoding="utf-8", newline="") as stream:
            rows = list(csv.DictReader(stream))
        assert len(rows) == len(complete_month) == 137
        assert [row["scope"] for row in rows] == [row["name"] for row in complete_month]
        assert all(row["month"] == "2026-09" for row in rows)
        assert str(path.resolve()) in str(app.screen.query_one("#export-status", Static).render())
        assert not app.engine.backend.writes


async def test_explicit_export_keeps_custom_filename(complete_month, report_folder):
    app = FinOpsApp(Engine(FakeBackend(), "2026-09"), Config(backend="fake"), first_run=False)
    async with app.run_test(size=(100, 32)) as pilot:
        await settle(app, pilot)
        app.action_export()
        await pilot.pause()
        with guarded_publish(app.current_guard()):
            app.screen.query_one("#export-name", Input).value = "reviewed-costs.csv"
        await pilot.click("#export-csv")
        await settle(app, pilot)
        assert (report_folder / "reviewed-costs.csv").is_file()
        assert not (report_folder / "chargeback-2026-09.csv").exists()


@pytest.mark.parametrize("installed,role", [(True, "owner"), (False, "owner"), (True, "member")])
async def test_chargeback_offers_installed_reconciler_without_widening_authority(tmp_path, installed, role,
                                                                               complete_month, report_folder):
    scripts = tmp_path / "scripts"
    scripts.mkdir()
    if installed:
        (scripts / "New-ClaudeChargebackReport.ps1").write_text("# fixture, never executed", encoding="utf-8")
    app = FinOpsApp(Engine(FakeBackend(role), "2026-09"), Config(backend="fake", repository=str(tmp_path)),
                     first_run=False)
    async with app.run_test(size=(100, 32)) as pilot:
        await settle(app, pilot)
        app.action_export()
        await pilot.pause()
        buttons = [button for button in app.screen.query(Button)
                   if str(button.label) == "Generate reconciled chargeback report"]
        assert bool(buttons) == installed
        if installed:
            assert buttons[0].disabled == (role != "owner")
            if role == "owner":
                await pilot.click(buttons[0])
                await pilot.pause()
                assert app.screen.heading == "Generate reconciled chargeback report"
                assert app.screen.preview is None
        assert not app.engine.backend.writes


def test_cli_report_json_output_still_saves_csv(tmp_path, complete_month):
    folder = tmp_path / "report-json"
    result = CliRunner().invoke(cli_app, ["report", "chargeback", "--backend", "fake", "--month", "2026-09",
                                         "--json", "--output", str(folder)])
    assert result.exit_code == 0, result.output
    path = folder / "chargeback-2026-09.csv"
    assert path.is_file()
    assert json.loads(result.output)["path"] == str(path.resolve())


def test_cli_report_what_if_creates_no_folder(tmp_path, complete_month):
    folder = tmp_path / "not-created"
    result = CliRunner().invoke(cli_app, ["report", "chargeback", "--backend", "fake", "--month", "2026-09",
                                         "--what-if", "--json", "--output", str(folder)])
    assert result.exit_code == 0, result.output
    assert not folder.exists()
    assert json.loads(result.output)["preview"] is True


def test_export_filename_race_uses_another_name_without_overwriting(tmp_path, monkeypatch, complete_month):
    original_open = Path.open
    raced = []
    path = tmp_path / "chargeback-2026-09.csv"

    def racing_open(file, mode="r", *args, **kwargs):
        if file == path and mode == "x" and not raced:
            with original_open(file, "wb") as stream:
                stream.write(b"another report")
            raced.append(True)
        return original_open(file, mode, *args, **kwargs)

    monkeypatch.setattr(Path, "open", racing_open)
    result = CliRunner().invoke(cli_app, ["report", "chargeback", "--backend", "fake", "--month", "2026-09",
                                         "--output", str(tmp_path)])
    assert result.exit_code == 0, result.output
    assert raced
    assert path.read_bytes() == b"another report"
    assert (tmp_path / "chargeback-2026-09-1.csv").is_file()
