$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$fail = 0
function Assert($Label, [bool]$Condition, $Detail = '') { if ($Condition) { Write-Host "  [OK]   $Label" -ForegroundColor Green } else { Write-Host "  [FAIL] $Label$(if ($Detail) { " - $Detail" })" -ForegroundColor Red; $script:fail++ } }
function Capture([scriptblock]$Block) { $script:Failure = $null; $script:Result = $null; try { $script:Result = & $Block } catch { $script:Failure = $_.Exception.Message } }
. (Join-Path $PSScriptRoot 'TestProjectionFixture.ps1')
. (Join-Path $root 'scripts\ApimNamedValue.ps1')
. (Join-Path $root 'scripts\ClaudeProjectionChecks.ps1')
$global:FixtureAz = ${function:az}
$global:FixtureRest = ${function:Invoke-RestMethod}
$global:ListMode = $null
function az {
    $line = $args -join ' '
    if ($global:ListMode -and $line -like 'apim nv show*') {
        $global:FixtureCalls.Add("az $line"); $global:LASTEXITCODE = 0
        $id = $args[([array]::IndexOf($args, '--named-value-id') + 1)]
        $standard = if ($global:ListMode -eq 'clean') { ",$FixtureApp," } else { ',00000000-0000-4000-8000-0000000000aa,' }
        $map = @{ 'allow-standard'=$standard; 'allow-premium'=','; 'bu-members'=','; 'entitlement-source'='named-value'; 'entitlement-resolver-url'=$FixtureResolverUrl; 'entitlement-resolver-audience'=$FixtureResolverAudience; 'entitlement-projection-prefix'='p84fixture' }
        if ($line -match '--query value') { return [string]$map[$id] }
        return (@{ name=$id; value=$map[$id]; secret=$false } | ConvertTo-Json -Compress)
    }
    & $global:FixtureAz @args
}
function Invoke-RestMethod {
    param($Uri, $Headers, $Method, $ErrorAction, $TimeoutSec, $Body, $ContentType, [switch]$UseBasicParsing)
    if ($global:ListMode -and [uri]::UnescapeDataString([string]$Uri) -match "displayName eq 'none'") { $global:FixtureCalls.Add("HTTP $Method none-group"); return [pscustomobject]@{ value=@() } }
    & $global:FixtureRest @PSBoundParameters
}
function At([string]$Pattern) { for ($i = 0; $i -lt $FixtureCalls.Count; $i++) { if ($FixtureCalls[$i] -match $Pattern) { return $i } }; return -1 }
function Writes { @($FixtureCalls | Where-Object { $_ -match '^az (deployment group create|apim nv (update|create)|cosmosdb sql role assignment create|functionapp|ad app create|ad sp create)' }) }
$repoBackups = { @(Get-ChildItem -LiteralPath (Join-Path $root 'onboarding') -Filter 'projection-switch-apim-p84-*.json' -ErrorAction SilentlyContinue) }
$deployer = Join-Path $root 'scripts\Deploy-ClaudeProjection.ps1'
function Invoke-DeployerSwitch([string]$Lists, [string]$Fixture = 'healthy') {
    Reset-ProjectionFixture $Fixture
    $global:ListMode = $Lists
    $before = @(& $repoBackups | ForEach-Object FullName)
    Capture { & $deployer -ResourceGroup rg-p84 -ApimName apim-p84 -NamePrefix p84fixture -FlipAfterCleanCompare -StandardGroup claude-code-standard -PremiumGroup none }
    $script:Made = @(& $repoBackups | Where-Object { $before -notcontains $_.FullName })
    $script:Made | Remove-Item -Force -ErrorAction SilentlyContinue
    $global:ListMode = $null
}

