# P95 projection switch (ADR-0050): admission over the action group and the job's settings, and the
# one switch function the deployer and the guided flow call.
#
# Offline. tests/TestProjectionFixture.ps1 answers every az, runner and ARM call and records it.

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$fail = 0
function Assert($Label, [bool]$Condition, $Detail = '') {
    if ($Condition) { Write-Host "  [OK]   $Label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $Label$(if ($Detail) { " - $Detail" })" -ForegroundColor Red; $script:fail++ }
}
function Capture([scriptblock]$Block) {
    $script:Failure = $null; $script:Result = $null
    try { $script:Result = & $Block } catch { $script:Failure = $_.Exception.Message }
}

. (Join-Path $PSScriptRoot 'TestProjectionFixture.ps1')
. (Join-Path $root 'scripts\ClaudeRunner.ps1')
. (Join-Path $root 'scripts\ClaudeProjectionChecks.ps1')

$digest = 'sha256:' + ('a' * 64)
function Set-GoodRenewalJob {
    $global:FixtureJob.properties.template.containers[0].image = "example.invalid/projection@$digest"
    $global:FixtureJob.properties.template.containers[0].command = @()
    $global:FixtureJob.properties.template.containers[0].args = @()
}
function Invoke-Admission([hashtable]$Extra = @{}) {
    $params = @{
        ResourceGroup = 'rg-p84'; RunnerName = 'runner-p84'; CosmosAccount = 'cosmos-p84fixture'; TenantId = $FixtureTenant
        AccountResourceId = $FixtureCosmosId; ReconcilerResourceId = $FixtureJobId; ImageDigest = $digest
        EntryPoint = 'node /app/sync/src/apply-projection.mjs'; ActionGroupResourceId = $FixtureActionGroupId
    }
    foreach ($key in $Extra.Keys) { $params[$key] = $Extra[$key] }
    Assert-ClaudeProjectionAdmission @params
}

Write-Host ''
Write-Host 'Projection switch - admission requires an alert receiver that receives (U119)' -ForegroundColor Cyan
Reset-ProjectionFixture
$groupOf = {
    param([bool]$Enabled, [object[]]$Emails, [object[]]$Sms = @())
    [pscustomobject]@{ properties = [pscustomobject]@{ enabled = $Enabled; emailReceivers = @($Emails); smsReceivers = @($Sms) } }
}
$enabledEmail = [pscustomobject]@{ name = 'email-0'; emailAddress = 'ops@example.invalid'; status = 'Enabled' }
Capture { Assert-ClaudeProjectionActionGroup -ActionGroup (& $groupOf $true @($enabledEmail)) -ActionGroupResourceId $FixtureActionGroupId }
Assert 'an enabled group with an Enabled email receiver is accepted' (-not $Failure) $Failure
foreach ($case in @(
        @{ Name = 'a disabled group'; Group = (& $groupOf $false @($enabledEmail)); Expect = 'disabled' }
        @{ Name = 'a group with no email receiver'; Group = (& $groupOf $true @()); Expect = 'no email receiver' }
        @{ Name = 'email receivers that are not Enabled'; Group = (& $groupOf $true @([pscustomobject]@{ status = 'Disabled' }, [pscustomobject]@{ status = 'NotSpecified' })); Expect = 'no email receiver' }
        @{ Name = 'a group whose only enabled receiver is SMS'; Group = (& $groupOf $true @() @([pscustomobject]@{ status = 'Enabled' })); Expect = 'no email receiver' }
    )) {
    Capture { Assert-ClaudeProjectionActionGroup -ActionGroup $case.Group -ActionGroupResourceId $FixtureActionGroupId }
    Assert "admission refuses $($case.Name), with the remedy" ($Failure -match '^Projection switch refused' -and $Failure -match $case.Expect -and $Failure -match 'Remedy') $Failure
}

Reset-ProjectionFixture
Set-GoodRenewalJob
Capture { Invoke-Admission }
$calls = $FixtureCalls -join "`n"
Assert 'admission reads the action group from ARM and admits a group that alerts someone' (-not $Failure -and $calls -match [regex]::Escape("HTTP Get https://management.azure.com${FixtureActionGroupId}?api-version=")) "$Failure | $calls"
foreach ($case in 'action-group-disabled', 'action-group-no-email', 'action-group-error') {
    Reset-ProjectionFixture $case
    Set-GoodRenewalJob
    Capture { Invoke-Admission }
    Assert "admission refuses before the runner reads Cosmos: $case" ($Failure -match '^Projection switch refused' -and (($FixtureCalls -join "`n") -notmatch 'container exec')) $Failure
}

