# U92 (docs/UNKNOWNS.md): the installer harnesses lost a run's output on the windows-latest runner. On Windows,
# .NET 10 redirects a child's standard output and standard error through synchronous anonymous pipes, so
# StreamReader.ReadToEndAsync holds a thread-pool thread for each pipe until the child closes it (dotnet/runtime
# src/libraries/System.Diagnostics.Process/src/System/Diagnostics/Process.Windows.cs, release/10.0; dotnet/runtime#81896).
# The harnesses ran six to twenty-two children at once and waited 5 s after each one exited; a read queued behind
# busy threads had not started, and the run's output was recorded as empty (PR #2 Test-All, 2026-10-03).
# This suite caps the thread pool at the processor count and keeps every worker busy, so that no queued work item
# runs, then checks the shared reader of tests/ChildOutputRead.ps1 and the harnesses that use it.
# While the pool is busy nothing here may wait on a timer: Start-Sleep and Task.Delay complete on a pool thread.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$script:fail = 0
$script:checks = 0
function Assert($label, $condition, $detail = '') {
    $script:checks++
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $label$(if ($detail) { " - $detail" })" -ForegroundColor Red; $script:fail++ }
}
Write-Host ''
Write-Host 'Harness reads of child output (a busy thread pool)' -ForegroundColor Cyan
$watch = [Diagnostics.Stopwatch]::StartNew()

$helper = Join-Path $PSScriptRoot 'ChildOutputRead.ps1'
if (Test-Path -LiteralPath $helper) { . $helper }
$loaded = [bool](Get-Command Start-ChildOutputRead -ErrorAction SilentlyContinue) -and [bool](Get-Command Receive-ChildOutputRead -ErrorAction SilentlyContinue)
Assert 'tests/ChildOutputRead.ps1 defines Start-ChildOutputRead and Receive-ChildOutputRead' $loaded

$pwsh = (Get-Process -Id $PID).Path
function New-Child([string]$Command) {
    $psi = [Diagnostics.ProcessStartInfo]::new($pwsh)
    foreach ($a in '-NoProfile', '-NonInteractive', '-Command', $Command) { $psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    [Diagnostics.Process]::Start($psi)
}
$print = "[Console]::Out.Write('p92-stdout-sentinel'); [Console]::Error.Write('p92-stderr-sentinel')"
$scratch = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('p92-child-output-' + [guid]::NewGuid().ToString('N'))))
New-Item -ItemType Directory -Force -Path $scratch | Out-Null
$grandchildFile = Join-Path $scratch 'grandchild.pid'

