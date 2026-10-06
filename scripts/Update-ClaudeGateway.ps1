<#
.SYNOPSIS
    Updates a gateway deployed by an older accelerator release to the current release.

.DESCRIPTION
    Plans the ordered migrations in scripts\flow\migrations and prints a fingerprinted plan. It writes only with
    -Apply and the plan's fingerprint, after a backup. Migration 0004 moves a gateway that serves entitlement from
    named values to the Cosmos projection (ADR-0054). Its plan finds the gateway's previous tier groups, business
    units and entitlement, checks the subscription's readiness, and shows the resources, network and cost. Without
    a decision record, -ResourceGroup and -ApimName name the gateway, and the apply writes the record.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$RecordPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'onboarding\claude-gateway.json'),
    [string]$DiscoveryPath,
    [string]$ResourceGroup,
    [string]$ApimName,
    [switch]$Apply,
    [string]$ApprovedPlanFingerprint,
    [string]$SnapshotPath,
    # The move to the Cosmos projection (ADR-0054). The previous values come from the gateway and its record;
    # these override them.
    [string]$StandardGroup,
    [string]$PremiumGroup,
    [string]$NamePrefix,
    [ValidateSet('', 'public', 'private')][string]$ResolverInboundAccess = '',
    [switch]$KeepNamedValues
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'flow\FlowContract.ps1')
. (Join-Path $PSScriptRoot 'flow\lib\LifecycleCommon.ps1')

if (-not (Test-Path -LiteralPath $RecordPath)) {
    if (-not ($ResourceGroup -and $ApimName)) {
        Write-Warning "No decision record found at '$RecordPath'. Nothing can be updated until setup has written the record."
        return [pscustomobject]@{ Plans = @(); Fingerprint = ''; SnapshotPath = $null; MissingRecord = $true }
    }
    Write-Host "No decision record at '$RecordPath'. The plan reads the live gateway $ApimName, and the apply writes the record." -ForegroundColor DarkGray
    $record = [pscustomobject]@{ resourceGroup = $ResourceGroup; apimName = $ApimName }
}
else { $record = Read-ClaudeDecisionRecord -Path $RecordPath }
# The gateway is read in the subscription the record names (ADR-0032), as the guided flow's discovery does.
$recordSubscription = Get-ClaudeFlowRecordSubscription -Record $record
$discovery = Import-ClaudeFlowLifecycleDiscovery -Path $DiscoveryPath
if (-not $discovery) {
    $target = Get-ClaudeFlowLifecycleRecordTarget -Record $record
    if ($ResourceGroup) { $target.ResourceGroup = $ResourceGroup }
    if ($ApimName) { $target.ApimName = $ApimName }
    $discovery = Get-ClaudeFlowLifecycleLiveDiscovery -ResourceGroup $target.ResourceGroup -ApimName $target.ApimName -SubscriptionId $recordSubscription
    # Migration 0004 renders facts read here, from the live gateway, Microsoft Graph and the subscription.
    . (Join-Path $PSScriptRoot 'ApimNamedValue.ps1')
    . (Join-Path $PSScriptRoot 'ClaudeRunner.ps1')
    . (Join-Path $PSScriptRoot 'ClaudeProjectionChecks.ps1')
    . (Join-Path $PSScriptRoot 'ClaudeProjectionReadiness.ps1')
    . (Join-Path $PSScriptRoot 'ClaudeProjectionInventory.ps1')
    . (Join-Path $PSScriptRoot 'ClaudeEntitlementMigration.ps1')
    $factParameters = @{ Discovery = $discovery; Record = $record; StandardGroup = $StandardGroup; PremiumGroup = $PremiumGroup
        NamePrefix = $NamePrefix; ResolverInboundAccess = $ResolverInboundAccess; KeepNamedValues = [bool]$KeepNamedValues }
    try { $facts = Get-ClaudeEntitlementMigrationFacts @factParameters }
    catch { $facts = New-ClaudeEntitlementMigrationFailure -Discovery $discovery -Message $_.Exception.Message }
    $discovery | Add-Member -NotePropertyName entitlementMigration -NotePropertyValue $facts -Force
    if ($facts.Needed -and @($facts.Checks).Count) {
        Write-Host ''
        Write-Host 'Readiness evidence for the move to the Cosmos projection (shown here, not part of the plan fingerprint):' -ForegroundColor Cyan
        foreach ($check in @($facts.Checks)) { Write-Host ("  {0,-4} {1}: {2}" -f $check.Result, $check.Name, $check.Evidence) }
    }
}
$target = Get-ClaudeFlowLifecycleRecordTarget -Record $record -Discovery $discovery
if (-not $SnapshotPath) {
    $SnapshotPath = Join-Path $root "backups\before-update-$($target.ApimName).json"
}
# A decision record other than the default is named in the commands this update prints: the apply command, and the
# resume command of a migration that fails part way (0004).
$defaultRecord = [IO.Path]::GetFullPath((Join-Path $root 'onboarding\claude-gateway.json'))
$recordFullPath = [IO.Path]::GetFullPath((Resolve-ClaudeFlowFilePath $RecordPath))
$resumeRecordPath = if ([string]::Equals($recordFullPath, $defaultRecord, [StringComparison]::OrdinalIgnoreCase)) { '' } else { $recordFullPath }
# A decision record of another gateway is not this gateway's record: the apply writes the record, and later syncs
# read the tier groups from it (scripts/Get-ClaudeGatewayTarget.ps1). The apply refuses it (ADR-0054).
$recordTarget = Get-ClaudeFlowLifecycleRecordTarget -Record $record
$recordProblem = ''
$namesDiffer = $recordTarget.ApimName -and $target.ApimName -and -not ([string]::Equals($recordTarget.ApimName, $target.ApimName, [StringComparison]::OrdinalIgnoreCase) -and
    (-not $recordTarget.ResourceGroup -or [string]::Equals($recordTarget.ResourceGroup, $target.ResourceGroup, [StringComparison]::OrdinalIgnoreCase)))
