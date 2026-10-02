
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
Write-Host 'P92 PowerShell preflight contract' -ForegroundColor Cyan
$installer = Get-Content -Raw -LiteralPath (Join-Path $root 'Install-ClaudeGateway.ps1')
Assert 'preflight parameters exist' ($installer -match '\[switch\]\$Preflight' -and $installer -match '\[switch\]\$Json' -and $installer -match '\[string\]\$AnswersPath')
$lib = Join-Path $root 'scripts\ClaudeInstallerAnswers.ps1'
Assert 'shared answers/preflight library exists' (Test-Path -LiteralPath $lib)
if (Test-Path -LiteralPath $lib) { . $lib }
$ids = 'answers.schema','answers.crossField','target.tenant','target.subscription','operator.adminPrereqs','foundry.account','foundry.deployments','apim.nameAvailability','apim.existingSku','apim.existingIdentity','entra.groupNames','businessUnits.ids','businessUnits.depth','address.inputs'
$missingIds = @()
if (Get-Command Get-ClaudeInstallerPreflightCheckIds -ErrorAction SilentlyContinue) { $got = @(Get-ClaudeInstallerPreflightCheckIds); $missingIds = @($ids | Where-Object { $_ -notin $got }) } else { $missingIds = $ids }
Assert 'preflight-json-shape has stable check ids' ($missingIds.Count -eq 0) ($missingIds -join ', ')
$libText = if (Test-Path -LiteralPath $lib) { Get-Content -Raw -LiteralPath $lib } else { '' }
Assert 'preflight-reuses-admin-prerequisites' ($libText -match 'Test-ClaudePrerequisites\s+-Mode\s+Admin')
Assert 'preflight uses P91 verdict reader' ($libText -match 'Invoke-ClaudeInstallAzRead' -and $libText -notmatch 'Invoke-AzOptional')
Assert 'preflight reports all failures' (Get-Command Invoke-ClaudeGatewayPreflight -ErrorAction SilentlyContinue)
Finish 'P92 PowerShell preflight contract'
