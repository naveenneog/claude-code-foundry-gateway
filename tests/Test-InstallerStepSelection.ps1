
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
Write-Host 'P92 PowerShell step selection and progress contract' -ForegroundColor Cyan
$installer = Get-Content -Raw -LiteralPath (Join-Path $root 'Install-ClaudeGateway.ps1')
Assert 'step selection parameters exist' ($installer -match '\[string\[\]\]\$Steps' -and $installer -match '\[switch\]\$ListSteps' -and $installer -match '\[string\]\$ProgressPath')
$ckpt = Get-Content -Raw -LiteralPath (Join-Path $root 'scripts\ClaudeInstallCheckpoint.ps1')
Assert 'liststeps-json-names-checkpoint-state' ($ckpt -match 'Get-ClaudeInstallStepList')
Assert 'selected-step-refuses-unverified-prerequisite' ($ckpt -match 'Assert-ClaudeInstallSelectedSteps')
Assert 'selected-step-reruns-with-p91-live-check' ($ckpt -match 'Test-ClaudeInstallStepSelected')
Assert 'progress events are emitted' ($ckpt -match 'function\s+Write-ClaudeInstallProgress\s*\{')
Assert 'progress events have required schema' ($ckpt -match 'schemaVersion' -and $ckpt -match 'resumeCommand' -and $ckpt -match 'skipped-verified')
Assert 'precedence-parameter-answers-checkpoint-default' ($installer -match 'Apply-ClaudeInstallerAnswers')
Assert 'business-units-from-answers-use-existing-script' ($installer -match 'BusinessUnits' -and $installer -match 'Set-ClaudeBusinessUnit.ps1' -and $installer -match '-Parent')
Assert 'business-units-print-usd-reconcile-command' ($installer -match 'Sync-ClaudeUsdBudgets.ps1')
Finish 'P92 PowerShell step selection and progress contract'
