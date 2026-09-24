import csv
import io
import json

import pytest
from typer.testing import CliRunner

from claude_finops.cli import app

runner = CliRunner()


@pytest.mark.parametrize("args", [
    ["whoami"], ["status"], ["budget", "list"], ["people", "find", "dev", "--team", "sales-emea"],
    ["governance", "show"], ["tier", "show"], ["requests", "list"],
    ["requests", "show", "contoso-request-001"], ["anomalies", "list"],
    ["usage", "show"], ["trends", "show"],
])
def test_read_commands_json_flags_anywhere(args):
    result = runner.invoke(app, [*args, "--backend", "fake", "--month", "2026-09", "--json"])
    assert result.exit_code == 0, result.output
    assert isinstance(json.loads(result.output), (dict, list))


def test_default_mutation_is_preview():
    result = runner.invoke(app, ["--backend", "fake", "budget", "set", "team", "sales-emea", "9M", "--json"])
    assert result.exit_code == 0, result.output
    assert json.loads(result.output)["preview"]


def test_what_if_overrides_apply():
    result = runner.invoke(app, ["budget", "set", "team", "sales-emea", "9M", "--apply", "--what-if",
                                "--backend", "fake", "--json"])
    assert result.exit_code == 0, result.output
    assert json.loads(result.output)["preview"]


def test_apply_tracks_effect():
    result = runner.invoke(app, ["budget", "set", "team", "sales-emea", "9M", "--apply", "--backend", "fake", "--json"])
    assert result.exit_code == 0, result.output
    assert json.loads(result.output)["apply_status"]["state"].startswith("Apply succeeded")


def test_csv_is_machine_readable():
    result = runner.invoke(app, ["report", "chargeback", "--csv", "--month", "2026-09", "--backend", "fake"])
    assert result.exit_code == 0, result.output
    assert len(list(csv.DictReader(io.StringIO(result.output)))) == 2


def test_validation_has_meaningful_exit_and_json():
    result = runner.invoke(app, ["--backend", "fake", "--json", "budget", "set", "team", "sales-emea", "bogus"])
    assert result.exit_code == 2
    assert "error" in json.loads(result.output)


def test_plain_no_args_is_not_fullscreen():
    result = runner.invoke(app, ["--backend", "fake", "--plain"])
    assert result.exit_code == 0, result.output
    assert "total_tokens" in result.output
    assert "\x1b" not in result.output
