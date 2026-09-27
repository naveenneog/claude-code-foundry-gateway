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
$countsPath = Join-Path $scratch 'counts.json'
$start = Join-Path $root 'Start-ClaudeGateway.ps1'
try {
    $env:CLAUDE_FLOW_SKIP_AZ_DISCOVERY = '1'
    $env:GUIDED_FLOW_COUNTS = $countsPath
    $updateRoot = Join-Path $root 'Update-ClaudeGateway.ps1'
    $updateScripts = Join-Path $root 'scripts\Update-ClaudeGateway.ps1'
    $debugSetup = Join-Path $root 'scripts\Debug-ClaudeSetup.ps1'
    $debugWorkstation = Join-Path $root 'scripts\Debug-ClaudeWorkstation.ps1'
    $createdIntegrationFiles = @()
    if (-not (Test-Path -LiteralPath $updateRoot)) {
        "param([string]`$RecordPath) 'root' | Set-Content -LiteralPath '$($scratch -replace '''','''''')\update-choice.txt' -Encoding UTF8" | Set-Content -LiteralPath $updateRoot -Encoding UTF8
        $createdIntegrationFiles += $updateRoot
    }
    if (-not (Test-Path -LiteralPath $updateScripts)) {
        "param([string]`$RecordPath) 'scripts' | Set-Content -LiteralPath '$($scratch -replace '''','''''')\update-choice.txt' -Encoding UTF8" | Set-Content -LiteralPath $updateScripts -Encoding UTF8
        $createdIntegrationFiles += $updateScripts
    }
    if (-not (Test-Path -LiteralPath $debugSetup)) {
        "param([string]`$RecordPath,[switch]`$SupportBundle) ('setup:' + [bool]`$SupportBundle) | Add-Content -LiteralPath '$($scratch -replace '''','''''')\diagnose-choice.txt'" | Set-Content -LiteralPath $debugSetup -Encoding UTF8
        $createdIntegrationFiles += $debugSetup
    }
    if (-not (Test-Path -LiteralPath $debugWorkstation)) {
        "param([string]`$RecordPath,[switch]`$SupportBundle) ('workstation:' + [bool]`$SupportBundle) | Add-Content -LiteralPath '$($scratch -replace '''','''''')\diagnose-choice.txt'" | Set-Content -LiteralPath $debugWorkstation -Encoding UTF8
        $createdIntegrationFiles += $debugWorkstation
    }
    & $start -Action Update -RecordPath $recordPath | Out-Null
    $updateChoice = Join-Path $scratch 'update-choice.txt'
    if (Test-Path -LiteralPath $updateChoice) {
        Assert 'Update prefers scripts/Update-ClaudeGateway.ps1 over the root fallback' ((Get-Content -LiteralPath $updateChoice -Raw).Trim() -eq 'scripts')
    }
    else {
        Assert 'Update delegates to the present branch updater' (Test-Path -LiteralPath $updateScripts)
    }
    & $start -Action Diagnose -RecordPath $recordPath -SupportBundle | Out-Null
    if ($createdIntegrationFiles -contains $debugSetup -or $createdIntegrationFiles -contains $debugWorkstation) {
        $diagnose = Get-Content -LiteralPath (Join-Path $scratch 'diagnose-choice.txt') -Raw
        Assert 'Diagnose passes RecordPath and SupportBundle to branch scripts' ($diagnose -match 'setup:True' -and $diagnose -match 'workstation:True')
    }
    else {
        Assert 'Diagnose delegates to present branch scripts' ((Test-Path -LiteralPath $debugSetup) -and (Test-Path -LiteralPath $debugWorkstation))
    }
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
    $mark = if ($env:GUIDED_FLOW_PLAN_MARK) { $env:GUIDED_FLOW_PLAN_MARK } else { 'default' }
    New-ClaudeFlowPlan -Step Foundation -Summary "Create gateway $($Record.decisions.foundation.sku) for $($Record.decisions.foundation.foundryAccount)" `
        -Actions @(New-ClaudeFlowAction -Verb Create -Target 'apim/contoso' -Detail "$($Record.decisions.foundation.sku):$mark") `
        -Costs @(New-ClaudeFlowCost -Item 'API Management' -MonthlyUsd 150 -Source 'stub') `
        -Implications @('Developers use the gateway URL') -Requires @('Contributor') -Rollback 'Delete the resource group'
}
function Invoke-ClaudeFlowStep {
    param($Record, $Plan)
    if ($env:GUIDED_FLOW_FAIL_FOUNDATION -eq '1') { throw 'foundation apply failed' }
    $counts = @{}
    if ($env:GUIDED_FLOW_COUNTS -and (Test-Path -LiteralPath $env:GUIDED_FLOW_COUNTS)) {
        $raw = Get-Content -LiteralPath $env:GUIDED_FLOW_COUNTS -Raw | ConvertFrom-Json
        foreach ($p in $raw.PSObject.Properties) { $counts[$p.Name] = [int]$p.Value }
    }
    $counts['Foundation'] = 1 + $(if ($counts.ContainsKey('Foundation')) { [int]$counts['Foundation'] } else { 0 })
    if ($env:GUIDED_FLOW_COUNTS) { $counts | ConvertTo-Json | Set-Content -LiteralPath $env:GUIDED_FLOW_COUNTS -Encoding UTF8 }
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
function Invoke-ClaudeFlowStep {
    param($Record, $Plan)
    if ($env:GUIDED_FLOW_FAIL_DEVICEPROFILES -eq '1') { throw 'device profiles apply failed' }
    @{ deviceProfiles = @{ tiers = @('standard','premium') } }
}
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
    @'
function Get-ClaudeFlowStepInfo { [pscustomobject]@{ Name = 'Tier'; Title = 'Tier'; DecisionKey = 'sku'; DependsOn = @('Foundation'); Actions = @('Change') } }
function Get-ClaudeFlowStepQuestions { param($Record, $Discovery) @() }
function Get-ClaudeFlowStepPlan { param($Record, $Discovery) New-ClaudeFlowPlan -Step Tier -Summary 'Tier' }
function Invoke-ClaudeFlowStep { param($Record, $Plan) @{} }
function Test-ClaudeFlowStep { param($Record) [pscustomobject]@{ Step = 'Tier'; Passed = $true; Checks = @() } }
'@ | Set-Content -LiteralPath (Join-Path $modules 'Tier.ps1') -Encoding UTF8

    $planOnly = & $start -Action Setup -RecordPath $recordPath -FlowModulePath $modules -PlanOnly -NonInteractiveAnswers @{ 'foundation.sku' = 'BasicV2' } *>&1 | Out-String
    Assert 'PlanOnly prints the combined review' ($planOnly -match '\[Foundation\]' -and $planOnly -match '\[DeviceProfiles\]' -and $planOnly -match '\[Guide\]')
    Assert 'PlanOnly prints a fingerprint' ($planOnly -match 'Fingerprint:\s+[a-f0-9]{64}')
    Assert 'PlanOnly notes absent branch modules without failing' ($planOnly -match 'Skipped absent step: Entitlement' -and $planOnly -match 'Skipped absent step: FinOps')
    Assert 'a present Change-only module is not reported as absent' ($planOnly -notmatch 'Skipped absent step: Tier')
    Assert 'a present Change-only module is named with the command that runs it' ($planOnly -match 'Tier[^\r\n]*-Action Change -Change sku')
    Assert 'PlanOnly writes nothing' (-not (Test-Path -LiteralPath $recordPath) -and -not (Test-Path -LiteralPath $guidePath))
    $fp = [regex]::Match($planOnly, 'Fingerprint:\s+([a-f0-9]{64})').Groups[1].Value
    $planOnlyAgain = & $start -Action Setup -RecordPath $recordPath -FlowModulePath $modules -PlanOnly -NonInteractiveAnswers @{ 'foundation.sku' = 'BasicV2' } *>&1 | Out-String
    $fpAgain = [regex]::Match($planOnlyAgain, 'Fingerprint:\s+([a-f0-9]{64})').Groups[1].Value
    Assert 'repeated PlanOnly keeps the same step order and fingerprint' ($fpAgain -eq $fp)

    Assert 'apply without a matching fingerprint is refused' ((Get-Thrown { & $start -Action Setup -RecordPath $recordPath -FlowModulePath $modules -NonInteractiveAnswers @{ 'foundation.sku' = 'BasicV2' } }) -match 'ApprovedPlanFingerprint')
    Assert 'a wrong fingerprint is refused' ((Get-Thrown { & $start -Action Setup -RecordPath $recordPath -FlowModulePath $modules -ApprovedPlanFingerprint ('0' * 64) -NonInteractiveAnswers @{ 'foundation.sku' = 'BasicV2' } }) -match 'does not match')
    Assert 'refusal writes nothing' (-not (Test-Path -LiteralPath $recordPath))

    & $start -Action Setup -RecordPath $recordPath -FlowModulePath $modules -ApprovedPlanFingerprint $fp -NonInteractiveAnswers @{ 'foundation.sku' = 'BasicV2' } | Out-Null
    $record = Read-Json $recordPath
    Assert 'questions are aggregated into the decision record' ($record.decisions.foundation.sku -eq 'BasicV2')
    Assert 'record fields from every applied step are preserved' ($record.gatewayUrl -match '^https://' -and $record.foundationApplied -and $record.decisions.deviceProfiles.tiers.Count -eq 2)
    Assert 'history is written after each step' ($record.history.Count -eq 3 -and (@($record.history | ForEach-Object decision) -join ',') -eq 'foundation,deviceProfiles,guide')
    Assert 'successful run clears activeRun' (-not ($record.PSObject.Properties.Name -contains 'activeRun'))
    Assert 'history entries carry runId' (@($record.history | Where-Object { -not $_.runId }).Count -eq 0)
    Assert 'generated guide contains the required sections' ((Get-Content -LiteralPath $guidePath -Raw) -match 'What was set up' -and (Get-Content -LiteralPath $guidePath -Raw) -match 'VS Code first, then CLI, then Desktop' -and (Get-Content -LiteralPath $guidePath -Raw) -match 'Update, change and diagnose')

    $changePlan = & $start -Action Change -Change foundation -RecordPath $recordPath -FlowModulePath $modules -PlanOnly -NonInteractiveAnswers @{ 'foundation.sku' = 'StandardV2' } *>&1 | Out-String
    Assert 'Change asks selected questions even when a decision exists' ($changePlan -match 'StandardV2')

    $answersPath = Join-Path $scratch 'answers.json'
    @{ 'foundation.sku' = 'BasicV2'; 'foundation.foundryAccount' = 'ai-contoso' } | ConvertTo-Json | Set-Content -LiteralPath $answersPath -Encoding UTF8
    $answersPlan = & $start -Action Setup -RecordPath (Join-Path $scratch 'answers-record.json') -FlowModulePath $modules -PlanOnly -AnswersPath $answersPath *>&1 | Out-String
    Assert 'AnswersPath supplies non-interactive answers' ($answersPlan -match 'BasicV2')
    Assert 'AnswersPath seeds unasked decision keys' ($answersPlan -match 'ai-contoso')

    $beforeSecond = (Read-Json $countsPath).Foundation
    & $start -Action Setup -RecordPath $recordPath -FlowModulePath $modules -ApprovedPlanFingerprint $fp -NonInteractiveAnswers @{ 'foundation.sku' = 'BasicV2' } | Out-Null
    $afterSecond = (Read-Json $countsPath).Foundation
    $record = Read-Json $recordPath
    Assert 'a later Setup starts a new run and reapplies steps' ($afterSecond -eq ($beforeSecond + 1) -and $record.history.Count -eq 6)

    Remove-Item -LiteralPath $recordPath -Force
    $resumeFp = $fp
    $env:GUIDED_FLOW_FAIL_DEVICEPROFILES = '1'
    Assert 'an interrupted run keeps activeRun for resume' ((Get-Thrown { & $start -Action Setup -RecordPath $recordPath -FlowModulePath $modules -ApprovedPlanFingerprint $resumeFp -NonInteractiveAnswers @{ 'foundation.sku' = 'BasicV2' } }) -match 'device profiles apply failed')
    $interrupted = Read-Json $recordPath
    $interruptedRunId = $interrupted.activeRun.id
    Assert 'interrupted history is scoped to activeRun' ($interrupted.activeRun.fingerprint -eq $resumeFp -and $interrupted.history[0].runId -eq $interruptedRunId)
    $env:GUIDED_FLOW_FAIL_DEVICEPROFILES = $null
    $countBeforeResume = (Read-Json $countsPath).Foundation
    & $start -Action Setup -RecordPath $recordPath -FlowModulePath $modules -ApprovedPlanFingerprint $resumeFp -NonInteractiveAnswers @{ 'foundation.sku' = 'BasicV2' } | Out-Null
    $countAfterResume = (Read-Json $countsPath).Foundation
    $record = Read-Json $recordPath
    Assert 'rerun resumes only the same activeRun fingerprint' ($record.history.Count -eq 3 -and $countAfterResume -eq $countBeforeResume -and -not ($record.PSObject.Properties.Name -contains 'activeRun'))

    Remove-Item -LiteralPath $recordPath -Force
    $env:GUIDED_FLOW_PLAN_MARK = 'old'
    $oldPlan = & $start -Action Setup -RecordPath $recordPath -FlowModulePath $modules -PlanOnly -NonInteractiveAnswers @{ 'foundation.sku' = 'BasicV2' } *>&1 | Out-String
    $oldFp = [regex]::Match($oldPlan, 'Fingerprint:\s+([a-f0-9]{64})').Groups[1].Value
    $env:GUIDED_FLOW_FAIL_DEVICEPROFILES = '1'
    Assert 'old fingerprint interruption is recorded' ((Get-Thrown { & $start -Action Setup -RecordPath $recordPath -FlowModulePath $modules -ApprovedPlanFingerprint $oldFp -NonInteractiveAnswers @{ 'foundation.sku' = 'BasicV2' } }) -match 'device profiles apply failed')
    $countBeforeNewFingerprint = (Read-Json $countsPath).Foundation
    $env:GUIDED_FLOW_PLAN_MARK = 'new'
    $newPlan = & $start -Action Setup -RecordPath $recordPath -FlowModulePath $modules -PlanOnly -NonInteractiveAnswers @{ 'foundation.sku' = 'BasicV2' } *>&1 | Out-String
    $newFp = [regex]::Match($newPlan, 'Fingerprint:\s+([a-f0-9]{64})').Groups[1].Value
    $env:GUIDED_FLOW_FAIL_DEVICEPROFILES = $null
    & $start -Action Setup -RecordPath $recordPath -FlowModulePath $modules -ApprovedPlanFingerprint $newFp -NonInteractiveAnswers @{ 'foundation.sku' = 'BasicV2' } | Out-Null
    $countAfterNewFingerprint = (Read-Json $countsPath).Foundation
    $record = Read-Json $recordPath
    Assert 'a changed plan fingerprint starts a new run instead of resuming' ($newFp -ne $oldFp -and $countAfterNewFingerprint -eq ($countBeforeNewFingerprint + 1) -and @($record.history | Select-Object -ExpandProperty runId -Unique).Count -ge 2)
    $env:GUIDED_FLOW_PLAN_MARK = $null

    $before = Get-Content -LiteralPath $recordPath -Raw
    & $start -Action Setup -RecordPath $recordPath -FlowModulePath $modules -ApprovedPlanFingerprint $fp -NonInteractiveAnswers @{ 'foundation.sku' = 'BasicV2' } -WhatIf | Out-Null
    $after = Get-Content -LiteralPath $recordPath -Raw
    Assert 'WhatIf writes nothing' ($before -eq $after)

    $status = & $start -Action Status -RecordPath $recordPath -FlowModulePath $modules *>&1 | Out-String
    Assert 'Status prints decisions, release and history' ($status -match 'Decisions' -and $status -match 'Release' -and $status -match 'History')

    # The real Foundation plan: an approval must not carry over to a different estate.
    $realFoundationPlan = {
        param([string]$ResourceGroup, [string]$NamePrefix)
        . (Join-Path $root 'scripts\flow\FlowContract.ps1')
        . (Join-Path $root 'scripts\flow\Foundation.ps1')
        $foundation = [pscustomobject]@{ sku = 'BasicV2'; subscriptionId = '00000000-0000-0000-0000-000000000001'; resourceGroup = $ResourceGroup; location = 'eastus2'; namePrefix = $NamePrefix; foundryAccount = 'ai-contoso'; foundryResourceGroup = 'rg-ai' }
        $rec = [pscustomobject]@{ schemaVersion = 2; decisions = [pscustomobject]@{ foundation = $foundation }; history = @() }
        $plan = Get-ClaudeFlowStepPlan -Record $rec -Discovery $null
        [pscustomobject]@{ Fingerprint = (Get-ClaudeFlowFingerprint -Plans @($plan)); Review = (Format-ClaudeFlowReview -Plans @($plan)) }
    }
    $planA = & $realFoundationPlan 'rg-p66-a' 'p66a'
    $planB = & $realFoundationPlan 'rg-p66-b' 'p66b'
    Assert 'the Foundation fingerprint changes when the target resource group and name change' ($planA.Fingerprint -ne $planB.Fingerprint)
    Assert 'the Foundation review names the resource group, gateway, region and Foundry account' ($planA.Review -match 'rg-p66-a/apim-p66a' -and $planA.Review -match 'eastus2' -and $planA.Review -match 'ai-contoso')

    # The same through the orchestrator with the shipped modules: module helpers must stay callable.
    $realReviews = foreach ($pair in @(@('rg-p66-a', 'p66a'), @('rg-p66-b', 'p66b'))) {
        $realAnswers = Join-Path $scratch "real-answers-$($pair[1]).json"
        @{ 'foundation.sku' = 'BasicV2'; 'foundation.resourceGroup' = $pair[0]; 'foundation.namePrefix' = $pair[1]; 'foundation.location' = 'eastus2'; 'foundation.foundryAccount' = 'ai-contoso'; 'deviceProfiles.conversationStorage' = 'local' } | ConvertTo-Json | Set-Content -LiteralPath $realAnswers -Encoding UTF8
        try { & $start -Action Setup -PlanOnly -RecordPath (Join-Path $scratch "real-record-$($pair[1]).json") -AnswersPath $realAnswers *>&1 | Out-String }
        catch { "THREW: $($_.Exception.Message)" }
    }
    $realFpA = [regex]::Match([string]$realReviews[0], 'Fingerprint:\s+([a-f0-9]{64})').Groups[1].Value
    $realFpB = [regex]::Match([string]$realReviews[1], 'Fingerprint:\s+([a-f0-9]{64})').Groups[1].Value
    Assert 'the orchestrator plans the shipped modules and names the target' ([string]$realReviews[0] -match 'rg-p66-a/apim-p66a' -and $realFpA) ([string]$realReviews[0] | Select-String -Pattern 'THREW.*' | ForEach-Object { $_.Matches[0].Value })
    Assert 'the orchestrator fingerprint differs between two targets' ($realFpA -and $realFpB -and $realFpA -ne $realFpB)

    $offlinePrice = & {
        . (Join-Path $root 'scripts\flow\FlowContract.ps1')
        . (Join-Path $root 'scripts\flow\lib\LifecycleCommon.ps1')
        function Invoke-RestMethod { throw 'simulated outage' }
        Get-ClaudeFlowLifecycleApimMonthlyCost -Sku BasicV2 -Region eastus2
    }
    Assert 'an unreachable price API is reported as unreachable, not as a missing meter' ($null -eq $offlinePrice.MonthlyUsd -and $offlinePrice.UnknownReason -match 'could not be reached') $offlinePrice.UnknownReason

    # Update through the flow: plan by default, apply only with an approved fingerprint.
    $shadow = Join-Path $scratch 'shadow'
    New-Item -ItemType Directory -Force -Path (Join-Path $shadow 'scripts\flow') | Out-Null
    Copy-Item -LiteralPath (Join-Path $root 'Start-ClaudeGateway.ps1') -Destination $shadow
    Copy-Item -LiteralPath (Join-Path $root 'scripts\ClaudeChoice.ps1') -Destination (Join-Path $shadow 'scripts')
    Copy-Item -LiteralPath (Join-Path $root 'scripts\flow\FlowContract.ps1') -Destination (Join-Path $shadow 'scripts\flow')
    $updateLog = Join-Path $scratch 'update-args.txt'
    "[CmdletBinding(SupportsShouldProcess)] param([string]`$RecordPath,[switch]`$Apply,[string]`$ApprovedPlanFingerprint) ('apply=' + [bool]`$Apply + ';fp=' + `$ApprovedPlanFingerprint) | Set-Content -LiteralPath '$($updateLog -replace '''','''''')'" | Set-Content -LiteralPath (Join-Path $shadow 'scripts\Update-ClaudeGateway.ps1') -Encoding UTF8
    $shadowStart = Join-Path $shadow 'Start-ClaudeGateway.ps1'
    & $shadowStart -Action Update -RecordPath $recordPath | Out-Null
    $updatePlanned = Get-Content -LiteralPath $updateLog -Raw
    & $shadowStart -Action Update -RecordPath $recordPath -ApprovedPlanFingerprint 'abc12345' | Out-Null
    $updateApplied = Get-Content -LiteralPath $updateLog -Raw
    & $shadowStart -Action Update -RecordPath $recordPath -ApprovedPlanFingerprint 'abc12345' -PlanOnly | Out-Null
    $updatePlanOnly = Get-Content -LiteralPath $updateLog -Raw
    Assert 'Update without a fingerprint only plans' ($updatePlanned -match 'apply=False;fp=\s*$')
    Assert 'Update with an approved fingerprint applies that plan' ($updateApplied -match 'apply=True;fp=abc12345')
    Assert 'Update with PlanOnly never applies' ($updatePlanOnly -match 'apply=False')
}
finally {
    $env:GUIDED_FLOW_FAIL_FOUNDATION = $null
    $env:GUIDED_FLOW_FAIL_DEVICEPROFILES = $null
    $env:GUIDED_FLOW_PLAN_MARK = $null
    $env:GUIDED_FLOW_COUNTS = $null
    $env:CLAUDE_FLOW_SKIP_AZ_DISCOVERY = $null
    foreach ($file in @($createdIntegrationFiles)) { if ($file) { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue } }
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail) { Write-Host "$fail assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'Guided flow orchestrator holds.' -ForegroundColor Green
exit 0
