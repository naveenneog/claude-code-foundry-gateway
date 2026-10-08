<#
.SYNOPSIS
    Deploys the scheduled USD budget reconciler for gateways without the AUM service.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ResourceGroup = $(& (Join-Path $PSScriptRoot 'Get-ClaudeGatewayTarget.ps1') ResourceGroup),
    [string]$ApimName,
    [string]$WorkspaceResourceId,
    [string]$WorkspaceCustomerId,
    [string]$RepositoryUrl,
    [string]$RepositoryRef,
    [string]$Cron = '*/5 * * * *',
    [string]$Image = 'python:3.12.11-slim-bookworm',
    [string]$ExistingEnvironmentId,
    [string]$Location,
    [switch]$RunNow,
    [Parameter(DontShow)][scriptblock]$Clock = { [DateTime]::UtcNow },
    [Parameter(DontShow)][scriptblock]$Sleep = { param([int]$Seconds) Start-Sleep -Seconds $Seconds }
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ClaudeChoice.ps1')
. (Join-Path $PSScriptRoot 'ClaudeUsdReconcilerSchedule.ps1')

function Assert-ClaudeUsdReconcilerRegisterValue {
    param([string]$Name, [AllowNull()][string]$Value, [string]$Pattern)
    if (-not $Value -or $Value -notmatch $Pattern) {
        throw "$Name contains characters that are refused before an az call."
    }
}

function Invoke-ClaudeUsdReconcilerAzJson {
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
    return ($text | ConvertFrom-Json)
}

function Invoke-ClaudeUsdReconcilerAzRestJson {
    param([Parameter(Mandatory = $true)][string[]]$Arguments, [Parameter(Mandatory = $true)][string]$What)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $global:LASTEXITCODE = 0
        $output = @(az rest @Arguments 2>&1)
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previous }
    if ($code -ne 0) { throw "Calling $What failed (az exit $code): $((($output | Out-String).Trim()))" }
    $text = (@($output | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] }) | Out-String).Trim()
    if (-not $text -or $text[0] -notin @('{', '[')) { return $null }
    return ($text | ConvertFrom-Json)
}

function Get-ClaudeUsdReconcilerJobGatewayId {
    param($Job)
    $container = @($Job.properties.template.containers)[0]
    foreach ($setting in @($container.env)) {
        if ([string]::Equals([string]$setting.name, 'GATEWAY_ID', [StringComparison]::Ordinal)) {
            return [string]$setting.value
        }
    }
    return ''
}

function Get-ClaudeUsdReconcilerJobsForGateway {
    param([Parameter(Mandatory = $true)][string]$ResourceGroup, [Parameter(Mandatory = $true)][string]$GatewayResourceId)
    Assert-ClaudeUsdReconcilerRegisterValue ResourceGroup $ResourceGroup '^[A-Za-z0-9._()-]{1,90}$'
    $listed = @(Invoke-ClaudeUsdReconcilerAzJson -Arguments @('resource', 'list', '-g', $ResourceGroup, '--resource-type', 'Microsoft.App/jobs', '-o', 'json') -What "the Container Apps jobs in $ResourceGroup")
    $tagged = @($listed | Where-Object {
        $_.tags -and [string]::Equals([string]$_.tags.component, 'usd-reconciler', [StringComparison]::Ordinal)
    })
    $matches = @()
    foreach ($item in $tagged) {
        $id = [string]$item.id
        Assert-ClaudeUsdReconcilerRegisterValue JobId $id '^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[-A-Za-z0-9._()]+/providers/Microsoft\.App/jobs/[-A-Za-z0-9]+$'
        $job = Invoke-ClaudeUsdReconcilerAzJson -Arguments @('resource', 'show', '--ids', $id, '--api-version', '2024-03-01', '-o', 'json') -What "job $([string]$item.name)"
        if ([string]::Equals((Get-ClaudeUsdReconcilerJobGatewayId $job), $GatewayResourceId, [StringComparison]::OrdinalIgnoreCase)) {
            $matches += $job
        }
    }
    return @($matches)
}

