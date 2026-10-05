$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$fail = 0
function Assert($Label, [bool]$Condition, $Detail = '') {
    if ($Condition) { Write-Host "  [OK]   $Label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $Label$(if ($Detail) { " - $Detail" })" -ForegroundColor Red; $script:fail++ }
}
function Capture([scriptblock]$Block) { $script:Failure = $null; $script:Result = $null; try { $script:Result = & $Block } catch { $script:Failure = $_.Exception.Message } }

Write-Host ''
Write-Host 'Projection guided flow switch' -ForegroundColor Cyan
. (Join-Path $root 'scripts\flow\Entitlement.ps1')

$record = [pscustomobject]@{ schemaVersion = 2; decisions = [pscustomobject]@{ entitlementStore = [pscustomobject]@{ target = 'projection' } }; history = @() }
$discovery = [pscustomobject]@{ resourceGroup = 'rg-p84'; apimName = 'apim-p84'; sku = 'BasicV2'; namedValues = @{ 'entitlement-source' = 'named-value'; 'entitlement-projection-prefix' = 'p84fixture' }; projectionPrefix = 'p84fixture' }
$plan = Get-ClaudeFlowStepPlan -Record $record -Discovery $discovery
$planText = (($plan.Implications + $plan.Requires + @($plan.Rollback) + @($plan.Actions | ForEach-Object Detail)) -join "`n")
Assert 'projection plan says no scheduled-renewal wait and rollback uses Sync-ClaudeAccess -Store named-value' ($planText -match 'no scheduled-renewal wait' -and $planText -match 'Sync-ClaudeAccess\.ps1 -Store named-value' -and $planText -notmatch '60-90|30-minute|renewal job|receipt') $planText

$missing = [pscustomobject]@{ resourceGroup = 'rg-p84'; apimName = 'apim-p84'; sku = 'BasicV2'; namedValues = @{ 'entitlement-source' = 'named-value' }; projectionPrefix = ''; projectionPrefixProblem = 'entitlement-projection-prefix is missing. Remedy: deploy the projection.' }
$missingPlan = Get-ClaudeFlowStepPlan -Record $record -Discovery $missing
Capture { Invoke-ClaudeFlowStep -Record $record -Plan $missingPlan }
Assert 'missing entitlement-projection-prefix refuses with deploy-projection remedy before switching' ($Failure -match 'entitlement-projection-prefix' -and $Failure -match 'Deploy-ClaudeProjection\.ps1') $Failure

$source = [IO.File]::ReadAllText((Join-Path $root 'scripts\flow\Entitlement.ps1')) + [IO.File]::ReadAllText((Join-Path $root 'scripts\flow\lib\LifecycleCommon.ps1')) + [IO.File]::ReadAllText((Join-Path $root 'scripts\flow\Discovery.ps1'))
Assert 'flow calls the shared switch with the discovered projection prefix' ($source -match 'Invoke-ClaudeProjectionSwitch .* -NamePrefix \$prefix')
Assert 'flow discovery reads entitlement-projection-prefix, not projection renewal receipts' ($source -match 'entitlement-projection-prefix' -and $source -notmatch 'Find-ClaudeFlowProjectionRenewal -Directory')

Write-Host ''
if ($fail) { Write-Host "$fail assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'Projection guided flow switch holds.' -ForegroundColor Green
exit 0
