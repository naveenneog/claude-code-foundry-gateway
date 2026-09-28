"""Keep an owned Windows command wrapper and its children inside one timeout."""

import ctypes
from ctypes import wintypes
import subprocess
import time


class ThreadEntry(ctypes.Structure):
    _fields_ = [("size", wintypes.DWORD), ("usage", wintypes.DWORD),
                ("thread_id", wintypes.DWORD), ("process_id", wintypes.DWORD),
                ("base_priority", wintypes.LONG), ("delta_priority", wintypes.LONG),
                ("flags", wintypes.DWORD)]


def resume_process(kernel, pid):
    # Popen closes CreateProcess's thread handle; Toolhelp locates our suspended thread.
    kernel.CreateToolhelp32Snapshot.argtypes = [wintypes.DWORD, wintypes.DWORD]
    kernel.CreateToolhelp32Snapshot.restype = wintypes.HANDLE
    for name in ("Thread32First", "Thread32Next"):
        function = getattr(kernel, name)
        function.argtypes = [wintypes.HANDLE, ctypes.POINTER(ThreadEntry)]
        function.restype = wintypes.BOOL
    kernel.OpenThread.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    kernel.OpenThread.restype = wintypes.HANDLE
    kernel.ResumeThread.argtypes = [wintypes.HANDLE]
    kernel.ResumeThread.restype = wintypes.DWORD
    snapshot = kernel.CreateToolhelp32Snapshot(0x00000004, 0)
    if not snapshot or snapshot == ctypes.c_void_p(-1).value:
        raise OSError("Cannot inspect the suspended Azure CLI thread.")
    try:
        entry = ThreadEntry()
        entry.size = ctypes.sizeof(entry)
        found = kernel.Thread32First(snapshot, ctypes.byref(entry))
        while found:
            if entry.size < ThreadEntry.process_id.offset + ctypes.sizeof(wintypes.DWORD):
                raise OSError("The Azure CLI thread snapshot is incomplete.")
            if entry.process_id == pid:
                thread = kernel.OpenThread(0x0002, False, entry.thread_id)
                if not thread:
                    raise OSError("Cannot open the suspended Azure CLI thread.")
                try:
                    if kernel.ResumeThread(thread) != 1:
                        raise OSError("Cannot resume the contained Azure CLI process.")
                finally:
                    kernel.CloseHandle(thread)
                return
            entry.size = ctypes.sizeof(entry)
            found = kernel.Thread32Next(snapshot, ctypes.byref(entry))
        raise OSError("Cannot find the suspended Azure CLI thread.")
    finally:
        kernel.CloseHandle(snapshot)


def run_wrapper(command, *, timeout):
    deadline = time.monotonic() + timeout
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
                                   text=True, encoding="utf-8", creationflags=0x00000004)
        handle = kernel.OpenProcess(0x0101, False, process.pid)
        if not handle or not kernel.AssignProcessToJobObject(job, handle):
            raise OSError("Cannot assign the Azure CLI process to its timeout boundary.")
        try:
            if time.monotonic() >= deadline:
                raise subprocess.TimeoutExpired(command, timeout)
            resume_process(kernel, process.pid)
            stdout, stderr = process.communicate(timeout=max(0, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            if not kernel.TerminateJobObject(job, 1):
                raise OSError("Cannot stop the timed-out Azure CLI process tree.") from None
            process.communicate(timeout=1)
            raise
        return subprocess.CompletedProcess(command, process.returncode, stdout, stderr)
    finally:
        try:
            kernel.TerminateJobObject(job, 1)
            if process is not None:
                try:
                    if process.poll() is None:
                        process.kill()
                    process.wait(timeout=1)
                finally:
                    process.stdout.close()
                    process.stderr.close()
        finally:
            if handle:
                kernel.CloseHandle(handle)
            kernel.CloseHandle(job)
