# The deployed projection sync job, found by the claude-projection-prefix tag that
# infra/projection-renewal.bicep puts on it, and the settings a redeployment keeps. Core az commands only:
# az containerapp needs the containerapp extension. No --query: on Windows az is az.cmd, and cmd.exe re-reads
# quotes and | in its arguments, so the filters run here.
. (Join-Path $PSScriptRoot 'ClaudeProjectionSchedule.ps1')

# Runs az and returns its parsed JSON. Lines az writes to stderr stay out of the parse: a warning with exit
# code 0 would otherwise break it (P104 council round 1).
function Invoke-ClaudeProjectionSyncAzJson {
    param([Parameter(Mandatory = $true)][string[]]$Arguments, [Parameter(Mandatory = $true)][string]$What)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $global:LASTEXITCODE = 0
        $output = @(az @Arguments 2>&1)
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previous }
    if ($code -ne 0) { throw "Reading $What failed (az exit $code): $((($output | Out-String).Trim()))" }
    $text = (@($output | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] }) | Out-String).Trim()
    if (-not $text) { return $null }
    # Windows PowerShell 5.1 emits a parsed JSON array as one pipeline object; a variable keeps it enumerable.
    $parsed = $text | ConvertFrom-Json
    return $parsed
}

function Assert-ClaudeProjectionSyncJobScope {
    param([string]$ResourceGroup, [string]$NamePrefix)
    if ($ResourceGroup -notmatch '^[A-Za-z0-9._-]{1,90}$') { throw "Resource group '$ResourceGroup' is not 1-90 letters, digits, '.', '_' or '-'; other characters are refused before an az call." }
    if ($NamePrefix -cnotmatch '^[a-z0-9](?:[a-z0-9]|-(?=[a-z0-9])){0,36}$') { throw "Prefix '$NamePrefix' is not the projection prefix: 1-37 lowercase letters or digits, with single hyphens inside." }
}

# Returns nothing when no job carries the prefix.
function Get-ClaudeProjectionSyncJob {
    param([Parameter(Mandatory = $true)][string]$ResourceGroup, [Parameter(Mandatory = $true)][string]$NamePrefix)
    Assert-ClaudeProjectionSyncJobScope -ResourceGroup $ResourceGroup -NamePrefix $NamePrefix
    $listed = @(Invoke-ClaudeProjectionSyncAzJson -Arguments @('resource', 'list', '-g', $ResourceGroup, '--resource-type', 'Microsoft.App/jobs', '-o', 'json') -What "the Container Apps jobs in $ResourceGroup")
    $tagged = @($listed | Where-Object {
            $_.tags -and [string]::Equals([string]$_.tags.'claude-projection-prefix', $NamePrefix, [StringComparison]::Ordinal) })
    if ($tagged.Count -eq 0) { return $null }
    if ($tagged.Count -gt 1) {
        throw "More than one Container Apps job in $ResourceGroup carries claude-projection-prefix ${NamePrefix}: $((@($tagged | ForEach-Object { $_.name })) -join ', '). Delete the job that is not in use, then rerun."
    }
    $job = Invoke-ClaudeProjectionSyncAzJson -Arguments @('resource', 'show', '--ids', ([string]$tagged[0].id), '--api-version', '2024-03-01', '-o', 'json') -What "job $($tagged[0].name)"
    $configuration = $job.properties.configuration
    $trigger = [string]$configuration.triggerType
    $cron = if ($trigger -eq 'Schedule') { [string]$configuration.scheduleTriggerConfig.cronExpression } else { '' }
    $container = @($job.properties.template.containers)[0]
    $settings = @{}
    foreach ($setting in @($container.env)) { $settings[[string]$setting.name] = [string]$setting.value }
    $digest = if ([string]$container.image -cmatch '@(sha256:[0-9a-f]{64})$') { $Matches[1] } else { '' }
    [pscustomobject]@{
        Id = [string]$job.id; Name = [string]$job.name; TriggerType = $trigger; Cron = $cron
        Interval = ConvertFrom-ClaudeProjectionSyncCron -Cron $cron
        ImageDigest = $digest
        StandardGroupId = $settings['PROJECTION_STANDARD_GROUP_ID']; PremiumGroupId = $settings['PROJECTION_PREMIUM_GROUP_ID']
    }
}

