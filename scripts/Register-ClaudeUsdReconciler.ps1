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
    [switch]$RunNow
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

function Get-ClaudeUsdReconcilerLeftoverCommands {
    param($Job, [string[]]$UsedEnvironmentNames = @(), [string[]]$UsedEnvironmentIds = @())
    $name = [string]$Job.name
    $suffix = if ($name -match '^job-usd-reconcile-(.+)$') { $Matches[1] } else { '' }
    $envId = [string]$Job.properties.environmentId
    $envName = if ($envId) { ($envId -split '/')[-1] } elseif ($suffix) { "cae-usd-reconcile-$suffix" } else { '' }
    $identityName = if ($suffix) { "id-usd-reconcile-$suffix" } else { '' }
    $commands = @()
    if ($identityName) { $commands += "az identity delete -g <resource-group> -n $identityName" }
    $environmentStillUsed = ($envName -and $envName -in @($UsedEnvironmentNames)) -or ($envId -and $envId -in @($UsedEnvironmentIds))
    if ($envName -and -not $environmentStillUsed) { $commands += "az containerapp env delete -g <resource-group> -n $envName" }
    return @($commands)
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
$oldJobs = @($existingJobs | Where-Object { [string]$_.name -ne [string]$outputs.jobName.value })
foreach ($job in $oldJobs) {
    $jobName = [string]$job.name
    $jobId = [string]$job.id
    Assert-ClaudeUsdReconcilerRegisterValue JobName $jobName '^[-A-Za-z0-9]{1,63}$'
    Assert-ClaudeUsdReconcilerRegisterValue JobId $jobId '^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[-A-Za-z0-9._()]+/providers/Microsoft\.App/jobs/[-A-Za-z0-9]+$'
    az resource delete --ids $jobId | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Deleting old USD reconciler job '$jobName' failed." }
    Write-Host "Deleted old USD reconciler job $jobName." -ForegroundColor Yellow
    foreach ($command in @(Get-ClaudeUsdReconcilerLeftoverCommands $job -UsedEnvironmentNames $usedEnvironmentNames -UsedEnvironmentIds $usedEnvironmentIds)) {
        Write-Host "Leftover resource may be removable if unused: $command" -ForegroundColor DarkGray
    }
}

$run = $null
if ($RunNow) {
    Start-Sleep -Seconds 90
    $execution = az containerapp job start -g $ResourceGroup -n $outputs.jobName.value --query name -o tsv
    $deadline = [DateTime]::UtcNow.AddMinutes(30)
    do {
        Start-Sleep -Seconds 15
        $status = az containerapp job execution show -g $ResourceGroup -n $outputs.jobName.value --job-execution-name $execution --query properties.status -o tsv 2>$null
    } while ($status -in @('Running', 'Processing', '') -and [DateTime]::UtcNow -lt $deadline)
    $run = [pscustomobject]@{ Execution = $execution; Status = $status }
}

[pscustomobject][ordered]@{
    Job = $outputs.jobName.value
    Environment = $outputs.environmentName.value
    PrincipalId = $outputs.principalId.value
    Cron = $outputs.cronExpression.value
    Commit = $RepositoryRef
    Image = $Image
    Run = $run
}
