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
            [pscustomobject]@{ Key = 'projection'; Label = 'Cosmos projection'; Detail = "Switching uses P86 scheduled-renewal admission: Cosmos evidence, pinned job definition and email-backed alerts. $($target.Sku): Basic v2 uses a public Entra-authenticated resolver; Standard/Premium v2 use a private resolver." },
            [pscustomobject]@{ Key = 'named-value'; Label = 'APIM named values'; Detail = 'Sets entitlement-source to named-value and serves allow-standard and allow-premium as they stand; refresh them with scripts/Sync-ClaudeAccess.ps1 first. Limited to roughly 100 developers.' }
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
    # The rights each direction's own step uses (docs/SECURE-PROJECTION.md, Rights used by the checks).
    $requires = @('API Management named value read and write permission', 'A writable backups/ folder for the snapshot')
    if ($desired -eq 'projection') {
        # ADR-0050: the shared switch deploys nothing; its one write follows the drift check, the compare and admission.
        $actions += New-ClaudeFlowAction -Verb Update -Target 'named value entitlement-source' -Detail 'named-value -> projection, after the drift check, the read-only compare and P86 renewal admission; nothing is deployed'
        $implications += 'Projection switching waits for the 30-minute scheduled reconciler, email-backed alerts and destination-bound Cosmos evidence; about 60-90 minutes are needed for two generation advances.'
        $implications += 'Records expire at most two hours after scan start, then every developer receives 503. The deployer reports the absolute expiry before switching.'
        $implications += 'Cost scenarios are measured with Measure-ClaudeProjectionCost.ps1 for 100 and 500 developers before deploy.'
        if ($target.Sku -eq 'BasicV2') { $implications += 'Basic v2 uses a public resolver endpoint protected by Microsoft Entra and pinned to the gateway managed identity.' }
        else { $implications += 'Standard v2 and Premium v2 use a private resolver reachable by gateway VNet integration.' }
        $requires += @('Directory group read permission, for the drift check', 'ARM read of the renewal job, its action group, the resolver deployment and the resolver site',
            'Microsoft.Web/sites/config/list/action on the resolver site (U122)', 'Cosmos data read through the in-VNet runner',
            'P86 scheduled reconciler evidence, pinned image digest and email-backed action group')
        $rollback = 'Refresh allow-standard and allow-premium with scripts/Sync-ClaudeAccess.ps1, check them with scripts/Compare-ClaudeEntitlement.ps1 -FailOnDrift, then set entitlement-source back to named-value. The snapshot taken at the write holds the values from before it.'
    }
    elseif ($desired -eq 'named-value') {
        $actions += New-ClaudeFlowAction -Verb Update -Target 'named value entitlement-source' -Detail 'projection -> named-value'
        $implications += 'This step does not change allow-standard or allow-premium. Lists not kept current during the projection window regrant removed developers and refuse added ones: refresh them with scripts/Sync-ClaudeAccess.ps1 and check them with scripts/Compare-ClaudeEntitlement.ps1 -FailOnDrift first.'
        $rollback = 'Run this step again with the Cosmos projection; the shared switch repeats the drift check, the compare and admission before it writes entitlement-source.'
    }
    else { throw "Unknown entitlement store '$desired'." }
    New-ClaudeFlowPlan -Step Entitlement `
        -Summary "Move entitlement from $current to $desired." `
        -Actions $actions `
        -Costs @((New-ClaudeFlowCost -Item 'Projection store and resolver' -Source 'Measure-ClaudeProjectionCost.ps1' -UnknownReason 'scenario depends on developer count, region and resolver profile')) `
        -Implications $implications `
        -Requires $requires `
        -Reversible $true `
        -Rollback $rollback `
        -Data @{ Target = $target; Current = $current; Desired = $desired; SnapshotPath = $null; SnapshotTaken = $false
            Renewal = $(if ($Discovery -and $Discovery.renewal) { $Discovery.renewal } else { $null })
            RenewalProblem = $(if ($Discovery -and $Discovery.renewalProblem) { [string]$Discovery.renewalProblem } else { $null }) }
}

