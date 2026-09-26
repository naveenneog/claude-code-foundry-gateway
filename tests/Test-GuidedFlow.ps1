# Guided flow orchestrator contract (ADR-0030). Offline; no Azure calls.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$fail = 0
function Assert($label, $condition, $detail = '') {
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $label$(if ($detail) { " - $detail" })" -ForegroundColor Red; $script:fail++ }
}
function Get-Thrown([scriptblock]$Block) { try { & $Block; return '' } catch { return $_.Exception.Message } }
function Read-Json($Path) { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }

Write-Host ''
Write-Host 'Guided flow - orchestrator' -ForegroundColor Cyan

$scratch = Join-Path ([IO.Path]::GetTempPath()) ('guided-flow-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch -Force | Out-Null
$modules = Join-Path $scratch 'flow'
New-Item -ItemType Directory -Path $modules -Force | Out-Null
$recordPath = Join-Path $scratch 'onboarding\claude-gateway.json'
$guidePath = Join-Path $scratch 'onboarding\HOW-TO-USE.md'
$start = Join-Path $root 'Start-ClaudeGateway.ps1'
try {
    $env:CLAUDE_FLOW_SKIP_AZ_DISCOVERY = '1'
    @'
function Get-ClaudeFlowStepInfo { [pscustomobject]@{ Name = 'Foundation'; Title = 'Foundation'; DecisionKey = 'foundation'; DependsOn = @(); Actions = @('Setup','Change','Guide') } }
function Get-ClaudeFlowStepQuestions {
    param($Record, $Discovery)
    @([pscustomobject]@{
        Key = 'foundation.sku'; Question = 'Which API Management tier?'; Recommended = 'BasicV2'
        Options = @(
            New-ClaudeChoiceOption -Value 'BasicV2' -Label 'Basic v2' -Detail '$150/month; public gateway; no VNet integration' -Recommended -Reason 'lowest-cost v2 tier for a pilot'
            New-ClaudeChoiceOption -Value 'StandardV2' -Label 'Standard v2' -Detail '$650/month; outbound VNet integration'
        )
    })
}
function Get-ClaudeFlowStepPlan {
    param($Record, $Discovery)
    New-ClaudeFlowPlan -Step Foundation -Summary "Create gateway $($Record.decisions.foundation.sku)" `
        -Actions @(New-ClaudeFlowAction -Verb Create -Target 'apim/contoso' -Detail $Record.decisions.foundation.sku) `
        -Costs @(New-ClaudeFlowCost -Item 'API Management' -MonthlyUsd 150 -Source 'stub') `
        -Implications @('Developers use the gateway URL') -Requires @('Contributor') -Rollback 'Delete the resource group'
}
function Invoke-ClaudeFlowStep {
    param($Record, $Plan)
    if ($env:GUIDED_FLOW_FAIL_FOUNDATION -eq '1') { throw 'foundation apply failed' }
    @{ gatewayUrl = 'https://apim-contoso.azure-api.net/claude'; resourceGroup = 'rg-contoso'; apimName = 'apim-contoso'; foundationApplied = $true }
}
function Test-ClaudeFlowStep { param($Record) [pscustomobject]@{ Step = 'Foundation'; Passed = $true; Checks = @(@{ Name = 'record'; Passed = $true; Evidence = 'applied'; Fix = '' }) } }
'@ | Set-Content -LiteralPath (Join-Path $modules 'Foundation.ps1') -Encoding UTF8

    @'
function Get-ClaudeFlowStepInfo { [pscustomobject]@{ Name = 'DeviceProfiles'; Title = 'Device profiles'; DecisionKey = 'deviceProfiles'; DependsOn = @('Foundation'); Actions = @('Setup','Change','Guide') } }
function Get-ClaudeFlowStepQuestions { param($Record, $Discovery) @() }
function Get-ClaudeFlowStepPlan {
    param($Record, $Discovery)
    New-ClaudeFlowPlan -Step DeviceProfiles -Summary 'Generate per-tier profiles' `
        -Actions @(New-ClaudeFlowAction -Verb Write -Target 'onboarding/profiles') `
        -Costs @() -Implications @('MDM assignment remains manual') -Rollback 'Delete generated profiles'
}
function Invoke-ClaudeFlowStep { param($Record, $Plan) @{ deviceProfiles = @{ tiers = @('standard','premium') } } }
function Test-ClaudeFlowStep { param($Record) [pscustomobject]@{ Step = 'DeviceProfiles'; Passed = $true; Checks = @(@{ Name = 'profiles'; Passed = $true; Evidence = 'generated'; Fix = '' }) } }
'@ | Set-Content -LiteralPath (Join-Path $modules 'DeviceProfiles.ps1') -Encoding UTF8

    @'
function Get-ClaudeFlowStepInfo { [pscustomobject]@{ Name = 'Guide'; Title = 'Guide'; DecisionKey = 'guide'; DependsOn = @('DeviceProfiles'); Actions = @('Setup','Guide') } }
function Get-ClaudeFlowStepQuestions { param($Record, $Discovery) @() }
function Get-ClaudeFlowStepPlan {
    param($Record, $Discovery)
    New-ClaudeFlowPlan -Step Guide -Summary 'Write deployment guide' -Actions @(New-ClaudeFlowAction -Verb Write -Target 'onboarding/HOW-TO-USE.md') -Rollback 'Delete generated guide'
}
function Invoke-ClaudeFlowStep {
    param($Record, $Plan)
    $path = Join-Path (Split-Path $Record.__recordPath -Parent) 'HOW-TO-USE.md'
    @(
        '# How to use this Claude gateway'
        ''
        '## What was set up'
        '## Monthly cost'
        '## Administrator daily tasks'
        '## Developer setup'
        'VS Code first, then CLI, then Desktop. Use MDM for managed devices.'
        '## FinOps tool'
        '## Workbooks and reports'
        '## Update, change and diagnose'
    ) | Set-Content -LiteralPath $path -Encoding UTF8
    @{ guide = @{ path = $path } }
}
function Test-ClaudeFlowStep { param($Record) [pscustomobject]@{ Step = 'Guide'; Passed = (Test-Path -LiteralPath (Join-Path (Split-Path $Record.__recordPath -Parent) 'HOW-TO-USE.md')); Checks = @() } }
'@ | Set-Content -LiteralPath (Join-Path $modules 'Guide.ps1') -Encoding UTF8

    $planOnly = & $start -Action Setup -RecordPath $recordPath -FlowModulePath $modules -PlanOnly -NonInteractiveAnswers @{ 'foundation.sku' = 'BasicV2' } *>&1 | Out-String
    Assert 'PlanOnly prints the combined review' ($planOnly -match '\[Foundation\]' -and $planOnly -match '\[DeviceProfiles\]' -and $planOnly -match '\[Guide\]')
    Assert 'PlanOnly prints a fingerprint' ($planOnly -match 'Fingerprint:\s+[a-f0-9]{64}')
    Assert 'PlanOnly notes absent branch modules without failing' ($planOnly -match 'Skipped absent step: Entitlement' -and $planOnly -match 'Skipped absent step: FinOps')
    Assert 'PlanOnly writes nothing' (-not (Test-Path -LiteralPath $recordPath) -and -not (Test-Path -LiteralPath $guidePath))
    $fp = [regex]::Match($planOnly, 'Fingerprint:\s+([a-f0-9]{64})').Groups[1].Value

    Assert 'apply without a matching fingerprint is refused' ((Get-Thrown { & $start -Action Setup -RecordPath $recordPath -FlowModulePath $modules -NonInteractiveAnswers @{ 'foundation.sku' = 'BasicV2' } }) -match 'ApprovedPlanFingerprint')
    Assert 'a wrong fingerprint is refused' ((Get-Thrown { & $start -Action Setup -RecordPath $recordPath -FlowModulePath $modules -ApprovedPlanFingerprint ('0' * 64) -NonInteractiveAnswers @{ 'foundation.sku' = 'BasicV2' } }) -match 'does not match')
    Assert 'refusal writes nothing' (-not (Test-Path -LiteralPath $recordPath))

    & $start -Action Setup -RecordPath $recordPath -FlowModulePath $modules -ApprovedPlanFingerprint $fp -NonInteractiveAnswers @{ 'foundation.sku' = 'BasicV2' } | Out-Null
    $record = Read-Json $recordPath
    Assert 'questions are aggregated into the decision record' ($record.decisions.foundation.sku -eq 'BasicV2')
    Assert 'record fields from every applied step are preserved' ($record.gatewayUrl -match '^https://' -and $record.foundationApplied -and $record.decisions.deviceProfiles.tiers.Count -eq 2)
    Assert 'history is written after each step' ($record.history.Count -eq 3 -and (@($record.history | ForEach-Object decision) -join ',') -eq 'foundation,deviceProfiles,guide')
    Assert 'generated guide contains the required sections' ((Get-Content -LiteralPath $guidePath -Raw) -match 'What was set up' -and (Get-Content -LiteralPath $guidePath -Raw) -match 'VS Code first, then CLI, then Desktop' -and (Get-Content -LiteralPath $guidePath -Raw) -match 'Update, change and diagnose')

    Remove-Item -LiteralPath $recordPath -Force
    $resumeFp = $fp
    $env:GUIDED_FLOW_FAIL_FOUNDATION = '1'
    Assert 'a failed step leaves no success-shaped history' ((Get-Thrown { & $start -Action Setup -RecordPath $recordPath -FlowModulePath $modules -ApprovedPlanFingerprint $resumeFp -NonInteractiveAnswers @{ 'foundation.sku' = 'BasicV2' } }) -match 'foundation apply failed')
    $env:GUIDED_FLOW_FAIL_FOUNDATION = $null
    & $start -Action Setup -RecordPath $recordPath -FlowModulePath $modules -ApprovedPlanFingerprint $resumeFp -NonInteractiveAnswers @{ 'foundation.sku' = 'BasicV2' } | Out-Null
    $record = Read-Json $recordPath
    Assert 'rerun resumes and completes after a failed first step' ($record.history.Count -eq 3)

    $before = Get-Content -LiteralPath $recordPath -Raw
    & $start -Action Setup -RecordPath $recordPath -FlowModulePath $modules -ApprovedPlanFingerprint $fp -NonInteractiveAnswers @{ 'foundation.sku' = 'BasicV2' } -WhatIf | Out-Null
    $after = Get-Content -LiteralPath $recordPath -Raw
    Assert 'WhatIf writes nothing' ($before -eq $after)

    $status = & $start -Action Status -RecordPath $recordPath -FlowModulePath $modules *>&1 | Out-String
    Assert 'Status prints decisions, release and history' ($status -match 'Decisions' -and $status -match 'Release' -and $status -match 'History')
}
finally {
    $env:GUIDED_FLOW_FAIL_FOUNDATION = $null
    $env:CLAUDE_FLOW_SKIP_AZ_DISCOVERY = $null
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail) { Write-Host "$fail assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'Guided flow orchestrator holds.' -ForegroundColor Green
exit 0
