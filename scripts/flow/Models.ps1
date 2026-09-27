. (Join-Path (Split-Path $PSScriptRoot -Parent) 'ClaudeModelLifecycle.ps1')

function Get-ClaudeFlowStepInfo {
    [pscustomobject]@{ Name = 'Models'; Title = 'Model lifecycle'; DecisionKey = 'models'; DependsOn = @('Foundation'); Actions = @('Change') }
}

function Get-ClaudeFlowStepQuestions {
    param($Record, $Discovery)
    $state = Get-ClaudeModelDiscovery (Get-ClaudeModelTarget $Record)
    Set-ClaudeRecordProperty $Discovery 'modelLifecycle' $state
    Get-ClaudeModelQuestions -Record $Record -Discovery $state
}

function Get-ClaudeFlowStepPlan {
    param($Record, $Discovery)
    $args = @{ Record = $Record; RecordPath = $Record.__recordPath; TierAssignments = Get-ClaudeModelAssignments $Record }
    if ($Discovery -and $Discovery.modelLifecycle) { $args.Discovery = $Discovery.modelLifecycle }
    $decision = Get-ClaudeDecision $Record models
    if ($decision -and $decision.priceBookPath) {
        if ($decision.priceBookPath -isnot [string]) { throw 'models.priceBookPath must be a scalar string.' }
        $path = $decision.priceBookPath
        if (-not [IO.Path]::IsPathRooted($path)) { $path = Join-Path (Get-ClaudeFlowLifecycleRepoRoot) $path }
        $args.PriceBookPath = $path
    }
    New-ClaudeModelPlan @args
}

function Initialize-ClaudeFlowStep {
    param($Record, $Plan)
    Initialize-ClaudeModelChange -Record $Record -Plan $Plan
}

function Invoke-ClaudeFlowStep {
    param($Record, $Plan)
    Invoke-ClaudeModelChange -Record $Record -Plan $Plan
}

function Test-ClaudeFlowStep {
    param($Record)
    $target = Get-ClaudeModelTarget $Record
    $state = Get-ClaudeModelDiscovery $target
    $checks = @()
    foreach ($tier in 'standard','premium') {
        $path = Join-Path (Split-Path $Record.__recordPath -Parent) "profiles\$tier\claude-code.managed-settings.json"
        $profile = Read-ClaudeDecisionRecord $path
        $names = @($Record.tiers.$tier.models)
        $checks += [pscustomobject]@{
            Name = "$tier model list and profile"
            Passed = ($state.NamedValues["models-$tier"] -ceq $Record.tiers.$tier.modelAllowList -and $profile -and (@($profile.availableModels) -join ',') -ceq ($names -join ','))
            Evidence = $path
            Fix = 'Replan Change models against the current gateway, then rerun workstation setup with the tier record.'
        }
    }
    [pscustomobject]@{ Step = 'Models'; Passed = @($checks | Where-Object { -not $_.Passed }).Count -eq 0; Checks = $checks }
}
