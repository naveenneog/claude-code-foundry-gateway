# P104: each sync job interval maps to one cron expression, one no-success range and one run count (ADR-0058).
$ErrorActionPreference = 'Stop'
$fail = 0
$count = 0
function Assert($Label, [bool]$Condition, $Detail = '') {
    $script:count++
    if ($Condition) { Write-Host "  [OK]   $Label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $Label $Detail" -ForegroundColor Red; $script:fail++ }
}
function Get-Refusal([scriptblock]$Action) {
    try { & $Action | Out-Null; return '' } catch { return $_.Exception.Message }
}

$module = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\ClaudeProjectionSchedule.ps1'
Assert 'the interval module exists' (Test-Path -LiteralPath $module) $module
if (Test-Path -LiteralPath $module) { . $module }
$loaded = [bool](Get-Command ConvertTo-ClaudeProjectionSyncSchedule -ErrorAction SilentlyContinue)
Assert 'it defines ConvertTo-ClaudeProjectionSyncSchedule' $loaded

# Interval, cron (UTC), no-success minutes (2 x interval + 15), runs in a 730-hour month (midpoint away from zero).
$expected = @(
    , @('30m', '*/30 * * * *', 30, 75, 1460)
    , @('1h', '0 * * * *', 60, 135, 730)
    , @('2h', '0 */2 * * *', 120, 255, 365)
    , @('3h', '0 */3 * * *', 180, 375, 243)
    , @('4h', '0 */4 * * *', 240, 495, 183)
    , @('6h', '0 */6 * * *', 360, 735, 122)
    , @('8h', '0 */8 * * *', 480, 975, 91)
    , @('12h', '0 */12 * * *', 720, 1455, 61)
)
Assert 'the expected table has eight rows of five values' ($expected.Count -eq 8 -and @($expected | Where-Object { $_.Count -ne 5 }).Count -eq 0)
if ($loaded) {
    foreach ($row in $expected) {
        $s = ConvertTo-ClaudeProjectionSyncSchedule -Interval $row[0]
        Assert "$($row[0]) runs as '$($row[1])'" ($s.Interval -ceq $row[0] -and $s.Cron -ceq $row[1]) "got '$($s.Interval)' '$($s.Cron)'"
        Assert "$($row[0]) is $($row[2]) minutes and its no-success range is $($row[3]) minutes" ($s.Minutes -eq $row[2] -and $s.NoSuccessMinutes -eq $row[3]) "got $($s.Minutes) / $($s.NoSuccessMinutes)"
        Assert "$($row[0]) runs $($row[4]) times in a 730-hour month" ($s.RunsPerMonth -eq $row[4]) "got $($s.RunsPerMonth)"
        Assert "$($row[0]) reads back from its cron expression" ((ConvertFrom-ClaudeProjectionSyncCron -Cron $row[1]) -ceq $row[0])
    }
    $manual = ConvertTo-ClaudeProjectionSyncSchedule -Interval 'manual'
    Assert 'manual has no cron expression, no no-success range and no scheduled runs' (
        $manual.Interval -ceq 'manual' -and $manual.Cron -ceq '' -and $manual.Minutes -eq 0 -and $manual.NoSuccessMinutes -eq 0 -and $manual.RunsPerMonth -eq 0)
    Assert 'an empty cron expression reads back as manual' ((ConvertFrom-ClaudeProjectionSyncCron -Cron '') -ceq 'manual')
    Assert 'a cron expression outside the list reads back as nothing' ($null -eq (ConvertFrom-ClaudeProjectionSyncCron -Cron '*/15 * * * *'))
    Assert 'an upper-case interval is accepted and written in lower case' ((ConvertTo-ClaudeProjectionSyncSchedule -Interval '2H').Interval -ceq '2h')
    Assert 'the default interval is 2h' ((Get-ClaudeProjectionSyncDefaultInterval) -ceq '2h')
    Assert 'the accepted values are the eight intervals and manual, in order' (
        ((Get-ClaudeProjectionSyncIntervals) -join ',') -ceq '30m,1h,2h,3h,4h,6h,8h,12h,manual')

    foreach ($bad in @('15m', '0m', '24h', '2 h', 'abc', '', ' 2h', '2h;', '90m')) {
        $message = Get-Refusal { ConvertTo-ClaudeProjectionSyncSchedule -Interval $bad }
        Assert "'$bad' is refused with the accepted values" (
            $message -match [regex]::Escape("'$bad'") -and $message -match '30m, 1h, 2h, 3h, 4h, 6h, 8h, 12h, manual' -and $message -match '30 minutes') $message
    }

    # The words an operator reads in the deploy output, the installer review and the schedule script.
    $hasWords = [bool](Get-Command Format-ClaudeProjectionSyncInterval -ErrorAction SilentlyContinue)
    Assert 'it defines Format-ClaudeProjectionSyncInterval' $hasWords
    if ($hasWords) {
        $wordCases = @(
            @{ Interval = '30m'; Words = 'every 30 minutes' }, @{ Interval = '1h'; Words = 'every hour' }, @{ Interval = '2h'; Words = 'every 2 hours' }
            @{ Interval = '3h'; Words = 'every 3 hours' }, @{ Interval = '4h'; Words = 'every 4 hours' }, @{ Interval = '6h'; Words = 'every 6 hours' }
            @{ Interval = '8h'; Words = 'every 8 hours' }, @{ Interval = '12h'; Words = 'every 12 hours' }, @{ Interval = 'manual'; Words = 'only when started' }
            @{ Interval = '2H'; Words = 'every 2 hours' }
        )
        Assert 'the word cases are ten interval and wording pairs' ($wordCases.Count -eq 10 -and @($wordCases | Where-Object { $_ -isnot [hashtable] }).Count -eq 0)
        foreach ($case in $wordCases) {
            $words = Format-ClaudeProjectionSyncInterval -Interval $case.Interval
            Assert "$($case.Interval) reads '$($case.Words)'" ($words -ceq $case.Words) "got '$words'"
        }
        $message = Get-Refusal { Format-ClaudeProjectionSyncInterval -Interval '15m' }
        Assert 'an interval that is not listed has no words' ($message -match "'15m'" -and $message -match '30 minutes') $message
    }
}

