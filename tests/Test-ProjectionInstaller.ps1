$root = Split-Path $PSScriptRoot -Parent
$fail = 0
function Assert($label, $condition, $detail = '') {
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $label$(if ($detail) { " - $detail" })" -ForegroundColor Red; $script:fail++ }
}

Write-Host ''
Write-Host 'Projection installer - Basic v2 and projection choice' -ForegroundColor Cyan

$installer = Get-Content (Join-Path $root 'Install-ClaudeGateway.ps1') -Raw
$deployerPath = Join-Path $root 'scripts\Deploy-ClaudeProjection.ps1'
$cost = Get-Content (Join-Path $root 'scripts\Measure-ClaudeProjectionCost.ps1') -Raw
$secure = Get-Content (Join-Path $root 'tests\Test-SecureProjection.ps1') -Raw

Assert 'installer has an entitlement store parameter' ($installer -match '\[ValidateSet\(''named-value'',''projection''\)\]\s*\[string\]\$EntitlementStore')
Assert 'installer asks for the entitlement store as a choice' ($installer -match 'Select-ClaudeChoice' -and $installer -match 'Entitlement store')
Assert 'installer chooser works under redirected wizard tests' ($installer -match 'Select-ClaudeChoice[\s\S]+-Interactive \$true')
Assert 'named values state the measured ceiling' ($installer -match '93 developer' -and $installer -match '110')
Assert 'projection choice is costed at the operator count' ($installer -match 'Measure-ClaudeProjectionCost\.ps1' -and $installer -match '-Developers \$devCount')
Assert 'BasicV2 projection selects the public resolver shape' ($installer -match "'BasicV2'\s*\{\s*'public'")
Assert 'StandardV2 projection selects the private resolver shape' ($installer -match "'StandardV2'\s*\{\s*'private'")
Assert 'PremiumV2 projection selects the private resolver shape' ($installer -match "'PremiumV2'\s*\{\s*'private'")
Assert 'Basic public shape names the Entra-only risk' ($installer -match 'public, Entra-authenticated resolver' -and $installer -match 'APIM v2 outbound IP')
Assert 'installer persists projection settings into claude-gateway.json' ($installer -match 'entitlementStore\s*=' -and $installer -match 'resolverInboundAccess\s*=' -and $installer -match 'projectionDeployer\s*=')
Assert 'installer invokes the one-command deployer for projection' ($installer -match 'Deploy-ClaudeProjection\.ps1' -and $installer -match '-FlipAfterCleanCompare')
Assert 'non-interactive projection refuses ambiguity' ($installer -match 'Projection requires .* -Yes' -or $installer -match 'Cannot choose projection unattended')
Assert '-Yes chooses the deterministic entitlement store default' ($installer -match 'selected from the declared developer count under -Yes')
Assert 'unattended projection always requires the deployer' ($installer.Contains('$Yes -and $EntitlementStore -eq ''projection'' -and -not $DeployProjection'))
Assert 'flip cannot be requested without the deployer' ($installer.Contains('$FlipProjectionAfterCleanCompare -and -not $DeployProjection'))

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
    Assert 'deployer exports gateway decisions' ($deployer -match 'Compare-ClaudeEntitlement\.ps1' -and $deployer -match '-ExportGatewayPath')
    Assert 'deployer runs projection comparison' ($deployer -match 'apply-projection\.mjs' -and $deployer -match '--compare')
    Assert 'deployer refuses drift before flip' ($deployer -match 'Refusing to flip' -and $deployer -match 'drift')
    Assert 'deployer flips only entitlement named values' ($deployer -match 'Set-ApimNamedValue' -and $deployer -match 'entitlement-source' -and $deployer -match 'entitlement-resolver-url' -and $deployer -match 'entitlement-resolver-audience')
    Assert 'deployer has bounded retries' ($deployer -match '\[ValidateRange\(1,10\)\]\[int\]\$RetryCount' -and $deployer -match 'Start-Sleep')
}

Write-Host ''
Write-Host 'Projection cost and security contract' -ForegroundColor Cyan

Assert 'cost model has an explicit P61 scenario mode' ($cost -match '\[switch\]\$P61Scenarios')
Assert 'cost model emits 100 and 500 developer rows' ($cost -match '100,500' -and $cost -match 'BasicV2 public resolver')
Assert 'secure tests cover public resolver authentication' ($secure -match 'public resolver is still Entra authenticated' -and $secure -match 'requireAuthentication: true')
Assert 'secure tests keep Cosmos private for the Basic public resolver' ($secure -match 'Cosmos stays private' -or $secure -match 'Cosmos remains private')

Write-Host ''
if ($fail) { Write-Host "$fail assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'Projection installer contract holds.' -ForegroundColor Green
exit 0
