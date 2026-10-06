<#
.SYNOPSIS
    Migration 0004: move a gateway that serves entitlement from named values to the Cosmos projection (ADR-0054).
    The facts come from Get-ClaudeEntitlementMigrationFacts (scripts/ClaudeEntitlementMigration.ps1), which
    Update-ClaudeGateway.ps1 gathers on live discovery; this file only renders, applies and verifies them.
#>

function Get-ClaudeFlowMigrationInfo {
    [pscustomobject]@{
        Name = '0004-entitlement-projection'
        Title = 'Move entitlement from named values to the Cosmos projection'
        DecisionKey = 'entitlement'
        DependsOn = @('0002-policy-and-named-values')
        Actions = @('Update')
    }
}

# What the fingerprint covers: decisions and results, not evidence that changes between runs (times, counts).
function ConvertTo-ClaudeMigrationPlanFacts($Facts) {
    $copy = [ordered]@{}
    foreach ($p in $Facts.PSObject.Properties) {
        if ($p.Name -eq 'Checks') { $copy.Checks = @(@($p.Value) | ForEach-Object { [pscustomobject][ordered]@{ Name = [string]$_.Name; Result = [string]$_.Result; Remedy = [string]$_.Remedy } }) }
        else { $copy[$p.Name] = $p.Value }
    }
    return [pscustomobject]$copy
}

function Format-ClaudeMigrationGroup($Group) {
    if (-not $Group) { return 'unknown' }
    if ($Group.Absent) { return "no group ($($Group.Source))" }
    if (-not $Group.Found) { return 'not found' }
    return ("{0} ({1}), from the {2}: {3} member(s) in Entra, {4} in allow-{5}; {6} would gain access and {7} would lose it at the move" -f
        $Group.Name, $Group.Id, $Group.Source, $Group.Members, $Group.Listed, $Group.Tier, $Group.Gained, $Group.Lost)
}

function Get-ClaudeFlowMigrationPlan {
    param([Parameter(Mandatory = $true)]$Record, $Discovery)
    $step = '0004-entitlement-projection'
    $facts = if ($Discovery -and $Discovery.PSObject.Properties['entitlementMigration']) { $Discovery.entitlementMigration } else { $null }
    if (-not $facts) {
        return New-ClaudeFlowPlan -Step $step -Summary 'Entitlement store not assessed: the discovery came from a file without migration facts. The update run against the live gateway (-ResourceGroup and -ApimName) plans the move to the Cosmos projection.'
    }
    if (-not $facts.Needed) { return New-ClaudeFlowPlan -Step $step -Summary ([string]$facts.Reason) }

    $planFacts = ConvertTo-ClaudeMigrationPlanFacts $facts
    $actions = [Collections.Generic.List[object]]::new()
    foreach ($r in @($facts.Resources.Resources)) {
        if ($r) { $actions.Add((New-ClaudeFlowAction -Verb Create -Target "$($r.Type) $($r.Name)" -Detail "$($r.Sku), $($r.Region)")) }
    }
    $actions.Add((New-ClaudeFlowAction -Verb Run -Target 'named-value refresh from Entra' -Detail 'scripts/Sync-ClaudeAccess.ps1 -Store named-value, as the installer does; named values keep serving'))
    $actions.Add((New-ClaudeFlowAction -Verb Update -Target 'named values entitlement-resolver-url, entitlement-resolver-audience, entitlement-projection-prefix' -Detail 'the deployed resolver; read only while entitlement-source is projection'))
    $actions.Add((New-ClaudeFlowAction -Verb Run -Target 'populate and compare the projection' -Detail "$($facts.Developers) developer(s), compared with the named values before the switch"))
    $actions.Add((New-ClaudeFlowAction -Verb Update -Target 'named value entitlement-source' -Detail 'named-value -> projection, only after a clean compare'))
    $premiumId = if ($facts.Groups -and $facts.Groups.Premium.Found) { $facts.Groups.Premium.Id } else { 'none' }
    $standardId = if ($facts.Groups) { $facts.Groups.Standard.Id } else { '' }
    $actions.Add((New-ClaudeFlowAction -Verb Write -Target 'named value entitlement-groups' -Detail "standard=$standardId, premium=$premiumId, for later syncs"))

    $costs = @(if ($null -ne $facts.MonthlyUsd) {
            New-ClaudeFlowCost -Item 'Cosmos projection (Cosmos DB, resolver, network, telemetry)' -MonthlyUsd ([decimal]$facts.MonthlyUsd) -Source 'scripts/Measure-ClaudeProjectionCost.ps1, Azure Retail Prices API list prices'
        } else {
            New-ClaudeFlowCost -Item 'Cosmos projection (Cosmos DB, resolver, network, telemetry)' -Source 'scripts/Measure-ClaudeProjectionCost.ps1' -UnknownReason ([string]$facts.CostUnknownReason)
        })

    $notes = [Collections.Generic.List[string]]::new()
    if ($facts.Blocked) {
        $notes.Add('BLOCKED: nothing is written until every FAIL below is fixed and the plan is made again.')
        foreach ($problem in @($facts.Problems)) { $notes.Add("BLOCKED: $problem") }
    }
    $notes.Add("Standard tier group: $(Format-ClaudeMigrationGroup $facts.Groups.Standard)")
    $notes.Add("Premium tier group: $(Format-ClaudeMigrationGroup $facts.Groups.Premium)")
    $notes.Add("Developers: $($facts.Developers) in the named-value lists; business units: $($facts.BusinessUnits) in bu-registry, read by the writer from the gateway.")
    $notes.Add("Name prefix $($facts.NamePrefix) ($($facts.PrefixSource)); region $($facts.Location); tier $($facts.Sku); resolver access $($facts.ResolverInboundAccess) ($($facts.AccessSource)).")
    foreach ($line in @($facts.InventoryLines)) { if ($line) { $notes.Add([string]$line) } }
    foreach ($check in @($facts.Checks)) {
        $notes.Add("Readiness: $($check.Name): $($check.Result)$(if ($check.Result -ne 'PASS' -and $check.Remedy) { " - $($check.Remedy)" })")
    }
    $notes.Add('Named values keep serving until the projection compares clean with them; the switch is one named-value write.')
    $notes.Add("Time: about $($facts.EstimatedMinutes) minutes (deployment about 20, then the snapshot transfer).")

    New-ClaudeFlowPlan -Step $step `
        -Summary 'Move entitlement from named values to the Cosmos projection, with the gateway''s previous groups and values (ADR-0054).' `
        -Actions $actions.ToArray() -Costs $costs -Implications $notes.ToArray() `
        -Requires @('PowerShell 7 with az, node, npm and tar', "Owner, or Contributor plus User Access Administrator, on $($facts.ResourceGroup)", 'Microsoft Graph read of the tier groups') `
        -Reversible $true `
        -Rollback 'Restore-ClaudeGateway.ps1 -Path <the snapshot this update takes> -Apply restores the named values, entitlement-source among them; the projection resources stay until they are deleted.' `
        -Data @{ Facts = $planFacts; Blocked = [bool]$facts.Blocked; Target = (Get-ClaudeFlowLifecycleRecordTarget -Record $Record -Discovery $Discovery) }
}