Write-Host ''
Write-Host 'Projection deployer and installer switch wiring' -ForegroundColor Cyan
Invoke-DeployerSwitch 'clean' 'compare-differs'
Assert 'deployer switch mode makes no deployment/registration/publish/role assignment/export/apply on compare refusal' ($Failure -match 'comparison found 1 differences' -and ($FixtureCalls -join "`n") -notmatch 'deployment group create|ad app create|functionapp|cosmosdb sql role assignment|--snapshot ' -and @(Writes).Count -eq 0 -and @($Made).Count -eq 0) "$Failure | $(($FixtureCalls | Select-Object -Last 10) -join ' | ')"
Invoke-DeployerSwitch 'clean'
$deployOrder = @((At 'apim nv show .*allow-premium'), (At 'apply-projection\.mjs .*--compare'), (At 'check-admission\.mjs'), (At '^az apim nv update .*entitlement-source --value projection'))
Assert 'deployer switches end to end through the real drift check: compare, evidence, backup, one write' (-not $Failure -and ($deployOrder -notcontains -1) -and (@(0..2 | Where-Object { $deployOrder[$_] -lt $deployOrder[$_ + 1] }).Count -eq 3) -and @(Writes).Count -eq 1 -and @($Made).Count -eq 1) "$Failure | positions $($deployOrder -join ',') | backups $(@($Made).Count)"
# P100 council round 4: the switch rerun the installer and the update print names -SubscriptionId; the switch, which
# runs without the preflight's subscription check, receives it.
Reset-ProjectionFixture
$global:ListMode = 'clean'
$before = @(& $repoBackups | ForEach-Object FullName)
Capture { & $deployer -ResourceGroup rg-p84 -ApimName apim-p84 -NamePrefix p84fixture -FlipAfterCleanCompare -StandardGroup claude-code-standard -PremiumGroup none -SubscriptionId 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' }
$made = @(& $repoBackups | Where-Object { $before -notcontains $_.FullName }); $made | Remove-Item -Force -ErrorAction SilentlyContinue
$global:ListMode = $null
Assert 'the deployer''s switch run with -SubscriptionId refuses another current subscription before it reads the gateway or writes' ($Failure -match '^Projection switch refused' -and $Failure -match 'az account set --subscription bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' -and ($FixtureCalls -join "`n") -notmatch 'apim show' -and @(Writes).Count -eq 0 -and $made.Count -eq 0) "$Failure | $(($FixtureCalls | Select-Object -First 3) -join ' | ')"
Reset-ProjectionFixture 'source-projection-other-url'
Capture { Assert-ClaudeProjectionResolverRedeploy -ResourceGroup rg-p84 -ApimName apim-p84 -NamePrefix p84fixture -SubscriptionId $FixtureSubscription -ResolverAppId $FixtureApp }
Assert 'deployer never redirects a gateway serving from the projection unless it redeploys the same resolver' ($Failure -match '^Refusing to redeploy the resolver' -and $Failure -match '-ResolverAppId' -and $Failure -match 'Sync-ClaudeAccess\.ps1 -Store named-value' -and @(Writes).Count -eq 0) $Failure
Reset-ProjectionFixture 'source-projection'
Capture { Assert-ClaudeProjectionResolverRedeploy -ResourceGroup rg-p84 -ApimName apim-p84 -NamePrefix p84fixture -SubscriptionId $FixtureSubscription -ResolverAppId $FixtureApp }
Assert 'deployer allows a projection gateway when it redeploys the resolver already serving it' (-not $Failure -and @(Writes).Count -eq 0) $Failure
$install = [IO.File]::ReadAllText((Join-Path $root 'Install-ClaudeGateway.ps1'))
Assert 'installer exposes FlipProjectionAfterCleanCompare without renewal receipt parameters' ($install -match 'FlipProjectionAfterCleanCompare' -and $install -notmatch 'ProjectionReconcilerResourceId|ProjectionRenewalImageDigest|ProjectionRenewalActionGroupResourceId|ProjectionRenewalEntryPoint|ReconcilerResourceId|RenewalImageDigest|RenewalActionGroupResourceId|RenewalEntryPoint')

Write-Host ''
Write-Host 'Projection deployer - pointing the gateway at the resolver' -ForegroundColor Cyan
function WrittenIds { @(Writes | ForEach-Object { [regex]::Match($_, '--named-value-id (\S+)').Groups[1].Value }) }
foreach ($case in @(
        @{ Fixture = 'source-projection-no-prefix'; Label = 'a gateway serving from a projection deployed before P97 gets only its prefix recorded'; Expect = 'entitlement-projection-prefix' }
        @{ Fixture = 'healthy'; Label = 'a gateway already pointed at this resolver with this prefix gets no write'; Expect = '' }
    )) {
    Reset-ProjectionFixture $case.Fixture
    Capture { Set-ClaudeProjectionGatewayResolver -ResourceGroup rg-p84 -ApimName apim-p84 -NamePrefix p84fixture -ResolverUrl $FixtureResolverUrl -ResolverAudience $FixtureResolverAudience }
    Assert $case.Label (-not $Failure -and ((WrittenIds) -join ',') -eq $case.Expect) "$Failure | writes: $((WrittenIds) -join ', ')"
}
Reset-ProjectionFixture 'source-projection-other-url'
Capture { Set-ClaudeProjectionGatewayResolver -ResourceGroup rg-p84 -ApimName apim-p84 -NamePrefix p84fixture -ResolverUrl 'https://func-resolver-p84fixture.azurewebsites.net/api' -ResolverAudience $FixtureResolverAudience }
Assert 'a projection gateway that calls another resolver is not redirected, and nothing is written' ($Failure -match '^Refusing to point the gateway' -and @(Writes).Count -eq 0) "$Failure | $(@(Writes) -join ' | ')"
Reset-ProjectionFixture
Capture { Set-ClaudeProjectionGatewayResolver -ResourceGroup rg-p84 -ApimName apim-p84 -NamePrefix p84new -ResolverUrl 'https://func-resolver-p84new.azurewebsites.net/api' -ResolverAudience $FixtureResolverAudience }
Assert 'a named-value gateway is pointed at a new resolver: url, audience, then prefix' (-not $Failure -and ((WrittenIds) -join ',') -eq 'entitlement-resolver-url,entitlement-resolver-audience,entitlement-projection-prefix') "$Failure | writes: $((WrittenIds) -join ', ')"
Reset-ProjectionFixture 'source-projection-no-prefix'
Capture { Set-ClaudeProjectionGatewayResolver -ResourceGroup rg-p84 -ApimName apim-p84 -NamePrefix p84fixture -ResolverUrl $FixtureResolverUrl -ResolverAudience $FixtureResolverAudience }
Assert 'D9C: the deployer records entitlement-projection-prefix for switch and sync discovery' (-not $Failure -and ((WrittenIds) -join ',') -eq 'entitlement-projection-prefix') "$Failure | writes: $((WrittenIds) -join ', ')"
$deployText = [IO.File]::ReadAllText($deployer)
Assert 'the deployer points the gateway only through Set-ClaudeProjectionGatewayResolver, inside its ShouldProcess' ($deployText -match "(?s)ShouldProcess\(\`$ApimName, 'set resolver named values and entitlement-projection-prefix[^']*'\)\) \{\s*\`$null = Set-ClaudeProjectionGatewayResolver" -and $deployText -notmatch "Set-ApimNamedValue[^\r\n]*-Id 'entitlement-resolver-url'")
Write-Host ''
if ($fail) { Write-Host "$fail assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'Projection deployer and installer wiring holds.' -ForegroundColor Green
exit 0