$subscriptionsDiffer = (Test-ClaudeFlowSubscriptionId $recordSubscription) -and $target.SubscriptionId -and -not [string]::Equals($recordSubscription, $target.SubscriptionId, [StringComparison]::OrdinalIgnoreCase)
if ($namesDiffer -or $subscriptionsDiffer) {
    $recordWhere = "$($recordTarget.ResourceGroup)/$($recordTarget.ApimName)$(if ($recordSubscription) { " in subscription $recordSubscription" })"
    $targetWhere = "$($target.ResourceGroup)/$($target.ApimName)$(if ($target.SubscriptionId) { " in subscription $($target.SubscriptionId)" })"
    $recordProblem = "The decision record at '$recordFullPath' describes $recordWhere, not $targetWhere. Remedy: -RecordPath with this gateway's record, or with a new path such as .\onboarding\claude-gateway.$($target.ResourceGroup)-$($target.ApimName).json, which the apply writes."
}
# Every write of the update (the backup, the migrations, the deployer and the switch) uses the Azure CLI's current
# subscription, so with a record that names a subscription the update applies only when that one is current (ADR-0054).
$subscriptionProblem = ''
if (-not $recordProblem -and (Test-ClaudeFlowSubscriptionId $recordSubscription) -and ($Apply -or -not $DiscoveryPath)) {
    $cliSubscription = ([string](az account show --query id -o tsv 2>$null)).Trim()
    if (-not [string]::Equals($cliSubscription, $recordSubscription, [StringComparison]::OrdinalIgnoreCase)) {
        $current = if ($cliSubscription) { $cliSubscription } else { 'not known (az account show returned none)' }
        $subscriptionProblem = "The Azure CLI's current subscription is $current; the decision record names $recordSubscription, and the update writes in the current subscription. Remedy: az account set --subscription $recordSubscription, then rerun."
    }
}

# Code-point order: the migrations' order feeds the plan's fingerprint (P76).
$migrationFiles = @(Sort-ClaudeFlowOrdinal -InputObject @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'flow\migrations') -Filter '*.ps1') -Key { $_.Name })
$plans = @()
foreach ($file in $migrationFiles) {
    . $file.FullName
    $plan = Get-ClaudeFlowMigrationPlan -Record $record -Discovery $discovery
    if ($plan.Data -is [hashtable]) {
        $plan.Data.SnapshotPath = $SnapshotPath
        $plan.Data.SnapshotTaken = $false
        $plan.Data.RecordPath = $resumeRecordPath
    }
    $plans += $plan
}
$fingerprint = Get-ClaudeFlowFingerprint -Plans $plans
Format-ClaudeFlowReview -Plans $plans
Write-Host ''
Write-Host "Plan fingerprint: $fingerprint" -ForegroundColor Cyan
$blocked = @($plans | Where-Object { $_.Data -is [hashtable] -and $_.Data.Blocked })

