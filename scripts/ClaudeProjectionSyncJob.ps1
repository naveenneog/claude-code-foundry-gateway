# The deployed projection sync job, found by the claude-projection-prefix tag that
# infra/projection-renewal.bicep puts on it. Core az resource commands only: az containerapp needs the
# containerapp extension. No --query: on Windows az is az.cmd, and cmd.exe re-reads quotes and | in its
# arguments, so the filter runs here. Returns nothing when no job carries the prefix.
. (Join-Path $PSScriptRoot 'ClaudeProjectionSchedule.ps1')

function Get-ClaudeProjectionSyncJob {
    param([Parameter(Mandatory = $true)][string]$ResourceGroup, [Parameter(Mandatory = $true)][string]$NamePrefix)
    if ($ResourceGroup -notmatch '^[A-Za-z0-9._-]{1,90}$') { throw "Resource group '$ResourceGroup' is not 1-90 letters, digits, '.', '_' or '-'; other characters are refused before an az call." }
    if ($NamePrefix -cnotmatch '^[a-z0-9](?:[a-z0-9]|-(?=[a-z0-9])){0,36}$') { throw "Prefix '$NamePrefix' is not the projection prefix: 1-37 lowercase letters or digits, with single hyphens inside." }
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $listText = az resource list -g $ResourceGroup --resource-type Microsoft.App/jobs -o json 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { throw "Listing the Container Apps jobs in $ResourceGroup failed: $($listText.Trim())" }
        # Windows PowerShell 5.1 emits a parsed JSON array as one pipeline object; a variable keeps it enumerable.
        $listed = $listText | ConvertFrom-Json
        $tagged = @(@($listed) | Where-Object {
                $_.tags -and [string]::Equals([string]$_.tags.'claude-projection-prefix', $NamePrefix, [StringComparison]::Ordinal) })
        if ($tagged.Count -eq 0) { return $null }
        if ($tagged.Count -gt 1) {
            throw "More than one Container Apps job in $ResourceGroup carries claude-projection-prefix ${NamePrefix}: $((@($tagged | ForEach-Object { $_.name })) -join ', '). Delete the job that is not in use, then rerun."
        }
        $showText = az resource show --ids ([string]$tagged[0].id) --api-version 2024-03-01 -o json 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { throw "Reading job $($tagged[0].name) failed: $($showText.Trim())" }
    }
    finally { $ErrorActionPreference = $previous }
    $job = $showText | ConvertFrom-Json
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
