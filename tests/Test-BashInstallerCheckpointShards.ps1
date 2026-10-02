
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$script:checks = 0
$script:fail = 0
function Assert($Label, $Condition, $Detail = '') {
    $script:checks++
    if ($Condition) { Write-Host "  [OK]   $Label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $Label$(if($Detail){" - $Detail"})" -ForegroundColor Red; $script:fail++ }
}
function Finish($Name) {
    if ($script:fail) { Write-Host "$Name failed: $script:fail of $script:checks" -ForegroundColor Red; exit 1 }
    Write-Host "$Name passed: $script:checks" -ForegroundColor Green
}

Write-Host ''
Write-Host 'P92 bash checkpoint shard registration contract' -ForegroundColor Cyan
$runner = Get-Content -Raw -LiteralPath (Join-Path $root 'tests\Test-All.ps1')
Assert 'bash-checkpoint-shards-cover-every-case-once' ($runner -match 'macOS/Linux installer checkpoint and resume \[0/' -and $runner -match 'macOS/Linux installer checkpoint and resume \[1/')
Assert 'bash-checkpoint-shard-loads-under-default-timeout' ($runner -notmatch "Test-BashInstallerCheckpoint\.ps1' -SkipReason \$bashInstallerSkip -TimeoutSeconds 900")
Finish 'P92 bash checkpoint shard registration contract'
