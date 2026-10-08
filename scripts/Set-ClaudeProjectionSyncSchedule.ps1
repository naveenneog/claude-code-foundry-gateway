<#
.SYNOPSIS
    Changes the interval of a deployed projection sync job.

.DESCRIPTION
    Reads the deployed Container Apps job, its image digest, tier group settings and alert action
    group, then redeploys scripts/Deploy-ClaudeProjectionRenewal.ps1 with the same settings and a
    new -SyncInterval. The redeploy skips the image build by passing the deployed image digest and
    updates the job trigger and alerts together.

.PARAMETER ResourceGroup
    Resource group that contains the projection sync job and action group.

.PARAMETER ApimName
    API Management gateway name used when reading the projection prefix named value and redeploying
    the job.

.PARAMETER Interval
    New sync interval: 30m, 1h, 2h, 3h, 4h, 6h, 8h, 12h, or manual.

.PARAMETER NamePrefix
    Projection prefix. When omitted, the script reads the entitlement-projection-prefix named value
    from the gateway.

.PARAMETER GatewayResourceGroup
    Resource group that contains the API Management gateway. Defaults to -ResourceGroup.

.PARAMETER ExpectedStandardGroup
    Object id of the standard tier group the job must use. With -ExpectedPremiumGroup, the script stops before
    any write when the job or its renewal deployment names other groups. It does not change the groups;
    scripts/Deploy-ClaudeProjectionRenewal.ps1 -StandardGroup does.

.PARAMETER ExpectedPremiumGroup
    Object id of the premium tier group the job must use, or none. Passed together with -ExpectedStandardGroup.

