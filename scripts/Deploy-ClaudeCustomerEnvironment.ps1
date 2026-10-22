<#
.SYNOPSIS
    Runs a production setup from one customer JSON file: existing APIM, Foundry, network and Entra groups (P124).

.DESCRIPTION
    The JSON is the customer sheet (docs/CUSTOMER-SETUP.md): gateway, network, projection, deployments, modelSets,
    profiles (the tiers, with their dollar credit and model set) and the 47 groups. One command runs it all:
    -Phase All (the default) runs every phase below in order and stops at the first failure; a rerun resumes. -Phase
    names one or more phases to run only those:

      Plan       Reads the sheet; resolves each group's object id from Entra by exact display name (read only);
                 writes onboarding\answers.<prefix>.json and onboarding\access-catalog.<prefix>.json and checks the
                 answers with the installer's own validator. No Azure write.
      Preflight  Install-ClaudeGateway.ps1 -Preflight: rights, network, DNS links, APIM, Foundry deployments. No write.
      Deploy     Install-ClaudeGateway.ps1 -Yes on the existing APIM, network and Foundry. Resumable.
      Catalog    Set-ClaudeAccessCatalog.ps1: one tier per sheet profile, one access profile per group.
      Limits     Set-ClaudePlanTokenQuotas.ps1: monthly token limits per tier and model family from each tier's credit.
      Sync       Sync-ClaudeAccess.ps1: the first full sync, run by the operator.
      Grant      Grant-ClaudeProjectionRenewalGraphAccess.ps1 for the sync job. The signed-in account must be a Privileged
                 Role Administrator or Global Administrator (an Azure subscription Owner cannot grant it).
      Schedule   Starts the sync job once, waits for success, then sets projection.syncInterval (for example 15m).

    Each phase prints what it ran. Plan writes files under onboarding\, which Git ignores.

.EXAMPLE
    ./scripts/Deploy-ClaudeCustomerEnvironment.ps1 -SheetPath ./onboarding/customer-sheet.json
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SheetPath,
    [string[]]$Phase = @('All'),
    [ValidateRange(0, 0.95)][decimal]$CacheReadShare = 0.5,
    [ValidateSet('standard', 'long')][string]$Haiku55PromptTier = 'long',
    [string]$OnboardingDirectory,
    # Test seams: offline group ids, and the scripts each phase runs.
    [Parameter(DontShow)][switch]$OfflineGroups,
    [Parameter(DontShow)][string]$ToolRoot
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if (-not $ToolRoot) { $ToolRoot = $root }
if (-not $OnboardingDirectory) { $OnboardingDirectory = Join-Path $root 'onboarding' }
$all = @('Plan', 'Preflight', 'Deploy', 'Catalog', 'Limits', 'Sync', 'Grant', 'Schedule')
$Phase = @($Phase | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
foreach ($p in $Phase) { if ($p -notin ($all + 'All')) { Write-Host "-Phase '$p' is not one of: $(($all + 'All') -join ', ')." -ForegroundColor Red; exit 2 } }
$run = if ($Phase -contains 'All') { $all } else { @($all | Where-Object { $_ -in $Phase }) }

. (Join-Path $PSScriptRoot 'ClaudeCustomerSheet.ps1')
. (Join-Path $PSScriptRoot 'ClaudeInstallerAnswers.ps1')
function Step([string]$Text) { Write-Host ''; Write-Host "== $Text" -ForegroundColor Cyan }
function Note([string]$Text) { Write-Host "   $Text" -ForegroundColor DarkGray }
function Invoke-Tool([string]$Relative, [hashtable]$Arguments) {
    $path = Join-Path $ToolRoot $Relative
    Note ("{0} {1}" -f $Relative, (($Arguments.GetEnumerator() | Sort-Object Name | ForEach-Object { if ($_.Value -is [bool] -and $_.Value) { "-$($_.Name)" } else { "-$($_.Name) $($_.Value)" } }) -join ' '))
    & $path @Arguments
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "$Relative failed (exit $LASTEXITCODE); later phases were not run." }
}

if (-not (Test-Path -LiteralPath $SheetPath)) { Write-Host "Sheet '$SheetPath' was not found." -ForegroundColor Red; exit 2 }
$sheet = Get-Content -Raw -LiteralPath $SheetPath | ConvertFrom-Json
$plan = New-ClaudeAnswersFromSheet -Sheet $sheet
if ($plan.Problems.Count) { Write-Host 'The sheet is incomplete; nothing was run:' -ForegroundColor Red; $plan.Problems | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }; exit 2 }
$a = $plan.Answers
$prefix = [string]$a.NamePrefix
$answersPath = Join-Path $OnboardingDirectory "answers.$prefix.json"
$catalogPath = Join-Path $OnboardingDirectory "access-catalog.$prefix.json"
$schedule = if ($plan.SyncInterval) { $plan.SyncInterval } else { '15m' }

