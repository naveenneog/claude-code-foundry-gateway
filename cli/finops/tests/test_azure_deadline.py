import os
import ctypes
from ctypes import wintypes
import json
from pathlib import Path
import sys
import time
import subprocess

import pytest

from claude_finops.config import az
from claude_finops.errors import FinOpsError


def child_wrapper(tmp_path):
    launcher = tmp_path / "az.cmd"
    child, grandchild = tmp_path / "child.py", tmp_path / "grandchild.py"
    child_marker, grandchild_marker = tmp_path / "child.json", tmp_path / "grandchild.json"
    grandchild.write_text(
        "import json,os,time\nfrom pathlib import Path\n"
        f"Path({str(grandchild_marker)!r}).write_text(json.dumps({{'pid':os.getpid()}}))\ntime.sleep(3)\n",
        encoding="utf-8")
    child.write_text(
        "import json,os,subprocess,sys,time\nfrom pathlib import Path\n"
        f"Path({str(child_marker)!r}).write_text(json.dumps({{'pid':os.getpid()}}))\n"
        f"subprocess.Popen([sys.executable, '-S', {str(grandchild)!r}])\ntime.sleep(3)\n",
        encoding="utf-8")
    # The fixed timeout measures containment, not the Windows venv redirector's startup.
    launcher.write_text(f'@echo off\r\n"{sys._base_executable}" -S "{child}"\r\n', encoding="utf-8")
    return launcher, (child_marker, grandchild_marker)


def assert_exited(pid):
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    kernel.OpenProcess.restype = wintypes.HANDLE
    kernel.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    handle = kernel.OpenProcess(0x00100000, False, pid)
    if not handle:
        assert ctypes.get_last_error() == 87, "Only a nonexistent process proves termination."
        return
    try:
        assert kernel.WaitForSingleObject(handle, 0) == 0, f"Owned descendant {pid} is still running."
    finally:
        kernel.CloseHandle(handle)


@pytest.mark.skipif(os.name != "nt", reason="The Windows az.cmd process tree is the regression target.")
def test_azure_cli_deadline_includes_child_pipe_cleanup(monkeypatch, tmp_path):
    launcher, child = tmp_path / "az.cmd", tmp_path / "child.py"
    child.write_text("import time\ntime.sleep(2)\n", encoding="utf-8")
    launcher.write_text(f'@echo off\r\n"{sys.executable}" "{child}"\r\n', encoding="utf-8")
    original, processes = subprocess.Popen, []

    def launched(*args, **kwargs):
        process = original(*args, **kwargs)
        processes.append(process)
        return process

    monkeypatch.setattr(subprocess, "Popen", launched)
    monkeypatch.setattr("claude_finops.config.shutil.which", lambda _: str(launcher))
    started = time.perf_counter()
    with pytest.raises(FinOpsError, match="did not finish"):
        az("account", "get-access-token", timeout=.15)
    assert time.perf_counter() - started < 1, "Timed-out az.cmd descendants must not keep output pipes alive."
    assert len(processes) == 1, "The deadline detector must prove an actual process was created."
    assert processes[0].pid > 0 and processes[0].poll() is not None


@pytest.mark.skipif(os.name != "nt", reason="The Windows az.cmd process tree is the regression target.")
def test_timeout_terminates_started_children_and_grandchildren(monkeypatch, tmp_path):
    launcher, markers = child_wrapper(tmp_path)
    monkeypatch.setattr("claude_finops.config.shutil.which", lambda _: str(launcher))
    started = time.perf_counter()
    with pytest.raises(FinOpsError, match="did not finish"):
        az("account", "get-access-token", timeout=.75)
    assert time.perf_counter() - started < 1.5, "Timed-out az.cmd descendants must not keep output pipes alive."
    for marker in markers:
        assert marker.exists(), "The timeout detector must prove the child and grandchild actually started."
        assert_exited(json.loads(marker.read_text())["pid"])


@pytest.mark.skipif(os.name != "nt", reason="The Windows az.cmd process tree is the regression target.")
def test_scheduling_delay_before_assignment_cannot_release_uncontained_children(monkeypatch, tmp_path):
    from claude_finops import windows_process
    launcher, markers = child_wrapper(tmp_path)
    original, processes = subprocess.Popen, []

    def delayed(*args, **kwargs):
        process = original(*args, **kwargs)
        processes.append(process)
        time.sleep(.35)
        assert not any(marker.exists() for marker in markers), "No wrapper instruction may run before job assignment."
        return process

    monkeypatch.setattr(windows_process.subprocess, "Popen", delayed)
    started = time.perf_counter()
    with pytest.raises(subprocess.TimeoutExpired):
        windows_process.run_wrapper([str(launcher)], timeout=1)
    assert time.perf_counter() - started < 1.75
    assert processes and processes[0].poll() is not None
    for marker in markers:
        assert marker.exists()
        assert_exited(json.loads(marker.read_text())["pid"])


@pytest.mark.skipif(os.name != "nt", reason="The Windows az.cmd process tree is the regression target.")
def test_assignment_failure_terminates_suspended_wrapper_without_starting_children(monkeypatch, tmp_path):
    from claude_finops import windows_process
    launcher, markers = child_wrapper(tmp_path)
    original, processes = subprocess.Popen, []
    native = ctypes.WinDLL("kernel32", use_last_error=True)
    native.AssignProcessToJobObject = lambda *args: 0

    def delayed(*args, **kwargs):
        process = original(*args, **kwargs)
        processes.append(process)
        time.sleep(.35)
        return process

    monkeypatch.setattr(windows_process.ctypes, "WinDLL", lambda *args, **kwargs: native)
    monkeypatch.setattr(windows_process.subprocess, "Popen", delayed)
    with pytest.raises(OSError, match="assign"):
        windows_process.run_wrapper([str(launcher)], timeout=1)
    assert len(processes) == 1 and processes[0].poll() is not None
    assert processes[0].stdout.closed and processes[0].stderr.closed
    assert not any(marker.exists() for marker in markers), "Assignment failure must run no wrapper instruction."


def test_launch_failure_is_not_reported_as_an_expired_deadline(monkeypatch):
    monkeypatch.setattr("claude_finops.config.shutil.which", lambda _: "az")
    monkeypatch.setattr("claude_finops.config.subprocess.run", lambda *args, **kwargs:
                        (_ for _ in ()).throw(OSError("launch refused")))
    with pytest.raises(FinOpsError, match="could not start") as error:
        az("account", "show")
    assert "did not finish" not in str(error.value)


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
