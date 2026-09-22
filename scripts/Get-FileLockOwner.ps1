<#
.SYNOPSIS
    Names the process holding a file open.

.DESCRIPTION
    "The process cannot access the file because it is being used by another
    process" does not say which process, and on Windows that is usually the
    only thing worth knowing. Sysinternals handle.exe answers it but is not
    installed by default and needs elevation; the Restart Manager API is in the
    box, needs no privilege, and is what Windows Installer itself uses to work
    out which applications to close.

    Written for the Claude Desktop launch failure, where an AppX container
    could not be created because the package's UserClasses.dat registry hive
    was held open. The deployment log reported error 0x20 - a sharing
    violation - and nothing else, and the diagnosis was wrong until the holder
    was named.

.PARAMETER Path
    One or more files to ask about.

.EXAMPLE
    ./scripts/Get-FileLockOwner.ps1 -Path "$env:LOCALAPPDATA\Packages\Claude_pzs8sxrjxfjjc\SystemAppData\Helium\UserClasses.dat"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string[]]$Path
)

$ErrorActionPreference = 'Stop'

$signature = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class RestartManager
{
    [StructLayout(LayoutKind.Sequential)]
    struct RM_UNIQUE_PROCESS { public int dwProcessId; public System.Runtime.InteropServices.ComTypes.FILETIME ProcessStartTime; }

    const int RmRebootReasonNone = 0;
    const int CCH_RM_MAX_APP_NAME = 255;
    const int CCH_RM_MAX_SVC_NAME = 63;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct RM_PROCESS_INFO
    {
        public RM_UNIQUE_PROCESS Process;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = CCH_RM_MAX_APP_NAME + 1)] public string strAppName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = CCH_RM_MAX_SVC_NAME + 1)] public string strServiceShortName;
        public int ApplicationType;
        public uint AppStatus;
        public uint TSSessionId;
        [MarshalAs(UnmanagedType.Bool)] public bool bRestartable;
    }

    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    static extern int RmStartSession(out uint pSessionHandle, int dwSessionFlags, string strSessionKey);
    [DllImport("rstrtmgr.dll")]
    static extern int RmEndSession(uint pSessionHandle);
    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    static extern int RmRegisterResources(uint pSessionHandle, uint nFiles, string[] rgsFilenames,
        uint nApplications, [In] RM_UNIQUE_PROCESS[] rgApplications, uint nServices, string[] rgsServiceNames);
    [DllImport("rstrtmgr.dll")]
    static extern int RmGetList(uint dwSessionHandle, out uint pnProcInfoNeeded, ref uint pnProcInfo,
        [In, Out] RM_PROCESS_INFO[] rgAffectedApps, ref uint lpdwRebootReasons);

    public static List<string> WhoIsUsing(string path)
    {
        var result = new List<string>();
        uint handle;
        string key = Guid.NewGuid().ToString();
        if (RmStartSession(out handle, 0, key) != 0) return result;
        try
        {
            if (RmRegisterResources(handle, 1, new[] { path }, 0, null, 0, null) != 0) return result;
            uint pnProcInfo = 0, pnProcInfoNeeded = 0, rebootReasons = RmRebootReasonNone;
            int rv = RmGetList(handle, out pnProcInfoNeeded, ref pnProcInfo, null, ref rebootReasons);
            if (rv == 234 && pnProcInfoNeeded > 0)
            {
                var info = new RM_PROCESS_INFO[pnProcInfoNeeded];
                pnProcInfo = pnProcInfoNeeded;
                if (RmGetList(handle, out pnProcInfoNeeded, ref pnProcInfo, info, ref rebootReasons) == 0)
                {
                    for (int i = 0; i < pnProcInfo; i++)
                        result.Add(info[i].Process.dwProcessId + "|" + info[i].strAppName + "|" + info[i].strServiceShortName);
                }
            }
        }
        finally { RmEndSession(handle); }
        return result;
    }
}
'@

if (-not ('RestartManager' -as [type])) {
    Add-Type -TypeDefinition $signature -Language CSharp
}

foreach ($p in $Path) {
    if (-not (Test-Path $p)) {
        Write-Host ("  {0}`n    file does not exist" -f $p) -ForegroundColor DarkGray
        continue
    }

    $full = (Resolve-Path $p).Path
    $locked = $false
    try { $s = [IO.File]::Open($full, 'Open', 'ReadWrite', 'None'); $s.Close() }
    catch { $locked = $true }

    Write-Host ''
    Write-Host ("  {0}" -f $full) -ForegroundColor Cyan
    if (-not $locked) {
        Write-Host '    not locked' -ForegroundColor Green
        continue
    }

    $holders = [RestartManager]::WhoIsUsing($full)
    if ($holders.Count -eq 0) {
        # Restart Manager reports processes. A hive loaded by the kernel has no
        # owning process to report, which is itself the answer: nothing can be
        # closed, and the handle goes when the hive is unloaded or the machine
        # restarts.
        Write-Host '    locked, and no process owns it' -ForegroundColor Yellow
        Write-Host '    That means the kernel holds it - a loaded registry hive, or a' -ForegroundColor DarkGray
        Write-Host '    section still mapped. There is no process to close.' -ForegroundColor DarkGray
        continue
    }

    Write-Host ('    locked by {0} process(es)' -f $holders.Count) -ForegroundColor Yellow
    foreach ($h in $holders) {
        $parts = $h -split '\|'
        $proc = $null
        try { $proc = Get-Process -Id ([int]$parts[0]) -ErrorAction SilentlyContinue } catch { }
        $svc = if ($parts[2]) { " service=$($parts[2])" } else { '' }
        $cmd = ''
        try {
            $ci = Get-CimInstance Win32_Process -Filter "ProcessId=$($parts[0])" -ErrorAction SilentlyContinue
            if ($ci -and $ci.CommandLine) { $cmd = $ci.CommandLine }
        }
        catch { }
        Write-Host ("      pid {0,-8} {1}{2}" -f $parts[0], $parts[1], $svc)
        if ($proc) { Write-Host ("        process  {0}" -f $proc.ProcessName) -ForegroundColor DarkGray }
        if ($cmd) {
            if ($cmd.Length -gt 140) { $cmd = $cmd.Substring(0, 140) + '...' }
            Write-Host ("        command  {0}" -f $cmd) -ForegroundColor DarkGray
        }
    }
}

Write-Host ''
