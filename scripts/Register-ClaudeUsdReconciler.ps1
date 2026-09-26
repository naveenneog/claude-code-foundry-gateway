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
    [string]$Image = 'mcr.microsoft.com/azure-cli:2.90.0',
    [string]$ExistingEnvironmentId,
    [string]$Location,
    [switch]$RunNow
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ClaudeChoice.ps1')
. (Join-Path $PSScriptRoot 'ClaudeUsdReconcilerSchedule.ps1')

if (-not (az account show --query id -o tsv 2>$null)) { throw 'Not signed in. Run: az login.' }
if (-not $ResourceGroup) { $ResourceGroup = Select-ClaudeResourceGroup }
if (-not $ApimName) { $ApimName = Select-ClaudeGateway -ResourceGroup $ResourceGroup }
if (-not $WorkspaceResourceId) {
    $workspace = Select-ClaudeWorkspace -ResourceGroup $ResourceGroup -ApimName $ApimName -ScriptRoot $PSScriptRoot
    $WorkspaceResourceId = $workspace
}
if (-not $WorkspaceCustomerId) {
    $WorkspaceCustomerId = az monitor log-analytics workspace show --ids $WorkspaceResourceId --query customerId -o tsv
    if ($LASTEXITCODE -ne 0 -or -not $WorkspaceCustomerId) { throw 'Cannot resolve workspace customer ID.' }
}
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
if (-not $Location) { $Location = az apim show -g $ResourceGroup -n $ApimName --query location -o tsv }
$gatewayId = az apim show -g $ResourceGroup -n $ApimName --query id -o tsv
if (-not $gatewayId) { throw 'Cannot resolve gateway resource ID.' }
$tags = @{ component = 'usd-reconciler'; packet = 'P66'; purpose = 'flow-finops' }
$parameters = New-ClaudeUsdReconcilerParameters -GatewayResourceId $gatewayId -WorkspaceResourceId $WorkspaceResourceId `
    -WorkspaceCustomerId $WorkspaceCustomerId -RepositoryUrl $RepositoryUrl -RepositoryRef $RepositoryRef `
    -Cron $Cron -Image $Image -Location $Location -ExistingEnvironmentId $ExistingEnvironmentId -Tags $tags

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
