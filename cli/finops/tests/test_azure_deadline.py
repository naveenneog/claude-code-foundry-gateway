import os
from pathlib import Path
import sys
import time
import subprocess

import pytest

from claude_finops.config import az
from claude_finops.errors import FinOpsError


@pytest.mark.skipif(os.name != "nt", reason="The Windows az.cmd process tree is the regression target.")
def test_azure_cli_deadline_includes_child_pipe_cleanup(monkeypatch, tmp_path):
    launcher = tmp_path / "az.cmd"
    child = tmp_path / "child.py"
    child.write_text("import time\ntime.sleep(2)\n", encoding="utf-8")
    launcher.write_text(f'@echo off\r\n"{sys.executable}" "{child}"\r\n', encoding="utf-8")
    monkeypatch.setattr("claude_finops.config.shutil.which", lambda _: str(launcher))
    started = time.perf_counter()
    with pytest.raises(FinOpsError, match="did not finish"):
        az("account", "get-access-token", timeout=.15)
    assert time.perf_counter() - started < 1, "Timed-out az.cmd descendants must not keep output pipes alive."


def test_msi_azure_cli_runs_its_python_directly_without_the_command_wrapper(monkeypatch, tmp_path):
    folder = tmp_path / "wbin"
    folder.mkdir()
    launcher = folder / "az.cmd"
    launcher.write_text('@IF EXIST "%~dp0\\..\\python.exe" (\n  SET AZ_INSTALLER=MSI\n'
                        '  "%~dp0\\..\\python.exe" -IBm azure.cli %*\n)\n', encoding="utf-8")
    python = tmp_path / "python.exe"
    python.touch()
    calls = []
    monkeypatch.setattr("claude_finops.config.shutil.which", lambda _: str(launcher))
    monkeypatch.setattr("claude_finops.config.subprocess.run", lambda args, **kwargs:
                        calls.append((args, kwargs)) or subprocess.CompletedProcess(args, 0, "address-only", ""))
    assert az("account", "show") == "address-only"
    assert calls[0][0][:3] == [str(python), "-IBm", "azure.cli"]
    assert calls[0][1]["env"]["AZ_INSTALLER"] == "MSI"


def test_turnstile_signin_credential_has_a_bounded_subprocess_deadline(monkeypatch):
    import httpx
    from claude_finops.config import Config
    from claude_finops.turnstile import TurnstileBackend
    calls = []
    monkeypatch.setattr("claude_finops.config.az", lambda *args, **kwargs: calls.append(kwargs) or "test-only")
    backend = TurnstileBackend(Config(backend="turnstile", url="https://turnstile.contoso.com",
                                     scope="api://contoso/Turnstile.Manage"),
                               transport=httpx.MockTransport(lambda _: httpx.Response(200, json={"role": "owner"})))
    assert backend.read("whoami")["role"] == "owner"
    assert 0 < calls[0]["timeout"] <= 2.5
    backend.close()
