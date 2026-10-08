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
    [string]$GatewayResourceGroup
)

$ErrorActionPreference = 'Stop'
trap {
    $PSCmdlet.ThrowTerminatingError([Management.Automation.ErrorRecord]::new($_.Exception, 'ProjectionSyncScheduleStopped', $_.CategoryInfo.Category, $null))
}

. (Join-Path $PSScriptRoot 'ApimNamedValue.ps1')
. (Join-Path $PSScriptRoot 'ClaudeProjectionSyncJob.ps1')

function Get-JsonAz {
    param([Parameter(Mandatory = $true)][string[]]$Arguments, [Parameter(Mandatory = $true)][string]$What)
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $global:LASTEXITCODE = 0
        $output = @(az @Arguments 2>&1)
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previous }
    if ($code -ne 0) {
        $detail = ($output | Out-String).Trim()
        throw "Could not read $What (az exit $code). $detail"
    }
    $text = ($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | Out-String).Trim()
    if (-not $text) { return $null }
    return ($text | ConvertFrom-Json)
}

function Get-EmailReceivers($ActionGroup) {
    $receivers = @()
    foreach ($source in @($ActionGroup.emailReceivers) + @($ActionGroup.properties.emailReceivers)) {
        foreach ($receiver in @($source)) {
            $email = ([string]$receiver.emailAddress).Trim()
            if ($email) { $receivers += $email }
        }
    }
    return @($receivers | Select-Object -Unique)
}

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
$imageDigest = [string]$job.ImageDigest
if (-not $imageDigest) { throw "The deployed job image has no sha256 image digest. Redeploy with scripts/Deploy-ClaudeProjectionRenewal.ps1 so this script can preserve the exact image." }
$standardGroup = [string]$job.StandardGroupId
$premiumGroup = [string]$job.PremiumGroupId
if (-not $standardGroup) { throw "The deployed job is missing PROJECTION_STANDARD_GROUP_ID. Redeploy it with scripts/Deploy-ClaudeProjectionRenewal.ps1." }
if (-not $premiumGroup) { throw "The deployed job is missing PROJECTION_PREMIUM_GROUP_ID. Redeploy it with scripts/Deploy-ClaudeProjectionRenewal.ps1." }

$currentCron = [string]$job.Cron
$currentInterval = $job.Interval
$currentWords = if ($currentInterval) { Format-ClaudeProjectionSyncInterval -Interval $currentInterval } else { 'a cron expression this script did not set' }

$actionGroupName = "ag-projection-renewal-$NamePrefix"
$actionGroup = Get-JsonAz -Arguments @('monitor', 'action-group', 'show', '-g', $ResourceGroup, '-n', $actionGroupName, '-o', 'json') -What "action group $actionGroupName"
$emails = @(Get-EmailReceivers $actionGroup)
if (-not $emails.Count) {
    throw "Action group $actionGroupName has no email receivers. Add at least one email receiver, or redeploy the sync job with scripts/Deploy-ClaudeProjectionRenewal.ps1."
}

if ($currentInterval -and $currentInterval -ceq $newSchedule.Interval) {
    Write-Output "The projection sync job already runs $(Format-ClaudeProjectionSyncInterval -Interval $newSchedule.Interval)."
    return
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

$deployArgs = @{
    ResourceGroup = $ResourceGroup
    ApimName = $ApimName
    NamePrefix = $NamePrefix
    AlertEmail = $emails
    StandardGroup = $standardGroup
    PremiumGroup = $premiumGroup
    ImageDigest = $imageDigest
    SyncInterval = $newSchedule.Interval
}
if ($PSBoundParameters.ContainsKey('GatewayResourceGroup') -and $GatewayResourceGroup) { $deployArgs['GatewayResourceGroup'] = $GatewayResourceGroup }
if ($WhatIfPreference) { $deployArgs['WhatIf'] = $true }

& (Join-Path $PSScriptRoot 'Deploy-ClaudeProjectionRenewal.ps1') @deployArgs
