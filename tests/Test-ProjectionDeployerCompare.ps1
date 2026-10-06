$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$fail = 0
$count = 0
function Assert($Label, [bool]$Condition, $Detail = '') {
    $script:count++
    if ($Condition) { Write-Host "  [OK]   $Label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $Label$(if ($Detail) { " - $Detail" })" -ForegroundColor Red; $script:fail++ }
}
function Capture([scriptblock]$Block) { $script:Failure = $null; $script:Result = $null; try { $script:Result = & $Block } catch { $script:Failure = $_.Exception.Message } }
. (Join-Path $PSScriptRoot 'TestProjectionFixture.ps1')
. (Join-Path $root 'scripts\ClaudeProjectionSwitch.ps1')

Write-Host ''
Write-Host 'Projection deployer - compare before any switch (ADR-0051 D10)' -ForegroundColor Cyan

$work = Join-Path $root '.test-work\p97-deployer-compare'
Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $work | Out-Null
$compareStub = Join-Path $work 'compare-stub.ps1'
[IO.File]::WriteAllText($compareStub, @'
param([string]$ResourceGroup, [string]$ApimName, [string]$StandardGroup, [string]$PremiumGroup, [string]$ExportGatewayPath, [bool]$FailOnDrift = $true)
$global:FixtureCalls.Add("compare-stub $ResourceGroup $ApimName $StandardGroup $PremiumGroup failOnDrift=$FailOnDrift")
if ($global:CompareDrift) { exit 1 }
[IO.File]::WriteAllText($ExportGatewayPath, '{"kind":"claude-gateway-decisions","premium":[],"standard":[]}')
exit 0
'@)
function Invoke-Compare {
    param([hashtable]$Extra = @{})
    $params = @{ ResourceGroup = 'rg-p84'; ApimName = 'apim-p84'; RunnerName = 'aci-projtest-p84fixture'; CosmosAccount = 'cosmos-p84fixture'; TenantId = $FixtureTenant; GatewayPath = (Join-Path $work 'gateway-decisions.json'); StandardGroup = 'claude-code-standard'; PremiumGroup = 'none'; CompareScript = $compareStub }
    foreach ($key in $Extra.Keys) { $params[$key] = $Extra[$key] }
    Invoke-ClaudeProjectionDeployerCompare @params
}

try {
    Reset-ProjectionFixture
    $global:CompareDrift = $false
    Capture { Invoke-Compare 6>$null }
    $calls = $FixtureCalls -join "`n"
    Assert 'a gateway with named-value members is drift-checked against Entra, then compared with its exported lists' (-not $Failure -and $Result.ok -eq $true -and
        $calls -match '(?m)^compare-stub rg-p84 apim-p84 claude-code-standard none failOnDrift=True' -and $calls -match 'apply-projection\.mjs .*--compare /work/gateway-decisions\.json' -and
        $calls -notmatch '--compare-snapshot') "$Failure | $calls"

    Reset-ProjectionFixture 'new-gateway'
    Capture { Invoke-Compare 6>$null }
    $calls = $FixtureCalls -join "`n"
    Assert 'a new gateway, with no named-value members, is compared with the snapshot just applied and not drift-checked' (-not $Failure -and $Result.ok -eq $true -and
        $calls -notmatch '(?m)^compare-stub' -and $calls -match 'apply-projection\.mjs .*--compare-snapshot /work/snapshot\.json') "$Failure | $calls"

    Reset-ProjectionFixture
    Capture { Invoke-Compare @{ CompareBaseline = 'Snapshot' } 6>$null }
    $calls = $FixtureCalls -join "`n"
    Assert 'snapshot baseline skips named-value drift and compares the projection with the fresh snapshot' (-not $Failure -and $Result.ok -eq $true -and
        $calls -notmatch '(?m)^compare-stub' -and $calls -match 'apply-projection\.mjs .*--compare-snapshot /work/snapshot\.json') "$Failure | $calls"

    Reset-ProjectionFixture
    $global:CompareDrift = $true
    Capture { Invoke-Compare 6>$null }
    Assert 'drift between the named-value lists and Entra refuses before any runner compare' ($Failure -match 'drift' -and ($FixtureCalls -join "`n") -notmatch 'apply-projection\.mjs') $Failure

    Reset-ProjectionFixture 'compare-differs'
    $global:CompareDrift = $false
    Capture { Invoke-Compare 6>$null }
    Assert 'a projection that differs from the gateway refuses' ($Failure -match 'Refusing to flip because projection drift remains') $Failure

    Reset-ProjectionFixture 'nv-read-error'
    Capture { Invoke-Compare 6>$null }
    Assert 'a named-value read that fails refuses rather than treating the gateway as new' ($Failure -and ($FixtureCalls -join "`n") -notmatch '--compare-snapshot') "$Failure | $($FixtureCalls -join ' | ')"

    $deployer = [IO.File]::ReadAllText((Join-Path $root 'scripts\Deploy-ClaudeProjection.ps1'))
    Assert 'the deployer compares only through Invoke-ClaudeProjectionDeployerCompare, inside its ShouldProcess' ($deployer -match "(?s)ShouldProcess\(\`$ApimName, 'export gateway decisions and compare projection'\)\) \{\s*\`$compare = Invoke-ClaudeProjectionDeployerCompare" -and
        $deployer -notmatch '--compare /work/gateway-decisions\.json')
    # A full sync counts as switch evidence only when its status names this Cosmos account (council round 1, Architect).
    Assert 'the deployer''s populate apply stamps the Cosmos account resource id, so its full sync counts as switch evidence' (
        $deployer -match '(?m)^\$accountResourceId = "/subscriptions/\$\(\(\[string\]\$apim\.id -split ''/''\)\[2\]\)/resourceGroups/\$ResourceGroup/providers/Microsoft\.DocumentDB/databaseAccounts/\$cosmosAccount"' -and
        $deployer -match 'apply-projection\.mjs --cosmos https://\$cosmosAccount\.documents\.azure\.com:443/ --tenant \$\(\$apim\.identity\.tenantId\) --account-resource-id \$accountResourceId --snapshot /work/snapshot\.json')
}
finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host ''
if ($fail) { Write-Host "$fail of $count assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "$count projection deployer compare assertion(s) passed." -ForegroundColor Green
exit 0
