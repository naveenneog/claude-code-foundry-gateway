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
Write-Host 'Projection installer - store choice and resolver shape' -ForegroundColor Cyan

$installer = Get-Content (Join-Path $root 'Install-ClaudeGateway.ps1') -Raw
$deployerPath = Join-Path $root 'scripts\Deploy-ClaudeProjection.ps1'
$cost = Get-Content (Join-Path $root 'scripts\Measure-ClaudeProjectionCost.ps1') -Raw
$secure = Get-Content (Join-Path $root 'tests\Test-SecureProjection.ps1') -Raw
$small = Resolve-ClaudeInstallerEntitlementStore -DeveloperCount 25 -BuCeiling 93 -ListCeiling 110 -Yes
$large = Resolve-ClaudeInstallerEntitlementStore -DeveloperCount 500 -BuCeiling 93 -ListCeiling 110 -Yes

Assert 'installer has an entitlement store parameter' ($installer -match '\[ValidateSet\(''named-value'',''projection''\)\]\s*\[string\]\$EntitlementStore')
Assert 'installer asks for the entitlement store as a choice' ($installer -match 'Select-ClaudeChoice' -and $installer -match 'Entitlement store')
Assert 'installer chooser works under redirected wizard tests' ($installer -match 'Select-ClaudeChoice[\s\S]+-Interactive \$true')
Assert 'named values state the measured ceiling the installer computes' ($installer -match '-BuCeiling \$buCeiling' -and $installer -match '-ListCeiling \$listCeiling' -and
    $small.Options[1].Detail -match '\b93 developers' -and $small.Options[1].Detail -match '\b110 per tier list') $small.Options[1].Detail
Assert 'projection choice is costed at the operator count' ($installer -match 'Measure-ClaudeProjectionCost\.ps1' -and $installer -match '-Developers \$devCount')
Capture { Resolve-ClaudeInstallerResolverInboundAccess -Sku BasicV2 -EntitlementStore projection -Requested private }
Assert 'BasicV2 refuses a private resolver before anything is created' ($Failure -match 'no outbound VNet integration' -and $Failure -match 'Nothing was created') $Failure
Assert 'Basic public shape names the Entra-only risk' ($installer -match 'public, Entra-authenticated resolver' -and $installer -match 'APIM v2 outbound IP')
Assert 'SKU guidance says zones and injection are not provisioned by this installer' ($installer -match 'without zone redundancy or Premium v2 VNet injection' -and $installer -match '-ExistingApimName')
Assert 'installer persists projection settings into claude-gateway.json' ($installer -match 'entitlementStore\s*=' -and $installer -match 'resolverInboundAccess\s*=' -and $installer -match 'projectionDeployer\s*=')
Assert 'installer deploys the projection whenever the store is projection' ($installer -match "(?s)if \(\`$EntitlementStore -eq 'projection'(?: -and [^{]+)?\) \{\s*Write-Step 'Projection deployment'.*?Invoke-ClaudeInstallerProjectionDeployment")
Assert 'an explicit store under -Yes is kept' ((Resolve-ClaudeInstallerEntitlementStore -EntitlementStore named-value -DeveloperCount 25 -BuCeiling 93 -ListCeiling 110 -Yes).Store -eq 'named-value')
Assert 'an existing named-value gateway without an explicit store migrates to projection' ((Resolve-ClaudeInstallerEntitlementStore -DeveloperCount 25 -BuCeiling 93 -ListCeiling 110 -DefaultStore named-value -Yes).Store -eq 'projection' -and $installer -match 'migrating from named values: deploy, compare, switch')
Assert '-Yes states the projection default it chose' ($installer -match 'EntitlementStore projection: default under -Yes')
Assert 'choosing projection implies the deployer; named values do not' ($small.DeployProjection -eq $true -and
    (Resolve-ClaudeInstallerEntitlementStore -EntitlementStore named-value -DeveloperCount 25 -BuCeiling 93 -ListCeiling 110 -Yes).DeployProjection -eq $false -and
    $installer -match "if \(\`$EntitlementStore -eq 'projection'(?: -and [^{]+)?\) \{\s*Write-Step 'Projection deployment'")
Assert 'flip no longer requires renewal admission inputs' ($installer -match 'FlipProjectionAfterCleanCompare' -and $installer -notmatch 'ProjectionRenewalImageDigest|ProjectionRenewalActionGroupResourceId|P86 admission requires')

Write-Host ''
Write-Host 'Projection deployer - compare-gated flip' -ForegroundColor Cyan

