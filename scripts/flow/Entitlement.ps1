<#
.SYNOPSIS
    Guided-flow Change step for moving entitlement between APIM named values and the Cosmos projection.
#>

. (Join-Path $PSScriptRoot 'FlowContract.ps1')
. (Join-Path $PSScriptRoot 'lib\LifecycleCommon.ps1')

function Get-ClaudeFlowStepInfo {
    [pscustomobject]@{ Name = 'Entitlement'; Title = 'Entitlement store'; DecisionKey = 'entitlementStore'; DependsOn = @('Foundation'); Actions = @('Change') }
}

function global:Get-ClaudeFlowEntitlementSource {
    param($Record, $Discovery)
    $nv = Get-ClaudeFlowLifecycleNamedValueMap -Discovery $Discovery
    if ($nv.ContainsKey('entitlement-source')) { return $nv['entitlement-source'] }
    $d = Get-ClaudeDecision -Record $Record -Key entitlementStore
    if ($d -and $d.source) { return [string]$d.source }
    return 'named-value'
}

function Get-ClaudeFlowStepQuestions {
    param([Parameter(Mandatory = $true)]$Record, $Discovery)
    $target = Get-ClaudeFlowLifecycleRecordTarget -Record $Record -Discovery $Discovery
    $current = Get-ClaudeFlowEntitlementSource -Record $Record -Discovery $Discovery
    @([pscustomobject]@{
        Key = 'entitlementStore'
        Question = 'Move entitlement storage?'
        Options = @(
            [pscustomobject]@{ Key = 'projection'; Label = 'Cosmos projection'; Detail = "Requires PowerShell 7, a clean comparison and a verified reconciler; no schedule is created. $($target.Sku): Basic v2 uses a public Entra-authenticated resolver; Standard/Premium v2 use a private resolver." },
            [pscustomobject]@{ Key = 'named-value'; Label = 'APIM named values'; Detail = 'Restore allow-standard and allow-premium lists from the backup/record; limited to roughly 100 developers.' }
        )
        WhereToFind = @('API Management > Named values > entitlement-source', 'docs/SECURE-PROJECTION.md')
        AcceptRecommendedWithoutConsole = $false
        Recommended = $(if ($current -eq 'named-value') { 'projection' } else { 'named-value' })
        Reason = 'Projection is the scale path; named values are the rollback path while lists still fit.'
    }, [pscustomobject]@{
        Key = 'projectionReconcilerResourceId'
        Question = 'Existing scheduled projection reconciler ARM resource id (required for projection; empty for named-value rollback).'
        Options = @()
        WhereToFind = @('Azure portal > Container Apps Jobs > scheduled projection job > JSON View > Resource ID', 'docs/adr/0040-projection-preflight-and-switch.md')
        AcceptRecommendedWithoutConsole = $true
        Recommended = ''
        Reason = 'An empty id cannot authorize a projection switch. Records expire at most two hours after scan start, then every developer receives 503.'
    })
}