.EXAMPLE
    pwsh -NoProfile -File ./scripts/Set-ClaudeProjectionSyncSchedule.ps1 -ResourceGroup rg-prod `
      -ApimName apim-prod -Interval 30m
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)][string]$ResourceGroup,
    [Parameter(Mandatory = $true)][string]$ApimName,
    [Parameter(Mandatory = $true)][string]$Interval,
    [string]$NamePrefix,
    [string]$GatewayResourceGroup,
    [string]$ExpectedStandardGroup,
    [string]$ExpectedPremiumGroup
)

$ErrorActionPreference = 'Stop'
trap {
    $PSCmdlet.ThrowTerminatingError([Management.Automation.ErrorRecord]::new($_.Exception, 'ProjectionSyncScheduleStopped', $_.CategoryInfo.Category, $null))
}

. (Join-Path $PSScriptRoot 'ApimNamedValue.ps1')
. (Join-Path $PSScriptRoot 'ClaudeEntitlementGroups.ps1')
. (Join-Path $PSScriptRoot 'ClaudeProjectionSyncJob.ps1')

$problems = [Collections.Generic.List[string]]::new()
if (-not $GatewayResourceGroup) { $GatewayResourceGroup = $ResourceGroup }
foreach ($pair in @(@('-ResourceGroup', $ResourceGroup), @('-GatewayResourceGroup', $GatewayResourceGroup))) {
    if ($pair[1] -notmatch '^[A-Za-z0-9._-]{1,90}$') {
        $problems.Add("$($pair[0]) '$($pair[1])' is not 1-90 letters, digits, '.', '_' or '-'; other characters are refused before an az call.")
    }
}
if ($ApimName -notmatch '^[A-Za-z0-9-]{1,50}$') { $problems.Add("-ApimName '$ApimName' is not an API Management name.") }
if (-not [string]::IsNullOrWhiteSpace($NamePrefix) -and $NamePrefix -cnotmatch '^[a-z0-9](?:[a-z0-9]|-(?=[a-z0-9])){0,36}$') {
    $problems.Add("-NamePrefix '$NamePrefix' is not the projection prefix: 1-37 lowercase letters or digits, with single hyphens inside.")
}
$newSchedule = $null
try { $newSchedule = ConvertTo-ClaudeProjectionSyncSchedule -Interval $Interval } catch { $problems.Add("-Interval: $($_.Exception.Message)") }
$expectsGroups = $PSBoundParameters.ContainsKey('ExpectedStandardGroup') -or $PSBoundParameters.ContainsKey('ExpectedPremiumGroup')
if ($expectsGroups) {
    if (-not ($PSBoundParameters.ContainsKey('ExpectedStandardGroup') -and $PSBoundParameters.ContainsKey('ExpectedPremiumGroup'))) {
        $problems.Add('-ExpectedStandardGroup and -ExpectedPremiumGroup are checked together; pass both.')
    }
    if ($PSBoundParameters.ContainsKey('ExpectedStandardGroup') -and -not (Test-ClaudeEntitlementGroupGuid $ExpectedStandardGroup)) {
        $problems.Add("-ExpectedStandardGroup '$ExpectedStandardGroup' is not a group object id.")
    }
    if ($PSBoundParameters.ContainsKey('ExpectedPremiumGroup') -and $ExpectedPremiumGroup -cne 'none' -and -not (Test-ClaudeEntitlementGroupGuid $ExpectedPremiumGroup)) {
        $problems.Add("-ExpectedPremiumGroup '$ExpectedPremiumGroup' is not a group object id or none.")
    }
}
if ($problems.Count) { throw ("Projection sync schedule change refused before any Azure call:`n  - " + ($problems -join "`n  - ")) }

if ([string]::IsNullOrWhiteSpace($NamePrefix)) {
    $NamePrefix = ([string](Get-ApimNamedValue -ResourceGroup $GatewayResourceGroup -ApimName $ApimName -Id 'entitlement-projection-prefix' -FailOnError)).Trim()
    if ($NamePrefix -cnotmatch '^[a-z0-9](?:[a-z0-9]|-(?=[a-z0-9])){0,36}$') {
        throw "The gateway named value entitlement-projection-prefix returned '$NamePrefix', not a projection prefix."
    }
}

$job = try { Get-ClaudeProjectionSyncJob -ResourceGroup $ResourceGroup -NamePrefix $NamePrefix }
catch {
    $message = $_.Exception.Message
    if ($message -match 'More than one Container Apps job') {
        throw "$message Remedy: keep one deployed sync job for the prefix, or redeploy it with scripts/Deploy-ClaudeProjectionRenewal.ps1."
    }
    throw
}
if (-not $job) {
    throw "No Container Apps job in $ResourceGroup has tag claude-projection-prefix '$NamePrefix'. Remedy: deploy it with scripts/Deploy-ClaudeProjectionRenewal.ps1."
}
# Only the job that the projection-renewal deployment created keeps its settings through this script: a job that
# merely carries the tag could otherwise pass its image and tier groups into the redeployment.
# The workspace, subnet and alert addresses are kept too, so the redeployment moves no log route or alert scope.
$renewalDeployment = "projection-renewal-$NamePrefix"
$jobSettings = Get-ClaudeProjectionSyncJobSettings -ResourceGroup $ResourceGroup -NamePrefix $NamePrefix
# A failed deployment records no job, so nothing it holds can be confirmed (P104 council round 2).
if (-not [string]::Equals([string]$jobSettings.RenewalDeploymentState, 'Succeeded', [StringComparison]::Ordinal)) {
    throw "The last deployment $renewalDeployment in $ResourceGroup is $($jobSettings.RenewalDeploymentState), so its job, tier groups and workspace cannot be confirmed. Nothing was changed. Redeploy the job with scripts/Deploy-ClaudeProjectionRenewal.ps1, or rerun the installer."
}
$recordedJobId = [string]$jobSettings.JobResourceId
if (-not $recordedJobId) {
    throw "Deployment $renewalDeployment in $ResourceGroup records no job. Nothing was changed. Redeploy the job with scripts/Deploy-ClaudeProjectionRenewal.ps1."
}
if (-not [string]::Equals($recordedJobId, [string]$job.Id, [StringComparison]::OrdinalIgnoreCase)) {
    throw "The job tagged claude-projection-prefix '$NamePrefix' is $($job.Name) ($($job.Id)), but deployment $renewalDeployment created $recordedJobId. Nothing was changed. Delete the job that is not in use, or redeploy with scripts/Deploy-ClaudeProjectionRenewal.ps1."
}
$imageDigest = [string]$job.ImageDigest
if (-not $imageDigest) { throw "The deployed job image has no sha256 image digest. Redeploy with scripts/Deploy-ClaudeProjectionRenewal.ps1 so this script can preserve the exact image." }
if (-not [string]$job.StandardGroupId) { throw "The deployed job is missing PROJECTION_STANDARD_GROUP_ID. Redeploy it with scripts/Deploy-ClaudeProjectionRenewal.ps1." }
if (-not [string]$job.PremiumGroupId) { throw "The deployed job is missing PROJECTION_PREMIUM_GROUP_ID. Redeploy it with scripts/Deploy-ClaudeProjectionRenewal.ps1." }
# The tier groups come from the deployment's record; the job's settings can be edited outside it, so a difference
# stops the change rather than carrying an edited group into the redeployment (P104 council round 2).
$standardGroup = [string]$jobSettings.StandardGroupId
$premiumGroup = [string]$jobSettings.PremiumGroupId
$sameGroups = $standardGroup -and $premiumGroup -and
    [string]::Equals($standardGroup, [string]$job.StandardGroupId, [StringComparison]::OrdinalIgnoreCase) -and
    [string]::Equals($premiumGroup, [string]$job.PremiumGroupId, [StringComparison]::OrdinalIgnoreCase)
if (-not $sameGroups) {
    throw ("The job's tier groups (standard $($job.StandardGroupId), premium $($job.PremiumGroupId)) differ from those deployment $renewalDeployment recorded " +
        "(standard $standardGroup, premium $premiumGroup). Nothing was changed. Redeploy with scripts/Deploy-ClaudeProjectionRenewal.ps1 -StandardGroup <id> -PremiumGroup <id or none> to set the groups.")
}
# Whoever can write the job can also write its deployment record, so both can agree on other groups. An admin who
# holds the intended object ids checks them here (P104 council round 3).
if ($expectsGroups -and -not ([string]::Equals($standardGroup, $ExpectedStandardGroup, [StringComparison]::OrdinalIgnoreCase) -and
        [string]::Equals($premiumGroup, $ExpectedPremiumGroup, [StringComparison]::OrdinalIgnoreCase))) {
    throw ("The job and deployment $renewalDeployment use tier groups standard $standardGroup, premium $premiumGroup, not the expected standard $ExpectedStandardGroup, " +
        "premium $ExpectedPremiumGroup. Nothing was changed. Redeploy with scripts/Deploy-ClaudeProjectionRenewal.ps1 -StandardGroup <id> -PremiumGroup <id or none> to set the groups.")
}

$currentCron = [string]$job.Cron
$currentInterval = $job.Interval
$currentWords = if ($currentInterval) { Format-ClaudeProjectionSyncInterval -Interval $currentInterval } else { 'a cron expression this script did not set' }

$actionGroupName = "ag-projection-renewal-$NamePrefix"
$emails = @($jobSettings.AlertEmails)
if (-not $emails.Count) {
    throw "Action group $actionGroupName has no email receivers. Add at least one email receiver, or redeploy the sync job with scripts/Deploy-ClaudeProjectionRenewal.ps1."
}

if ($currentInterval -and $currentInterval -ceq $newSchedule.Interval) {
    # The same interval is in place only with the alert rules the template deploys for it: one no-success rule
    # for a schedule, none for manual, and never P97's 45-minute rule. Otherwise the redeployment repairs them.
    $ruleNames = @(Invoke-ClaudeProjectionSyncAzJson -Arguments @('resource', 'list', '-g', $ResourceGroup, '--resource-type', 'Microsoft.Insights/scheduledQueryRules', '-o', 'json') -What "the alert rules in $ResourceGroup" |
            ForEach-Object { [string]$_.name })
    $hasRule = { param($name) @($ruleNames | Where-Object { [string]::Equals($_, $name, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0 }
    $rulesInPlace = -not (& $hasRule "sqr-projection-$NamePrefix-no-success-45m") -and
        ((& $hasRule "sqr-projection-$NamePrefix-no-success") -eq ($newSchedule.Interval -cne 'manual'))
    # A cron edited outside the deployment leaves the no-success range of the recorded schedule.
    $recordedInPlace = [string]::Equals([string]$jobSettings.RecordedCron, $newSchedule.Cron, [StringComparison]::Ordinal) -and
        [int]$jobSettings.RecordedNoSuccessMinutes -eq [int]$newSchedule.NoSuccessMinutes
    if ($rulesInPlace -and $recordedInPlace) {
        Write-Output "The projection sync job already runs $(Format-ClaudeProjectionSyncInterval -Interval $newSchedule.Interval)."
        return
    }
    Write-Output "The projection sync job already runs $(Format-ClaudeProjectionSyncInterval -Interval $newSchedule.Interval), but its alert rules or its recorded schedule differ from the template; redeploying to repair them."
}

$toWords = Format-ClaudeProjectionSyncInterval -Interval $newSchedule.Interval
if ($newSchedule.Interval -ceq 'manual') {
    Write-Output "Changing projection sync schedule for '$NamePrefix' from $currentWords to $toWords."
    Write-Output 'The manual job has no scheduled runs per month and no no-success alert rule.'
}
else {
    Write-Output "Changing projection sync schedule for '$NamePrefix' from $currentWords to $toWords."
    Write-Output "The new schedule runs $($newSchedule.RunsPerMonth) times per 730-hour month; the no-success alert reads $($newSchedule.NoSuccessMinutes) minutes."
}
Write-Output "Keeping the tier groups that deployment $renewalDeployment recorded and the job uses: standard $standardGroup, premium $premiumGroup."

$deployArgs = @{
    ResourceGroup = $ResourceGroup
    ApimName = $ApimName
    NamePrefix = $NamePrefix
    AlertEmail = $emails
    StandardGroup = $standardGroup
    PremiumGroup = $premiumGroup
    ImageDigest = $imageDigest
    SyncInterval = $newSchedule.Interval
    KeepRegistry = $true
}
if ($jobSettings.WorkspaceResourceId) { $deployArgs['WorkspaceResourceId'] = [string]$jobSettings.WorkspaceResourceId }
if ($jobSettings.RenewalSubnetId) { $deployArgs['RenewalSubnetId'] = [string]$jobSettings.RenewalSubnetId }
if ($PSBoundParameters.ContainsKey('GatewayResourceGroup') -and $GatewayResourceGroup) { $deployArgs['GatewayResourceGroup'] = $GatewayResourceGroup }
if ($WhatIfPreference) { $deployArgs['WhatIf'] = $true }

& (Join-Path $PSScriptRoot 'Deploy-ClaudeProjectionRenewal.ps1') @deployArgs