Write-Host ''
Write-Host 'Projection switch - admission binds the evidence to the job settings' -ForegroundColor Cyan
$fixtureClient = '00000000-0000-4000-8000-000000000088'
Reset-ProjectionFixture
Set-GoodRenewalJob
Capture { Invoke-Admission @{ GatewayResourceId = $FixtureGatewayId.ToUpperInvariant(); StandardGroupId = $FixtureGroupId; PremiumGroupId = 'none'; IdentityClientId = $fixtureClient } }
$runner = @($FixtureCalls | Where-Object { $_ -match 'container exec' }) -join "`n"
Assert 'admission passes the job definition settings to the runner check' (-not $Failure -and $runner -match "--client-id $fixtureClient" -and $runner -match "--standard-group-id $FixtureGroupId" -and
    $runner -match '--premium-group-id none' -and $runner -match [regex]::Escape("--gateway-resource-id $FixtureGatewayId")) "$Failure | $runner"
foreach ($case in @(
        @{ Name = 'another gateway'; Extra = @{ GatewayResourceId = $FixtureGatewayId.Replace('apim-p84', 'apim-other') }; Expect = 'gateway' }
        @{ Name = 'another standard group'; Extra = @{ StandardGroupId = '00000000-0000-4000-8000-0000000000aa' }; Expect = 'standard' }
        @{ Name = 'a premium group where the job has none'; Extra = @{ PremiumGroupId = '00000000-0000-4000-8000-0000000000bb' }; Expect = 'premium' }
        @{ Name = 'another identity'; Extra = @{ IdentityClientId = '00000000-0000-4000-8000-0000000000cc' }; Expect = 'client id' }
    )) {
    Reset-ProjectionFixture
    Set-GoodRenewalJob
    Capture { Invoke-Admission $case.Extra }
    Assert "admission refuses a job bound to $($case.Name), before the runner" ($Failure -match '^Projection switch refused' -and $Failure -match $case.Expect -and (($FixtureCalls -join "`n") -notmatch 'container exec')) $Failure
}
Reset-ProjectionFixture
Set-GoodRenewalJob
$FixtureJob.properties.template.containers[0].env = @($FixtureJob.properties.template.containers[0].env | ForEach-Object {
        if ($_.name -eq 'PROJECTION_GATEWAY_RESOURCE_ID') { [pscustomobject]@{ name = $_.name; value = $FixtureGatewayId.Replace('rg-p84', 'rg(p84)') } } else { $_ } })
Capture { Invoke-Admission }
Assert 'a job gateway id with characters cmd.exe re-reads stops before the runner command' ($Failure -match '^Projection switch refused' -and (($FixtureCalls -join "`n") -notmatch 'container exec')) $Failure

