<#
.SYNOPSIS
    Puts the Turnstile export and sync on a schedule, as a managed identity with no secret.

.DESCRIPTION
    Deploys infra/turnstile-schedule.bicep into the gateway's resource group: a user-assigned
    managed identity and an Azure Container Apps job that runs
    Invoke-ClaudeTurnstileSchedule.ps1 on a cron schedule. Then grants the identity what the
    export and sync need, through Connect-ClaudeTurnstile.ps1 -ExporterPrincipalId, so the
    grants are made in one place.

    Nothing is assumed. The gateway, its workspace and the Turnstile connection are read from
    the gateway; the scripts the job runs are this repository at a commit that must already be
    on the remote, so the job cannot run code that was never pushed.

.PARAMETER RepositoryRef
    The commit the job runs. Defaults to this clone's HEAD, which must be on the remote.

.PARAMETER RunNow
    Start one run straight away and wait for it, rather than for the first scheduled one.

.EXAMPLE
    ./scripts/Register-ClaudeTurnstileSchedule.ps1 -RunNow

.EXAMPLE
    ./scripts/Register-ClaudeTurnstileSchedule.ps1 -Cron '*/30 * * * *' -NoGovernance
#>
[CmdletBinding()]
param(
    [string]$ResourceGroup = $(& (Join-Path $PSScriptRoot 'Get-ClaudeGatewayTarget.ps1') ResourceGroup),
    [string]$ApimName,
    [string]$RepositoryUrl,
    [string]$RepositoryRef,
    [string]$Cron = '7 * * * *',
    [switch]$NoGovernance,
    [switch]$RunNow
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ApimNamedValue.ps1')
. (Join-Path $PSScriptRoot 'ClaudeBusinessUnit.ps1')
. (Join-Path $PSScriptRoot 'ClaudeTurnstile.ps1')
. (Join-Path $PSScriptRoot 'ClaudeTurnstileGovernance.ps1')
$repo = Split-Path $PSScriptRoot -Parent

if (-not (az account show --query id -o tsv 2>$null)) { throw 'Not signed in. Run: az login' }
if (-not $ApimName) {
    $ApimName = az apim list -g $ResourceGroup --query "[0].name" -o tsv 2>$null
    if (-not $ApimName) { throw "No API Management instance in $ResourceGroup. Pass -ApimName." }
}
$integration = ConvertFrom-ClaudeTurnstileIntegrationValue (Get-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id $script:TurnstileIntegrationNamedValue)
if (-not $integration) { throw "$ApimName is not connected to Turnstile. Run ./scripts/Connect-ClaudeTurnstile.ps1 first." }
$workspace = Get-ClaudeGatewayWorkspaceId -ResourceGroup $ResourceGroup -ApimName $ApimName

if (-not $RepositoryUrl) {
    $origin = (git -C $repo remote get-url origin 2>$null)
    if (-not $origin) { throw 'This clone has no origin remote. Pass -RepositoryUrl.' }
    $RepositoryUrl = ($origin.Trim() -replace '^git@github\.com:', 'https://github.com/')
    if ($RepositoryUrl -notmatch '\.git$') { $RepositoryUrl += '.git' }
}
if (-not $RepositoryRef) {
    $RepositoryRef = (git -C $repo rev-parse HEAD).Trim()
    git -C $repo fetch -q origin 2>$null
    $onRemote = @(git -C $repo branch -r --contains $RepositoryRef 2>$null | Where-Object { $_.Trim() })
    if (-not $onRemote.Count) { throw "HEAD ($($RepositoryRef.Substring(0, 12))) is not on the remote, so the job could not fetch it. Push it, or pass -RepositoryRef." }
}
if ($RepositoryRef -notmatch '^[0-9a-f]{40}$') { throw 'RepositoryRef must be a full commit id, so what runs cannot change without a redeploy.' }

# Parameters go through a file: on Windows az runs through cmd.exe, which re-parses arguments.
$parameters = @{
    '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
    contentVersion = '1.0.0.0'
    parameters     = @{
        gatewayApimName     = @{ value = $ApimName }
        workspaceResourceId = @{ value = $workspace }
        repositoryUrl       = @{ value = $RepositoryUrl }
        repositoryRef       = @{ value = $RepositoryRef }
        cronExpression      = @{ value = $Cron }
        governance          = @{ value = (-not $NoGovernance) }
    }
}
$file = [IO.Path]::GetTempFileName()
try {
    [IO.File]::WriteAllText($file, ($parameters | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "Deploying the schedule into $ResourceGroup (commit $($RepositoryRef.Substring(0, 12)))..."
    $deployment = az deployment group create -g $ResourceGroup -n turnstile-schedule --template-file (Join-Path $repo 'infra/turnstile-schedule.bicep') --parameters "@$file" --query properties.outputs -o json | ConvertFrom-Json
}
finally { Remove-Item $file -ErrorAction SilentlyContinue }
if (-not $deployment) { throw 'The deployment returned no outputs.' }
$principalId = $deployment.principalId.value
$jobName = $deployment.jobName.value

Write-Host "Granting the job's identity what the export and sync need..."
$connect = & (Join-Path $PSScriptRoot 'Connect-ClaudeTurnstile.ps1') -ResourceGroup $ResourceGroup -ApimName $ApimName -ExporterPrincipalId $principalId -SkipValidation

$run = $null
if ($RunNow) {
    # Role assignments take effect within minutes, not at once; a run started straight away
    # can be refused by a grant that has not yet propagated.
    Start-Sleep -Seconds 90
    $execution = az containerapp job start -g $ResourceGroup -n $jobName --query name -o tsv
    $deadline = (Get-Date).AddMinutes(30)
    do {
        Start-Sleep -Seconds 15
        $status = az containerapp job execution show -g $ResourceGroup -n $jobName --job-execution-name $execution --query properties.status -o tsv 2>$null
    } while ($status -in @('Running', 'Processing', '') -and (Get-Date) -lt $deadline)
    $run = [pscustomobject]@{ Execution = $execution; Status = $status }
}

[pscustomobject][ordered]@{
    Job         = $jobName
    Schedule    = "$Cron (UTC)"
    Commit      = $RepositoryRef
    PrincipalId = $principalId
    Governance  = -not $NoGovernance
    Granted     = $connect.Granted
    Run         = $run
}
