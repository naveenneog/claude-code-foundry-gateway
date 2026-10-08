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
    Copy-Item -LiteralPath (Join-Path $root 'scripts\ClaudeProjectionSyncJob.ps1') -Destination (Join-Path $scripts 'ClaudeProjectionSyncJob.ps1')
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
    [switch]$KeepRegistry,
    [string]$WorkspaceResourceId,
    [string]$RenewalSubnetId,
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
    KeepRegistry = [bool]$KeepRegistry
    WorkspaceResourceId = $WorkspaceResourceId
    RenewalSubnetId = $RenewalSubnetId
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
    $rgId = '/subscriptions/00000000-0000-4000-8000-000000000104/resourceGroups/rg-p104'
    $global:ProjectionScheduleAzCalls = [Collections.Generic.List[string]]::new()
    $global:ProjectionScheduleScenario = @{}
    function New-Job([string]$Prefix = 'p104fixture', [string]$Cron = '0 */2 * * *', [string]$Image = $digest, [string]$StandardGroup = $standard, [string]$PremiumGroup = $premium) {
        $trigger = if ($Cron) { 'Schedule' } else { 'Manual' }
        $configuration = if ($Cron) {
            @{ triggerType = $trigger; scheduleTriggerConfig = @{ cronExpression = $Cron } }
        }
        else {
            @{ triggerType = $trigger; manualTriggerConfig = @{ parallelism = 1; replicaCompletionCount = 1 } }
        }
        [pscustomobject]@{
            id = "$rgId/providers/Microsoft.App/jobs/caj-renew-$Prefix"
            name = "caj-renew-$Prefix"
            tags = @{ 'claude-projection-prefix' = $Prefix }
            properties = @{
                configuration = $configuration
                template = @{
                    containers = @(
                        @{
                            image = "acrp104.azurecr.io/claude-projection-sync@$Image"
                            env = @(
                                @{ name = 'PROJECTION_STANDARD_GROUP_ID'; value = $StandardGroup }
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
        $line = @($args | ForEach-Object { [string]$_ }) -join ' '
        $global:ProjectionScheduleAzCalls.Add($line)
        $global:LASTEXITCODE = 0
        if ($line -ceq 'resource list -g rg-p104 --resource-type Microsoft.App/jobs -o json') {
            if (-not @($global:ProjectionScheduleScenario.Jobs).Count) { return '[]' }
            return (@($global:ProjectionScheduleScenario.Jobs | ForEach-Object { @{ id = $_.id; name = $_.name; tags = $_.tags } }) | ConvertTo-Json -Depth 6)
        }
        if ($line -match '^resource show --ids .*/providers/Microsoft\.App/jobs/[^ ]+ --api-version 2024-03-01 -o json$') {
            $id = [regex]::Match($line, '^resource show --ids (.+) --api-version 2024-03-01 -o json$').Groups[1].Value
            $job = @($global:ProjectionScheduleScenario.Jobs | Where-Object { $_.id -eq $id }) | Select-Object -First 1
            if (-not $job) { $global:LASTEXITCODE = 9; return "stub az has no job for: $id" }
            return ($job | ConvertTo-Json -Depth 20)
        }
        if ($line -match '^monitor action-group show ') {
            return ([pscustomobject]@{ emailReceivers = @($global:ProjectionScheduleScenario.Emails | ForEach-Object { @{ emailAddress = $_ } }) } | ConvertTo-Json -Depth 6)
        }
        if ($line -ceq 'deployment group show -g rg-p104 -n projection-renewal-p104fixture -o json') {
            $deployedJob = if ($global:ProjectionScheduleScenario.ContainsKey('DeployedJobId')) { $global:ProjectionScheduleScenario.DeployedJobId } else { "$rgId/providers/Microsoft.App/jobs/caj-renew-p104fixture" }
            return (@{ properties = @{
                        parameters = @{ logAnalyticsWorkspaceId = @{ value = "$rgId/providers/Microsoft.OperationalInsights/workspaces/law-custom" }
                            containerAppsSubnetId = @{ value = "$rgId/providers/Microsoft.Network/virtualNetworks/vnet-p104/subnets/renewal" } }
                        outputs = @{ jobResourceId = @{ type = 'String'; value = $deployedJob } } } } | ConvertTo-Json -Depth 6)
        }
        if ($line -ceq 'deployment group show -g rg-p104 -n projection-registry-p104fixture -o json') {
            return (@{ properties = @{ outputs = @{ acrName = @{ value = 'acrp104' } } } } | ConvertTo-Json -Depth 6)
        }
        if ($line -ceq 'acr show -g rg-p104 -n acrp104 -o json') { return (@{ name = 'acrp104'; sku = @{ name = 'Premium' } } | ConvertTo-Json -Depth 4) }
        if ($line -ceq 'resource list -g rg-p104 --resource-type Microsoft.Insights/scheduledQueryRules -o json') {
            $rules = if ($global:ProjectionScheduleScenario.ContainsKey('Rules')) { @($global:ProjectionScheduleScenario.Rules) } else { @('sqr-projection-p104fixture-no-success', 'sqr-projection-p104fixture-renewal-failed') }
            if (-not $rules.Count) { return '[]' }
            return (ConvertTo-Json -Depth 4 @($rules | ForEach-Object { @{ name = $_; type = 'Microsoft.Insights/scheduledQueryRules' } }))
        }
        if ($line -match '^apim nv show ') {
            if ($global:ProjectionScheduleScenario.NamedValue -eq $null) {
                $global:LASTEXITCODE = 3
                Write-Error '(ResourceNotFound) NamedValue not found'
                return
            }
            $global:LASTEXITCODE = 0
            return $global:ProjectionScheduleScenario.NamedValue
        }
        throw "Unexpected az call: $line"
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
        Assert 'the schedule change keeps the registry: no registry or image deployment' ($deploy -and $deploy.KeepRegistry -eq $true) ($deploy | ConvertTo-Json -Compress)
        Assert 'the schedule change keeps the workspace and the subnet of the renewal deployment' ($deploy -and
            $deploy.WorkspaceResourceId -ceq "$rgId/providers/Microsoft.OperationalInsights/workspaces/law-custom" -and
            $deploy.RenewalSubnetId -ceq "$rgId/providers/Microsoft.Network/virtualNetworks/vnet-p104/subnets/renewal") ($deploy | ConvertTo-Json -Compress)
        # P104 council round 1 (Security): only the job the projection-renewal deployment created is redeployed with
        # its own settings; another job that carries the prefix tag is refused.
        $impostor = Invoke-ScheduleScenario -Scenario @{ DeployedJobId = "$rgId/providers/Microsoft.App/jobs/caj-renew-other" } -Overrides @{}
        Assert 'a tagged job that the renewal deployment did not create is refused before any deployment' ($impostor.Failure -match 'projection-renewal-p104fixture' -and
            $impostor.Failure -match 'caj-renew-p104fixture' -and $impostor.Failure -match 'Nothing was changed' -and $impostor.Deploy.Count -eq 0) "$($impostor.Failure) | deploy calls $($impostor.Deploy.Count)"
        $noRecord = Invoke-ScheduleScenario -Scenario @{ DeployedJobId = '' } -Overrides @{}
        Assert 'a renewal deployment that records no job is refused before any deployment' ($noRecord.Failure -match 'projection-renewal-p104fixture' -and $noRecord.Deploy.Count -eq 0) "$($noRecord.Failure) | deploy calls $($noRecord.Deploy.Count)"
        Assert 'the job lookup uses core az resource commands, with no query or containerapp extension' (($change.Calls -join ' | ') -match '^resource list -g rg-p104 --resource-type Microsoft.App/jobs -o json' -and ($change.Calls -join ' | ') -match 'resource show --ids .*/providers/Microsoft\.App/jobs/' -and ($change.Calls -join ' | ') -notmatch '--query|^containerapp') ($change.Calls -join ' | ')

        $same = Invoke-ScheduleScenario -Scenario @{} -Overrides @{ Interval = '2h' }
        Assert 'the same interval with the alert rules in place exits without redeploying' (-not $same.Failure -and $same.Deploy.Count -eq 0 -and $same.Output -match 'already runs every 2 hours') "$($same.Failure) | $($same.Output)"
        # P104 council round 1 (Coder): the same interval repairs alert rules that differ from the template.
        $p97Rule = Invoke-ScheduleScenario -Scenario @{ Rules = @('sqr-projection-p104fixture-no-success-45m') } -Overrides @{ Interval = '2h' }
        Assert 'the same interval with the retired 45-minute rule redeploys to repair the rules' (-not $p97Rule.Failure -and $p97Rule.Deploy.Count -eq 1 -and $p97Rule.Output -match 'alert rules') "$($p97Rule.Failure) | $($p97Rule.Output)"
        $noRule = Invoke-ScheduleScenario -Scenario @{ Rules = @() } -Overrides @{ Interval = '2h' }
        Assert 'the same scheduled interval without the no-success rule redeploys' (-not $noRule.Failure -and $noRule.Deploy.Count -eq 1) "$($noRule.Failure) | $($noRule.Output)"
        $manualWithRule = Invoke-ScheduleScenario -Scenario @{ Jobs = @(New-Job -Cron '') } -Overrides @{ Interval = 'manual' }
        Assert 'a manual job that still has a no-success rule redeploys to remove it' (-not $manualWithRule.Failure -and $manualWithRule.Deploy.Count -eq 1) "$($manualWithRule.Failure) | $($manualWithRule.Output)"
        $manualClean = Invoke-ScheduleScenario -Scenario @{ Jobs = @(New-Job -Cron ''); Rules = @('sqr-projection-p104fixture-renewal-failed') } -Overrides @{ Interval = 'manual' }
        Assert 'a manual job without a no-success rule is already in place' (-not $manualClean.Failure -and $manualClean.Deploy.Count -eq 0 -and $manualClean.Output -match 'already runs only when started') "$($manualClean.Failure) | $($manualClean.Output)"

        foreach ($bad in @('15m', '24h', '2h;')) {
            $refused = Invoke-ScheduleScenario -Scenario @{} -Overrides @{ Interval = $bad }
            Assert "$bad is refused before any az call" ($refused.Failure -match 'refused before any Azure call' -and $refused.Calls.Count -eq 0 -and $refused.Deploy.Count -eq 0) "$($refused.Failure) | calls $($refused.Calls.Count)"
        }

        $manualTo2h = Invoke-ScheduleScenario -Scenario @{ Jobs = @(New-Job -Cron '') } -Overrides @{ Interval = '2h' }
        Assert 'manual to 2h redeploys to 2h' (-not $manualTo2h.Failure -and $manualTo2h.Deploy.Count -eq 1 -and $manualTo2h.Deploy[0].SyncInterval -eq '2h' -and $manualTo2h.Output -match 'only when started' -and $manualTo2h.Output -match 'every 2 hours') "$($manualTo2h.Failure) | $($manualTo2h.Output)"

        $noDigest = Invoke-ScheduleScenario -Scenario @{ Jobs = @(New-Job -Image 'latest') } -Overrides @{}
        Assert 'a job image without a digest is refused before deploy' ($noDigest.Failure -match 'image digest' -and $noDigest.Deploy.Count -eq 0) "$($noDigest.Failure) | deploys $($noDigest.Deploy.Count)"

        $missingStandard = Invoke-ScheduleScenario -Scenario @{ Jobs = @(New-Job -StandardGroup '') } -Overrides @{}
        Assert 'a job without the standard group id is refused before deploy' ($missingStandard.Failure -match 'PROJECTION_STANDARD_GROUP_ID' -and $missingStandard.Deploy.Count -eq 0) "$($missingStandard.Failure) | deploys $($missingStandard.Deploy.Count)"
        $missingPremium = Invoke-ScheduleScenario -Scenario @{ Jobs = @(New-Job -PremiumGroup '') } -Overrides @{}
        Assert 'a job without the premium group id is refused before deploy' ($missingPremium.Failure -match 'PROJECTION_PREMIUM_GROUP_ID' -and $missingPremium.Deploy.Count -eq 0) "$($missingPremium.Failure) | deploys $($missingPremium.Deploy.Count)"

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
