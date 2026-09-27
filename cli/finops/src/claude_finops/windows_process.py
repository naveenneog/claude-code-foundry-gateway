"""Keep an owned Windows command wrapper and its children inside one timeout."""

import ctypes
from ctypes import wintypes
import subprocess


def run_wrapper(command, *, timeout):
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.CreateJobObjectW.argtypes = [ctypes.c_void_p, wintypes.LPCWSTR]
    kernel.CreateJobObjectW.restype = wintypes.HANDLE
    kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    kernel.OpenProcess.restype = wintypes.HANDLE
    kernel.AssignProcessToJobObject.argtypes = [wintypes.HANDLE, wintypes.HANDLE]
    kernel.AssignProcessToJobObject.restype = wintypes.BOOL
    kernel.TerminateJobObject.argtypes = [wintypes.HANDLE, wintypes.UINT]
    kernel.TerminateJobObject.restype = wintypes.BOOL
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    kernel.CloseHandle.restype = wintypes.BOOL
    job = kernel.CreateJobObjectW(None, None)
    if not job:
        raise OSError("Cannot create the Azure CLI process boundary.")
    process = None
    handle = None
    try:
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   text=True, encoding="utf-8")
        handle = kernel.OpenProcess(0x0101, False, process.pid)
        if not handle or not kernel.AssignProcessToJobObject(job, handle):
            raise OSError("Cannot assign the Azure CLI process to its timeout boundary.")
        try:
            stdout, stderr = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            if not kernel.TerminateJobObject(job, 1):
                raise OSError("Cannot stop the timed-out Azure CLI process tree.") from None
            process.communicate(timeout=1)
            raise
        return subprocess.CompletedProcess(command, process.returncode, stdout, stderr)
    finally:
        kernel.TerminateJobObject(job, 1)
        if process is not None:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=1)
            process.stdout.close()
            process.stderr.close()
        if handle:
            kernel.CloseHandle(handle)
        kernel.CloseHandle(job)
