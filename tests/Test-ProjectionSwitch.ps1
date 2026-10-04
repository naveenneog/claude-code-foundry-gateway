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
if ($fail) { Write-Host "$fail assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'Projection switch holds.' -ForegroundColor Green
exit 0
