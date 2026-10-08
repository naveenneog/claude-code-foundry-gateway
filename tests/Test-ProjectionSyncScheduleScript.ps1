# P104: changing a deployed projection sync job interval without rebuilding its image (ADR-0058).
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$fail = 0
$script:assertions = 0
function Assert($Label, [bool]$Condition, $Detail = '') {
    $script:assertions++
    if ($Condition) { Write-Host "  [OK]   $Label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $Label$(if ($Detail) { " - $Detail" })" -ForegroundColor Red; $script:fail++ }
}
function Get-Refusal([scriptblock]$Action) {
    try { & $Action | Out-Null; return '' } catch { return $_.Exception.Message }
}

$setScript = Join-Path $root 'scripts\Set-ClaudeProjectionSyncSchedule.ps1'
Assert 'the schedule change script exists' (Test-Path -LiteralPath $setScript -PathType Leaf) $setScript

$work = Join-Path ([IO.Path]::GetTempPath()) ('projection-sync-schedule-script-' + [guid]::NewGuid().ToString('N'))
$deployCallsPath = Join-Path $work 'deploy-calls.json'
New-Item -ItemType Directory -Force -Path $work | Out-Null

try {
    $scripts = Join-Path $work 'scripts'
    New-Item -ItemType Directory -Force -Path $scripts | Out-Null
    Copy-Item -LiteralPath (Join-Path $root 'scripts\ClaudeProjectionSchedule.ps1') -Destination (Join-Path $scripts 'ClaudeProjectionSchedule.ps1')
    Copy-Item -LiteralPath (Join-Path $root 'scripts\ApimNamedValue.ps1') -Destination (Join-Path $scripts 'ApimNamedValue.ps1')
    if (Test-Path -LiteralPath $setScript -PathType Leaf) {
        Copy-Item -LiteralPath $setScript -Destination (Join-Path $scripts 'Set-ClaudeProjectionSyncSchedule.ps1')
    }
    @'
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)][string]$ResourceGroup,
    [Parameter(Mandatory = $true)][string]$ApimName,
    [Parameter(Mandatory = $true)][string]$NamePrefix,
    [Parameter(Mandatory = $true)][string[]]$AlertEmail,
    [Parameter(Mandatory = $true)][string]$StandardGroup,
    [Parameter(Mandatory = $true)][string]$PremiumGroup,
    [Parameter(Mandatory = $true)][string]$ImageDigest,
    [Parameter(Mandatory = $true)][string]$SyncInterval,
    [string]$GatewayResourceGroup
)
$record = [ordered]@{
    ResourceGroup = $ResourceGroup
    ApimName = $ApimName
    NamePrefix = $NamePrefix
    AlertEmail = @($AlertEmail)
    StandardGroup = $StandardGroup
    PremiumGroup = $PremiumGroup
    ImageDigest = $ImageDigest
    SyncInterval = $SyncInterval
    GatewayResourceGroup = $GatewayResourceGroup
    WhatIf = [bool]$WhatIfPreference
    Bound = @($PSBoundParameters.Keys)
}
$path = Join-Path $PSScriptRoot '..\deploy-calls.json'
$calls = @()
if (Test-Path -LiteralPath $path) { $calls = @(Get-Content -LiteralPath $path -Raw | ConvertFrom-Json) }
$calls += [pscustomobject]$record
[IO.File]::WriteAllText($path, ($calls | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
[pscustomobject]$record
'@ | Set-Content -LiteralPath (Join-Path $scripts 'Deploy-ClaudeProjectionRenewal.ps1') -Encoding utf8NoBOM

    $digest = 'sha256:' + ('a' * 64)
    $standard = '11111111-1111-4111-8111-111111111111'
    $premium = '22222222-2222-4222-8222-222222222222'
    $global:ProjectionScheduleAzCalls = [Collections.Generic.List[string]]::new()
    $global:ProjectionScheduleScenario = @{}
    function New-Job([string]$Prefix = 'p104fixture', [string]$Cron = '0 */2 * * *', [string]$Image = $digest, [string]$PremiumGroup = $premium) {
        $trigger = if ($Cron) { 'Schedule' } else { 'Manual' }
        $configuration = if ($Cron) {
            @{ triggerType = $trigger; scheduleTriggerConfig = @{ cronExpression = $Cron } }
        }
        else {
            @{ triggerType = $trigger; manualTriggerConfig = @{ parallelism = 1; replicaCompletionCount = 1 } }
        }
        [pscustomobject]@{
            name = "caj-renew-$Prefix"
            tags = @{ 'claude-projection-prefix' = $Prefix }
            properties = @{
                configuration = $configuration
                template = @{
                    containers = @(
                        @{
                            image = "acrp104.azurecr.io/claude-projection-sync@$Image"
                            env = @(
                                @{ name = 'PROJECTION_STANDARD_GROUP_ID'; value = $standard }
                                @{ name = 'PROJECTION_PREMIUM_GROUP_ID'; value = $PremiumGroup }
                            )
                        }
                    )
                }
            }
        }
    }
    function Set-Scenario([hashtable]$Values) {
        $global:ProjectionScheduleScenario = @{
            Prefix = 'p104fixture'
            Jobs = @(New-Job)
            Emails = @('ops@example.invalid', 'oncall@example.invalid')
            NamedValue = 'p104fixture'
        }
        foreach ($key in $Values.Keys) { $global:ProjectionScheduleScenario[$key] = $Values[$key] }
        $global:ProjectionScheduleAzCalls.Clear()
        Remove-Item -LiteralPath $deployCallsPath -Force -ErrorAction SilentlyContinue
    }
    function global:az {
        $global:ProjectionScheduleAzCalls.Add(($args -join ' '))
        if (($args -join ' ') -match '^containerapp job list ') { return ($global:ProjectionScheduleScenario.Jobs | ConvertTo-Json -Depth 20) }
        if (($args -join ' ') -match '^monitor action-group show ') {
            return ([pscustomobject]@{ emailReceivers = @($global:ProjectionScheduleScenario.Emails | ForEach-Object { @{ emailAddress = $_ } }) } | ConvertTo-Json -Depth 6)
        }
        if (($args -join ' ') -match '^apim nv show ') {
            if ($global:ProjectionScheduleScenario.NamedValue -eq $null) {
                $global:LASTEXITCODE = 3
                Write-Error '(ResourceNotFound) NamedValue not found'
                return
            }
            $global:LASTEXITCODE = 0
            return $global:ProjectionScheduleScenario.NamedValue
        }
        throw "Unexpected az call: $($args -join ' ')"
    }
    function Get-DeployCalls {
        if (-not (Test-Path -LiteralPath $deployCallsPath)) { return @() }
        return @(Get-Content -LiteralPath $deployCallsPath -Raw | ConvertFrom-Json)
    }
    function Invoke-ScheduleScenario([hashtable]$Scenario, [hashtable]$Overrides) {
        Set-Scenario $Scenario
        $params = @{
            ResourceGroup = 'rg-p104'
            ApimName = 'apim-p104'
            Interval = '30m'
            NamePrefix = 'p104fixture'
        }
        foreach ($key in $Overrides.Keys) { $params[$key] = $Overrides[$key] }
        $out = ''
        $failure = ''
        try { $out = (& (Join-Path $scripts 'Set-ClaudeProjectionSyncSchedule.ps1') @params *>&1 | Out-String -Width 400) }
        catch { $failure = $_.Exception.Message }
        [pscustomobject]@{ Failure = $failure; Output = $out; Calls = @($global:ProjectionScheduleAzCalls); Deploy = @(Get-DeployCalls) }
    }

    Write-Host ''
    Write-Host 'Projection sync schedule change - redeploy contract' -ForegroundColor Cyan

    if (Test-Path -LiteralPath (Join-Path $scripts 'Set-ClaudeProjectionSyncSchedule.ps1')) {
        $change = Invoke-ScheduleScenario -Scenario @{} -Overrides @{}
        $deploy = $change.Deploy | Select-Object -First 1
        Assert '2h to 30m calls the deploy script once' (-not $change.Failure -and $change.Deploy.Count -eq 1) "$($change.Failure) | $($change.Output)"
        Assert 'the deploy call keeps the digest, groups, receivers, prefix and interval' ($deploy -and
            $deploy.ResourceGroup -eq 'rg-p104' -and $deploy.ApimName -eq 'apim-p104' -and $deploy.NamePrefix -eq 'p104fixture' -and
            $deploy.ImageDigest -eq $digest -and $deploy.StandardGroup -eq $standard -and $deploy.PremiumGroup -eq $premium -and
            (($deploy.AlertEmail | Sort-Object) -join ',') -eq 'oncall@example.invalid,ops@example.invalid' -and $deploy.SyncInterval -eq '30m') ($deploy | ConvertTo-Json -Compress)
        Assert 'the job list is filtered in PowerShell by prefix tag' (($change.Calls -join ' | ') -match '^containerapp job list -g rg-p104 -o json' -and ($change.Calls -join ' | ') -notmatch '--query') ($change.Calls -join ' | ')

        $same = Invoke-ScheduleScenario -Scenario @{} -Overrides @{ Interval = '2h' }
        Assert 'the same interval exits without redeploying' (-not $same.Failure -and $same.Deploy.Count -eq 0 -and $same.Output -match 'already runs every 2 hours') "$($same.Failure) | $($same.Output)"

        foreach ($bad in @('15m', '24h', '2h;')) {
            $refused = Invoke-ScheduleScenario -Scenario @{} -Overrides @{ Interval = $bad }
            Assert "$bad is refused before any az call" ($refused.Failure -match 'refused before any Azure call' -and $refused.Calls.Count -eq 0 -and $refused.Deploy.Count -eq 0) "$($refused.Failure) | calls $($refused.Calls.Count)"
        }

        $manualTo2h = Invoke-ScheduleScenario -Scenario @{ Jobs = @(New-Job -Cron '') } -Overrides @{ Interval = '2h' }
        Assert 'manual to 2h redeploys to 2h' (-not $manualTo2h.Failure -and $manualTo2h.Deploy.Count -eq 1 -and $manualTo2h.Deploy[0].SyncInterval -eq '2h' -and $manualTo2h.Output -match 'only when started' -and $manualTo2h.Output -match 'every 2 hours') "$($manualTo2h.Failure) | $($manualTo2h.Output)"

        $noDigest = Invoke-ScheduleScenario -Scenario @{ Jobs = @(New-Job -Image 'latest') } -Overrides @{}
        Assert 'a job image without a digest is refused before deploy' ($noDigest.Failure -match 'image digest' -and $noDigest.Deploy.Count -eq 0) "$($noDigest.Failure) | deploys $($noDigest.Deploy.Count)"

        $noJob = Invoke-ScheduleScenario -Scenario @{ Jobs = @() } -Overrides @{}
        Assert 'no matching job is refused with the deploy remedy' ($noJob.Failure -match 'No Container Apps job' -and $noJob.Failure -match 'Deploy-ClaudeProjectionRenewal\.ps1' -and $noJob.Deploy.Count -eq 0) $noJob.Failure
        $twoJobs = Invoke-ScheduleScenario -Scenario @{ Jobs = @(New-Job; New-Job) } -Overrides @{}
        Assert 'two matching jobs are refused with the deploy remedy' ($twoJobs.Failure -match 'More than one Container Apps job' -and $twoJobs.Failure -match 'Deploy-ClaudeProjectionRenewal\.ps1' -and $twoJobs.Deploy.Count -eq 0) $twoJobs.Failure

        $nonePremium = Invoke-ScheduleScenario -Scenario @{ Jobs = @(New-Job -PremiumGroup 'none') } -Overrides @{}
        Assert 'premium none is passed through' (-not $nonePremium.Failure -and $nonePremium.Deploy[0].PremiumGroup -eq 'none') "$($nonePremium.Failure) | $($nonePremium.Deploy[0] | ConvertTo-Json -Compress)"

        $whatIf = Invoke-ScheduleScenario -Scenario @{} -Overrides @{ WhatIf = $true }
        Assert 'WhatIf reaches the deploy script' (-not $whatIf.Failure -and $whatIf.Deploy.Count -eq 1 -and $whatIf.Deploy[0].WhatIf -eq $true) "$($whatIf.Failure) | $($whatIf.Deploy[0] | ConvertTo-Json -Compress)"

        $gatewayGroup = Invoke-ScheduleScenario -Scenario @{} -Overrides @{ GatewayResourceGroup = 'rg-gateway' }
        Assert 'GatewayResourceGroup reaches the deploy script when given' (-not $gatewayGroup.Failure -and $gatewayGroup.Deploy.Count -eq 1 -and $gatewayGroup.Deploy[0].GatewayResourceGroup -eq 'rg-gateway') "$($gatewayGroup.Failure) | $($gatewayGroup.Deploy[0] | ConvertTo-Json -Compress)"

        $namedPrefix = Invoke-ScheduleScenario -Scenario @{} -Overrides @{ NamePrefix = $null }
        Assert 'the prefix is read from the named value when NamePrefix is absent' (-not $namedPrefix.Failure -and $namedPrefix.Deploy.Count -eq 1 -and $namedPrefix.Deploy[0].NamePrefix -eq 'p104fixture' -and (($namedPrefix.Calls -join ' | ') -match 'apim nv show')) "$($namedPrefix.Failure) | $($namedPrefix.Calls -join ' | ')"

        $noEmail = Invoke-ScheduleScenario -Scenario @{ Emails = @() } -Overrides @{}
        Assert 'no email receivers are refused before deploy' ($noEmail.Failure -match 'email receiver' -and $noEmail.Deploy.Count -eq 0) "$($noEmail.Failure) | deploys $($noEmail.Deploy.Count)"
    }
}
finally {
    Remove-Item Function:\az -ErrorAction SilentlyContinue
    Remove-Variable -Name ProjectionScheduleAzCalls -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable -Name ProjectionScheduleScenario -Scope Global -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail) { Write-Host "$fail of $assertions projection sync schedule script assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "$assertions projection sync schedule script assertions passed." -ForegroundColor Green
exit 0