function Initialize-ClaudeFlowStep {
    # Start-ClaudeGateway.ps1 runs this after approval and before Invoke-ClaudeFlowStep. It names the
    # snapshot the write gate takes, as scripts/Update-ClaudeGateway.ps1 does for its migrations; the
    # snapshot itself is taken at the write, so a refused switch leaves none.
    param([Parameter(Mandatory = $true)]$Record, [Parameter(Mandatory = $true)]$Plan)
    if ((Test-ClaudeFlowPlanIsNoop $Plan) -or $Plan.Data.SnapshotPath) { return }
    $name = 'before-entitlement-{0}-{1}.json' -f $Plan.Data.Target.ApimName, [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
    $Plan.Data.SnapshotPath = Join-Path (Join-Path (Get-ClaudeFlowLifecycleRepoRoot) 'backups') $name
    $Plan.Data.SnapshotTaken = $false
}

function Invoke-ClaudeFlowStep {
    param([Parameter(Mandatory = $true)]$Record, [Parameter(Mandatory = $true)]$Plan)
    if (Test-ClaudeFlowPlanIsNoop $Plan) { return @{} }
    $target = $Plan.Data.Target
    if ($Plan.Data.Desired -eq 'projection') {
        $renewal = $Plan.Data.Renewal
        if (-not $renewal) {
            $why = if ($Plan.Data.RenewalProblem) { " $($Plan.Data.RenewalProblem)" } else { '' }
            throw "Projection switch refused: P86 admission needs renewal runner, Cosmos destination, reconciler job, image digest and email action group evidence, from the renewal job's receipt.$why Expected wait after deploying the 30-minute job is about 60-90 minutes."
        }
        # ADR-0050: the shared switch runs the drift check and the compare before admission; the flow's
        # own snapshot, taken at the write and named in the rollback text, is its backup.
        . (Join-Path (Split-Path $PSScriptRoot -Parent) 'ClaudeProjectionSwitch.ps1')
        $flowPlan = $Plan
        $snapshotGate = { Assert-ClaudeFlowLifecycleSnapshotBeforeWrite -Plan $flowPlan | Out-Null; [string]$flowPlan.Data.SnapshotPath }.GetNewClosure()
        $null = Invoke-ClaudeProjectionSwitch -ResourceGroup $target.ResourceGroup -ApimName $target.ApimName -Renewal $renewal `
            -StandardGroup ([string]$renewal.standardGroupId) -PremiumGroup ([string]$renewal.premiumGroupId) -Backup $snapshotGate
    }
    else {
        Assert-ClaudeFlowLifecycleSnapshotBeforeWrite -Plan $Plan
        . (Join-Path (Get-ClaudeFlowLifecycleRepoRoot) 'scripts\ApimNamedValue.ps1')
        Set-ApimNamedValue -ResourceGroup $target.ResourceGroup -ApimName $target.ApimName -Id 'entitlement-source' -Value $Plan.Data.Desired
    }
    Add-ClaudeDecisionHistory -Record $Record -Action Change -Decision entitlementStore -From $Plan.Data.Current -To $Plan.Data.Desired -Commit (Get-ClaudeFlowReleaseInfo).commit
    @{ entitlementStore = @{ from = $Plan.Data.Current; to = $Plan.Data.Desired } }
}

function Test-ClaudeFlowStep {
    param([Parameter(Mandatory = $true)]$Record)
    [pscustomobject]@{ Step = 'Entitlement'; Passed = $true; Checks = @(@{ Name = 'projection-admission'; Passed = $true; Evidence = 'Projection switch requires P86 Cosmos evidence, pinned job definition and email action group; named-value rollback remains available.'; Fix = '' }) }
}
