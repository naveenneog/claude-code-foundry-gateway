
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
Write-Host 'P92 bash preflight, steps and progress contract' -ForegroundColor Cyan
$installer = Get-Content -Raw -LiteralPath (Join-Path $root 'install-claude-gateway.sh')
Assert 'bash preflight flags exist' ($installer -match '--answers-file' -and $installer -match '--preflight' -and $installer -match '--json')
Assert 'bash step flags exist' ($installer -match '--list-steps' -and $installer -match '--steps' -and $installer -match '--progress-file')
$lib = Join-Path $root 'scripts\install-answers.sh'
Assert 'bash shared answers library exists' (Test-Path -LiteralPath $lib)
$txt = if (Test-Path -LiteralPath $lib) { Get-Content -Raw -LiteralPath $lib } else { '' }
Assert 'bash-preflight-uses-same-schema' ($txt -match 'claude-gateway.answers.schema.json')
Assert 'bash-progress-events-have-required-schema' ($txt -match 'schemaVersion' -and $txt -match 'resumeCommand' -and $txt -match 'skipped-verified')
$forbidden = '(?m)^[^#\n]*(\b(declare|local|typeset)\s+-[a-zA-Z]*A\b|\bmapfile\b|\breadarray\b|\$\{[^}\n]*(,,|\^\^)[^}\n]*\}|\|&|&>>|\bcoproc\b|\bsed\s+-i(\s|$)|\bdate\s+(-[a-zA-Z]*\s+)*-d\b|\breadlink\s+-f\b|\bstat\s+-c\b|\bfind\b[^\n]*-printf\b|\bgrep\s+-[a-zA-Z]*P)'
Assert 'bash-preflight-keeps-bash-32-syntax' ($txt -and -not [regex]::IsMatch($txt, $forbidden))
Finish 'P92 bash preflight, steps and progress contract'
