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


# TerminateJobObject starts termination and returns; a process object is signaled only when its
# teardown completes (https://learn.microsoft.com/windows/win32/api/processthreadsapi/nf-processthreadsapi-terminateprocess).
# Descendants therefore outlive any test run, so that only the job boundary ends them within
# EXIT_WAIT_MS, and they record their creation time, so that a reused process id is not mistaken
# for them.
DESCENDANT_SECONDS = 60
EXIT_WAIT_MS = 10_000
SYNCHRONIZE, QUERY_LIMITED, TERMINATE = 0x00100000, 0x00001000, 0x00000001


def identified_script(marker, body=""):
    # The marker appears complete or not at all, even when the process is ended while writing it.
    return (
        "import ctypes,json,os,subprocess,sys,time\nfrom ctypes import wintypes\n"
        "kernel=ctypes.WinDLL('kernel32')\nkernel.GetCurrentProcess.restype=wintypes.HANDLE\n"
        "kernel.GetProcessTimes.argtypes=[wintypes.HANDLE]+[ctypes.POINTER(wintypes.FILETIME)]*4\n"
        "times=[wintypes.FILETIME() for _ in range(4)]\n"
        "kernel.GetProcessTimes(kernel.GetCurrentProcess(),*map(ctypes.byref,times))\n"
        "created=times[0].dwHighDateTime<<32|times[0].dwLowDateTime\n"
        f"marker={str(marker)!r}\n"
        "open(marker+'.tmp','w',encoding='utf-8').write(json.dumps({'pid':os.getpid(),'created':created}))\n"
        "os.replace(marker+'.tmp',marker)\n" + body)


def kernel32():
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    kernel.OpenProcess.restype = wintypes.HANDLE
    kernel.GetProcessTimes.argtypes = [wintypes.HANDLE] + [ctypes.POINTER(wintypes.FILETIME)] * 4
    kernel.GetProcessTimes.restype = wintypes.BOOL
    kernel.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
    kernel.WaitForSingleObject.restype = wintypes.DWORD
    kernel.TerminateProcess.argtypes = [wintypes.HANDLE, wintypes.UINT]
    kernel.TerminateProcess.restype = wintypes.BOOL
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    return kernel


def open_recorded(kernel, marker, access):
    """A handle to the process the marker records, or None when that process no longer exists."""
    identity = json.loads(Path(marker).read_text(encoding="utf-8"))
    handle = kernel.OpenProcess(access, False, identity["pid"])
    if not handle:
        # 87: no process has the id. 5: the id now belongs to a process this user cannot open,
        # which a descendant started by this test never is.
        assert ctypes.get_last_error() in (87, 5), "Only a nonexistent process proves termination."
        return None, identity
    times = [wintypes.FILETIME() for _ in range(4)]
    if not kernel.GetProcessTimes(handle, *map(ctypes.byref, times)):
        kernel.CloseHandle(handle)
        raise AssertionError(f"Cannot read the creation time of process {identity['pid']}.")
    if times[0].dwHighDateTime << 32 | times[0].dwLowDateTime != identity["created"]:
        kernel.CloseHandle(handle)
        return None, identity
    return handle, identity


def assert_exited(marker, wait_ms=EXIT_WAIT_MS):
    kernel = kernel32()
    handle, identity = open_recorded(kernel, marker, SYNCHRONIZE | QUERY_LIMITED)
    if handle is None:
        return
    try:
        assert kernel.WaitForSingleObject(handle, wait_ms) == 0, \
            f"Owned descendant {identity['pid']} is still running {wait_ms} ms after the deadline."
    finally:
        kernel.CloseHandle(handle)


def stop_survivor(marker):
    kernel = kernel32()
    handle, _ = open_recorded(kernel, marker, SYNCHRONIZE | QUERY_LIMITED | TERMINATE)
    if handle is not None:
        try:
            kernel.TerminateProcess(handle, 1)
        finally:
            kernel.CloseHandle(handle)


