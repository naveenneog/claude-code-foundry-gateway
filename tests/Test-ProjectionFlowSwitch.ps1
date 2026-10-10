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
Write-Host 'Projection guided flow - the prefix comes from the gateway' -ForegroundColor Cyan
. (Join-Path $PSScriptRoot 'TestProjectionFixture.ps1')
. (Join-Path $root 'scripts\flow\Discovery.ps1')
Reset-ProjectionFixture
$flowRecord = [pscustomobject]@{ schemaVersion = 2; resourceGroup = 'rg-p84'; apimName = 'apim-p84'; decisions = [pscustomobject]@{ entitlementStore = [pscustomobject]@{ target = 'projection' } }; history = @() }
$live = Get-ClaudeFlowDiscovery -RecordPath '' -Record $flowRecord 6>$null
Assert 'the guided flow discovery does not report a missing prefix it did not read' ($live.gateway -and -not $live.projectionPrefixProblem -and ($FixtureCalls -join "`n") -match 'apim show -g rg-p84 -n apim-p84') "$($live.projectionPrefixProblem) | $($FixtureCalls -join ' | ')"
$livePlan = Get-ClaudeFlowStepPlan -Record $flowRecord -Discovery $live
Reset-ProjectionFixture
Capture { Invoke-ClaudeFlowStep -Record $flowRecord -Plan $livePlan 6>$null }
$flowCalls = $FixtureCalls -join "`n"
Assert 'the Entitlement step reads entitlement-projection-prefix from the gateway and switches that projection' ($flowCalls -match 'apim nv show -g rg-p84 --service-name apim-p84 --named-value-id entitlement-projection-prefix' -and $flowCalls -match 'deployment group show -g rg-p84 -n projection-resolver-p84fixture') "$Failure | $(($FixtureCalls | Select-Object -First 5) -join ' | ')"
# P100 council round 4: the step switches in the subscription its discovery read the gateway in.
$otherDiscovery = [pscustomobject]@{ subscriptionId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'; resourceGroup = 'rg-p84'; apimName = 'apim-p84'; sku = 'BasicV2'; namedValues = @{ 'entitlement-source' = 'named-value'; 'entitlement-projection-prefix' = 'p84fixture' }; projectionPrefix = 'p84fixture' }
$otherPlan = Get-ClaudeFlowStepPlan -Record $flowRecord -Discovery $otherDiscovery
Reset-ProjectionFixture
Capture { Invoke-ClaudeFlowStep -Record $flowRecord -Plan $otherPlan 6>$null }
Assert 'the Entitlement step passes the discovered subscription to the switch, which refuses another current one before it reads the gateway' ($Failure -match '^Projection switch refused' -and $Failure -match 'az account set --subscription bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' -and ($FixtureCalls -join "`n") -notmatch 'apim show|apim nv update') "$Failure | $($FixtureCalls -join ' | ')"
Reset-ProjectionFixture 'prefix-missing'
Capture { Invoke-ClaudeFlowStep -Record $flowRecord -Plan $livePlan 6>$null }
Assert 'a gateway without entitlement-projection-prefix refuses with the deploy remedy before the switch reads anything else' ($Failure -match 'entitlement-projection-prefix' -and $Failure -match 'Deploy-ClaudeProjection\.ps1' -and ($FixtureCalls -join "`n") -notmatch 'apim show|deployment group show') "$Failure | $($FixtureCalls -join ' | ')"
# P98 council round 2 (Security residual): the guided switch said Standard v2 and Premium v2 use a private
# resolver; since ADR-0052 the installer deploys it public by default on every tier.
$flowText = [IO.File]::ReadAllText((Join-Path $root 'scripts\flow\Entitlement.ps1'))
Assert 'the guided switch describes the resolver as deployed, public by default on every tier' (
    $flowText -notmatch 'Standard v2 and Premium v2 use a private resolver' -and $flowText -notmatch 'Standard/Premium v2 use a private resolver' -and
    ([regex]::Matches($flowText, 'public and Entra-authenticated by default')).Count -eq 2)
Write-Host ''
if ($fail) { Write-Host "$fail assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'Projection guided flow switch holds.' -ForegroundColor Green
exit 0