Write-Host ''
Write-Host 'Projection switch - one function: drift check, compare, admission, backup, one write' -ForegroundColor Cyan
$switchModule = Join-Path $root 'scripts\ClaudeProjectionSwitch.ps1'
Assert 'the switch module exists' (Test-Path -LiteralPath $switchModule)
if (Test-Path -LiteralPath $switchModule) { . $switchModule }
$work = Join-Path ([IO.Path]::GetTempPath()) ('projection-switch-' + [guid]::NewGuid().ToString('N'))
$backupDir = Join-Path $work 'onboarding'
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
# Stands in for scripts/Compare-ClaudeEntitlement.ps1: records its turn, exports decisions, exits 1 on drift.
$compareStub = Join-Path $work 'compare-stub.ps1'
[IO.File]::WriteAllText($compareStub, @'
param([string]$ResourceGroup, [string]$ApimName, [string]$StandardGroup, [string]$PremiumGroup, [string]$ExportGatewayPath, [bool]$FailOnDrift = $true)
$global:FixtureCalls.Add("compare-stub $ResourceGroup $ApimName $StandardGroup $PremiumGroup")
if ($global:CompareDrift) { Write-Host 'Drift: 1 identity would lose access.'; exit 1 }
[IO.File]::WriteAllText($ExportGatewayPath, '{"kind":"claude-gateway-decisions","premium":[],"standard":[]}')
exit 0
'@)
$renewal = [pscustomobject]@{
    kind = 'claude-projection-renewal-receipt'; schemaVersion = 1; resourceGroup = 'rg-p84'; namePrefix = 'p84fixture'
    runnerName = 'aci-projtest-p84fixture'; cosmosAccount = 'cosmos-p84fixture'; accountResourceId = $FixtureCosmosId; tenantId = $FixtureTenant
    reconcilerResourceId = $FixtureJobId; imageDigest = $digest; entryPoint = 'node /app/sync/src/apply-projection.mjs'
    actionGroupResourceId = $FixtureActionGroupId; gatewayResourceId = $FixtureGatewayId; standardGroupId = $FixtureGroupId
    premiumGroupId = 'none'; identityClientId = $fixtureClient
}
function Invoke-Switch([hashtable]$Extra = @{}) {
    $params = @{ ResourceGroup = 'rg-p84'; ApimName = 'apim-p84'; Renewal = $renewal; StandardGroup = 'claude-code-standard'; PremiumGroup = 'none'; BackupDirectory = $backupDir; CompareScript = $compareStub }
    foreach ($key in $Extra.Keys) { $params[$key] = $Extra[$key] }
    Invoke-ClaudeProjectionSwitch @params
}
function Get-CallAt([string]$Pattern) { for ($i = 0; $i -lt $FixtureCalls.Count; $i++) { if ($FixtureCalls[$i] -match $Pattern) { return $i } }; return -1 }
function Get-Backups { @(Get-ChildItem -LiteralPath $backupDir -Filter 'projection-switch-apim-p84-*.json' -ErrorAction SilentlyContinue) }
function Get-Writes { @($FixtureCalls | Where-Object { $_ -match '^az (deployment group create|apim nv (update|create)|cosmosdb sql role assignment create|functionapp|ad app create)' }) }

Reset-ProjectionFixture
Set-GoodRenewalJob
$global:CompareDrift = $false
Get-Backups | Remove-Item -Force
Capture { Invoke-Switch }
$order = @((Get-CallAt '^compare-stub rg-p84 apim-p84 claude-code-standard none'), (Get-CallAt 'apply-projection\.mjs .*--compare /work/gateway-decisions\.json'), (Get-CallAt 'actionGroups/ag-projection-renewal'),
    (Get-CallAt 'check-admission\.mjs'), (Get-CallAt '^az apim nv show .*allow-standard'), (Get-CallAt '^az apim nv update .*--named-value-id entitlement-source --value projection'))
Assert 'the switch runs the drift check, the runner compare, admission, the backup and the write, in that order' (-not $Failure -and $order[0] -ge 0 -and
    (@(0..4 | Where-Object { $order[$_] -lt $order[$_ + 1] }).Count -eq 5)) "$Failure | positions $($order -join ',')"
Assert 'its only Azure write is entitlement-source' (@(Get-Writes).Count -eq 1 -and @(Get-Writes)[0] -match 'entitlement-source --value projection') ((Get-Writes) -join ' | ')
Assert 'nothing is deployed, published or applied' ((($FixtureCalls -join "`n") -notmatch '--snapshot') -and (($FixtureCalls -join "`n") -notmatch 'Sync-ClaudeProjection'))
$backups = Get-Backups
$backupJson = if ($backups.Count -eq 1) { Get-Content -LiteralPath $backups[0].FullName -Raw | ConvertFrom-Json } else { $null }
Assert 'the backup holds the entitlement named values from before the write' ($backupJson -and $backupJson.kind -eq 'claude-projection-switch-backup' -and $backupJson.namedValues.'entitlement-source' -eq 'named-value' -and
    @('allow-standard', 'allow-premium', 'bu-members' | Where-Object { $backupJson.namedValues.PSObject.Properties.Name -contains $_ }).Count -eq 3) "backups $($backups.Count)"
Assert 'the result names the backup and the rollback' ($Result -and $Result.Switched -eq $true -and $Result.BackupPath -eq $backups[0].FullName -and
    $Result.Rollback -match 'Sync-ClaudeAccess\.ps1' -and $Result.Rollback -match 'Compare-ClaudeEntitlement\.ps1 -FailOnDrift' -and $Result.Rollback -match 'named-value') "$($Result | ConvertTo-Json -Compress)"

foreach ($case in @(
        @{ Name = 'drift between the lists and Entra'; Fixture = 'healthy'; Drift = $true; Extra = @{}; Expect = 'drift'; RunnerIdle = $true }
        @{ Name = 'an admission refusal'; Fixture = 'action-group-disabled'; Drift = $false; Extra = @{}; Expect = 'disabled'; RunnerIdle = $false }
        @{ Name = 'a receipt for another gateway'; Fixture = 'healthy'; Drift = $false; Extra = @{ Renewal = ($renewal | Select-Object * -ExcludeProperty gatewayResourceId | Add-Member -NotePropertyName gatewayResourceId -NotePropertyValue $FixtureGatewayId.Replace('apim-p84', 'apim-other') -PassThru) }; Expect = 'apim-other'; RunnerIdle = $true }
    )) {
    Reset-ProjectionFixture $case.Fixture
    Set-GoodRenewalJob
    $global:CompareDrift = $case.Drift
    Get-Backups | Remove-Item -Force
    Capture { Invoke-Switch $case.Extra }
    $runnerRan = ($FixtureCalls -join "`n") -match 'container exec'
    Assert "a refusal for $($case.Name) leaves entitlement-source and writes no backup" ($Failure -match '^Projection switch refused' -and $Failure -match $case.Expect -and
        (Get-Writes).Count -eq 0 -and (Get-Backups).Count -eq 0 -and (-not $case.RunnerIdle -or -not $runnerRan)) "$Failure | writes $((Get-Writes).Count) backups $((Get-Backups).Count) runner $runnerRan"
}
$global:CompareDrift = $false
Reset-ProjectionFixture
Set-GoodRenewalJob
Get-Backups | Remove-Item -Force
Capture { Invoke-Switch @{ WhatIf = $true } }
Assert '-WhatIf runs the compare and admission and stops before the backup and the write' (-not $Failure -and $Result -and $Result.Switched -eq $false -and
    (Get-CallAt 'check-admission\.mjs') -ge 0 -and (Get-Writes).Count -eq 0 -and (Get-Backups).Count -eq 0) "$Failure"

Write-Host ''
Write-Host 'Projection switch - the deployer switch mode deploys, publishes and applies nothing (D5)' -ForegroundColor Cyan
$receiptPath = Join-Path $work 'projection-renewal-p84fixture.json'
[IO.File]::WriteAllText($receiptPath, ($renewal | ConvertTo-Json -Depth 5))
$deployer = Join-Path $root 'scripts\Deploy-ClaudeProjection.ps1'
$other = Join-Path $work 'projection-renewal-other.json'
[IO.File]::WriteAllText($other, (($renewal | Select-Object * -ExcludeProperty gatewayResourceId | Add-Member -NotePropertyName gatewayResourceId -NotePropertyValue $FixtureGatewayId.Replace('apim-p84', 'apim-other') -PassThru) | ConvertTo-Json -Depth 5))
Reset-ProjectionFixture
Set-GoodRenewalJob
Capture { & $deployer -ResourceGroup rg-p84 -ApimName apim-p84 -NamePrefix p84fixture -FlipAfterCleanCompare -RenewalReceiptPath $other -StandardGroup claude-code-standard -PremiumGroup none }
Assert 'the deployer switches through the shared function, which refuses a receipt for another gateway' ($Failure -match 'apim-other' -and (Get-Writes).Count -eq 0) "$Failure"
Reset-ProjectionFixture
Set-GoodRenewalJob
Capture { & $deployer -ResourceGroup rg-p84 -ApimName apim-p84 -NamePrefix p84fixture -FlipAfterCleanCompare -RenewalReceiptPath $receiptPath -StandardGroup claude-code-standard -PremiumGroup none }
$deployCalls = $FixtureCalls -join "`n"
Assert 'the deployer switch mode makes no deployment, registration, publish, role assignment, export or apply' ($deployCalls -notmatch 'deployment group create|ad app create|functionapp|cosmosdb sql role assignment|--snapshot' -and
    @($FixtureCalls | Where-Object { $_ -match '^az apim nv (update|create)' -and $_ -notmatch 'entitlement-source' }).Count -eq 0) "$Failure"
Reset-ProjectionFixture
Capture { & $deployer -ResourceGroup rg-p84 -ApimName apim-p84 -NamePrefix p84fixture -FlipAfterCleanCompare -RenewalReceiptPath (Join-Path $work 'missing.json') }
Assert 'a missing receipt and no renewal parameters refuse before any Azure call, with the remedy' ($Failure -match 'P86 admission requires' -and $Failure -match 'Deploy-ClaudeProjectionRenewal\.ps1' -and $Failure -match '60-90 minutes' -and $FixtureCalls.Count -eq 0) "$Failure | calls $($FixtureCalls.Count)"

Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($fail) { Write-Host "$fail assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'Projection switch holds.' -ForegroundColor Green
exit 0
