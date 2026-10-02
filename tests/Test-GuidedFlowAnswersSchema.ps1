
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
Write-Host 'P92 guided-flow answers schema contract' -ForegroundColor Cyan
$start = Get-Content -Raw -LiteralPath (Join-Path $root 'Start-ClaudeGateway.ps1')
$flow = Get-Content -Raw -LiteralPath (Join-Path $root 'scripts\flow\FlowContract.ps1')
Assert 'answerspath-validates-with-schema' ($flow -match 'claude-gateway.answers.schema.json' -or $start -match 'claude-gateway.answers.schema.json')
Assert 'planonly-includes-shared-preflight' ($flow -match '\$checks\s*=\s*Invoke-ClaudeGatewayPreflight\s+-Answers' -or $start -match 'Invoke-ClaudeGatewayPreflight')
Assert 'approved-fingerprint-binds-preflighted-plan' ($flow -match 'preflight' -and $flow -match 'fingerprint')
Assert 'noninteractive-answers-precedence' ($flow -match 'NonInteractiveAnswers' -and $flow -match 'AnswersPath')
Finish 'P92 guided-flow answers schema contract'
