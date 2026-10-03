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
$summary = [regex]::Match($out, '(?m)^# tests\s+(\d+)\s*$')
$tapCount = if ($summary.Success) { [int]$summary.Groups[1].Value } else { @([regex]::Matches($out, '(?m)^\s*(?:not )?ok\s+\d+\s+-\s+')).Count }
Assert 'node:test loaded and reported individual subtests' ($tapCount -ge 10) $out
foreach ($match in [regex]::Matches($out, '(?m)^ok\s+\d+\s+-\s+(.+)$')) {
    Assert ("node:test: " + $match.Groups[1].Value.Trim()) $true
}
foreach ($match in [regex]::Matches($out, '(?m)^not ok\s+\d+\s+-\s+(.+)$')) {
    Assert ("node:test: " + $match.Groups[1].Value.Trim()) $false $out
}
if ($code -ne 0 -and $tapCount -eq 0) { Assert 'node:test process exited successfully' $false $out }

Write-Host ''
Write-Host ("{0} checks, {1} failed, {2:N1} s" -f $script:checks, $script:fail, $watch.Elapsed.TotalSeconds)
if ($script:fail) { exit 1 }
