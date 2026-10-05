$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$fail = 0
function Assert($Label, [bool]$Condition, $Detail = '') {
    if ($Condition) { Write-Host "  [OK]   $Label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $Label$(if ($Detail) { " - $Detail" })" -ForegroundColor Red; $script:fail++ }
}

Write-Host ''
Write-Host 'Projection deployer and installer wiring' -ForegroundColor Cyan
$deploy = [IO.File]::ReadAllText((Join-Path $root 'scripts\Deploy-ClaudeProjection.ps1'))
$install = [IO.File]::ReadAllText((Join-Path $root 'Install-ClaudeGateway.ps1'))

Assert 'deployer switch mode calls Invoke-ClaudeProjectionSwitch with NamePrefix and no renewal receipt parameters' ($deploy -match 'Invoke-ClaudeProjectionSwitch .* -NamePrefix \$NamePrefix' -and $deploy -notmatch 'RenewalReceiptPath|RenewalImageDigest|RenewalActionGroupResourceId|RenewalEntryPoint|ReconcilerResourceId')
$pointStart = $deploy.IndexOf("Step 'Point the gateway at the resolver'")
$pointText = if ($pointStart -ge 0) { $deploy.Substring($pointStart) } else { '' }
$setUrl = "Set-ApimNamedValue -ResourceGroup `$ResourceGroup -ApimName `$ApimName -Id 'entitlement-resolver-url'"
Assert 'deployer confirms resolver service principal before writing resolver named values' ($pointText.IndexOf('Confirm-ClaudeProjectionResolverServicePrincipal -AppId $ResolverAppId') -ge 0 -and $pointText.IndexOf('Confirm-ClaudeProjectionResolverServicePrincipal -AppId $ResolverAppId') -lt $pointText.IndexOf($setUrl))
Assert 'deployer writes entitlement-projection-prefix under the resolver point guard' ($pointText.Contains("entitlement-projection-prefix' -Value `$NamePrefix") -and $pointText.Contains("entitlement-projection-prefix') -eq `$NamePrefix"))
Assert 'deployer starts the runner before populate runner file/exec work' ($deploy.IndexOf('Start-ClaudeProjectionRunner -ResourceGroup $ResourceGroup -Name $($network.runnerName)') -gt 0 -and $deploy.IndexOf('Start-ClaudeProjectionRunner -ResourceGroup $ResourceGroup -Name $($network.runnerName)') -lt $deploy.IndexOf('Send-RunnerFile -ResourceGroup $ResourceGroup -Name $($network.runnerName)'))
Assert 'deployer final note says switch is available now with FlipAfterCleanCompare' ($deploy -match 'To switch now, rerun with -FlipAfterCleanCompare' -and $deploy -notmatch '60-90 minutes|30-minute')
Assert 'installer FlipProjectionAfterCleanCompare no longer requires or forwards renewal parameters' ($install -match 'FlipProjectionAfterCleanCompare' -and $install -notmatch 'ProjectionReconcilerResourceId|ProjectionRenewalImageDigest|ProjectionRenewalActionGroupResourceId|ProjectionRenewalEntryPoint|ReconcilerResourceId|RenewalImageDigest|RenewalActionGroupResourceId|RenewalEntryPoint')

Write-Host ''
if ($fail) { Write-Host "$fail assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'Projection deployer and installer wiring holds.' -ForegroundColor Green
exit 0