# What a redeployment of the job keeps (P104 council rounds 1-3): the alert addresses of the live action group,
# the live registry SKU and network access, and the workspace, subnet, tier groups and schedule that the last
# renewal deployment recorded. A failed deployment records parameters but no outputs, so its state is returned
# and the callers decide; the job id that a successful deployment created binds a tagged job to it.
function Get-ClaudeProjectionSyncJobSettings {
    param([Parameter(Mandatory = $true)][string]$ResourceGroup, [Parameter(Mandatory = $true)][string]$NamePrefix)
    Assert-ClaudeProjectionSyncJobScope -ResourceGroup $ResourceGroup -NamePrefix $NamePrefix
    $renewalName = "projection-renewal-$NamePrefix"
    $renewal = Invoke-ClaudeProjectionSyncAzJson -Arguments @('deployment', 'group', 'show', '-g', $ResourceGroup, '-n', $renewalName, '-o', 'json') -What "deployment $renewalName"
    $registryName = "projection-registry-$NamePrefix"
    $registry = Invoke-ClaudeProjectionSyncAzJson -Arguments @('deployment', 'group', 'show', '-g', $ResourceGroup, '-n', $registryName, '-o', 'json') -What "deployment $registryName"
    $acrName = [string]$registry.properties.outputs.acrName.value
    # A failed registry deployment records no outputs; infra/projection-renewal.bicep requires acrName, so the
    # renewal deployment names the registry the job pulls from (P104 council round 3).
    if ($acrName -cnotmatch '^[a-z0-9]{5,50}$') { $acrName = [string]$renewal.properties.parameters.acrName.value }
    if ($acrName -cnotmatch '^[a-z0-9]{5,50}$') {
        throw "Neither deployment $registryName nor $renewalName records a registry name, so the registry's SKU and network access cannot be read. Nothing was changed. Redeploy the job with scripts/Deploy-ClaudeProjectionRenewal.ps1."
    }
    $acr = Invoke-ClaudeProjectionSyncAzJson -Arguments @('acr', 'show', '-g', $ResourceGroup, '-n', $acrName, '-o', 'json') -What "registry $acrName"
    $acrSku = [string]$acr.sku.name
    $acrAccess = [string]$acr.publicNetworkAccess
    $groupName = "ag-projection-renewal-$NamePrefix"
    $actionGroup = Invoke-ClaudeProjectionSyncAzJson -Arguments @('monitor', 'action-group', 'show', '-g', $ResourceGroup, '-n', $groupName, '-o', 'json') -What "action group $groupName"
    $emails = @(@(@($actionGroup.emailReceivers) + @($actionGroup.properties.emailReceivers)) | Where-Object { $_ } |
            ForEach-Object { ([string]$_.emailAddress).Trim() } | Where-Object { $_ } | Select-Object -Unique)
    $parameters = $renewal.properties.parameters
    $recordedMinutes = 0
    if ($null -ne $parameters.noSuccessMinutes.value) { $recordedMinutes = [int]$parameters.noSuccessMinutes.value }
    [pscustomobject]@{
        RenewalDeploymentState = [string]$renewal.properties.provisioningState
        JobResourceId = [string]$renewal.properties.outputs.jobResourceId.value
        AlertEmails = $emails
        AcrSku = $acrSku
        RegistryPublicNetworkAccess = $acrAccess
        WorkspaceResourceId = [string]$parameters.logAnalyticsWorkspaceId.value
        RenewalSubnetId = [string]$parameters.containerAppsSubnetId.value
        StandardGroupId = [string]$parameters.standardGroupId.value
        PremiumGroupId = [string]$parameters.premiumGroupId.value
        RecordedCron = [string]$parameters.cronExpression.value
        RecordedNoSuccessMinutes = $recordedMinutes
    }
}