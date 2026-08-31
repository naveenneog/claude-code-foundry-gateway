# Runs the preflight under both PowerShell 7 and Windows PowerShell 5.1, to
# prove the argument canary actually detects the difference between them.

$root = Split-Path $PSScriptRoot -Parent
$pre = Join-Path $PSScriptRoot 'Test-Prerequisites.ps1'

$hosts = @(
    @{ Name = 'PowerShell 7';           Exe = (Get-Command pwsh -ErrorAction SilentlyContinue).Source },
    @{ Name = 'Windows PowerShell 5.1'; Exe = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' }
)

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
    & $h.Exe -NoProfile -Command $cmd 2>&1 | ForEach-Object { $_ }
}
Write-Host ''
