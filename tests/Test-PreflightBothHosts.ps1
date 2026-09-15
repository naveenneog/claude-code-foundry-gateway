# Runs the preflight under both PowerShell 7 and Windows PowerShell 5.1, to
# prove the argument canary actually detects the difference between them.

$root = Split-Path $PSScriptRoot -Parent
$pre = Join-Path $root 'scripts/Test-Prerequisites.ps1'

$hosts = @(
    @{ Name = 'PowerShell 7';           Exe = (Get-Command pwsh -ErrorAction SilentlyContinue).Source },
    @{ Name = 'Windows PowerShell 5.1'; Exe = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' }
)

$fail = 0
$ran = 0

foreach ($h in $hosts) {
    if (-not $h.Exe -or -not (Test-Path $h.Exe)) {
        Write-Host "skip $($h.Name) - not installed" -ForegroundColor DarkGray
        continue
    }
    Write-Host ''
    Write-Host ('=' * 66) -ForegroundColor DarkCyan
    Write-Host " $($h.Name)" -ForegroundColor Cyan
    Write-Host ('=' * 66) -ForegroundColor DarkCyan

    $cmd = ". '$pre'; `$r = Test-ClaudePrerequisites -Mode Admin; Write-Host `"RESULT=`$r`""
    $out = & $h.Exe -NoProfile -Command $cmd 2>&1 | ForEach-Object { Write-Host $_; $_ } | Out-String

    # RESULT must carry a boolean. Matching the bare label was not enough: a
    # failed dot-source is a non-terminating error, so the child carried on and
    # printed "RESULT=" with nothing after it, and the check passed anyway.
    # Its value is not asserted - that depends on what is installed here - but
    # a value must be there, which means the preflight ran and returned.
    if ($out -match 'RESULT=(True|False)') {
        Write-Host "  returned $($Matches[1]) on $($h.Name)" -ForegroundColor Green
        $ran++
    }
    else {
        Write-Host "  FAIL - preflight did not return on $($h.Name)" -ForegroundColor Red
        $fail++
    }
}
Write-Host ''

# This previously fell off the end without an exit code, so Test-All reported
# whatever the last child process left behind - including PASS for a preflight
# that had thrown on both hosts.
if ($ran -eq 0) { Write-Host 'No PowerShell host was available - this check proved nothing.' -ForegroundColor Red; exit 1 }
if ($fail) { Write-Host "Preflight failed to return on $fail host(s)." -ForegroundColor Red; exit 1 }
Write-Host "Preflight returned on $ran host(s)." -ForegroundColor Green
exit 0