$minWorkers = 0; $minIo = 0; [Threading.ThreadPool]::GetMinThreads([ref]$minWorkers, [ref]$minIo)
$maxWorkers = 0; $maxIo = 0; [Threading.ThreadPool]::GetMaxThreads([ref]$maxWorkers, [ref]$maxIo)
$cores = [Environment]::ProcessorCount
$gate = [Threading.ManualResetEventSlim]::new($false)
$blockers = @()
$controlRead = $null
try {
    # The pool's maximum may not be lower than the processor count, so the cap is the processor count, and more
    # work items than threads wait on the gate: each queued one sits ahead of any read queued after it.
    $capped = [Threading.ThreadPool]::SetMinThreads($cores, $minIo)
    $capped = $capped -and [Threading.ThreadPool]::SetMaxThreads($cores, $maxIo)
    if ($capped) {
        $count = [Math]::Min(256, 2 * $cores + [Threading.ThreadPool]::ThreadCount)
        $blockers = @(for ($i = 0; $i -lt $count; $i++) { [Threading.Tasks.Task]::Run([Action]$gate.Wait) })
        $clock = [Diagnostics.Stopwatch]::StartNew()
        while ($clock.Elapsed.TotalSeconds -lt 10 -and -not ([Threading.ThreadPool]::ThreadCount -ge $cores -and [Threading.ThreadPool]::PendingWorkItemCount -gt 0)) { [Threading.Thread]::Sleep(50) }
    }
    $busy = $capped -and [Threading.ThreadPool]::PendingWorkItemCount -gt 0
    Assert 'setup: the thread pool is capped at the processor count, every worker is busy and work is queued' $busy "capped=$capped threads=$([Threading.ThreadPool]::ThreadCount) of $cores, pending=$([Threading.ThreadPool]::PendingWorkItemCount)"

    # The idiom the harnesses used before U92, on a child that has exited.
    $control = New-Child $print
    $controlRead = $control.StandardOutput.ReadToEndAsync()
    $control.WaitForExit()
    $controlDone = $controlRead.Wait(5000)
    Assert 'control: with every worker busy, ReadToEndAsync has not read the output of a child that exited 5 s earlier; the harnesses recorded such a run''s output as empty' ($busy -and -not $controlDone) "read done: $controlDone"

    if ($loaded) {
        $child = New-Child $print
        $out = Start-ChildOutputRead $child.StandardOutput
        $err = Start-ChildOutputRead $child.StandardError
        $child.WaitForExit()
        $text = try { (Receive-ChildOutputRead $out 'the standard output of the child' -TimeoutSeconds 10) + '|' + (Receive-ChildOutputRead $err 'the standard error of the child' -TimeoutSeconds 10) } catch { "threw: $($_.Exception.Message)" }
        Assert 'with every worker busy, Start-ChildOutputRead reads the whole standard output and standard error of a child that exited' ($busy -and $text -ceq 'p92-stdout-sentinel|p92-stderr-sentinel') $text

        # A child that leaves a process holding its standard output: that process inherits the pipe and keeps it
        # open after the child exits, as a background job of an installer would.
        $grandchild = "`$g = [Diagnostics.ProcessStartInfo]::new('$($pwsh.Replace("'", "''"))'); foreach (`$a in '-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep 30') { `$g.ArgumentList.Add(`$a) }; `$g.UseShellExecute = `$false; " +
            "`$p = [Diagnostics.Process]::Start(`$g); [IO.File]::WriteAllText('$($grandchildFile.Replace("'", "''"))', [string]`$p.Id); [Console]::Out.Write('p92-before-exit')"
        $holder = New-Child $grandchild
        $held = Start-ChildOutputRead $holder.StandardOutput
        $heldErr = Start-ChildOutputRead $holder.StandardError
        $holder.WaitForExit()
        $reported = try { $value = Receive-ChildOutputRead $held 'the standard output of the holder' -TimeoutSeconds 3; "returned [$value]" } catch { $_.Exception.Message }
        Assert 'a read that a process started by the child keeps open is reported when its bound passes, naming the stream, and is not returned as empty' (
            $reported -like '*the standard output of the holder*' -and $reported -like '*still open 3 s after*') $reported
    }
}
finally {
    $gate.Set()
    if ($blockers) { [void][Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]$blockers, 10000) }
    [void][Threading.ThreadPool]::SetMaxThreads($maxWorkers, $maxIo)
    [void][Threading.ThreadPool]::SetMinThreads($minWorkers, $minIo)
    if (Test-Path -LiteralPath $grandchildFile) {
        $id = 0
        if ([int]::TryParse([IO.File]::ReadAllText($grandchildFile), [ref]$id)) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
    }
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}
if ($controlRead) {
    # The output was there all along: it arrives once the pool has a free thread.
    $late = $controlRead.Wait(10000)
    Assert 'control: the same read returns the child''s whole output once the pool has a free thread' ($late -and $controlRead.Result -ceq 'p92-stdout-sentinel') "done: $late"
}

# ------------------------------------------------------------------ the harnesses
# A wait whose timeout turns an unfinished read into an empty string, as the harnesses had it: an if over the read
# task's Wait of 5000 ms, its Result in the then branch, and an empty string in the else branch.
$lossy = '\.Wait\(\s*\d+\s*\)\s*\)\s*\{[^{}]*\.Result\b[^{}]*\}\s*else\s*\{\s*(''''|"")\s*\}'
$sources = @(Get-ChildItem -LiteralPath $PSScriptRoot -Recurse -File -Filter '*.ps1')
$offenders = @($sources | Where-Object { [IO.File]::ReadAllText($_.FullName) -match $lossy } | ForEach-Object { [IO.Path]::GetRelativePath($root, $_.FullName).Replace('\', '/') })
Assert "no test turns a read that is still open after a short wait into empty output ($($sources.Count) files)" ($sources.Count -gt 100 -and -not $offenders.Count) ($offenders -join ', ')
$readers = 'tests/BashInstallerHarness.ps1', 'tests/InstallerCheckpointHarness.ps1', 'tests/Test-BashInstaller.ps1', 'tests/Test-FlowPermutations.ps1', 'tests/Test-FlowStart.ps1', 'tests/Test-InstallerPreflight.ps1'
$unshared = @(foreach ($r in $readers) {
        $path = Join-Path $root $r
        if (-not (Test-Path -LiteralPath $path)) { "$r (missing)"; continue }
        $text = [IO.File]::ReadAllText($path)
        if ($text -notmatch 'Start-ChildOutputRead \$\w+\.Standard(Output|Error)' -or $text -match 'ReadToEndAsync\(') { $r }
    })
Assert 'the harnesses that run installer and flow children read their output through Start-ChildOutputRead, and none through ReadToEndAsync' (-not $unshared.Count) ($unshared -join ', ')

Write-Host ''
Write-Host ("{0} checks, {1} failed, {2:N1} s" -f $script:checks, $script:fail, $watch.Elapsed.TotalSeconds)
if ($script:fail) { exit 1 }
