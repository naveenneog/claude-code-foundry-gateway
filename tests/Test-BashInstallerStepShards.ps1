# P92 round 3, the lead's item 11 (docs/adr/0047-lean-installer-phase-0.md decision 14):
# tests/Test-BashInstallerStepSelection.ps1 runs as two Test-All checks within the default per-check timeout,
# as tests/Test-BashInstallerCheckpoint.ps1 does, and the two shards together run every check of the suite
# exactly once. The checks are those of tests/BashSuiteShards.ps1.
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
Write-Host 'Bash step-selection suite shards' -ForegroundColor Cyan
. (Join-Path $PSScriptRoot 'BashSuiteShards.ps1')
Test-BashSuiteShards -Root $root -Suite 'Test-BashInstallerStepSelection.ps1' -Name 'bash-steps' -MinAsserts 20
Write-Host ''
Write-Host ("{0} checks, {1} failed" -f $script:checks, $script:fail)
if ($script:fail) { exit 1 }