<#
.SYNOPSIS
    Guided-flow chargeback report step: recipients, schedule, delivery and one generated report.
#>

$script:FlowRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $PSScriptRoot 'FlowContract.ps1')
. (Join-Path $script:FlowRoot 'scripts\ClaudeChoice.ps1')

function Get-ClaudeFlowStepInfo {
    [pscustomobject]@{
        Name = 'Reports'
        Title = 'Chargeback reports'
        DecisionKey = 'reports'
        DependsOn = @('Monitoring', 'Budgets')
        Actions = @('Setup', 'Change')
    }
}

function Get-ReportsFlowDecision {
    param($Record)
    $existing = Get-ClaudeDecision -Record $Record -Key 'reports'
    if ($null -eq $existing) { return [pscustomobject]@{} }
    return $existing
}

function Get-ClaudeFlowStepQuestions {
    param($Record, $Discovery)
    $decision = Get-ReportsFlowDecision $Record
    if ($decision.enabled) { return @() }
    @(
        [pscustomobject]@{
            Key = 'reports.enabled'
            Question = 'Configure chargeback report generation and delivery?'
            Options = @(
                (New-ClaudeChoiceOption -Value 'true' -Label 'Configure reports' -Detail 'Deploy/report through existing P50 scripts; ACS, private storage and Container Apps jobs are priced.' -Recommended -Reason 'The owner requested report generation at the end of setup.')
                (New-ClaudeChoiceOption -Value 'false' -Label 'Skip reports' -Detail 'No report schedule or sample report will be generated.')
            )
            WhereToFind = @('docs/CHARGEBACK-REPORTS.md')
            AcceptRecommendedWithoutConsole = $true
            Recommended = 'true'
            Reason = 'The guided flow should leave the administrator with a real report.'
        }
    )
}

function Get-ClaudeFlowStepPlan {
    param($Record, $Discovery)
    $decision = Get-ReportsFlowDecision $Record
    $enabled = if ($decision.PSObject.Properties.Name -contains 'enabled') { [bool]$decision.enabled } else { $true }
    $actions = [System.Collections.Generic.List[object]]::new()
    if ($enabled) {
        $actions.Add((New-ClaudeFlowAction -Verb Deploy -Target 'Chargeback report schedule' -Detail 'Register-ClaudeChargebackSchedule.ps1 deploys private storage, ACS and jobs or updates existing resources.'))
        $actions.Add((New-ClaudeFlowAction -Verb Write -Target 'Report recipients' -Detail 'Set-ClaudeChargebackRecipients.ps1 writes allowed-domain recipient lists.'))
        $actions.Add((New-ClaudeFlowAction -Verb Run -Target 'One report' -Detail 'New-ClaudeChargebackReport.ps1 generates a real report after setup.'))
    }
    $recipients = @($decision.recipients)
    $allowedDomains = @($decision.allowedDomains)
    if (-not $allowedDomains.Count) { $allowedDomains = @('contoso.com') }
    $cron = if ($decision.cron) { [string]$decision.cron } else { '0 6 1 * *' }
    New-ClaudeFlowPlan -Step 'Reports' -Summary $(if ($enabled) { 'Configure monthly chargeback reports and generate one report.' } else { 'Chargeback reports skipped.' }) `
        -Actions @($actions) `
        -Costs @(
            (New-ClaudeFlowCost -Item 'Chargeback reports standing networking' -MonthlyUsd 29.70 -Source 'docs/CHARGEBACK-REPORTS.md P50 dated East US 2 list-price BOM')
            (New-ClaudeFlowCost -Item 'ACS email and job execution' -Source 'Azure Retail Prices API via CHARGEBACK-REPORTS.md' -UnknownReason 'Usage-based: recipients, attachment size, job seconds and storage operations.')
        ) `
        -Implications @('Reports are list-price showback, not Azure invoices.', 'Azure-managed ACS domains are limited; broad production delivery needs a verified custom domain and quota.', 'One report is generated at setup so the administrator sees the actual artifacts.') `
        -Requires @('Workspace functions published', 'Allowed recipient domains', 'Resource deployment rights for first schedule registration') `
        -Reversible $true -Rollback 'Register-ClaudeChargebackSchedule.ps1 -Remove, optionally -PurgeArchive after retention approval.' `
        -Data @{ enabled = $enabled; recipients = @($recipients); allowedDomains = @($allowedDomains); cron = $cron; delivery = $(if ($decision.delivery) { [string]$decision.delivery } else { 'archive-and-email' }) }
}

function Invoke-ClaudeFlowStep {
    param($Record, $Plan)
    if (-not $Plan.Data.enabled) { return @{ reports = [pscustomobject]@{ enabled = $false } } }
    & (Join-Path $script:FlowRoot 'scripts\Register-ClaudeChargebackSchedule.ps1') -AllowedDomains $Plan.Data.allowedDomains -Cron $Plan.Data.cron -RunNow
    if ($LASTEXITCODE) { throw 'Register-ClaudeChargebackSchedule.ps1 failed.' }
    foreach ($recipient in @($Plan.Data.recipients)) {
        & (Join-Path $script:FlowRoot 'scripts\Set-ClaudeChargebackRecipients.ps1') -AllUnits -Add $recipient
        if ($LASTEXITCODE) { throw "Set-ClaudeChargebackRecipients.ps1 failed for $recipient." }
    }
    $report = & (Join-Path $script:FlowRoot 'scripts\New-ClaudeChargebackReport.ps1')
    if ($LASTEXITCODE) { throw 'New-ClaudeChargebackReport.ps1 failed.' }
    return @{ reports = [pscustomobject]@{ enabled = $true; cron = $Plan.Data.cron; generated = $report; configuredUtc = [DateTime]::UtcNow.ToString('o') } }
}

function Test-ClaudeFlowStep {
    param($Record)
    $decision = Get-ReportsFlowDecision $Record
    $checks = @(
        [pscustomobject]@{ Name = 'report decision recorded'; Passed = ($decision.PSObject.Properties.Name -contains 'enabled'); Evidence = $(if ($decision.PSObject.Properties.Name -contains 'enabled') { [string]$decision.enabled } else { 'No reports.enabled decision.' }); Fix = 'Run the Reports step.' }
        [pscustomobject]@{ Name = 'allowed recipient domains'; Passed = (@($decision.allowedDomains).Count -gt 0 -or -not [bool]$decision.enabled); Evidence = ((@($decision.allowedDomains)) -join ', '); Fix = 'Record at least one allowed recipient domain before enabling email delivery.' }
    )
    [pscustomobject]@{ Step = 'Reports'; Passed = -not @($checks | Where-Object { -not $_.Passed }).Count; Checks = @($checks) }
}
