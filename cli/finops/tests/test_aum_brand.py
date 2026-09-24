import json
from unittest.mock import patch

import pytest
from typer.testing import CliRunner

from claude_finops.brand import BANNER, PRODUCT, show_banner
from claude_finops.cli import app

EXPECTED = " _____ _____ _____ \n|  _  |  |  |     |\n|     |  |  | | | |\n|__|__|_____|_|_|_|"


def test_owner_banner_exact_ascii():
    assert BANNER == EXPECTED
    assert BANNER.isascii()
    assert PRODUCT == "AUM - Azure Usage Management"


@pytest.mark.parametrize("flags", [
    {"tty": False}, {"tty": True, "plain": True}, {"tty": True, "as_json": True},
    {"tty": True, "screen_reader": True},
])
def test_banner_is_suppressed_for_machine_and_accessible_output(flags):
    assert not show_banner(**flags)
    assert show_banner(tty=True)


def test_version_without_config_non_tty_has_no_art():
    result = CliRunner().invoke(app, ["--version"])
    assert result.exit_code == 0, result.output
    assert PRODUCT in result.output
    assert BANNER not in result.output


def test_version_tty_has_banner():
    with patch("claude_finops.cli.terminal_output", return_value=True):
        result = CliRunner().invoke(app, ["--version"])
    assert result.exit_code == 0, result.output
    assert BANNER in result.output


def test_version_json_contains_only_json():
    result = CliRunner().invoke(app, ["--version", "--json"])
    assert result.exit_code == 0, result.output
    assert json.loads(result.output)["product"] == PRODUCT


def test_no_arguments_in_pipe_is_linear_not_tui():
    result = CliRunner().invoke(app, ["--backend", "fake"])
    assert result.exit_code == 0, result.output
    assert "total_tokens" in result.output
    assert BANNER not in result.output


def test_deprecated_entry_prints_one_notice_on_stderr(capsys):
    from claude_finops.cli import legacy_main
    with patch("claude_finops.cli.main") as primary:
        legacy_main()
    primary.assert_called_once()
    captured = capsys.readouterr()
    assert not captured.out
    assert len(captured.err.splitlines()) == 1
    assert "Deprecated" in captured.err and "aum" in captured.err


@pytest.mark.parametrize("flag", ["--plain", "--screen-reader", "--json"])
def test_tty_version_accessibility_modes_suppress_art(flag):
    with patch("claude_finops.cli.terminal_output", return_value=True):
        result = CliRunner().invoke(app, ["--version", flag])
    assert result.exit_code == 0
    assert BANNER not in result.output