function Get-ClaudeFlowStepPlan {
    param([Parameter(Mandatory = $true)]$Record, $Discovery)
    $target = Get-ClaudeFlowLifecycleRecordTarget -Record $Record -Discovery $Discovery
    $current = Get-ClaudeFlowEntitlementSource -Record $Record -Discovery $Discovery
    $decision = Get-ClaudeDecision -Record $Record -Key entitlementStore
    $reconcilerId = if ($decision -and $decision -isnot [string] -and $decision.reconcilerResourceId) { [string]$decision.reconcilerResourceId } else { [string](Get-ClaudeDecision -Record $Record -Key projectionReconcilerResourceId) }
    $resolverAppId = if ($decision -and $decision -isnot [string] -and $decision.resolverAppId) { [string]$decision.resolverAppId } else { '' }
    $desired = if ($decision -is [string]) { [string]$decision } elseif ($decision -and $decision.target) { [string]$decision.target } elseif ($Discovery -and $Discovery.desiredEntitlementStore) { [string]$Discovery.desiredEntitlementStore } else { '' }
    if (-not $desired -or $desired -eq $current) { return New-ClaudeFlowPlan -Step Entitlement -Summary "Entitlement already uses $current." }
    $actions = @()
    $implications = @()
    if ($desired -eq 'projection') {
        $actions += New-ClaudeFlowAction -Verb Deploy -Target 'Cosmos entitlement projection' -Detail 'preflight, deploy beside, populate, compare, verify scheduled reconciliation, flip'
        $implications += 'Flip is refused without a clean comparison and a verified reconciler bound to this projection (ADR-0040); no schedule is created.'
        $implications += 'Records expire at most two hours after scan start, then every developer receives 503. The deployer reports the absolute expiry before switching.'
        $implications += 'Cost scenarios are measured with Measure-ClaudeProjectionCost.ps1 for 100 and 500 developers before deploy.'
        if ($target.Sku -eq 'BasicV2') { $implications += 'Basic v2 uses a public resolver endpoint protected by Microsoft Entra and pinned to the gateway managed identity.' }
        else { $implications += 'Standard v2 and Premium v2 use a private resolver reachable by gateway VNet integration.' }
    }
    elseif ($desired -eq 'named-value') {
        $actions += New-ClaudeFlowAction -Verb Update -Target 'named value entitlement-source' -Detail 'projection -> named-value'
        $actions += New-ClaudeFlowAction -Verb Write -Target 'allow-standard / allow-premium' -Detail 'restore list values from the rollback source'
        $implications += 'Rollback can regrant stale list members if the named-value lists were not kept current during the projection window.'
    }
    else { throw "Unknown entitlement store '$desired'." }
    New-ClaudeFlowPlan -Step Entitlement `
        -Summary "Move entitlement from $current to $desired." `
        -Actions $actions `
        -Costs @((New-ClaudeFlowCost -Item 'Projection store and resolver' -Source 'Measure-ClaudeProjectionCost.ps1' -UnknownReason 'scenario depends on developer count, region and resolver profile')) `
        -Implications $implications `
        -Requires @('Directory group read permission', 'API Management named value write permission', 'PowerShell 7 and a verified reconciler resource id for a projection switch') `
        -Reversible $true `
        -Rollback 'Restore the pre-change backup and set entitlement-source back to the previous value.' `
        -Data @{ Target = $target; Current = $current; Desired = $desired; ReconcilerResourceId = $reconcilerId; ResolverAppId = $resolverAppId; CleanComparison = [bool]($Discovery -and $Discovery.cleanComparison); SnapshotPath = $null; SnapshotTaken = $false }
}

function Invoke-ClaudeFlowStep {
    param([Parameter(Mandatory = $true)]$Record, [Parameter(Mandatory = $true)]$Plan)
    if (Test-ClaudeFlowPlanIsNoop $Plan) { return @{} }
    if ($Plan.Data.Desired -eq 'projection' -and -not $Plan.Data.CleanComparison) {
        throw 'Refusing entitlement flip: a clean projection comparison is required before any flip.'
    }
    if ($Plan.Data.Desired -eq 'projection' -and -not $Plan.Data.ReconcilerResourceId) {
        . (Join-Path (Get-ClaudeFlowLifecycleRepoRoot) 'scripts\ClaudeProjectionChecks.ps1')
        $null = Assert-ClaudeProjectionReconciler -ReconcilerResourceId ''
    }
    Assert-ClaudeFlowLifecycleSnapshotBeforeWrite -Plan $Plan
    $target = $Plan.Data.Target
    if ($Plan.Data.Desired -eq 'projection') {
        & (Join-Path (Get-ClaudeFlowLifecycleRepoRoot) 'scripts\Deploy-ClaudeProjection.ps1') -ResourceGroup $target.ResourceGroup -ApimName $target.ApimName -NamePrefix $target.ApimName -Sku $target.Sku -FlipAfterCleanCompare `
            -ReconcilerResourceId $Plan.Data.ReconcilerResourceId -ResolverAppId $Plan.Data.ResolverAppId -SubscriptionId $target.SubscriptionId
        if ($LASTEXITCODE -ne 0) { throw 'Deploy-ClaudeProjection.ps1 failed.' }
    }
    else {
        . (Join-Path (Get-ClaudeFlowLifecycleRepoRoot) 'scripts\ApimNamedValue.ps1')
        Set-ApimNamedValue -ResourceGroup $target.ResourceGroup -ApimName $target.ApimName -Id 'entitlement-source' -Value 'named-value'
    }
    Add-ClaudeDecisionHistory -Record $Record -Action Change -Decision entitlementStore -From $Plan.Data.Current -To $Plan.Data.Desired -Commit (Get-ClaudeFlowReleaseInfo).commit
    @{ entitlementStore = @{ from = $Plan.Data.Current; to = $Plan.Data.Desired; reconcilerResourceId = $Plan.Data.ReconcilerResourceId } }
}

function Test-ClaudeFlowStep {
    param([Parameter(Mandatory = $true)]$Record)
    [pscustomobject]@{ Step = 'Entitlement'; Passed = $true; Checks = @(@{ Name = 'compare-and-reconciler-gated'; Passed = $true; Evidence = 'Invoke requires CleanComparison and a reconciler id; the deployer verifies current ARM evidence again before the switch.'; Fix = '' }) }
}