if (-not $Apply -or $WhatIfPreference) {
    if ($blocked.Count) {
        Write-Host "Plan only, and blocked in $(@($blocked | ForEach-Object Step) -join ', '): nothing can be applied until the BLOCKED items are fixed and the plan is made again.$(if (@($blocked | Where-Object Step -eq '0004-entitlement-projection').Count) { ' With -KeepNamedValues the update plans no move to the projection, and its other migrations apply.' })" -ForegroundColor Yellow
    }
    elseif ($recordProblem) {
        Write-Host "Plan only. $recordProblem -Apply refuses this record." -ForegroundColor Yellow
    }
    elseif ($subscriptionProblem) {
        Write-Host "Plan only. $subscriptionProblem" -ForegroundColor Yellow
    }
    else {
        $parts = @('.\Update-ClaudeGateway.ps1')
        foreach ($name in 'RecordPath', 'DiscoveryPath', 'ResourceGroup', 'ApimName', 'SnapshotPath', 'StandardGroup', 'PremiumGroup', 'NamePrefix', 'ResolverInboundAccess') {
            if (-not ($PSBoundParameters.ContainsKey($name) -and $PSBoundParameters[$name])) { continue }
            # The root shim always passes the record path; the default record needs no option.
            if ($name -eq 'RecordPath' -and -not $resumeRecordPath) { continue }
            $parts += "-$name $(ConvertTo-ClaudeFlowCommandArgument $PSBoundParameters[$name])"
        }
        if ($KeepNamedValues) { $parts += '-KeepNamedValues' }
        Write-Host 'Plan only. Nothing has been changed. Add -Apply with -ApprovedPlanFingerprint to write; for this plan:' -ForegroundColor Cyan
        Write-Host ("  " + (($parts + @('-Apply', "-ApprovedPlanFingerprint $fingerprint")) -join ' '))
    }
    return [pscustomobject]@{ Plans = $plans; Fingerprint = $fingerprint; SnapshotPath = $SnapshotPath }
}
if ($recordProblem) {
    throw "$recordProblem Nothing was written."
}
if ($subscriptionProblem) {
    throw "$subscriptionProblem Nothing was written."
}
if ($blocked.Count) {
    throw "The plan is blocked in $(@($blocked | ForEach-Object Step) -join ', '); nothing was written. Fix the BLOCKED items shown above and plan again.$(if (@($blocked | Where-Object Step -eq '0004-entitlement-projection').Count) { ' With -KeepNamedValues the update plans no move to the projection, and its other migrations apply.' })"
}
if ($ApprovedPlanFingerprint -ne $fingerprint) {
    throw "Approved plan fingerprint does not match the plan made now; nothing was written. The plan printed above is the current one: review it, and to apply it rerun with -Apply -ApprovedPlanFingerprint $fingerprint."
}
if (-not $PSCmdlet.ShouldProcess($target.ApimName, 'apply ordered gateway update migrations')) { return }

foreach ($file in $migrationFiles) {
    . $file.FullName
    $plan = @($plans | Where-Object Step -eq (Get-ClaudeFlowMigrationInfo).Name)[0]
    Invoke-ClaudeFlowMigration -Record $record -Plan $plan | Out-Null
    Sync-ClaudeFlowLifecycleSnapshotTaken -Plans $plans
    if (-not $DiscoveryPath -and -not (Test-ClaudeFlowPlanIsNoop $plan)) {
        $discovery = Get-ClaudeFlowLifecycleLiveDiscovery -ResourceGroup $target.ResourceGroup -ApimName $target.ApimName -SubscriptionId $recordSubscription
    }
    # A migration whose verification needs its own plan (0004: nothing to verify when no move was planned) takes it.
    $check = if ((Get-Command Test-ClaudeFlowMigration).Parameters.ContainsKey('Plan')) { Test-ClaudeFlowMigration -Record $record -Discovery $discovery -Plan $plan }
        else { Test-ClaudeFlowMigration -Record $record -Discovery $discovery }
    if (-not $check.Passed) {
        throw "Migration '$($plan.Step)' did not verify. Roll back with .\scripts\Restore-ClaudeGateway.ps1 -Path '$SnapshotPath' -Apply."
    }
}
$release = Get-ClaudeFlowReleaseInfo
Set-ClaudeDecisionRelease -Record $record -Version $release.version -Commit $release.commit
Write-ClaudeDecisionRecord -Record $record -Path $RecordPath
Write-Host "Updated. Snapshot: $SnapshotPath" -ForegroundColor Green
