# Syntax-checks and smoke-tests the bash workstation script from Windows,
# using whichever bash is available (Git Bash or WSL).

# This test lives in tests/, but the shell scripts and the banner it exercises
# ship to users and live in scripts/.
$scriptsDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts'

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
$scripts += Get-ChildItem (Join-Path $scriptsDir '*.sh') -ErrorAction SilentlyContinue
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
if ($fail -ne 0) { Write-Host "$fail script(s) have syntax errors." -ForegroundColor Red; exit 1 }
Write-Host 'All shell scripts parse.' -ForegroundColor Green

# Parsing is not enough. A mangled $(dirname ...) once made the workstation
# script source a banner path that did not exist: still valid bash, so -n
# passed, but the banner silently never rendered. These checks run the banner
# for real and assert something recognisable comes back.
Write-Host ''
Write-Host 'Runtime checks' -ForegroundColor Cyan

$bannerFail = 0
function Assert-Contains($label, $text, $needle) {
    if ($text -match [regex]::Escape($needle)) {
        Write-Host ("  [OK]   {0}" -f $label) -ForegroundColor Green
    } else {
        Write-Host ("  [FAIL] {0} - expected '{1}'" -f $label, $needle) -ForegroundColor Red
        $script:bannerFail++
    }
}

$bannerPath = '/' + ((Join-Path $scriptsDir 'banner.sh').Replace('\','/') -replace '^([A-Za-z]):','$1')

$utf8 = & $bash -c "export LANG=en_US.UTF-8; . '$bannerPath'; claude_banner 'test'" 2>&1 | Out-String
Assert-Contains 'banner.sh renders' $utf8 'Naveen Gopalakrishna'

# The art is pure ASCII specifically so there is only ever one rendering, on
# every terminal and code page. Assert that at the byte level.
#
# An earlier version of this check ran the banner under LANG=C and compared the
# output to a UTF-8 run, on the theory that a non-ASCII character would render
# differently. It does not: bash emits the same bytes whatever the locale, so
# that check passed happily with a U+2500 in the file. Inspecting the bytes is
# the only thing that actually tests the property.
foreach ($f in @(
    @{ Name = 'banner.sh';      Path = (Join-Path $scriptsDir 'banner.sh') },
    @{ Name = 'Show-Banner.ps1'; Path = (Join-Path $scriptsDir 'Show-Banner.ps1') }
)) {
    if (-not (Test-Path $f.Path)) { continue }
    $bytes = [IO.File]::ReadAllBytes($f.Path)
    $bad = @($bytes | Where-Object { $_ -gt 127 }).Count
    if ($bad -eq 0) {
        Write-Host ("  [OK]   {0} is pure ASCII" -f $f.Name) -ForegroundColor Green
    } else {
        Write-Host ("  [FAIL] {0} has {1} non-ASCII byte(s) - it will need a BOM, and the shell art will vary by console" -f $f.Name, $bad) -ForegroundColor Red
        $bannerFail++
    }
}

# The two entry-point scripts must actually reach the banner, not fall through
# to the plain header because the source path was wrong.
#
# --help is not a usable probe: both scripts print usage and exit before the
# banner, by design. So each is run just far enough to render it and stop.

# The gateway installer prints the banner, then preflight. Closed stdin makes
# it stop at the first prompt.
$gw = Join-Path (Split-Path $PSScriptRoot -Parent) 'install-claude-gateway.sh'
if (Test-Path $gw) {
    $p = '/' + (($gw).Replace('\','/') -replace '^([A-Za-z]):','$1')
    $out = & $bash -c "export LANG=en_US.UTF-8; timeout 25 bash '$p' </dev/null 2>&1 | head -20" 2>&1 | Out-String
    Assert-Contains 'install-claude-gateway.sh shows the banner' $out 'github.com/naveenneog'
}

# The workstation script refuses to run on MINGW64 - correctly, it points
# Windows users at the PowerShell version - and that check comes before the
# banner. uname is shimmed to reach it. HOME is redirected at the same time so
# a run that gets further than expected cannot touch the real profile.
$ws = Join-Path $scriptsDir 'setup-claude-workstation.sh'
if (Test-Path $ws) {
    $p = '/' + (($ws).Replace('\','/') -replace '^([A-Za-z]):','$1')
    $probe = @'
tmp=$(mktemp -d); shim="$tmp/bin"; mkdir -p "$shim"
printf '#!/bin/sh\nif [ "$1" = "-s" ]; then echo Linux; else /usr/bin/uname "$@"; fi\n' > "$shim/uname"
chmod +x "$shim/uname"
PATH="$shim:$PATH" HOME="$tmp/home" LANG=en_US.UTF-8 \
  timeout 25 bash 'SCRIPT' --skip-install --skip-desktop --skip-vscode </dev/null 2>&1 | head -20
rm -rf "$tmp"
'@ -replace 'SCRIPT', $p
    $out = & $bash -c $probe 2>&1 | Out-String
    Assert-Contains 'setup-claude-workstation.sh shows the banner' $out 'github.com/naveenneog'
}

Write-Host ''
if ($bannerFail -eq 0) { Write-Host 'Runtime checks passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$bannerFail runtime check(s) failed." -ForegroundColor Red; exit 1 }
