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
Write-Host 'Installer UI server' -ForegroundColor Cyan
$watch = [Diagnostics.Stopwatch]::StartNew()
$out = & node --test --test-reporter=tap (Join-Path $PSScriptRoot 'installer-ui.test.mjs') 2>&1 | Out-String
$code = $LASTEXITCODE
Assert 'node:test covers launch security, schema rendering, preflight, commands, run and rerun with the stub' ($code -eq 0) $out

Write-Host ''
Write-Host ("{0} checks, {1} failed, {2:N1} s" -f $script:checks, $script:fail, $watch.Elapsed.TotalSeconds)
if ($script:fail) { exit 1 }