# The deployed job, found by its claude-projection-prefix tag with core az resource commands (the installer
# keeps its interval on a re-run; Set-ClaudeProjectionSyncSchedule.ps1 changes it).
$lookupModule = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\ClaudeProjectionSyncJob.ps1'
Assert 'the job lookup module exists' (Test-Path -LiteralPath $lookupModule) $lookupModule
if (Test-Path -LiteralPath $lookupModule) { . $lookupModule }
$hasLookup = [bool](Get-Command Get-ClaudeProjectionSyncJob -ErrorAction SilentlyContinue)
Assert 'it defines Get-ClaudeProjectionSyncJob' $hasLookup
if ($hasLookup) {
    $rgId = '/subscriptions/00000000-0000-4000-8000-000000000104/resourceGroups/rg-p104'
    $global:P104Jobs = @{ Case = ''; Calls = $null }
    function global:az {
        $line = @($args | ForEach-Object { [string]$_ }) -join ' '
        $state = $global:P104Jobs
        $state.Calls.Add($line)
        $global:LASTEXITCODE = 0
        if ($line -ceq 'resource list -g rg-p104 --resource-type Microsoft.App/jobs -o json') {
            if ($state.Case -eq 'list-fails') { $global:LASTEXITCODE = 1; return 'ERROR: (AuthorizationFailed) no read' }
            # az can write a warning to stderr and still exit 0; the lookup parses stdout only.
            if ($state.Case -eq 'warns') { Write-Error 'WARNING: This command is in preview and under development.' }
            $jobs = @(
                @{ id = "$rgId/providers/Microsoft.App/jobs/caj-renew-a"; name = 'caj-renew-a'; tags = @{ 'claude-projection-prefix' = 'p104fixture' } }
                @{ id = "$rgId/providers/Microsoft.App/jobs/caj-renew-b"; name = 'caj-renew-b'; tags = @{ 'claude-projection-prefix' = 'otherfixture' } }
                @{ id = "$rgId/providers/Microsoft.App/jobs/job-reports"; name = 'job-reports'; tags = $null }
            )
            if ($state.Case -eq 'two-jobs') { $jobs += @{ id = "$rgId/providers/Microsoft.App/jobs/caj-renew-c"; name = 'caj-renew-c'; tags = @{ 'claude-projection-prefix' = 'p104fixture' } } }
            if ($state.Case -eq 'no-job') { $jobs = @($jobs[1], $jobs[2]) }
            return (ConvertTo-Json -Depth 5 @($jobs))
        }
        if ($line -ceq "resource show --ids $rgId/providers/Microsoft.App/jobs/caj-renew-a --api-version 2024-03-01 -o json") {
            $trigger = if ($state.Case -eq 'manual') { 'Manual' } else { 'Schedule' }
            $cron = if ($state.Case -eq 'odd-cron') { '15 */2 * * *' } else { '0 */2 * * *' }
            $image = if ($state.Case -eq 'tag-image') { 'acrp104.azurecr.io/claude-projection-sync:latest' } else { 'acrp104.azurecr.io/claude-projection-sync@sha256:' + ('e' * 64) }
            return (@{ id = "$rgId/providers/Microsoft.App/jobs/caj-renew-a"; name = 'caj-renew-a'; properties = @{
                        configuration = @{ triggerType = $trigger; scheduleTriggerConfig = $(if ($trigger -eq 'Schedule') { @{ cronExpression = $cron } } else { $null }) }
                        template = @{ containers = @(@{ name = 'projection-renewal'; image = $image; env = @(
                                        @{ name = 'PROJECTION_STANDARD_GROUP_ID'; value = '10000000-0000-4000-8000-000000000001' }
                                        @{ name = 'PROJECTION_PREMIUM_GROUP_ID'; value = 'none' }) }) } } } | ConvertTo-Json -Depth 8)
        }
        # The settings a redeployment keeps: the renewal deployment's parameters and job, the registry, the alert addresses.
        if ($line -ceq 'deployment group show -g rg-p104 -n projection-renewal-p104fixture -o json') {
            $renewalState = if ($state.Case -eq 'renewal-failed') { 'Failed' } else { 'Succeeded' }
            $renewalOutputs = if ($state.Case -eq 'renewal-failed') { $null } else { @{ jobResourceId = @{ value = "$rgId/providers/Microsoft.App/jobs/caj-renew-a" } } }
            $renewalParameters = @{ logAnalyticsWorkspaceId = @{ value = "$rgId/providers/Microsoft.OperationalInsights/workspaces/law-custom" }
                containerAppsSubnetId = @{ value = "$rgId/providers/Microsoft.Network/virtualNetworks/vnet-p104/subnets/renewal" }
                actionGroupEmailReceivers = @{ value = @('deployed@example.invalid') }
                standardGroupId = @{ value = '10000000-0000-4000-8000-000000000001' }; premiumGroupId = @{ value = 'none' }
                cronExpression = @{ value = '0 */2 * * *' }; noSuccessMinutes = @{ value = 255 } }
            # infra/projection-renewal.bicep requires acrName, so a renewal deployment records the registry it pulls from.
            if ($state.Case -ne 'no-registry-name') { $renewalParameters.acrName = @{ value = 'acrp104' } }
            return (@{ properties = @{ provisioningState = $renewalState; parameters = $renewalParameters; outputs = $renewalOutputs } } | ConvertTo-Json -Depth 8)
        }
        if ($line -ceq 'deployment group show -g rg-p104 -n projection-registry-p104fixture -o json') {
            if ($state.Case -in 'registry-failed', 'no-registry-name') {
                return (@{ properties = @{ provisioningState = 'Failed'; parameters = @{ acrSku = @{ value = 'Premium' } }; outputs = $null } } | ConvertTo-Json -Depth 8)
            }
            return (@{ properties = @{ provisioningState = 'Succeeded'; parameters = @{ acrSku = @{ value = 'Basic' } }; outputs = @{ acrName = @{ value = 'acrp104' }; acrSkuChosen = @{ value = 'Basic' } } } } | ConvertTo-Json -Depth 8)
        }
        if ($line -ceq 'acr show -g rg-p104 -n acrp104 -o json') {
            $access = if ($state.Case -in 'private-acr', 'registry-failed') { 'Disabled' } else { 'Enabled' }
            return (@{ name = 'acrp104'; sku = @{ name = $(if ($state.Case -eq 'standard-acr') { 'Standard' } else { 'Premium' }) }; publicNetworkAccess = $access } | ConvertTo-Json -Depth 4)
        }
        if ($line -ceq 'monitor action-group show -g rg-p104 -n ag-projection-renewal-p104fixture -o json') {
            return (@{ name = 'ag-projection-renewal-p104fixture'; emailReceivers = @(@{ emailAddress = 'ops@example.invalid' }, @{ emailAddress = ' oncall@example.invalid ' }, @{ emailAddress = 'ops@example.invalid' }) } | ConvertTo-Json -Depth 6)
        }
        $global:LASTEXITCODE = 9
        return "stub az has no answer for: $line"
    }
    function Find-Job([string]$Case, [string]$Group = 'rg-p104', [string]$Prefix = 'p104fixture') {
        $global:P104Jobs.Case = $Case
        $global:P104Jobs.Calls = [Collections.Generic.List[string]]::new()
        $failure = $null; $job = $null
        try { $job = Get-ClaudeProjectionSyncJob -ResourceGroup $Group -NamePrefix $Prefix } catch { $failure = $_.Exception.Message }
        [pscustomobject]@{ Job = $job; Failure = $failure; Calls = @($global:P104Jobs.Calls) }
    }
    $found = Find-Job 'scheduled'
    Assert 'the job tagged with the prefix is found, with its interval, digest and groups' (-not $found.Failure -and $found.Job.Name -ceq 'caj-renew-a' -and
        $found.Job.Interval -ceq '2h' -and $found.Job.Cron -ceq '0 */2 * * *' -and $found.Job.TriggerType -ceq 'Schedule' -and $found.Job.ImageDigest -ceq ('sha256:' + ('e' * 64)) -and
        $found.Job.StandardGroupId -ceq '10000000-0000-4000-8000-000000000001' -and $found.Job.PremiumGroupId -ceq 'none') "$($found.Failure) | $($found.Job | ConvertTo-Json -Compress)"
    Assert 'the lookup uses core az resource commands, with no --query and no containerapp extension' ($found.Calls.Count -eq 2 -and
        @($found.Calls | Where-Object { $_ -match '--query|^containerapp' }).Count -eq 0) ($found.Calls -join ' | ')
    $manual = Find-Job 'manual'
    Assert 'a manual job reads as manual' ($manual.Job.Interval -ceq 'manual' -and $manual.Job.Cron -ceq '') "$($manual.Failure) | $($manual.Job | ConvertTo-Json -Compress)"
    $odd = Find-Job 'odd-cron'
    Assert 'a cron that is not one of the intervals reads as no interval, with the cron kept' ($null -eq $odd.Job.Interval -and $odd.Job.Cron -ceq '15 */2 * * *') "$($odd.Job | ConvertTo-Json -Compress)"
    $tagImage = Find-Job 'tag-image'
    Assert 'an image without a digest reads as no digest' ($tagImage.Job -and $tagImage.Job.ImageDigest -ceq '') "$($tagImage.Job | ConvertTo-Json -Compress)"
    $none = Find-Job 'no-job'
    Assert 'no job with the prefix returns nothing' (-not $none.Failure -and $null -eq $none.Job -and $none.Calls.Count -eq 1) "$($none.Failure)"
    $two = Find-Job 'two-jobs'
    Assert 'two jobs with the prefix are refused, naming both' ($two.Failure -match 'caj-renew-a' -and $two.Failure -match 'caj-renew-c') $two.Failure
    $listFails = Find-Job 'list-fails'
    Assert 'a failed list stops with the az error' ($listFails.Failure -match 'AuthorizationFailed') $listFails.Failure
    $badGroup = Find-Job 'scheduled' -Group 'rg&calc'
    Assert 'a resource group with cmd metacharacters is refused before any az call' ($badGroup.Failure -match 'rg&calc' -and $badGroup.Calls.Count -eq 0) $badGroup.Failure
    $badPrefix = Find-Job 'scheduled' -Prefix 'P104_Fixture'
    Assert 'a prefix the projection deployer refuses is refused before any az call' ($badPrefix.Failure -match 'P104_Fixture' -and $badPrefix.Calls.Count -eq 0) $badPrefix.Failure
    $warned = Find-Job 'warns'
    Assert 'a warning az writes to stderr with exit code 0 does not break the lookup' (-not $warned.Failure -and $warned.Job.Name -ceq 'caj-renew-a') "$($warned.Failure)"

    # P104 council round 1 (Coder): a redeployment keeps the alert addresses, the registry SKU, the workspace and the
    # subnet; the renewal deployment's job id binds a tagged job to the deployment.
    $hasSettings = [bool](Get-Command Get-ClaudeProjectionSyncJobSettings -ErrorAction SilentlyContinue)
    Assert 'it defines Get-ClaudeProjectionSyncJobSettings' $hasSettings
    if ($hasSettings) {
        function Read-Settings([string]$Case) {
            $global:P104Jobs.Case = $Case
            $global:P104Jobs.Calls = [Collections.Generic.List[string]]::new()
            $failure = $null; $settings = $null
            try { $settings = Get-ClaudeProjectionSyncJobSettings -ResourceGroup 'rg-p104' -NamePrefix 'p104fixture' } catch { $failure = $_.Exception.Message }
            [pscustomobject]@{ Settings = $settings; Failure = $failure; Calls = @($global:P104Jobs.Calls) }
        }
        $read = Read-Settings 'scheduled'
        Assert 'the settings hold the job id, the live alert addresses, the live registry SKU and access, the workspace, the subnet and the recorded groups and schedule' (-not $read.Failure -and
            $read.Settings.RenewalDeploymentState -ceq 'Succeeded' -and $read.Settings.JobResourceId -ceq "$rgId/providers/Microsoft.App/jobs/caj-renew-a" -and
            ((@($read.Settings.AlertEmails) | Sort-Object) -join ',') -ceq 'oncall@example.invalid,ops@example.invalid' -and $read.Settings.AcrSku -ceq 'Premium' -and
            $read.Settings.RegistryPublicNetworkAccess -ceq 'Enabled' -and
            $read.Settings.WorkspaceResourceId -ceq "$rgId/providers/Microsoft.OperationalInsights/workspaces/law-custom" -and
            $read.Settings.RenewalSubnetId -ceq "$rgId/providers/Microsoft.Network/virtualNetworks/vnet-p104/subnets/renewal" -and
            $read.Settings.StandardGroupId -ceq '10000000-0000-4000-8000-000000000001' -and $read.Settings.PremiumGroupId -ceq 'none' -and
            $read.Settings.RecordedCron -ceq '0 */2 * * *' -and $read.Settings.RecordedNoSuccessMinutes -eq 255) "$($read.Failure) | $($read.Settings | ConvertTo-Json -Compress)"
        Assert 'the settings are read with no --query' ($read.Calls.Count -eq 4 -and @($read.Calls | Where-Object { $_ -match '--query' }).Count -eq 0) ($read.Calls -join ' | ')
        $standardAcr = Read-Settings 'standard-acr'
        Assert 'the live registry SKU is returned as read; the installer decides what it can keep' (-not $standardAcr.Failure -and $standardAcr.Settings.AcrSku -ceq 'Standard') "$($standardAcr.Failure)"
        $failedRenewal = Read-Settings 'renewal-failed'
        Assert 'a failed renewal deployment is reported as failed with no job id, not as another job' (-not $failedRenewal.Failure -and $failedRenewal.Settings.RenewalDeploymentState -ceq 'Failed' -and
            -not $failedRenewal.Settings.JobResourceId -and $failedRenewal.Settings.StandardGroupId -ceq '10000000-0000-4000-8000-000000000001') "$($failedRenewal.Failure) | $($failedRenewal.Settings | ConvertTo-Json -Compress)"
        # P104 council round 3 (Coder): a failed registry deployment records no outputs; the renewal deployment's
        # acrName names the registry, so its live SKU and network access are read rather than guessed.
        $failedRegistry = Read-Settings 'registry-failed'
        Assert 'a failed registry deployment reads the live registry that the renewal deployment recorded, with its network access' (-not $failedRegistry.Failure -and
            $failedRegistry.Settings.AcrSku -ceq 'Premium' -and $failedRegistry.Settings.RegistryPublicNetworkAccess -ceq 'Disabled' -and
            @($failedRegistry.Calls | Where-Object { $_ -ceq 'acr show -g rg-p104 -n acrp104 -o json' }).Count -eq 1) "$($failedRegistry.Failure) | $($failedRegistry.Settings | ConvertTo-Json -Compress) | $($failedRegistry.Calls -join ' | ')"
        $noName = Read-Settings 'no-registry-name'
        Assert 'no registry name in either deployment stops the read before the alert group is read' ($noName.Failure -match 'registry name' -and
            $noName.Failure -match 'projection-registry-p104fixture' -and $noName.Failure -match 'projection-renewal-p104fixture' -and $noName.Failure -match 'Nothing was changed' -and
            @($noName.Calls | Where-Object { $_ -match '^(acr|monitor) ' }).Count -eq 0) "$($noName.Failure) | $($noName.Calls -join ' | ')"
    }
    Remove-Item Function:\az -ErrorAction SilentlyContinue
}

if ($fail) { Write-Host "$fail sync schedule assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "$count sync schedule assertion(s) passed: intervals map to one cron, range and run count." -ForegroundColor Green