if ('Plan' -in $run) {
    Step 'Plan: answers file and access catalog from the sheet'
    New-Item -ItemType Directory -Force -Path $OnboardingDirectory | Out-Null
    $a | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $answersPath -Encoding utf8
    $problems = @(Test-ClaudeInstallerAnswersFile -Path $answersPath -Consumer 'Install-ClaudeGateway.ps1')
    if ($problems.Count) {
        Write-Host 'The installer refuses the answers this sheet produces:' -ForegroundColor Red
        $problems | ForEach-Object { Write-Host "  $($_.answer): $($_.message) $($_.remedy)" -ForegroundColor Red }
        exit 2
    }
    Note "answers: $answersPath (checked by the installer's validator)"
    $convert = @{ InputPath = $SheetPath; OutputPath = $catalogPath }
    if ($OfflineGroups) { $convert.Offline = $true }
    Invoke-Tool 'scripts\ConvertTo-ClaudeAccessCatalog.ps1' $convert
    $catalog = Get-Content -Raw -LiteralPath $catalogPath | ConvertFrom-Json
    Note "catalog: $catalogPath ($(@($catalog.plans).Count) tiers, $(@($catalog.profiles).Count) groups)"
    Note "network: $($a.ProjectionNetworkMode)$(if ($a.ProjectionVnetId) { " $($a.ProjectionVnetId)" }); Foundry: $($a.FoundryAuthenticationMode) $($a.FoundryAccount); APIM: $($a.ExistingApimName)"
}

foreach ($needFile in @(@('Preflight', $answersPath), @('Deploy', $answersPath), @('Catalog', $catalogPath), @('Limits', $catalogPath))) {
    if ($needFile[0] -in $run -and -not (Test-Path -LiteralPath $needFile[1])) { Write-Host "$($needFile[0]) needs $($needFile[1]); run -Phase Plan first." -ForegroundColor Red; exit 2 }
}

if ('Preflight' -in $run) { Step 'Preflight (read only)'; Invoke-Tool 'Install-ClaudeGateway.ps1' @{ AnswersPath = $answersPath; Preflight = $true } }
if ('Deploy' -in $run) { Step 'Deploy on the existing APIM, network and Foundry'; Invoke-Tool 'Install-ClaudeGateway.ps1' @{ AnswersPath = $answersPath; Yes = $true; ProgressPath = (Join-Path $OnboardingDirectory "install-progress.$prefix.ndjson") } }
if ('Catalog' -in $run) { Step 'Tiers and groups'; Invoke-Tool 'scripts\Set-ClaudeAccessCatalog.ps1' @{ ResourceGroup = $a.ResourceGroup; ApimName = $a.ExistingApimName; Path = $catalogPath } }
if ('Limits' -in $run) {
    Step 'Token limits per tier'
    $limits = @{ ResourceGroup = $a.ResourceGroup; ApimName = $a.ExistingApimName; CatalogPath = $catalogPath; FoundryAccount = $a.FoundryAccount
        FoundryResourceGroup = $a.FoundryResourceGroup; SubscriptionId = $a.SubscriptionId; SheetPath = $SheetPath; CacheReadShare = $CacheReadShare; Haiku55PromptTier = $Haiku55PromptTier }
    if ($a.FoundrySubscriptionId) { $limits.FoundrySubscriptionId = $a.FoundrySubscriptionId }
    Invoke-Tool 'scripts\Set-ClaudePlanTokenQuotas.ps1' $limits
}
if ('Sync' -in $run) { Step 'First full sync'; Invoke-Tool 'scripts\Sync-ClaudeAccess.ps1' @{ ResourceGroup = $a.ResourceGroup; ApimName = $a.ExistingApimName; StandardGroup = $a.StandardGroup; PremiumGroup = $a.PremiumGroup } }

function Get-RenewalOutput([string]$Deployment, [string]$Output) {
    $v = & az deployment group show -g $a.ResourceGroup -n $Deployment --subscription $a.SubscriptionId --query "properties.outputs.$Output.value" -o tsv 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $v) { throw "Deployment $Deployment has no output $Output in $($a.ResourceGroup); run -Phase Deploy first." }
    return ([string]$v).Trim()
}
if ('Grant' -in $run) {
    Step 'Graph read permission for the sync job (Entra admin)'
    Invoke-Tool 'scripts\Grant-ClaudeProjectionRenewalGraphAccess.ps1' @{ PrincipalId = (Get-RenewalOutput "projection-registry-$prefix" 'identityPrincipalId') }
}
if ('Schedule' -in $run) {
    Step "Prove one sync job run, then schedule it every $schedule"
    $job = Get-RenewalOutput "projection-renewal-$prefix" 'jobName'
    $execution = & az containerapp job start -g $a.ResourceGroup -n $job --subscription $a.SubscriptionId --query name -o tsv
    if ($LASTEXITCODE -ne 0) { throw "Starting $job failed." }
    $deadline = (Get-Date).AddMinutes(20)
    do {
        Start-Sleep -Seconds 20
        $status = & az containerapp job execution show -g $a.ResourceGroup -n $job --job-execution-name $execution --subscription $a.SubscriptionId --query properties.status -o tsv 2>$null
        Note "$execution $status"
    } while ($status -notin 'Succeeded', 'Failed', 'Stopped', 'Degraded' -and (Get-Date) -lt $deadline)
    if ($status -ne 'Succeeded') {
        throw "The sync job run ended '$status'. A Graph grant can take hours to reach the job identity; check ContainerAppConsoleLogs for $job and run -Phase Schedule again."
    }
    Invoke-Tool 'scripts\Set-ClaudeProjectionSyncSchedule.ps1' @{ ResourceGroup = $a.ResourceGroup; ApimName = $a.ExistingApimName; Interval = $schedule }
}
Write-Host ''
Write-Host "Done: $($run -join ', ')." -ForegroundColor Green