function Get-ClaudeUsdReconcilerJobPrincipalId {
    param($Job)
    if (-not ($Job -and $Job.PSObject.Properties.Name -contains 'identity' -and $Job.identity)) { return '' }
    if (-not ($Job.identity.PSObject.Properties.Name -contains 'userAssignedIdentities' -and $Job.identity.userAssignedIdentities)) { return '' }
    foreach ($entry in @($Job.identity.userAssignedIdentities.PSObject.Properties)) {
        $candidate = ''
        if ($entry.Value -and $entry.Value.PSObject.Properties.Name -contains 'principalId') {
            $candidate = [string]$entry.Value.principalId
        }
        $parsed = [guid]::Empty
        if ($candidate -and [guid]::TryParse($candidate, [ref]$parsed)) { return $candidate }
    }
    return ''
}

function Test-ClaudeUsdReconcilerStringIn {
    param([AllowNull()][string]$Value, [string[]]$Candidates = @())
    foreach ($candidate in @($Candidates)) {
        if ([string]::Equals([string]$Value, [string]$candidate, [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Get-ClaudeUsdReconcilerLeftoverCommands {
    param($Job, [string]$WorkspaceResourceId, [string]$GatewayResourceId, [string[]]$UsedEnvironmentNames = @(), [string[]]$UsedEnvironmentIds = @())
    $name = [string]$Job.name
    $suffix = if ($name -match '^job-usd-reconcile-(.+)$') { $Matches[1] } else { '' }
    $envId = [string]$Job.properties.environmentId
    $envName = if ($envId) { ($envId -split '/')[-1] } elseif ($suffix) { "cae-usd-reconcile-$suffix" } else { '' }
    $identityName = if ($suffix) { "id-usd-reconcile-$suffix" } else { '' }
    $commands = @()
    $principalId = Get-ClaudeUsdReconcilerJobPrincipalId $Job
    if ($principalId) {
        $commands += "az role assignment delete --assignee $principalId --scope $WorkspaceResourceId"
        $commands += "az role assignment delete --assignee $principalId --scope $GatewayResourceId"
    }
    elseif ($identityName) {
        $commands += "old identity principalId is unavailable; role assignment delete commands cannot be printed"
    }
    if ($identityName) { $commands += "az identity delete -g <resource-group> -n $identityName" }
    $environmentStillUsed = ($envName -and (Test-ClaudeUsdReconcilerStringIn -Value $envName -Candidates $UsedEnvironmentNames)) -or
        ($envId -and (Test-ClaudeUsdReconcilerStringIn -Value $envId -Candidates $UsedEnvironmentIds))
    if ($envName -and -not $environmentStillUsed) { $commands += "az containerapp env delete -g <resource-group> -n $envName" }
    return @($commands)
}

function Start-ClaudeUsdReconcilerExecution {
    param([Parameter(Mandatory = $true)][string]$JobId)
    Assert-ClaudeUsdReconcilerRegisterValue JobId $JobId '^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[-A-Za-z0-9._()]+/providers/Microsoft\.App/jobs/[-A-Za-z0-9]+$'
    try {
        Invoke-ClaudeUsdReconcilerAzRestJson -Arguments @('--method', 'post', '--url', "https://management.azure.com$JobId/start?api-version=2024-03-01") -What 'the USD reconciler job start' | Out-Null
        return $true
    }
    catch {
        Write-Warning $_.Exception.Message
        return $false
    }
}

function Get-ClaudeUsdReconcilerExecutions {
    param([Parameter(Mandatory = $true)][string]$JobId)
    Assert-ClaudeUsdReconcilerRegisterValue JobId $JobId '^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[-A-Za-z0-9._()]+/providers/Microsoft\.App/jobs/[-A-Za-z0-9]+$'
    $result = Invoke-ClaudeUsdReconcilerAzRestJson -Arguments @('--method', 'get', '--url', "https://management.azure.com$JobId/executions?api-version=2024-03-01") -What 'the USD reconciler job executions'
    if ($null -eq $result) { return @() }
    if ($result.PSObject.Properties['value']) { return @($result.value) }
    return @($result)
}

function ConvertTo-ClaudeUsdReconcilerUtc {
    param([Parameter(Mandatory = $true)][object]$Value)
    if ($Value -is [DateTimeOffset]) { return $Value.UtcDateTime }
    if ($Value -is [datetime]) {
        if ($Value.Kind -eq [DateTimeKind]::Unspecified) {
            return [DateTime]::SpecifyKind($Value, [DateTimeKind]::Utc)
        }
        return $Value.ToUniversalTime()
    }
    return ([DateTimeOffset]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal)).UtcDateTime
}

function Wait-ClaudeUsdReconcilerFirstSuccess {
    param(
        [Parameter(Mandatory = $true)][string]$JobId,
        [Parameter(Mandatory = $true)][string]$JobName,
        [Parameter(Mandatory = $true)][datetime]$DeployStartedUtc,
        [Parameter(Mandatory = $true)][scriptblock]$Clock,
        [Parameter(Mandatory = $true)][scriptblock]$Sleep
    )
    $retryUntil = $DeployStartedUtc.AddMinutes(12)
    $hardStop = $DeployStartedUtc.AddMinutes(35)
    $attempted = $false
    $lastFailed = ''
    $handledFailures = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    while ((& $Clock).ToUniversalTime() -lt $hardStop) {
        $now = (& $Clock).ToUniversalTime()
        if (-not $attempted) {
            if (Start-ClaudeUsdReconcilerExecution -JobId $JobId) {
                $attempted = $true
            }
            else {
                if ($now -ge $retryUntil) { break }
                & $Sleep 60
                continue
            }
        }
        & $Sleep 15
        $executions = @(Get-ClaudeUsdReconcilerExecutions -JobId $JobId | Where-Object {
            try {
                $start = ConvertTo-ClaudeUsdReconcilerUtc $_.properties.startTime
                $start -ge $DeployStartedUtc
            }
            catch { $false }
        } | Sort-Object { ConvertTo-ClaudeUsdReconcilerUtc $_.properties.startTime })
        $success = @($executions | Where-Object { [string]$_.properties.status -eq 'Succeeded' } | Select-Object -Last 1)
        if ($success.Count) {
            $ended = try { ConvertTo-ClaudeUsdReconcilerUtc $success[0].properties.endTime } catch { (& $Clock).ToUniversalTime() }
            Write-Host ("Run {0} succeeded at {1:HH:mm} UTC." -f ([string]$success[0].name), $ended) -ForegroundColor Green
            return [pscustomobject]@{ Status = 'Succeeded'; Execution = [string]$success[0].name; OldJobsKept = @() }
        }
        $active = @($executions | Where-Object { [string]$_.properties.status -in @('Running', 'Processing', 'Pending') })
        if ($active.Count) { continue }
        $now = (& $Clock).ToUniversalTime()
        if ($now -ge $retryUntil) { break }
        $failed = @($executions | Where-Object { [string]$_.properties.status -eq 'Failed' } | Select-Object -Last 1)
        if ($failed.Count) {
            $lastFailed = [string]$failed[0].name
            if ($handledFailures.Add($lastFailed)) {
                $retryAt = $now.AddSeconds(60)
                Write-Host ("Run {0} failed. Role assignments for a new job identity can take up to 10 minutes to take effect; starting another run at {1:HH:mm} UTC." -f $lastFailed, $retryAt) -ForegroundColor Yellow
                & $Sleep 60
                if (-not (Start-ClaudeUsdReconcilerExecution -JobId $JobId)) {
                    $attempted = $false
                }
            }
        }
    }
    return [pscustomobject]@{ Status = 'Failed'; Execution = $lastFailed; OldJobsKept = @() }
}

function Format-ClaudeUsdReconcilerArgument {
    param([AllowNull()][string]$Value)
    return "'" + ([string]$Value).Replace("'", "''") + "'"
}

if (-not (az account show --query id -o tsv 2>$null)) { throw 'Not signed in. Run: az login.' }
if (-not $ResourceGroup) { $ResourceGroup = Select-ClaudeResourceGroup }
Assert-ClaudeUsdReconcilerRegisterValue ResourceGroup $ResourceGroup '^[A-Za-z0-9._()-]{1,90}$'
if (-not $ApimName) { $ApimName = Select-ClaudeGateway -ResourceGroup $ResourceGroup }
Assert-ClaudeUsdReconcilerRegisterValue ApimName $ApimName '^[A-Za-z0-9][A-Za-z0-9-]{0,48}[A-Za-z0-9]$'
if (-not $WorkspaceResourceId) {
    $workspace = Select-ClaudeWorkspace -ResourceGroup $ResourceGroup -ApimName $ApimName -ScriptRoot $PSScriptRoot
    $WorkspaceResourceId = $workspace
}
Assert-ClaudeUsdReconcilerRegisterValue WorkspaceResourceId $WorkspaceResourceId '^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[-A-Za-z0-9._()]+/providers/Microsoft\.OperationalInsights/workspaces/[-A-Za-z0-9]+$'
if (-not $WorkspaceCustomerId) {
    $WorkspaceCustomerId = az monitor log-analytics workspace show --ids $WorkspaceResourceId --query customerId -o tsv
    if ($LASTEXITCODE -ne 0 -or -not $WorkspaceCustomerId) { throw 'Cannot resolve workspace customer ID.' }
}
Assert-ClaudeUsdReconcilerRegisterValue WorkspaceCustomerId $WorkspaceCustomerId '^[0-9a-fA-F-]{36}$'
if (-not $RepositoryUrl) {
    $repo = Split-Path $PSScriptRoot -Parent
    $RepositoryUrl = ((git -C $repo remote get-url origin).Trim() -replace '^git@github\.com:', 'https://github.com/')
    if ($RepositoryUrl -notmatch '\.git$') { $RepositoryUrl += '.git' }
}
if (-not $RepositoryRef) {
    $repo = Split-Path $PSScriptRoot -Parent
    $RepositoryRef = (git -C $repo rev-parse HEAD).Trim()
    git -C $repo fetch -q origin 2>$null
    if (-not @(git -C $repo branch -r --contains $RepositoryRef 2>$null | Where-Object { $_.Trim() }).Count) {
        throw "HEAD ($($RepositoryRef.Substring(0, 12))) is not on the remote. Push it, or pass -RepositoryRef."
    }
}
Assert-ClaudeUsdReconcilerRegisterValue RepositoryUrl $RepositoryUrl '^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(\.git)?$'
Assert-ClaudeUsdReconcilerRegisterValue RepositoryRef $RepositoryRef '^[0-9a-f]{40}$'
if (-not $Location) { $Location = az apim show -g $ResourceGroup -n $ApimName --query location -o tsv }
Assert-ClaudeUsdReconcilerRegisterValue Location $Location '^[A-Za-z0-9 -]{1,64}$'
$gatewayId = az apim show -g $ResourceGroup -n $ApimName --query id -o tsv
if (-not $gatewayId) { throw 'Cannot resolve gateway resource ID.' }
Assert-ClaudeUsdReconcilerRegisterValue GatewayResourceId $gatewayId '^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[-A-Za-z0-9._()]+/providers/Microsoft\.ApiManagement/service/[-A-Za-z0-9]+$'
$tags = @{ component = 'usd-reconciler'; packet = 'P66'; purpose = 'flow-finops' }
$parameters = New-ClaudeUsdReconcilerParameters -GatewayResourceId $gatewayId -WorkspaceResourceId $WorkspaceResourceId `
    -WorkspaceCustomerId $WorkspaceCustomerId -RepositoryUrl $RepositoryUrl -RepositoryRef $RepositoryRef `
    -Cron $Cron -Image $Image -Location $Location -ExistingEnvironmentId $ExistingEnvironmentId -Tags $tags
$existingJobs = @(Get-ClaudeUsdReconcilerJobsForGateway -ResourceGroup $ResourceGroup -GatewayResourceId $gatewayId)

if (-not $PSCmdlet.ShouldProcess("$ResourceGroup/$ApimName", 'Deploy scheduled USD reconciler job')) { return }
$deployStartedUtc = (& $Clock).ToUniversalTime()
$file = Join-Path ([IO.Path]::GetTempPath()) ('usd-reconciler-' + [guid]::NewGuid().ToString('N') + '.json')
try {
    [IO.File]::WriteAllText($file, ($parameters | ConvertTo-Json -Depth 30), (New-Object Text.UTF8Encoding($false)))
    $root = Split-Path $PSScriptRoot -Parent
    $outputs = az deployment group create -g $ResourceGroup -n "usd-reconciler-$ApimName" `
        --template-file (Join-Path $root 'infra\usd-reconciler-job.bicep') --parameters "@$file" --query properties.outputs -o json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or -not $outputs) { throw 'USD reconciler deployment failed.' }
}
finally { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }

$usedEnvironmentNames = @([string]$outputs.environmentName.value | Where-Object { $_ })
$usedEnvironmentIds = @($ExistingEnvironmentId | Where-Object { $_ })
if ($ExistingEnvironmentId) { $usedEnvironmentNames += ($ExistingEnvironmentId -split '/')[-1] }
$oldJobs = @($existingJobs | Where-Object { -not [string]::Equals([string]$_.name, [string]$outputs.jobName.value, [StringComparison]::OrdinalIgnoreCase) })
$run = $null
$jobId = [string]$outputs.jobId.value
if (-not $jobId) {
    $jobId = "$gatewayId/providers/Microsoft.App/jobs/$([string]$outputs.jobName.value)"
    $jobId = $jobId -replace '/providers/Microsoft.ApiManagement/service/[^/]+/providers/', '/providers/'
}
Assert-ClaudeUsdReconcilerRegisterValue JobId $jobId '^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[-A-Za-z0-9._()]+/providers/Microsoft\.App/jobs/[-A-Za-z0-9]+$'
$needsSuccessfulRun = $RunNow -or $oldJobs.Count -gt 0
if ($needsSuccessfulRun) {
    $run = Wait-ClaudeUsdReconcilerFirstSuccess -JobId $jobId -JobName ([string]$outputs.jobName.value) -DeployStartedUtc $deployStartedUtc -Clock $Clock -Sleep $Sleep
}
if (-not $needsSuccessfulRun -or $run.Status -eq 'Succeeded') {
    foreach ($job in $oldJobs) {
        $jobName = [string]$job.name
        $oldJobId = [string]$job.id
        Assert-ClaudeUsdReconcilerRegisterValue JobName $jobName '^[-A-Za-z0-9]{1,63}$'
        Assert-ClaudeUsdReconcilerRegisterValue JobId $oldJobId '^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[-A-Za-z0-9._()]+/providers/Microsoft\.App/jobs/[-A-Za-z0-9]+$'
        az resource delete --ids $oldJobId | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Deleting old USD reconciler job '$jobName' failed." }
        Write-Host "Deleted old USD reconciler job $jobName." -ForegroundColor Yellow
        foreach ($command in @(Get-ClaudeUsdReconcilerLeftoverCommands $job -WorkspaceResourceId $WorkspaceResourceId -GatewayResourceId $gatewayId -UsedEnvironmentNames $usedEnvironmentNames -UsedEnvironmentIds $usedEnvironmentIds)) {
            Write-Host "Leftover resource may be removable if unused: $command" -ForegroundColor DarkGray
        }
    }
}
elseif ($oldJobs.Count) {
    $kept = @($oldJobs | ForEach-Object { [string]$_.name })
    $run.OldJobsKept = $kept
    $rerunParts = @(
        '.\scripts\Register-ClaudeUsdReconciler.ps1',
        '-ResourceGroup', (Format-ClaudeUsdReconcilerArgument $ResourceGroup),
        '-ApimName', (Format-ClaudeUsdReconcilerArgument $ApimName),
        '-WorkspaceResourceId', (Format-ClaudeUsdReconcilerArgument $WorkspaceResourceId),
        '-WorkspaceCustomerId', (Format-ClaudeUsdReconcilerArgument $WorkspaceCustomerId),
        '-RepositoryUrl', (Format-ClaudeUsdReconcilerArgument $RepositoryUrl),
        '-RepositoryRef', (Format-ClaudeUsdReconcilerArgument $RepositoryRef),
        '-Cron', (Format-ClaudeUsdReconcilerArgument $Cron),
        '-Image', (Format-ClaudeUsdReconcilerArgument $Image),
        '-Location', (Format-ClaudeUsdReconcilerArgument $Location)
    )
    if ($ExistingEnvironmentId) { $rerunParts += @('-ExistingEnvironmentId', (Format-ClaudeUsdReconcilerArgument $ExistingEnvironmentId)) }
    if ($RunNow) { $rerunParts += '-RunNow' }
    Write-Warning ("New USD reconciler job {0} has not succeeded; kept old job(s) {1} so the dollar-budget state stays fresh. Read logs in the gateway workspace with: ContainerAppConsoleLogs | where JobName == '{0}' | order by TimeGenerated desc | take 50 . Rerun: {2}" -f [string]$outputs.jobName.value, ($kept -join ', '), ($rerunParts -join ' '))
}

[pscustomobject][ordered]@{
    Job = $outputs.jobName.value
    Environment = $outputs.environmentName.value
    PrincipalId = $outputs.principalId.value
    Cron = $outputs.cronExpression.value
    Commit = $RepositoryRef
    Image = $Image
    Run = $run
    OldJobsKept = $(if ($run -and $run.OldJobsKept) { @($run.OldJobsKept) } else { @() })
}
