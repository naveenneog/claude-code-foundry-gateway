<#
.SYNOPSIS
    Guided-flow monitoring step: publish every shipped KQL function and workbook definition.
#>

$script:FlowRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $PSScriptRoot 'FlowContract.ps1')
. (Join-Path $script:FlowRoot 'scripts\ClaudeChoice.ps1')

function Get-ClaudeFlowStepInfo {
    [pscustomobject]@{
        Name = 'Monitoring'
        Title = 'Monitoring workbooks and saved queries'
        DecisionKey = 'monitoring'
        DependsOn = @('Foundation')
        Actions = @('Setup', 'Change')
    }
}

function Get-MonitoringFlowWorkbookDefinitions {
    param([string]$Root = $script:FlowRoot)
    # Code-point order: the plan lists these, and its fingerprint is compared across shells (P76).
    @(Sort-ClaudeFlowOrdinal -InputObject @(Get-ChildItem -LiteralPath (Join-Path $Root 'infra') -Filter 'workbook*.json' -File) -Key { $_.Name } |
        ForEach-Object {
            $name = if ($_.BaseName -eq 'workbook') { 'Claude gateway' } else { 'Claude gateway - ' + ($_.BaseName -replace '^workbook-', '') }
            [pscustomobject]@{ Name = $name; Path = $_.FullName; RelativePath = $_.FullName.Substring($Root.Length + 1) }
        })
}

function Get-MonitoringFlowQueryDefinitions {
    param([string]$Root = $script:FlowRoot)
    @(Sort-ClaudeFlowOrdinal -InputObject @(Get-ChildItem -LiteralPath (Join-Path $Root 'analytics') -Filter '*.kql' -File) -Key { $_.Name } |
        ForEach-Object { [pscustomobject]@{ Path = $_.FullName; RelativePath = $_.FullName.Substring($Root.Length + 1) } })
}

function Get-ClaudeFlowStepQuestions {
    param($Record, $Discovery)
    $existing = Get-ClaudeDecision -Record $Record -Key 'monitoring'
    if ($existing.enabled) { return @() }
    @([pscustomobject]@{
        Key = 'monitoring.enabled'
        Question = 'Deploy saved KQL functions and every shipped workbook to the gateway workspace?'
        Options = @(
            (New-ClaudeChoiceOption -Value 'true' -Label 'Deploy monitoring collection' -Detail '$0 standing cost; workspace query charges depend on table plan.' -Recommended -Reason 'The guided flow should leave administrators with the full portal collection.')
            (New-ClaudeChoiceOption -Value 'false' -Label 'Skip monitoring deployment' -Detail 'No workbook or function will be published by the flow.')
        )
        WhereToFind = @('docs/MONITORING.md#7-dashboard')
        AcceptRecommendedWithoutConsole = $true
        Recommended = 'true'
        Reason = 'The owner asked for workbook collection deployment as part of the product flow.'
    })
}

function Get-ClaudeFlowStepPlan {
    param($Record, $Discovery)
    $decision = Get-ClaudeDecision -Record $Record -Key 'monitoring'
    $enabled = if ($null -ne $decision -and $decision.PSObject.Properties.Name -contains 'enabled') { [bool]$decision.enabled } else { $true }
    $workbooks = @(Get-MonitoringFlowWorkbookDefinitions)
    $queries = @(Get-MonitoringFlowQueryDefinitions)
    $actions = [System.Collections.Generic.List[object]]::new()
    if ($enabled) {
        $actions.Add((New-ClaudeFlowAction -Verb Deploy -Target 'Saved KQL functions' -Detail (($queries.RelativePath) -join ', ')))
        foreach ($workbook in $workbooks) { $actions.Add((New-ClaudeFlowAction -Verb Deploy -Target $workbook.Name -Detail $workbook.RelativePath)) }
    }
    New-ClaudeFlowPlan -Step 'Monitoring' -Summary $(if ($enabled) { 'Publish the full monitoring collection.' } else { 'Monitoring deployment skipped.' }) `
        -Actions @($actions) `
        -Costs @((New-ClaudeFlowCost -Item 'Saved functions and workbooks' -MonthlyUsd 0 -Source 'Azure Monitor workbook and saved-search definitions; query/ingestion billed separately.')) `
        -Implications @('Definitions are idempotent and update in place. Publish queries before workbooks so tiles resolve.', 'The list is discovered from analytics/*.kql and infra/workbook*.json; no hard-coded workbook count.') `
        -Requires @('Workspace saved-search and workbook write access') -Reversible $true -Rollback 'Run Publish-ClaudeWorkbook.ps1 -Remove for each workbook and Publish-ClaudeQueries.ps1 -Remove.' `
        -Data @{ enabled = $enabled; workbooks = @($workbooks); queries = @($queries) }
}

function Invoke-ClaudeFlowStep {
    param($Record, $Plan)
    if (-not $Plan.Data.enabled) { return @{ monitoring = [pscustomobject]@{ enabled = $false } } }
    & (Join-Path $script:FlowRoot 'scripts\Publish-ClaudeQueries.ps1')
    if ($LASTEXITCODE) { throw 'Publish-ClaudeQueries.ps1 failed.' }
    $links = [System.Collections.Generic.List[object]]::new()
    foreach ($workbook in @($Plan.Data.workbooks)) {
        & (Join-Path $script:FlowRoot 'scripts\Publish-ClaudeWorkbook.ps1') -WorkbookFile $workbook.Path -Name $workbook.Name
        if ($LASTEXITCODE) { throw "Publish-ClaudeWorkbook.ps1 failed for $($workbook.RelativePath)." }
        $links.Add([pscustomobject]@{ name = $workbook.Name; source = $workbook.RelativePath })
    }
    return @{ monitoring = [pscustomobject]@{ enabled = $true; workbooks = @($links); configuredUtc = [DateTime]::UtcNow.ToString('o') } }
}

function Test-ClaudeFlowStep {
    param($Record)
    $workbooks = @(Get-MonitoringFlowWorkbookDefinitions)
    $queries = @(Get-MonitoringFlowQueryDefinitions)
    $checks = @(
        [pscustomobject]@{ Name = 'workbook definitions discovered'; Passed = ($workbooks.Count -gt 0); Evidence = (($workbooks.RelativePath) -join ', '); Fix = 'Add workbook JSON under infra/ or fix repository layout.' }
        [pscustomobject]@{ Name = 'query definitions discovered'; Passed = ($queries.Count -gt 0); Evidence = (($queries.RelativePath) -join ', '); Fix = 'Add KQL under analytics/ or fix repository layout.' }
    )
    [pscustomobject]@{ Step = 'Monitoring'; Passed = -not @($checks | Where-Object { -not $_.Passed }).Count; Checks = @($checks) }
}
