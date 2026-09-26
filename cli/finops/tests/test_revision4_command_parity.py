import json

import pytest
from typer.testing import CliRunner

from claude_finops.cli import app
from claude_finops.engine import Engine
from claude_finops.fake import FakeBackend


@pytest.mark.parametrize("noun", ["usage", "trends", "anomalies"])
def test_analytics_commands_accept_every_filter_chip(monkeypatch, noun):
    backend = FakeBackend()
    seen = []
    original = backend.read
    def read(resource, **params):
        seen.append((resource, params))
        return original(resource, **params)
    backend.read = read
    monkeypatch.setattr("claude_finops.cli.connect", lambda _: backend)
    verb = "list" if noun == "anomalies" else "show"
    result = CliRunner().invoke(app, [noun, verb, "--unit", "sales", "--team", "sales-emea",
        "--person", "dev-001@contoso.com", "--model", "claude-sonnet", "--surface", "claude-code",
        "--tier", "standard", "--backend", "fake", "--json"])
    assert result.exit_code == 0, result.output
    params = seen[-1][1]
    assert params["organization_id"] == "sales" and params["department_id"] == "sales-emea"
    assert params["user_id"] == "dev-001@contoso.com" and params["model_id"] == "claude-sonnet"
    assert params["runtime"] == "claude-code" and params["tier"] == "standard"


def test_lookup_command_matches_terminal_engine():
    result = CliRunner().invoke(app, ["lookup", "sales-emea", "--backend", "fake", "--json"])
    assert result.exit_code == 0, result.output
    assert any(row["id"] == "sales-emea" for row in json.loads(result.output)["items"])


def test_assistant_settings_share_engine_preview_and_write_rules(monkeypatch):
    backend = FakeBackend(features={"assistant": True})
    monkeypatch.setattr("claude_finops.cli.connect", lambda _: backend)
    command = ["ask", "configure", "--auto-title", "--backend", "fake", "--json"]
    result = CliRunner().invoke(app, command + ["--apply", "--what-if"])
    assert result.exit_code == 0, result.output
    assert json.loads(result.output)["preview"] and not backend.writes
    result = CliRunner().invoke(app, command + ["--apply"])
    assert result.exit_code == 0, result.output
    assert backend.writes[-1][0] == "assistant_settings"


def test_future_request_expiry_is_validated_before_write():
    from claude_finops.errors import FinOpsError
    engine = Engine(FakeBackend(features={"approvals": True}), "2026-09")
    with pytest.raises(FinOpsError, match="expiry"):
        engine.request_budget("team", "sales-emea", "10M", "Capacity", expires_at="yesterday", apply=True)
    assert not engine.backend.writes
