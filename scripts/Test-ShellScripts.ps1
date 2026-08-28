# Syntax-checks and smoke-tests the bash workstation script from Windows,
# using whichever bash is available (Git Bash or WSL).

$candidates = @(
    'C:\Program Files\Git\bin\bash.exe',
    'C:\Program Files\Git\usr\bin\bash.exe',
    "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe"
)

$bash = $null
foreach ($c in $candidates) { if (Test-Path $c) { $bash = $c; break } }
if (-not $bash) {
    $cmd = Get-Command bash -ErrorAction SilentlyContinue
    if ($cmd) { $bash = $cmd.Source }
}

if (-not $bash) {
    Write-Host 'No bash found on this machine.' -ForegroundColor Yellow
    Write-Host 'Install Git for Windows or enable WSL to syntax-check the shell scripts.' -ForegroundColor DarkGray
    exit 1
}

Write-Host "bash: $bash" -ForegroundColor Cyan
Write-Host ''

$scripts = @()
$scripts += Get-ChildItem (Join-Path $PSScriptRoot '*.sh') -ErrorAction SilentlyContinue
$scripts += Get-ChildItem (Join-Path (Split-Path $PSScriptRoot -Parent) '*.sh') -ErrorAction SilentlyContinue
$scripts = $scripts | Sort-Object FullName -Unique
if (-not $scripts) { Write-Host 'No .sh files found.' -ForegroundColor Yellow; exit 0 }

$fail = 0
foreach ($s in $scripts) {
    # Git Bash needs a POSIX path.
    $p = '/' + ($s.FullName -replace '\\','/' -replace '^([A-Za-z]):','$1')
    $out = & $bash -n $p 2>&1
    if ($LASTEXITCODE -eq 0) { Write-Host ("  [OK]   {0}" -f $s.Name) -ForegroundColor Green }
    else {
        $fail++
        Write-Host ("  [FAIL] {0}" -f $s.Name) -ForegroundColor Red
        $out | Select-Object -First 6 | ForEach-Object { Write-Host "         $_" -ForegroundColor DarkGray }
    }
}

Write-Host ''
if ($fail -eq 0) { Write-Host 'All shell scripts parse.' -ForegroundColor Green }
else { Write-Host "$fail script(s) have syntax errors." -ForegroundColor Red; exit 1 }
