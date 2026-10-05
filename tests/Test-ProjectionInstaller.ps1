$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$fail = 0
$count = 0
function Assert($label, $condition, $detail = '') {
    $script:count++
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $label$(if ($detail) { " - $detail" })" -ForegroundColor Red; $script:fail++ }
}
function Capture([scriptblock]$Block) {
    $script:Failure = ''
    $script:Result = $null
    try { $script:Result = & $Block }
    catch { $script:Failure = $_.Exception.Message }
}

. (Join-Path $root 'scripts\ClaudeChoice.ps1')
. (Join-Path $root 'scripts\ClaudeInstallProjection.ps1')

Write-Host ''
Write-Host 'Projection installer - P98 contract behaviour' -ForegroundColor Cyan

$small = Resolve-ClaudeInstallerEntitlementStore -DeveloperCount 25 -BuCeiling 93 -ListCeiling 110 -Yes
$large = Resolve-ClaudeInstallerEntitlementStore -DeveloperCount 500 -BuCeiling 93 -ListCeiling 110 -Yes
Assert 'Cosmos projection is the unattended default for small and large teams' ($small.Store -eq 'projection' -and $large.Store -eq 'projection')
Assert 'projection is offered first and recommended; named values are the small-team fallback' ($small.Options[0].Value -eq 'projection' -and $small.Options[0].Recommended -and $small.Options[1].Value -eq 'named-value') ($small.Options | ConvertTo-Json -Depth 4)

Capture { Resolve-ClaudeInstallerEntitlementStore -EntitlementStore named-value -DeveloperCount 500 -BuCeiling 93 -ListCeiling 110 -Yes }
Assert 'named values above the measured ceiling are refused with the capacity reason' ($Failure -match '4,096-character' -and $Failure -match 'Choose projection') $Failure

foreach ($sku in 'BasicV2','StandardV2','PremiumV2') {
    $choice = Resolve-ClaudeInstallerResolverInboundAccess -Sku $sku -EntitlementStore projection
    Assert "resolver defaults to public on $sku" ($choice.Access -eq 'public') ($choice | ConvertTo-Json -Depth 4)
}
$private = Resolve-ClaudeInstallerResolverInboundAccess -Sku PremiumV2 -EntitlementStore projection -Requested private
Assert 'private resolver remains available with the outbound VNet prerequisite' ($private.Access -eq 'private' -and $private.Message -match 'outbound VNet integration' -and $private.Message -match 'updated 2025-12-04') $private.Message

$calls = [System.Collections.Generic.List[object]]::new()
Invoke-ClaudeInstallerProjectionDeployment -Root $root -ResourceGroup rg-p98 -ApimName apim-p98 -NamePrefix p98 `
    -Location eastus2 -Sku BasicV2 -ResolverInboundAccess public -StandardGroup standard -PremiumGroup premium `
    -InvokeScript { param($Path, [string[]]$Arguments) $calls.Add([pscustomobject]@{ Path = $Path; Args = $Arguments }); 0 } | Out-Null
Assert 'choosing projection invokes the projection deployer and switch without renewal inputs' (
    $calls.Count -eq 1 -and
    ($calls[0].Args -contains '-FlipAfterCleanCompare') -and
    -not @($calls[0].Args | Where-Object { $_ -like '*Renewal*' -or $_ -eq '-ReconcilerResourceId' }).Count
) ($calls | ConvertTo-Json -Depth 5)

Assert 'new projection gateways do not populate named-value entitlement lists' (-not (Test-ClaudeInstallerShouldSyncNamedValues -EntitlementStore projection -NewGateway $true))
Assert 'named-value gateways still populate named-value entitlement lists' (Test-ClaudeInstallerShouldSyncNamedValues -EntitlementStore named-value -NewGateway $true)

Write-Host ''
if ($fail) { Write-Host "$fail of $count assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "$count projection installer assertion(s) passed." -ForegroundColor Green
