# P92 A14 (docs/adr/0047-lean-installer-phase-0.md decision 14): tests/Test-BashInstallerCheckpoint.ps1 runs as
# seven Test-All checks, each measured alone at most half of the default per-check timeout, and the seven shards
# together run every check of the suite exactly once. The partition is read from the suite's syntax tree: every
# Assert sits inside one Test-ShardGroup block, and each group belongs to one shard. The weights are the measured
# durations in tests/test-all-durations.json. The checks are those of tests/BashSuiteShards.ps1.
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
Write-Host 'Bash checkpoint suite shards' -ForegroundColor Cyan
. (Join-Path $PSScriptRoot 'BashSuiteShards.ps1')
Test-BashSuiteShards -Root $root -Suite 'Test-BashInstallerCheckpoint.ps1' -Name 'bash-checkpoint' -MinAsserts 40
Write-Host ''
Write-Host ("{0} checks, {1} failed" -f $script:checks, $script:fail)
if ($script:fail) { exit 1 }