@pytest.fixture
def child_wrapper(tmp_path):
    assert DESCENDANT_SECONDS * 1000 >= 3 * EXIT_WAIT_MS, "A natural exit must not pass for termination."
    launcher = tmp_path / "az.cmd"
    child, grandchild = tmp_path / "child.py", tmp_path / "grandchild.py"
    child_marker, grandchild_marker = tmp_path / "child.json", tmp_path / "grandchild.json"
    grandchild.write_text(identified_script(grandchild_marker, f"time.sleep({DESCENDANT_SECONDS})\n"),
                          encoding="utf-8")
    child.write_text(identified_script(child_marker, f"subprocess.Popen([sys.executable, '-S', {str(grandchild)!r}])\n"
                                                     f"time.sleep({DESCENDANT_SECONDS})\n"), encoding="utf-8")
    # The fixed timeout measures containment, not the Windows venv redirector's startup.
    launcher.write_text(f'@echo off\r\n"{sys._base_executable}" -S "{child}"\r\n', encoding="utf-8")
    yield launcher, (child_marker, grandchild_marker)
    # A failed containment check must not leave its descendants running for a minute.
    for marker in (child_marker, grandchild_marker):
        if marker.exists():
            stop_survivor(marker)


def start_identified(tmp_path, name, seconds):
    marker = tmp_path / f"{name}.json"
    script = tmp_path / f"{name}.py"
    script.write_text(identified_script(marker, f"time.sleep({seconds})\n"), encoding="utf-8")
    process = subprocess.Popen([sys._base_executable, "-S", str(script)])
    deadline = time.monotonic() + 30
    while not marker.exists():
        assert process.poll() is None and time.monotonic() < deadline, "The identified process did not start."
        time.sleep(.05)
    return process, marker


@pytest.mark.skipif(os.name != "nt", reason="Windows process identity is the regression target.")
def test_exit_proof_waits_for_a_process_that_is_still_ending(tmp_path):
    process, marker = start_identified(tmp_path, "ending", 1.5)
    try:
        assert process.poll() is None, "The proof must start while the process is still running."
        assert_exited(marker)
        assert process.wait(timeout=5) == 0
    finally:
        if process.poll() is None:
            process.kill()


@pytest.mark.skipif(os.name != "nt", reason="Windows process identity is the regression target.")
def test_exit_proof_fails_for_a_recorded_process_that_keeps_running(tmp_path):
    process, marker = start_identified(tmp_path, "running", DESCENDANT_SECONDS)
    try:
        with pytest.raises(AssertionError, match="still running 300 ms after the deadline"):
            assert_exited(marker, wait_ms=300)
    finally:
        stop_survivor(marker)
        process.wait(timeout=10)


@pytest.mark.skipif(os.name != "nt", reason="Windows process identity is the regression target.")
def test_exit_proof_does_not_mistake_a_reused_id_for_the_descendant(tmp_path):
    marker = tmp_path / "reused.json"
    # This test's own process is running, but it is not the process the marker records.
    marker.write_text(json.dumps({"pid": os.getpid(), "created": 1}), encoding="utf-8")
    started = time.perf_counter()
    assert_exited(marker)
    assert time.perf_counter() - started < 1, "A reused id must not be waited on."


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
def test_timeout_terminates_started_children_and_grandchildren(monkeypatch, child_wrapper):
    launcher, markers = child_wrapper
    monkeypatch.setattr("claude_finops.config.shutil.which", lambda _: str(launcher))
    started = time.perf_counter()
    with pytest.raises(FinOpsError, match="did not finish"):
        az("account", "get-access-token", timeout=.75)
    assert time.perf_counter() - started < 1.5, "Timed-out az.cmd descendants must not keep output pipes alive."
    for marker in markers:
        assert marker.exists(), "The timeout detector must prove the child and grandchild actually started."
        assert_exited(marker)


@pytest.mark.skipif(os.name != "nt", reason="The Windows az.cmd process tree is the regression target.")
def test_scheduling_delay_before_assignment_cannot_release_uncontained_children(monkeypatch, child_wrapper):
    from claude_finops import windows_process
    launcher, markers = child_wrapper
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
        assert_exited(marker)


@pytest.mark.skipif(os.name != "nt", reason="The Windows az.cmd process tree is the regression target.")
def test_assignment_failure_terminates_suspended_wrapper_without_starting_children(monkeypatch, child_wrapper):
    from claude_finops import windows_process
    launcher, markers = child_wrapper
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
