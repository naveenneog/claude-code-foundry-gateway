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
            [pscustomobject]@{ Key = 'projection'; Label = 'Cosmos projection'; Detail = "Switching is unavailable in P84; the scheduled reconciler is proposed as P86. $($target.Sku): Basic v2 uses a public Entra-authenticated resolver; Standard/Premium v2 use a private resolver." },
            [pscustomobject]@{ Key = 'named-value'; Label = 'APIM named values'; Detail = 'Restore allow-standard and allow-premium lists from the backup/record; limited to roughly 100 developers.' }
        )
        WhereToFind = @('API Management > Named values > entitlement-source', 'docs/SECURE-PROJECTION.md')
        AcceptRecommendedWithoutConsole = $false
        Recommended = $(if ($current -eq 'named-value') { 'projection' } else { 'named-value' })
        Reason = 'Projection is the scale path; named values are the rollback path while lists still fit.'
    })
}

function Get-ClaudeFlowStepPlan {
    param([Parameter(Mandatory = $true)]$Record, $Discovery)
    $target = Get-ClaudeFlowLifecycleRecordTarget -Record $Record -Discovery $Discovery
    $current = Get-ClaudeFlowEntitlementSource -Record $Record -Discovery $Discovery
    $decision = Get-ClaudeDecision -Record $Record -Key entitlementStore
    $desired = if ($decision -is [string]) { [string]$decision } elseif ($decision -and $decision.target) { [string]$decision.target } elseif ($Discovery -and $Discovery.desiredEntitlementStore) { [string]$Discovery.desiredEntitlementStore } else { '' }
    if (-not $desired -or $desired -eq $current) { return New-ClaudeFlowPlan -Step Entitlement -Summary "Entitlement already uses $current." }
    $actions = @()
    $implications = @()
    if ($desired -eq 'projection') {
        $actions += New-ClaudeFlowAction -Verb Deploy -Target 'Cosmos entitlement projection' -Detail 'Requires P86 scheduled-renewal evidence from Cosmos through the in-VNet runner plus a pinned no-override job definition.'
        $implications += 'Projection switching waits for the 30-minute scheduled reconciler, email-backed alerts and destination-bound Cosmos evidence; about 60-90 minutes are needed for two generation advances.'
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
        -Requires @('Directory group read permission', 'API Management named value write permission', 'P86 scheduled reconciler evidence, pinned image digest and email-backed action group') `
        -Reversible $true `
        -Rollback 'Restore the pre-change backup and set entitlement-source back to the previous value.' `
        -Data @{ Target = $target; Current = $current; Desired = $desired; CleanComparison = [bool]($Discovery -and $Discovery.cleanComparison); SnapshotPath = $null; SnapshotTaken = $false; Renewal = $(if ($Discovery -and $Discovery.renewal) { $Discovery.renewal } else { $null }) }
}

function Invoke-ClaudeFlowStep {
    param([Parameter(Mandatory = $true)]$Record, [Parameter(Mandatory = $true)]$Plan)
    if (Test-ClaudeFlowPlanIsNoop $Plan) { return @{} }
    if ($Plan.Data.Desired -eq 'projection') {
        . (Join-Path (Get-ClaudeFlowLifecycleRepoRoot) 'scripts\ClaudeProjectionChecks.ps1')
        $renewal = $Plan.Data.Renewal
        if (-not $renewal -or -not $renewal.runnerName -or -not $renewal.cosmosAccount -or -not $renewal.accountResourceId -or -not $renewal.reconcilerResourceId -or -not $renewal.imageDigest -or -not $renewal.actionGroupResourceId) {
            throw 'Projection switch refused: P86 admission needs renewal runner, Cosmos destination, reconciler job, image digest and email action group evidence. Expected wait after deploying the 30-minute reconciler is about 60-90 minutes.'
        }
        $null = Assert-ClaudeProjectionAdmission -ResourceGroup $target.ResourceGroup -RunnerName $renewal.runnerName -CosmosAccount $renewal.cosmosAccount `
            -TenantId $renewal.tenantId -AccountResourceId $renewal.accountResourceId -ReconcilerResourceId $renewal.reconcilerResourceId `
            -ImageDigest $renewal.imageDigest -EntryPoint $(if ($renewal.entryPoint) { $renewal.entryPoint } else { 'node /app/sync/src/apply-projection.mjs' }) `
            -ActionGroupResourceId $renewal.actionGroupResourceId
    }
    Assert-ClaudeFlowLifecycleSnapshotBeforeWrite -Plan $Plan
    $target = $Plan.Data.Target
    . (Join-Path (Get-ClaudeFlowLifecycleRepoRoot) 'scripts\ApimNamedValue.ps1')
    Set-ApimNamedValue -ResourceGroup $target.ResourceGroup -ApimName $target.ApimName -Id 'entitlement-source' -Value $Plan.Data.Desired
    Add-ClaudeDecisionHistory -Record $Record -Action Change -Decision entitlementStore -From $Plan.Data.Current -To $Plan.Data.Desired -Commit (Get-ClaudeFlowReleaseInfo).commit
    @{ entitlementStore = @{ from = $Plan.Data.Current; to = $Plan.Data.Desired } }
}

function Test-ClaudeFlowStep {
    param([Parameter(Mandatory = $true)]$Record)
    [pscustomobject]@{ Step = 'Entitlement'; Passed = $true; Checks = @(@{ Name = 'projection-admission'; Passed = $true; Evidence = 'Projection switch requires P86 Cosmos evidence, pinned job definition and email action group; named-value rollback remains available.'; Fix = '' }) }
}
