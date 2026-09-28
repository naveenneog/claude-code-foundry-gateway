<#
.SYNOPSIS
    Reviews and reconciles existing Foundry Claude deployments, gateway tiers and client profiles.
.DESCRIPTION
    PlanOnly and WhatIf are read-only. Applying requires the reviewed fingerprint, a non-secret
    gateway snapshot and gateway-owned tier governance. No Foundry deployment or Entra group changes.
.EXAMPLE
    .\scripts\Sync-ClaudeModels.ps1 -RecordPath .\onboarding\claude-gateway.json -PlanOnly `
        -TierAssignments @{ 'claude-opus-5-5' = 'premium'; 'claude-haiku-4-5' = 'both' }
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$RecordPath = 'onboarding\claude-gateway.json',
    [string]$SubscriptionId,
    [string]$ResourceGroup,
    [string]$ApimName,
    [string]$FoundryAccount,
    [string]$FoundryResourceGroup,
    [hashtable]$TierAssignments,
    [string]$AnswersPath,
    [string]$PriceBookPath,
    [switch]$PlanOnly,
    [string]$ApprovedPlanFingerprint
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ClaudeModelLifecycle.ps1')
$root = Split-Path $PSScriptRoot -Parent
if (-not [IO.Path]::IsPathRooted($RecordPath)) { $RecordPath = Join-Path $root $RecordPath }
$RecordPath = [IO.Path]::GetFullPath($RecordPath)
$record = Read-ClaudeDecisionRecord $RecordPath
if (-not $record) { $record = [pscustomobject]@{ schemaVersion = 2; decisions = [pscustomobject]@{}; history = @() } }
if ($record.mode -and $record.mode -ne 'gateway') { throw 'Model sync requires a gateway record, not a direct-Foundry workstation record.' }
foreach ($key in 'SubscriptionId','ResourceGroup','ApimName','FoundryAccount','FoundryResourceGroup') {
    if (-not $PSBoundParameters.ContainsKey($key)) { continue }
    $value = $PSBoundParameters[$key]
    if ($record.$key -and $record.$key -ne $value) { throw "Explicit $key conflicts with the record. A different gateway needs its own RecordPath." }
    Set-ClaudeRecordProperty $record $key $value
}
Set-ClaudeRecordProperty $record '__recordPath' $RecordPath
$assignments = Get-ClaudeModelAssignments $record
$decision = Get-ClaudeDecision $record models
if (-not $PriceBookPath -and $decision -and $decision.priceBookPath) { $PriceBookPath = [string]$decision.priceBookPath }
if ($AnswersPath) {
    if (-not [IO.Path]::IsPathRooted($AnswersPath)) { $AnswersPath = Join-Path $root $AnswersPath }
    $answers = Read-ClaudeDecisionRecord $AnswersPath
    if (-not $answers -or $answers.GetType().FullName -ne 'System.Management.Automation.PSCustomObject') { throw 'AnswersPath must contain a JSON object.' }
    foreach ($p in $answers.PSObject.Properties) {
        if ($p.Name.StartsWith('models.tiers.')) { $assignments[$p.Name.Substring('models.tiers.'.Length).Replace('~','.')] = $p.Value }
        elseif ($p.Name -eq 'models.priceBookPath') {
            if ($p.Value -isnot [string]) { throw 'models.priceBookPath must be a scalar string.' }
            if (-not $PSBoundParameters.ContainsKey('PriceBookPath')) { $PriceBookPath = $p.Value }
        }
        else { throw "Unsupported model answer key '$($p.Name)'." }
    }
}
if ($TierAssignments) { foreach ($key in $TierAssignments.Keys) { $assignments[$key] = $TierAssignments[$key] } }
if (-not $PriceBookPath) { $PriceBookPath = Join-Path $root 'config\price-book.json' }
if (-not [IO.Path]::IsPathRooted($PriceBookPath)) { $PriceBookPath = Join-Path $root $PriceBookPath }
$target = Get-ClaudeModelTarget $record
$discovery = Get-ClaudeModelDiscovery $target
foreach ($q in @(Get-ClaudeModelQuestions $record $discovery -PriceBook (Get-ClaudeModelPriceBook $PriceBookPath))) {
    $name = $q.Key.Substring('models.tiers.'.Length).Replace('~','.')
    if (-not $assignments.ContainsKey($name)) {
        $assignments[$name] = Select-ClaudeChoice -Parameter $q.Key -Question $q.Question -Options $q.Options -WhereToFind $q.WhereToFind -AcceptRecommendedWithoutConsole:$q.AcceptRecommendedWithoutConsole
    }
}
$plan = New-ClaudeModelPlan -Record $record -RecordPath $RecordPath -PriceBookPath $PriceBookPath -TierAssignments $assignments -Discovery $discovery
$fingerprint = Get-ClaudeFlowFingerprint @($plan)
Write-Host (Format-ClaudeFlowReview @($plan))
Write-Host "Fingerprint: $fingerprint" -ForegroundColor Cyan
if ($PlanOnly) { return }
if ($WhatIfPreference) { Write-Host 'WhatIf: no model changes were written.'; return }
if (-not $ApprovedPlanFingerprint -and (Test-ClaudeInteractive)) { $ApprovedPlanFingerprint = Read-Host 'Type the first 8 fingerprint characters to apply' }
if (-not $ApprovedPlanFingerprint -or $ApprovedPlanFingerprint.Length -lt 8 -or -not $fingerprint.StartsWith($ApprovedPlanFingerprint, [StringComparison]::OrdinalIgnoreCase)) {
    throw "ApprovedPlanFingerprint does not match $fingerprint; no changes were written."
}
if (-not $PSCmdlet.ShouldProcess($target.ApimName, 'Apply the reviewed model lifecycle plan')) { return }
$principal = Invoke-ClaudeModelAz -Arguments @('account','show') -SubscriptionId $target.SubscriptionId -What 'Reading the model change principal'
Initialize-ClaudeModelChange -Record $record -Plan $plan
$changes = Invoke-ClaudeModelChange -Record $record -Plan $plan
Set-ClaudeDecision -Record $record -Key models -Value $changes.models
$release = Get-ClaudeFlowReleaseInfo -Repo $root
Add-ClaudeDecisionHistory -Record $record -Action Change -Decision models -From $decision -To $changes.models -Principal $principal.user.name -Commit $release.commit
Set-ClaudeDecisionRelease -Record $record -Version $release.version -Commit $release.commit
Write-ClaudeModelRecord -Record $record -Path $RecordPath
Write-Host 'Model lists and client files are recorded. Gateway propagation is verified with a real tier request.'