Assert 'one-command deployer ships' (Test-Path $deployerPath)
if (Test-Path $deployerPath) {
    $deployer = Get-Content $deployerPath -Raw
    Assert 'deployer supports WhatIf' ($deployer -match 'SupportsShouldProcess')
    Assert 'deployer validates SKU and inbound shape' ($deployer -match "\[ValidateSet\('BasicV2','StandardV2','PremiumV2'\)\]" -and $deployer -match "(?s)BasicV2.*public")
    Assert 'deployer deploys the private Cosmos projection' ($deployer -match 'projection\.bicep' -and $deployer -match "networkAccess='private-only'")
    Assert 'deployer deploys the resolver with selected inbound access' ($deployer -match 'resolver\.bicep' -and $deployer -match 'inboundAccess=')
    Assert 'deployer passes resolver identity allow lists through a parameter file' ($deployer -match 'allowedCallerAppIds = @\{ value = @\(\$gatewayAppId\) \}' -and $deployer -match 'allowedCallerObjectIds = @\{ value = @\(\$gatewayObjectId\) \}' -and $deployer -match '--parameters "@\$resolverParamFile"')
    Assert 'deployer publishes resolver code' ($deployer -match 'functionapp deployment source config-zip' -and $deployer -match 'resolver\.zip')
    Assert 'deployer uses an in-network runner for private Cosmos writes' ($deployer -match 'runnerEnabled=true' -and $deployer -match 'Send-RunnerFile' -and $deployer -match 'Invoke-RunnerCommand')
    Assert 'deployer grants the runner data contributor on one container' ($deployer -match 'cosmosdb sql role assignment create' -and $deployer -match '00000000-0000-0000-0000-000000000002' -and $deployer -match '/dbs/claude/colls/entitlement')
    Assert 'deployer populates from Entra' ($deployer -match 'Sync-ClaudeProjection\.ps1' -and $deployer -match 'apply-projection\.mjs')
    # The compare moved into Invoke-ClaudeProjectionDeployerCompare (tests/Test-ProjectionDeployerCompare.ps1 runs it).
    $compareText = [IO.File]::ReadAllText((Join-Path $root 'scripts\ClaudeProjectionSwitch.ps1'))
    Assert 'deployer exports gateway decisions' ($deployer -match 'Invoke-ClaudeProjectionDeployerCompare' -and $compareText -match 'Compare-ClaudeEntitlement\.ps1' -and $compareText -match '-ExportGatewayPath')
    Assert 'deployer runs projection comparison' ($deployer -match 'apply-projection\.mjs' -and $compareText -match '--compare /work/gateway-decisions\.json' -and $compareText -match '--compare-snapshot /work/snapshot\.json')
    Assert 'deployer refuses drift before flip' ($compareText -match 'Refusing to flip' -and $compareText -match 'drift from Entra')
    $switchText = Get-Content (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\ClaudeProjectionSwitch.ps1') -Raw
    Assert 'deployer switches only through the shared switch, which writes after sync switch evidence' ($deployer -match 'Invoke-ClaudeProjectionSwitch' -and $deployer -notmatch "Set-ApimNamedValue[^\r\n]*-Id 'entitlement-source'" -and
        $deployer -match '-NamePrefix \$NamePrefix' -and $switchText -match "(?s)Assert-ClaudeProjectionAdmission.*Set-ApimNamedValue[^\r\n]*-Id 'entitlement-source'" -and $switchText -notmatch 'RenewalActionGroupResourceId|image-digest|entrypoint')
    Assert 'deployer has bounded retries' ($deployer -match '\[ValidateRange\(1,10\)\]\[int\]\$RetryCount' -and $deployer -match 'Start-Sleep')
}

Write-Host ''
Write-Host 'Projection cost and security contract' -ForegroundColor Cyan

Assert 'cost model has an explicit P61 scenario mode' ($cost -match '\[switch\]\$P61Scenarios')
Assert 'cost model emits 100 and 500 developer rows' ($cost -match '100,500' -and $cost -match 'BasicV2 public resolver')
Assert 'secure tests cover public resolver authentication' ($secure -match 'public resolver is still Entra authenticated' -and $secure -match 'requireAuthentication: true')
Assert 'secure tests keep Cosmos private for the Basic public resolver' ($secure -match 'Cosmos stays private' -or $secure -match 'Cosmos remains private')

Write-Host ''
Write-Host 'Projection installer - P98 contract behaviour' -ForegroundColor Cyan

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
    -InvokeScript { param($Path, $Arguments) $calls.Add([pscustomobject]@{ Path = $Path; Args = $Arguments }); 0 } | Out-Null
Assert 'choosing projection invokes the projection deployer, then the switch, without renewal inputs' (
    $calls.Count -eq 2 -and
    (-not $calls[0].Args.Contains('FlipAfterCleanCompare')) -and $calls[1].Args.Contains('FlipAfterCleanCompare') -and
    -not @($calls | ForEach-Object { $_.Args.Keys } | Where-Object { $_ -like '*Renewal*' -or $_ -eq 'ReconcilerResourceId' }).Count
) ($calls | ConvertTo-Json -Depth 5)

Assert 'new projection gateways do not populate named-value entitlement lists' (-not (Test-ClaudeInstallerShouldSyncNamedValues -EntitlementStore projection -NewGateway $true))
Assert 'named-value gateways still populate named-value entitlement lists' (Test-ClaudeInstallerShouldSyncNamedValues -EntitlementStore named-value -NewGateway $true)

Write-Host ''
if ($fail) { Write-Host "$fail of $count assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "$count projection installer assertion(s) passed." -ForegroundColor Green