function Invoke-ClaudeFlowMigration {
    param([Parameter(Mandatory = $true)]$Record, [Parameter(Mandatory = $true)]$Plan)
    if (Test-ClaudeFlowPlanIsNoop $Plan) { return @{} }
    if ($Plan.Data.Blocked) { throw 'The move to the projection is blocked by the plan''s checks; nothing was written.' }
    Assert-ClaudeFlowLifecycleSnapshotBeforeWrite -Plan $Plan
    $root = Get-ClaudeFlowLifecycleRepoRoot
    foreach ($script in 'ApimNamedValue.ps1', 'ClaudeInstallProjection.ps1', 'ClaudeEntitlementMigration.ps1') { . (Join-Path $root "scripts\$script") }
    $facts = $Plan.Data.Facts
    $resume = ".\Update-ClaudeGateway.ps1 -ResourceGroup $($facts.ResourceGroup) -ApimName $($facts.ApimName)"
    $null = Invoke-ClaudeEntitlementMigrationApply -Facts $facts -Root $root -ResumeCommand $resume
    $release = Get-ClaudeFlowReleaseInfo
    Add-ClaudeDecisionHistory -Record $Record -Action Update -Decision entitlement -From 'named-value' -To 'projection' -Commit $release.commit
    @{ entitlement = 'projection' }
}

function Test-ClaudeFlowMigration {
    param([Parameter(Mandatory = $true)]$Record, $Discovery, $Plan)
    $step = '0004-entitlement-projection'
    if ($Plan -and (Test-ClaudeFlowPlanIsNoop $Plan)) {
        return [pscustomobject]@{ Step = $step; Passed = $true; Checks = @(@{ Name = 'entitlement store'; Passed = $true; Evidence = 'no move planned'; Fix = '' }) }
    }
    $values = Get-ClaudeFlowLifecycleNamedValueMap -Discovery $Discovery
    $source = [string]$values['entitlement-source']
    $prefix = if ($values['entitlement-projection-prefix']) { [string]$values['entitlement-projection-prefix'] } elseif ($Discovery -and $Discovery.PSObject.Properties['projectionPrefix']) { [string]$Discovery.projectionPrefix } else { '' }
    $passed = $source -eq 'projection' -and [bool]$prefix
    [pscustomobject]@{
        Step = $step
        Passed = $passed
        Checks = @(@{ Name = 'entitlement-source projection with a recorded prefix'; Passed = $passed; Evidence = "entitlement-source=$source; entitlement-projection-prefix=$prefix"; Fix = 'Run the update again; it resumes the move, or restore the snapshot to return to named values.' })
    }
}
