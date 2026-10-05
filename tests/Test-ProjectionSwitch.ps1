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
Reset-ProjectionFixture 'job-error'
Set-GoodRenewalJob
Capture { Invoke-Admission }
Assert 'a renewal job that cannot be read refuses with the job id and the remedy, before the runner' ($Failure -match '^Projection switch refused: could not read the renewal job' -and
    $Failure -match [regex]::Escape($FixtureJobId) -and $Failure -match 'Remedy: .*Deploy-ClaudeProjectionRenewal\.ps1' -and (($FixtureCalls -join "`n") -notmatch 'container exec')) $Failure

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
# Council round 1: the job must renew the Cosmos account and tenant that admission reads and the receipt names.
foreach ($case in @(
        @{ Name = 'another Cosmos account'; Env = 'PROJECTION_ACCOUNT_RESOURCE_ID'; Value = $FixtureCosmosId.Replace('cosmos-p84fixture', 'cosmos-other'); Expect = 'Cosmos account' }
        @{ Name = 'another tenant'; Env = 'PROJECTION_TENANT_ID'; Value = $FixtureApp; Expect = 'tenant' }
    )) {
    Reset-ProjectionFixture
    Set-GoodRenewalJob
    $FixtureJob.properties.template.containers[0].env = @($FixtureJob.properties.template.containers[0].env | ForEach-Object {
            if ($_.name -eq $case.Env) { [pscustomobject]@{ name = $_.name; value = $case.Value } } else { $_ } })
    Capture { Invoke-Admission }
    Assert "admission refuses a job that renews $($case.Name) than the one it reads, before the runner" ($Failure -match '^Projection switch refused' -and $Failure -match $case.Expect -and $Failure -match 'Remedy' -and (($FixtureCalls -join "`n") -notmatch 'container exec')) $Failure
}

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
Reset-ProjectionFixture
Set-GoodRenewalJob
Get-Backups | Remove-Item -Force
$switchLines = @(try { Invoke-Switch 6>&1 | Where-Object { $_ -is [Management.Automation.InformationRecord] } | ForEach-Object { [string]$_.MessageData } } catch { "THREW $($_.Exception.Message)" })
Assert 'the success line names how many renewals admission counted' (($switchLines -join "`n") -match 'entitlement-source is projection after admission over 3 renewals') (($switchLines | Select-Object -Last 3) -join ' / ')
Get-Backups | Remove-Item -Force

foreach ($case in @(
        @{ Name = 'drift between the lists and Entra'; Fixture = 'healthy'; Drift = $true; Extra = @{}; Expect = 'drift'; RunnerIdle = $true; AdmissionIdle = $true }
        @{ Name = 'a projection that differs from the gateway'; Fixture = 'compare-differs'; Drift = $false; Extra = @{}; Expect = "projection and the gateway's decisions differ for 1 of 2 identities \(missing 1\)"; RunnerIdle = $false; AdmissionIdle = $true }
        @{ Name = 'a runner compare that fails'; Fixture = 'compare-error'; Drift = $false; Extra = @{}; Expect = 'runner compare did not complete'; RunnerIdle = $false; AdmissionIdle = $true }
        @{ Name = 'a runner answer that is not a compare'; Fixture = 'compare-no-mode'; Drift = $false; Extra = @{}; Expect = 'runner compare did not complete'; RunnerIdle = $false; AdmissionIdle = $true }
        @{ Name = 'an admission refusal'; Fixture = 'action-group-disabled'; Drift = $false; Extra = @{}; Expect = 'disabled'; RunnerIdle = $false; AdmissionIdle = $false }
        @{ Name = 'a receipt for another gateway'; Fixture = 'healthy'; Drift = $false; Extra = @{ Renewal = ($renewal | Select-Object * -ExcludeProperty gatewayResourceId | Add-Member -NotePropertyName gatewayResourceId -NotePropertyValue $FixtureGatewayId.Replace('apim-p84', 'apim-other') -PassThru) }; Expect = 'apim-other'; RunnerIdle = $true; AdmissionIdle = $true }
    )) {
    Reset-ProjectionFixture $case.Fixture
    Set-GoodRenewalJob
    $global:CompareDrift = $case.Drift
    Get-Backups | Remove-Item -Force
    Capture { Invoke-Switch $case.Extra }
    $runnerRan = ($FixtureCalls -join "`n") -match 'container exec'
    $admissionRan = ($FixtureCalls -join "`n") -match 'actionGroups/|check-admission\.mjs'
    Assert "a refusal for $($case.Name) leaves entitlement-source and writes no backup" ($Failure -match '^Projection switch refused' -and $Failure -match $case.Expect -and
        (Get-Writes).Count -eq 0 -and (Get-Backups).Count -eq 0 -and (-not $case.RunnerIdle -or -not $runnerRan) -and (-not $case.AdmissionIdle -or -not $admissionRan)) "$Failure | writes $((Get-Writes).Count) backups $((Get-Backups).Count) runner $runnerRan admission $admissionRan"
}
$global:CompareDrift = $false
Reset-ProjectionFixture
Set-GoodRenewalJob
Get-Backups | Remove-Item -Force
Capture { Invoke-Switch @{ WhatIf = $true } }
Assert '-WhatIf runs the compare and admission and stops before the backup and the write' (-not $Failure -and $Result -and $Result.Switched -eq $false -and
    (Get-CallAt 'check-admission\.mjs') -ge 0 -and (Get-Writes).Count -eq 0 -and (Get-Backups).Count -eq 0) "$Failure"
# -Confirm asks about the write only (council round 1, Coder). In a runspace with no host the first prompt
# throws, so the calls made before it show which question came first.
$confirmShell = [powershell]::Create()
$null = $confirmShell.AddScript({
        param($Root, $Renewal, $CompareStub, $BackupDir)
        $ErrorActionPreference = 'Stop'
        . (Join-Path $Root 'tests\TestProjectionFixture.ps1')
        . (Join-Path $Root 'scripts\ClaudeProjectionSwitch.ps1')
        Reset-ProjectionFixture
        $global:FixtureJob.properties.template.containers[0].image = "example.invalid/projection@$($Renewal.imageDigest)"
        $global:FixtureJob.properties.template.containers[0].command = @()
        $global:FixtureJob.properties.template.containers[0].args = @()
        $failure = try {
            $null = Invoke-ClaudeProjectionSwitch -ResourceGroup rg-p84 -ApimName apim-p84 -Renewal $Renewal -StandardGroup claude-code-standard -PremiumGroup none -BackupDirectory $BackupDir -CompareScript $CompareStub -Confirm
            ''
        }
        catch { $_.Exception.Message }
        [pscustomobject]@{ Failure = $failure; Calls = @($global:FixtureCalls) }
    }).AddArgument($root).AddArgument($renewal).AddArgument($compareStub).AddArgument($backupDir)
$confirmRun = @($confirmShell.Invoke())[0]
$confirmShell.Dispose()
$confirmCalls = @($confirmRun.Calls) -join "`n"
Assert '-Confirm asks about the write after admission, not about working files before it' ($confirmRun.Failure -match 'prompts the user' -and $confirmRun.Failure -match 'entitlement-source' -and
    $confirmCalls -match 'check-admission\.mjs' -and $confirmCalls -notmatch 'apim nv update' -and (Get-Backups).Count -eq 0) "$($confirmRun.Failure)"

Write-Host ''
Write-Host 'Projection switch - the receipt is checked before any call, and bound to the gateway (council round 1)' -ForegroundColor Cyan
# Receipt values reach az.cmd arguments (re-read by cmd.exe), the runner's command line (split on spaces,
# URL-decoded) and ARM URLs (which carry the management token).
function New-RenewalWith([hashtable]$Change) {
    $copy = $renewal | Select-Object *
    foreach ($key in $Change.Keys) { $copy | Add-Member -NotePropertyName $key -NotePropertyValue $Change[$key] -Force }
    $copy
}
function Get-Refusals([object[]]$Cases) {
    @(foreach ($case in $Cases) {
            Reset-ProjectionFixture
            Set-GoodRenewalJob
            Get-Backups | Remove-Item -Force
            Capture { Invoke-Switch @{ Renewal = (New-RenewalWith $case.Change) } }
            $field = @($case.Change.Keys)[0]
            if (-not ($Failure -match '^Projection switch refused' -and $Failure -match [regex]::Escape($case.Expect) -and $FixtureCalls.Count -eq $case.Calls -and (Get-Backups).Count -eq 0)) {
                "$field=$($case.Change[$field]) (calls $($FixtureCalls.Count): $Failure)"
            }
        })
}
$unsafe = Get-Refusals @(
    @{ Change = @{ resourceGroup = 'rg-p84&whoami' }; Expect = 'resourceGroup'; Calls = 0 }
    @{ Change = @{ runnerName = 'aci-projtest-p84fixture&whoami' }; Expect = 'runnerName'; Calls = 0 }
    @{ Change = @{ cosmosAccount = 'cosmos-p84fixture^whoami' }; Expect = 'cosmosAccount'; Calls = 0 }
    @{ Change = @{ tenantId = "$FixtureTenant&whoami" }; Expect = 'tenantId'; Calls = 0 }
    @{ Change = @{ entryPoint = 'node /app/sync/src/apply-projection.mjs" & whoami & "' }; Expect = 'entryPoint'; Calls = 0 }
    @{ Change = @{ accountResourceId = "$FixtureCosmosId%26whoami" }; Expect = 'accountResourceId'; Calls = 0 }
    @{ Change = @{ gatewayResourceId = "$FixtureGatewayId|whoami" }; Expect = 'gatewayResourceId'; Calls = 0 }
    @{ Change = @{ namePrefix = 'p84(fixture)' }; Expect = 'namePrefix'; Calls = 0 }
)
Assert 'a receipt value with characters cmd.exe or the runner re-reads is refused before any call' (-not $unsafe.Count) ($unsafe -join ' || ')
$offArm = Get-Refusals @(
    @{ Change = @{ reconcilerResourceId = '@attacker.example/subscriptions/x' }; Expect = 'reconcilerResourceId'; Calls = 0 }
    @{ Change = @{ actionGroupResourceId = "$FixtureActionGroupId@attacker.example" }; Expect = 'actionGroupResourceId'; Calls = 0 }
    @{ Change = @{ actionGroupResourceId = "$FixtureActionGroupId#x" }; Expect = 'actionGroupResourceId'; Calls = 0 }
)
Assert 'a receipt resource id that would send the management token to another host is refused before any call' (-not $offArm.Count) ($offArm -join ' || ')
$malformed = Get-Refusals @(
    @{ Change = @{ kind = 'claude-projection-switch-backup' }; Expect = 'version 1 renewal receipt'; Calls = 0 }
    @{ Change = @{ schemaVersion = 2 }; Expect = 'version 1 renewal receipt'; Calls = 0 }
    @{ Change = @{ imageDigest = 'sha256:' + ('A' * 64) }; Expect = 'imageDigest'; Calls = 0 }
    @{ Change = @{ standardGroupId = 'claude-code-standard' }; Expect = 'standardGroupId'; Calls = 0 }
    @{ Change = @{ premiumGroupId = 'all' }; Expect = 'premiumGroupId'; Calls = 0 }
    @{ Change = @{ identityClientId = 'not-a-guid' }; Expect = 'identityClientId'; Calls = 0 }
)
Assert 'a receipt of another kind or version, or with a malformed digest or id, is refused before any call' (-not $malformed.Count) ($malformed -join ' || ')
$otherSubscription = '00000000-0000-4000-8000-000000000099'
$inconsistent = Get-Refusals @(
    @{ Change = @{ actionGroupResourceId = $FixtureActionGroupId.Replace('/resourceGroups/rg-p84/', '/resourceGroups/rg-other/') }; Expect = 'resource group'; Calls = 0 }
    @{ Change = @{ accountResourceId = $FixtureCosmosId.Replace('cosmos-p84fixture', 'cosmos-other') }; Expect = 'cosmosAccount'; Calls = 0 }
    @{ Change = @{ reconcilerResourceId = $FixtureJobId.Replace($FixtureSubscription, $otherSubscription) }; Expect = 'subscription'; Calls = 0 }
    @{ Change = @{ reconcilerResourceId = $FixtureJobId.Replace($FixtureSubscription, $otherSubscription); accountResourceId = $FixtureCosmosId.Replace($FixtureSubscription, $otherSubscription); actionGroupResourceId = $FixtureActionGroupId.Replace($FixtureSubscription, $otherSubscription) }; Expect = 'subscription'; Calls = 0 }
)
Assert "a receipt whose resources are outside the gateway's subscription or the receipt's resource group, or name another Cosmos account, is refused before any call" (-not $inconsistent.Count) ($inconsistent -join ' || ')
$unbound = Get-Refusals @(
    @{ Change = @{ tenantId = $FixtureApp }; Expect = 'tenant'; Calls = 1 }
)
Assert "a receipt for another tenant than the gateway's managed identity stops after reading the gateway" (-not $unbound.Count) ($unbound -join ' || ')
Reset-ProjectionFixture
Set-GoodRenewalJob
Capture { Invoke-Admission @{ ActionGroupResourceId = '@attacker.example/x' } }
Assert 'admission sends the management token only to management.azure.com' ($Failure -match '^Projection switch refused' -and $Failure -match 'not an Azure resource id' -and $FixtureCalls.Count -eq 0) "$Failure | calls $($FixtureCalls.Count)"
$runnerRefusals = @(foreach ($case in @(
            @{ ResourceGroup = 'rg-p84'; Name = 'runner-p84'; Command = 'node "x"' }
            @{ ResourceGroup = 'rg-p84'; Name = 'runner-p84'; Command = 'node a+b' }
            @{ ResourceGroup = 'rg-p84'; Name = 'runner-p84'; Command = 'node a%20b' }
            @{ ResourceGroup = 'rg-p84&whoami'; Name = 'runner-p84'; Command = 'node --version' }
            @{ ResourceGroup = 'rg-p84'; Name = 'runner^p84'; Command = 'node --version' }
        )) {
        Reset-ProjectionFixture
        Capture { Invoke-RunnerCommand @case }
        if (-not ($Failure -match '^Runner command refused' -and $FixtureCalls.Count -eq 0)) { "$($case.ResourceGroup) $($case.Name) '$($case.Command)' (calls $($FixtureCalls.Count): $Failure)" }
    })
Assert 'a runner command or target that the runner or cmd.exe would alter is refused before az' (-not $runnerRefusals.Count) ($runnerRefusals -join ' || ')
$callerRefusals = @(foreach ($case in @(@{ ResourceGroup = 'rg-p84&whoami' }, @{ ApimName = 'apim-p84^x' })) {
        Reset-ProjectionFixture
        Set-GoodRenewalJob
        Capture { Invoke-Switch $case }
        if (-not ($Failure -match '^Projection switch refused' -and $FixtureCalls.Count -eq 0)) { "$(@($case.Values)[0]) (calls $($FixtureCalls.Count): $Failure)" }
    })
Assert "the switch's own resource group and gateway name are checked before any call" (-not $callerRefusals.Count) ($callerRefusals -join ' || ')

Write-Host ''
Write-Host 'Projection switch - the gateway calls the resolver that reads the renewed Cosmos account (council round 1)' -ForegroundColor Cyan
foreach ($case in @(
        @{ Name = 'a gateway that still calls the resolver placeholder'; Fixture = 'resolver-placeholder'; Expect = 'entitlement-resolver-url' }
        @{ Name = 'a gateway that calls another resolver'; Fixture = 'resolver-other-url'; Expect = 'entitlement-resolver-url' }
        @{ Name = 'a resolver that reads another Cosmos account'; Fixture = 'resolver-other-cosmos'; Expect = 'reads Cosmos account cosmos-other' }
        @{ Name = 'no resolver deployment for the receipt'; Fixture = 'resolver-missing'; Expect = 'could not read the resolver deployment projection-resolver-p84fixture' }
        @{ Name = 'a gateway that asks for another token audience'; Fixture = 'resolver-other-audience'; Expect = 'entitlement-resolver-audience' }
        @{ Name = 'a resolver site whose live settings read another Cosmos account'; Fixture = 'resolver-live-cosmos'; Expect = 'reads Cosmos account cosmos-other.documents.azure.com' }
        @{ Name = 'a resolver site that serves another host name'; Fixture = 'resolver-live-host'; Expect = 'func-resolver-p84fixture-a1b2.eastus2-01.azurewebsites.net' }
        @{ Name = 'resolver settings that cannot be read'; Fixture = 'resolver-settings-error'; Expect = 'Microsoft.Web/sites/config/list/action' }
    )) {
    Reset-ProjectionFixture $case.Fixture
    Set-GoodRenewalJob
    Get-Backups | Remove-Item -Force
    Capture { Invoke-Switch }
    Assert "the switch refuses $($case.Name), before the drift check" ($Failure -match '^Projection switch refused' -and $Failure -match [regex]::Escape($case.Expect) -and $Failure -match 'Remedy' -and
        (Get-CallAt '^compare-stub') -lt 0 -and (Get-Writes).Count -eq 0 -and (Get-Backups).Count -eq 0) "$Failure | compare at $(Get-CallAt '^compare-stub')"
}

# The real scripts/Compare-ClaudeEntitlement.ps1 against chosen gateway lists. The fixture directory has
# one standard member and no group named 'none'. 'clean' lists hold that member; 'drift' lists do not.
$global:FixtureAz = ${function:az}
$global:FixtureRest = ${function:Invoke-RestMethod}
$global:ListMode = $null
function az {
    $line = $args -join ' '
    if ($global:ListMode -and $line -like 'apim nv show*') {
        $global:FixtureCalls.Add("az $line"); $global:LASTEXITCODE = 0
        $standard = if ($global:ListMode -eq 'clean') { ",$FixtureApp," } else { ',' }
        $map = @{ 'allow-standard' = $standard; 'allow-premium' = ','; 'bu-members' = ','; 'entitlement-source' = 'named-value'; 'entitlement-resolver-url' = $FixtureResolverUrl; 'entitlement-resolver-audience' = $FixtureResolverAudience }
        $id = $args[([array]::IndexOf($args, '--named-value-id') + 1)]
        if ($line -match '--query value') { return [string]$map[$id] }
        return (@{ name = $id; value = $map[$id]; secret = $false } | ConvertTo-Json -Compress)
    }
    & $global:FixtureAz @args
}
function Invoke-RestMethod {
    param($Uri, $Headers, $Method, $ErrorAction, $TimeoutSec, $Body, $ContentType, [switch]$UseBasicParsing)
    if ($global:ListMode -and [uri]::UnescapeDataString([string]$Uri) -match "displayName eq 'none'") { $global:FixtureCalls.Add("HTTP $Method none-group"); return [pscustomobject]@{ value = @() } }
    & $global:FixtureRest @PSBoundParameters
}
$repoBackups = { @(Get-ChildItem -LiteralPath (Join-Path $root 'onboarding') -Filter 'projection-switch-apim-p84-*.json' -ErrorAction SilentlyContinue) }

Write-Host ''
Write-Host 'Projection switch - the deployer switch mode deploys, publishes and applies nothing (D5)' -ForegroundColor Cyan
$receiptPath = Join-Path $work 'projection-renewal-p84fixture.json'
[IO.File]::WriteAllText($receiptPath, ($renewal | ConvertTo-Json -Depth 5))
$deployer = Join-Path $root 'scripts\Deploy-ClaudeProjection.ps1'
$other = Join-Path $work 'projection-renewal-other.json'
[IO.File]::WriteAllText($other, (($renewal | Select-Object * -ExcludeProperty gatewayResourceId | Add-Member -NotePropertyName gatewayResourceId -NotePropertyValue $FixtureGatewayId.Replace('apim-p84', 'apim-other') -PassThru) | ConvertTo-Json -Depth 5))
function Invoke-Deployer([string]$Receipt, [string]$Lists) {
    Reset-ProjectionFixture
    Set-GoodRenewalJob
    $global:ListMode = $Lists
    $before = @(& $repoBackups | ForEach-Object FullName)
    Capture { & $deployer -ResourceGroup rg-p84 -ApimName apim-p84 -NamePrefix p84fixture -FlipAfterCleanCompare -RenewalReceiptPath $Receipt -StandardGroup claude-code-standard -PremiumGroup none }
    $script:Made = @(& $repoBackups | Where-Object { $before -notcontains $_.FullName })
    $script:Made | Remove-Item -Force -ErrorAction SilentlyContinue
    $global:ListMode = $null
}
Invoke-Deployer $other 'clean'
Assert 'the deployer switches through the shared function, which refuses a receipt for another gateway' ($Failure -match 'apim-other' -and (Get-Writes).Count -eq 0 -and $Made.Count -eq 0) "$Failure"
Invoke-Deployer $receiptPath 'drift'
Assert 'the deployer switch mode makes no deployment, registration, publish, role assignment, export or apply' ($Failure -match 'drift' -and
    ($FixtureCalls -join "`n") -notmatch 'deployment group create|ad app create|functionapp|cosmosdb sql role assignment|--snapshot' -and (Get-Writes).Count -eq 0 -and $Made.Count -eq 0) "$Failure"
Invoke-Deployer $receiptPath 'clean'
$deployOrder = @((Get-CallAt 'apim nv show .*allow-premium -o json'), (Get-CallAt 'apply-projection\.mjs .*--compare'), (Get-CallAt 'check-admission\.mjs'), (Get-CallAt '^az apim nv update .*entitlement-source --value projection'))
Assert 'the deployer switches end to end through the real drift check: compare, admission, backup, one write' (-not $Failure -and $deployOrder[0] -ge 0 -and
    (@(0..2 | Where-Object { $deployOrder[$_] -lt $deployOrder[$_ + 1] }).Count -eq 3) -and @(Get-Writes).Count -eq 1 -and $Made.Count -eq 1) "$Failure | positions $($deployOrder -join ',') | backups $($Made.Count)"
Reset-ProjectionFixture
Capture { & $deployer -ResourceGroup rg-p84 -ApimName apim-p84 -NamePrefix p84fixture -FlipAfterCleanCompare -RenewalReceiptPath (Join-Path $work 'missing.json') }
Assert 'a missing receipt and no renewal parameters refuse before any Azure call, with the remedy' ($Failure -match 'P86 admission requires' -and $Failure -match 'Deploy-ClaudeProjectionRenewal\.ps1' -and $Failure -match '60-90 minutes' -and $FixtureCalls.Count -eq 0) "$Failure | calls $($FixtureCalls.Count)"
Reset-ProjectionFixture
Capture { & $deployer -ResourceGroup rg-p84 -ApimName apim-p84 -NamePrefix p84fixture -FlipAfterCleanCompare -RenewalReceiptPath $receiptPath -RenewalImageDigest ('sha256:' + ('b' * 64)) }
Assert 'a renewal parameter that differs from the receipt refuses before any Azure call, with the remedy' ($Failure -match '-RenewalImageDigest is sha256:b{64}, but the renewal receipt .* records sha256:a{64}\. Remedy: pass the receipt''s value, or leave the parameter out' -and $FixtureCalls.Count -eq 0) "$Failure | calls $($FixtureCalls.Count)"
Reset-ProjectionFixture
Capture { & $deployer -ResourceGroup rg-p84 -ApimName apim-p84 -NamePrefix p84fixture -FlipAfterCleanCompare -RenewalReceiptPath $receiptPath -RenewalEntryPoint 'node /app/other.mjs' }
Assert 'a -RenewalEntryPoint that differs from the receipt refuses before any Azure call' ($Failure -match '-RenewalEntryPoint is node /app/other\.mjs, but the renewal receipt .* records node /app/sync/src/apply-projection\.mjs' -and $FixtureCalls.Count -eq 0) "$Failure | calls $($FixtureCalls.Count)"
# Council round 1 (QA): a receipt file that is not a receipt, and reads that find nothing.
$badReceipts = @(foreach ($case in @(
            @{ Name = 'not JSON'; Text = '{ not json'; Expect = 'is not JSON' }
            @{ Name = 'another kind'; Text = (($renewal | Select-Object * -ExcludeProperty kind | Add-Member -NotePropertyName kind -NotePropertyValue 'claude-projection-switch-backup' -PassThru) | ConvertTo-Json -Depth 5); Expect = 'is not a version 1 renewal receipt' }
            @{ Name = 'no runner'; Text = (($renewal | Select-Object * -ExcludeProperty runnerName) | ConvertTo-Json -Depth 5); Expect = 'has no runnerName' }
        )) {
        $badPath = Join-Path $work ("receipt-$($case.Name -replace ' ', '-').json")
        [IO.File]::WriteAllText($badPath, $case.Text)
        Reset-ProjectionFixture
        Capture { & $deployer -ResourceGroup rg-p84 -ApimName apim-p84 -NamePrefix p84fixture -FlipAfterCleanCompare -RenewalReceiptPath $badPath }
        if (-not ($Failure -match '^Projection switch refused' -and $Failure -match [regex]::Escape($case.Expect) -and $Failure -match 'Deploy-ClaudeProjectionRenewal\.ps1' -and $FixtureCalls.Count -eq 0)) { "$($case.Name): $Failure (calls $($FixtureCalls.Count))" }
    })
Assert 'a receipt file that is not JSON, is another kind or lacks a field refuses before any Azure call, with the remedy' (-not $badReceipts.Count) ($badReceipts -join ' || ')
Reset-ProjectionFixture 'standard-missing'
Set-GoodRenewalJob
Capture { Invoke-Switch }
Assert 'a tier group that Microsoft Graph does not find refuses before the drift check' ($Failure -match "^Projection switch refused: the standard tier group 'claude-code-standard' was not found" -and (Get-CallAt '^compare-stub') -lt 0 -and (Get-Writes).Count -eq 0) "$Failure"
Reset-ProjectionFixture 'apim-empty'
Set-GoodRenewalJob
Capture { Invoke-Switch }
Assert 'a gateway read that returns no id refuses before anything else is read' ($Failure -match '^Projection switch refused: API Management apim-p84 in rg-p84 could not be read' -and $FixtureCalls.Count -eq 1) "$Failure | calls $($FixtureCalls.Count)"
# Council round 1: the deployer's normal run points the gateway at the resolver it deployed, which the
# switch then requires (entitlement-source stays named-value, so the gateway does not call it yet).
$deploySource = Get-Content -LiteralPath $deployer -Raw
$deployAst = [Management.Automation.Language.Parser]::ParseInput($deploySource, [ref]$null, [ref]$null)
$pointStep = @($deployAst.FindAll({ param($node) $node -is [Management.Automation.Language.IfStatementAst] -and $node.Clauses[0].Item1.Extent.Text -match 'ShouldProcess' -and $node.Extent.Text -match 'entitlement-resolver-url' }, $true))
$pointAt = if ($pointStep.Count -eq 1) { $deploySource.IndexOf($pointStep[0].Extent.Text) } else { -1 }
Assert 'the deployer points the gateway at the resolver it deployed, after the resolver and before population' ($pointStep.Count -eq 1 -and
    $pointAt -gt $deploySource.IndexOf("Step 'Publish resolver code'") -and $pointAt -lt $deploySource.IndexOf("Step 'Populate projection from Entra'")) "decisions $($pointStep.Count) at $pointAt"
if ($pointStep.Count -eq 1) {
    Reset-ProjectionFixture
    $ResourceGroup = 'rg-p84'; $ApimName = 'apim-p84'
    $resolverUrl = 'https://func-resolver-p84fixture.azurewebsites.net/api'; $resolverAudience = "api://$FixtureApp"
    $pointBlock = [scriptblock]::Create($pointStep[0].Extent.Text.Replace($pointStep[0].Clauses[0].Item1.Extent.Text, '$true'))
    Capture { & $pointBlock }
    $pointCalls = $FixtureCalls -join "`n"
    Assert 'it writes entitlement-resolver-url and entitlement-resolver-audience from the resolver deployment outputs' (-not $Failure -and
        $pointCalls -match [regex]::Escape("--named-value-id entitlement-resolver-url --value $resolverUrl") -and $pointCalls -match [regex]::Escape("--named-value-id entitlement-resolver-audience --value $resolverAudience")) "$Failure | $pointCalls"
    Remove-Variable ResourceGroup, ApimName, resolverUrl, resolverAudience -ErrorAction SilentlyContinue
}
# Council round 2: on a gateway that serves from the projection, the gateway calls these values for every
# request, so the deployer's normal run must not point it at another resolver. The whole step runs from the
# deployer's own text, with its decision taken as yes.
$stepStart = $deploySource.IndexOf("Step 'Point the gateway at the resolver'")
$stepEnd = $deploySource.IndexOf('Ok "entitlement-resolver-url is')
$stepText = if ($stepStart -ge 0 -and $stepEnd -gt $stepStart) { $deploySource.Substring($stepStart, $stepEnd - $stepStart) } else { '' }
$stepText = $stepText.Replace("`$PSCmdlet.ShouldProcess(`$ApimName, 'set entitlement-resolver-url and entitlement-resolver-audience to the deployed resolver')", '$true')
$pointRefusals = @(foreach ($case in @(
            @{ Name = 'a projection gateway is not pointed at another resolver'; Fixture = 'source-projection'; Url = 'https://func-resolver-other.azurewebsites.net/api'; Expect = 'Refusing'; Writes = 0 }
            @{ Name = 'a projection gateway already on this resolver is left as it is'; Fixture = 'source-projection'; Url = 'https://func-resolver-p84fixture.azurewebsites.net/api'; Expect = ''; Writes = 0 }
            @{ Name = 'a named-value gateway is pointed at the new resolver'; Fixture = 'healthy'; Url = 'https://func-resolver-other.azurewebsites.net/api'; Expect = ''; Writes = 2 }
        )) {
        Reset-ProjectionFixture $case.Fixture
        $stepOutcome = & {
            function Step { }
            $ResourceGroup = 'rg-p84'; $ApimName = 'apim-p84'; $resolverUrl = $case.Url; $resolverAudience = "api://$FixtureApp"
            try { & ([scriptblock]::Create($stepText)) | Out-Null; '' } catch { $_.Exception.Message }
        }
        $writes = @($FixtureCalls | Where-Object { $_ -match '^az apim nv update' }).Count
        $ok = $stepText -and $writes -eq $case.Writes -and $(if ($case.Expect) { $stepOutcome -match "^$($case.Expect)" -and $stepOutcome -match 'Sync-ClaudeAccess\.ps1' } else { -not $stepOutcome })
        if (-not $ok) { "$($case.Name): writes $writes, outcome '$stepOutcome'" }
    })
Assert "the deployer's resolver step never redirects a gateway that serves from the projection" ($stepText -and -not $pointRefusals.Count) ($pointRefusals -join ' || ')
Reset-ProjectionFixture
Capture { @(1..2 | ForEach-Object { Save-ClaudeProjectionSwitchBackup -ResourceGroup rg-p84 -ApimName apim-p84 -GatewayResourceId $FixtureGatewayId -Directory $backupDir }) }
Assert 'two backups in the same second are two files; neither overwrites the other' (-not $Failure -and @($Result | Select-Object -Unique).Count -eq 2 -and @($Result | Where-Object { Test-Path -LiteralPath $_ }).Count -eq 2) "$Failure"
Write-Host ''
Write-Host 'Projection switch - the guided flow finds the receipt and switches through the same function (D9)' -ForegroundColor Cyan
. (Join-Path $root 'scripts\flow\Entitlement.ps1')
$receipts = Join-Path $work 'receipts'
New-Item -ItemType Directory -Force -Path $receipts | Out-Null
Capture { Find-ClaudeFlowProjectionRenewal -Directory $receipts -GatewayResourceId $FixtureGatewayId }
Assert 'no receipt names the gateway: no evidence, with the remedy' (-not $Failure -and -not $Result.Receipt -and $Result.Problem -match 'no renewal receipt' -and $Result.Problem -match 'Deploy-ClaudeProjectionRenewal\.ps1') "$Failure $($Result.Problem)"
[IO.File]::WriteAllText((Join-Path $receipts 'projection-renewal-other.json'), (Get-Content -LiteralPath $other -Raw))
[IO.File]::WriteAllText((Join-Path $receipts 'projection-renewal-p84fixture.json'), (Get-Content -LiteralPath $receiptPath -Raw))
Capture { Find-ClaudeFlowProjectionRenewal -Directory $receipts -GatewayResourceId $FixtureGatewayId.ToUpperInvariant() }
Assert 'the one receipt that names the gateway is the evidence; a receipt for another gateway is not' (-not $Failure -and $Result.Receipt.reconcilerResourceId -eq $FixtureJobId -and -not $Result.Problem) "$Failure $($Result.Problem)"
[IO.File]::WriteAllText((Join-Path $receipts 'projection-renewal-again.json'), (Get-Content -LiteralPath $receiptPath -Raw))
Capture { Find-ClaudeFlowProjectionRenewal -Directory $receipts -GatewayResourceId $FixtureGatewayId }
Assert 'two receipts for one gateway are ambiguous and give no evidence' (-not $Failure -and -not $Result.Receipt -and $Result.Problem -match '2 renewal receipts') "$Failure $($Result.Problem)"

# Live discovery reads receipts under the repository's onboarding/; here that root is a temporary directory.
$discoveryRoot = Join-Path $work 'discovery-root'
$discoveryReceipts = Join-Path $discoveryRoot 'onboarding'
New-Item -ItemType Directory -Force -Path $discoveryReceipts | Out-Null
$realRepoRoot = ${function:Get-ClaudeFlowLifecycleRepoRoot}
function Invoke-LiveDiscovery {
    Set-Item -Path function:global:Get-ClaudeFlowLifecycleRepoRoot -Value ([scriptblock]::Create("'$discoveryRoot'"))
    try {
        & {
            function az {
                $joined = $args -join ' '
                if ($joined -like 'apim show*') { return (@{ id = $FixtureGatewayId; location = 'eastus2'; sku = @{ name = 'BasicV2'; capacity = 1 } } | ConvertTo-Json -Compress) }
                if ($joined -like 'apim nv list*') { return '[]' }
                if ($joined -like 'account get-access-token*') { return 'token' }
                throw "unexpected az $joined"
            }
            function Invoke-RestMethod { [pscustomobject]@{ properties = [pscustomobject]@{ value = '<policies />' } } }
            Get-ClaudeFlowLifecycleLiveDiscovery -ResourceGroup rg-p84 -ApimName apim-p84
        }
    }
    finally { Set-Item -Path function:global:Get-ClaudeFlowLifecycleRepoRoot -Value $realRepoRoot }
}
Capture { Invoke-LiveDiscovery }
Assert 'live discovery without a receipt for the gateway carries no renewal, and the reason' (-not $Failure -and -not $Result.renewal -and $Result.renewalProblem -match 'no renewal receipt under onboarding/ names gateway') "$Failure $($Result.renewalProblem)"
[IO.File]::WriteAllText((Join-Path $discoveryReceipts 'projection-renewal-p84fixture.json'), (Get-Content -LiteralPath $receiptPath -Raw))
Capture { Invoke-LiveDiscovery }
Assert 'live discovery carries the receipt that names the discovered gateway (AC4)' (-not $Failure -and $Result.renewal.reconcilerResourceId -eq $FixtureJobId -and -not $Result.renewalProblem -and
    (Get-ClaudeFlowLifecycleRepoRoot) -eq $root) "$Failure $($Result.renewalProblem) | root $(Get-ClaudeFlowLifecycleRepoRoot)"

# Council round 1 (Coder): Start-ClaudeGateway.ps1 -Action Change runs Get-ClaudeFlowDiscovery, the step's plan,
# its Initialize-ClaudeFlowStep as Prepare, then Invoke. The same sequence through the real functions; the
# repository root is a temporary directory whose Backup-ClaudeGateway.ps1 records the gate's backup.
$startText = Get-Content -LiteralPath (Join-Path $root 'Start-ClaudeGateway.ps1') -Raw
Assert 'Start-ClaudeGateway prepares each step with its Initialize-ClaudeFlowStep before applying it' ($startText -match "'Initialize-ClaudeFlowStep'" -and $startText -match '\$Steps\[\$i\]\.Prepare' -and
    $startText.IndexOf('Initialize-FlowSteps -Steps $steps') -gt 0 -and $startText.IndexOf('Initialize-FlowSteps -Steps $steps') -lt $startText.IndexOf('Invoke-ApplySteps -Steps $steps -Plans @($plans)'))
. (Join-Path $root 'scripts\flow\Discovery.ps1')
$startRoot = Join-Path $work 'start-root'
New-Item -ItemType Directory -Force -Path (Join-Path $startRoot 'onboarding'), (Join-Path $startRoot 'scripts') | Out-Null
$startRecordPath = Join-Path $startRoot 'onboarding\claude-gateway.json'
$startRecord = [pscustomobject]@{ schemaVersion = 2; apimName = 'apim-p84'; resourceGroup = 'rg-p84'; decisions = [pscustomobject]@{ entitlementStore = [pscustomobject]@{ target = 'projection' } }; history = @() }
[IO.File]::WriteAllText($startRecordPath, ($startRecord | ConvertTo-Json -Depth 6))
[IO.File]::WriteAllText((Join-Path $startRoot 'onboarding\projection-renewal-p84fixture.json'), (Get-Content -LiteralPath $receiptPath -Raw))
[IO.File]::WriteAllText((Join-Path $startRoot 'scripts\Backup-ClaudeGateway.ps1'), @'
param([string]$ResourceGroup, [string]$ApimName, [string]$Path, [string]$SubscriptionId)
$global:FixtureCalls.Add("backup $ApimName")
New-Item -ItemType Directory -Force -Path (Split-Path $Path -Parent) | Out-Null
[IO.File]::WriteAllText($Path, '{}')
exit 0
'@)
Reset-ProjectionFixture
Set-GoodRenewalJob
$global:ListMode = 'clean'
Set-Item -Path function:global:Get-ClaudeFlowLifecycleRepoRoot -Value ([scriptblock]::Create("'$startRoot'"))
$script:StartPlan = $null
$script:StartOutput = @()
try {
    Capture {
        $startDiscovery = Get-ClaudeFlowDiscovery -RecordPath $startRecordPath -Record $startRecord
        $script:StartPlan = Get-ClaudeFlowStepPlan -Record $startRecord -Discovery $startDiscovery
        if (Get-Command Initialize-ClaudeFlowStep -ErrorAction SilentlyContinue) { $null = Initialize-ClaudeFlowStep -Record $startRecord -Plan $script:StartPlan }
        Invoke-ClaudeFlowStep -Record $startRecord -Plan $script:StartPlan 6>&1 | ForEach-Object {
            if ($_ -is [Management.Automation.InformationRecord]) { $script:StartOutput += [string]$_.MessageData } else { $_ }
        }
    }
}
finally {
    Set-Item -Path function:global:Get-ClaudeFlowLifecycleRepoRoot -Value $realRepoRoot
    $global:ListMode = $null
}
$startSnapshot = if ($script:StartPlan) { [string]$script:StartPlan.Data.SnapshotPath } else { '' }
Assert 'through Start-ClaudeGateway''s sequence, discovery finds the receipt beside the record and the switch makes its one write' (-not $Failure -and $script:StartPlan.Data.Renewal.reconcilerResourceId -eq $FixtureJobId -and
    @(Get-Writes).Count -eq 1 -and (Get-CallAt '^backup apim-p84') -gt (Get-CallAt 'check-admission\.mjs') -and (Get-CallAt '^backup apim-p84') -lt (Get-CallAt '^az apim nv update .*entitlement-source --value projection')) "$Failure | renewal $($script:StartPlan.Data.Renewal.reconcilerResourceId) | writes $(@(Get-Writes).Count)"
Assert "the flow's rollback text names its snapshot (AC6)" ($startSnapshot -and (Test-Path -LiteralPath $startSnapshot) -and (($script:StartOutput -join "`n") -match [regex]::Escape($startSnapshot))) "snapshot '$startSnapshot'"
Reset-ProjectionFixture
Capture { Get-ClaudeFlowDiscovery -RecordPath (Join-Path $work 'no-receipts\claude-gateway.json') -Record $startRecord }
Assert 'discovery without a receipt for the gateway carries the reason the flow refuses with' (-not $Failure -and -not $Result.renewal -and $Result.renewalProblem -match 'no renewal receipt') "$Failure | $($Result.renewalProblem)"

$flowRecord = [pscustomobject]@{ schemaVersion = 2; decisions = [pscustomobject]@{ entitlementStore = [pscustomobject]@{ target = 'projection' } }; history = @() }
$flowDiscovery = [pscustomobject]@{ resourceGroup = 'rg-p84'; apimName = 'apim-p84'; sku = 'BasicV2'; apimId = $FixtureGatewayId; namedValues = @{ 'entitlement-source' = 'named-value' }; renewal = $null; renewalProblem = 'no renewal receipt under onboarding/ names gateway x. Remedy: deploy the renewal job.' }
$flowPlan = Get-ClaudeFlowStepPlan -Record $flowRecord -Discovery $flowDiscovery
Reset-ProjectionFixture
Capture { Invoke-ClaudeFlowStep -Record $flowRecord -Plan $flowPlan }
Assert 'the flow without a receipt refuses with the reason, before any Azure call' ($Failure -match 'P86 admission needs' -and $Failure -match 'no renewal receipt under onboarding' -and $Failure -match '60-90 minutes' -and $FixtureCalls.Count -eq 0) "$Failure | calls $($FixtureCalls.Count)"

$flowDiscovery.renewal = $renewal
$flowDiscovery.renewalProblem = $null
foreach ($clean in @($true, $false)) {
    $flowPlan = Get-ClaudeFlowStepPlan -Record $flowRecord -Discovery $flowDiscovery
    $flowPlan.Data.SnapshotPath = Join-Path $work 'flow-snapshot.json'
    $flowPlan.Data.SnapshotTaken = $true
    $before = @(& $repoBackups | ForEach-Object FullName)
    Reset-ProjectionFixture
    Set-GoodRenewalJob
    $global:ListMode = $(if ($clean) { 'clean' } else { 'drift' })
    Capture { Invoke-ClaudeFlowStep -Record $flowRecord -Plan $flowPlan }
    $made = @(& $repoBackups | Where-Object { $before -notcontains $_.FullName })
    if ($clean) {
        Assert 'the flow switches through the shared function: the real drift check, compare, admission and one write' (-not $Failure -and (Get-CallAt 'apim nv show .*allow-premium -o json') -ge 0 -and
            (Get-CallAt 'apim nv show .*allow-premium -o json') -lt (Get-CallAt 'check-admission\.mjs') -and @(Get-Writes).Count -eq 1 -and $Result.entitlementStore.to -eq 'projection') "$Failure"
        Assert "the flow's own snapshot is the backup; no backup file is written" ($made.Count -eq 0) "backups $($made.Count)"
    }
    else {
        Assert 'the flow cannot skip the compare: drift refuses before the runner, with no write' ($Failure -match 'drift' -and (($FixtureCalls -join "`n") -notmatch 'container exec') -and @(Get-Writes).Count -eq 0) "$Failure"
    }
    $made | Remove-Item -Force -ErrorAction SilentlyContinue
}
# AC4: discovery reads the receipt only; the switch's admission confirms it in ARM before any write.
foreach ($case in @(
        @{ Name = 'a receipt whose job cannot be read'; Fixture = 'job-error'; Renewal = $renewal; Expect = 'could not read the renewal job' }
        @{ Name = 'a receipt whose job runs another image digest'; Fixture = 'healthy'; Expect = 'not the tested pinned digest'
            Renewal = ($renewal | Select-Object * -ExcludeProperty imageDigest | Add-Member -NotePropertyName imageDigest -NotePropertyValue ('sha256:' + ('b' * 64)) -PassThru) }
    )) {
    $flowDiscovery.renewal = $case.Renewal
    $flowPlan = Get-ClaudeFlowStepPlan -Record $flowRecord -Discovery $flowDiscovery
    $flowPlan.Data.SnapshotPath = Join-Path $work 'flow-snapshot.json'
    $flowPlan.Data.SnapshotTaken = $true
    $before = @(& $repoBackups | ForEach-Object FullName)
    Reset-ProjectionFixture $case.Fixture
    Set-GoodRenewalJob
    $global:ListMode = 'clean'
    Capture { Invoke-ClaudeFlowStep -Record $flowRecord -Plan $flowPlan }
    $made = @(& $repoBackups | Where-Object { $before -notcontains $_.FullName })
    Assert "the flow refuses $($case.Name), before any write (AC4)" ($Failure -match '^Projection switch refused' -and $Failure -match $case.Expect -and $Failure -match 'Remedy' -and
        @(Get-Writes).Count -eq 0 -and $made.Count -eq 0 -and (($FixtureCalls -join "`n") -notmatch 'check-admission\.mjs')) "$Failure | writes $(@(Get-Writes).Count) backups $($made.Count)"
    $made | Remove-Item -Force -ErrorAction SilentlyContinue
}
$flowDiscovery.renewal = $renewal
$global:ListMode = $null

Write-Host ''
Write-Host 'Projection switch - no other supported path moves entitlement-source to projection (council round 1)' -ForegroundColor Cyan
# Every code path that names entitlement-source in a write. A new one fails here until it is classified.
$writerPattern = "Set-ApimNamedValue\b.*-Id\s+'?entitlement-source\b|nv (update|create)\b.*--named-value-id\s+`"?entitlement-source\b|key:\s*'entitlement-source'|namedValues/entitlement-source\b"
$writerFiles = @(@(Get-ChildItem -LiteralPath (Join-Path $root 'scripts') -Filter '*.ps1' -File -Recurse) + @(Get-Item -LiteralPath (Join-Path $root 'Install-ClaudeGateway.ps1')) +
    @(Get-ChildItem -LiteralPath (Join-Path $root 'infra') -Filter '*.bicep' -File) | Where-Object { @([IO.File]::ReadAllLines($_.FullName) | Where-Object { $_ -match $writerPattern -and $_ -notmatch '^\s*#' }).Count } |
    ForEach-Object { $_.FullName.Substring($root.Length + 1).Replace('\', '/') } | Sort-Object)
$classified = @('infra/main.bicep', 'scripts/ClaudeProjectionSwitch.ps1', 'scripts/flow/Entitlement.ps1')
Assert 'the only code that writes entitlement-source by name is the switch, the flow''s named-value rollback and the template the installer feeds the live value' (($writerFiles -join ',') -eq ($classified -join ',')) "writers: $($writerFiles -join ', ')"
$installerText = Get-Content -LiteralPath (Join-Path $root 'Install-ClaudeGateway.ps1') -Raw
$bicepText = Get-Content -LiteralPath (Join-Path $root 'infra\main.bicep') -Raw
Assert 'the installer passes the live entitlement-source to the template, whose default is named-value' ($installerText -match "entitlementSource=\`$\(if \(\`$entSrc\) \{ \`$entSrc \} else \{ 'named-value' \}\)" -and $bicepText -match "param entitlementSource string = 'named-value'")
Assert 'an update creates a missing entitlement-source as named-value' ((Get-ClaudeFlowLifecycleTemplateNamedValueDefaults)['entitlement-source'].Value -eq 'named-value')
# Restore-ClaudeGateway.ps1 puts back every named value it changed; entitlement-source=projection waits for the switch.
$restoreScript = Join-Path $root 'scripts\Restore-ClaudeGateway.ps1'
foreach ($case in @(
        @{ Name = 'a backup taken on the projection does not switch a named-value gateway'; Backup = 'projection'; Live = 'named-value'; Writes = $false }
        @{ Name = 'a backup taken on named values returns a projection gateway to them'; Backup = 'named-value'; Live = 'projection'; Writes = $true }
    )) {
    $backupFile = Join-Path $work "restore-$($case.Backup).json"
    [IO.File]::WriteAllText($backupFile, (@{
                schemaVersion = 1; capturedAt = '2026-10-05T00:00:00Z'; capturedBy = 'test'
                gateway = @{ subscriptionId = $FixtureSubscription; resourceGroup = 'rg-p84'; apimName = 'apim-p84'; workspaceName = 'law-p84'; apiId = 'claude-foundry' }
                namedValues = @(@{ name = 'entitlement-source'; displayName = 'entitlement-source'; value = $case.Backup }, @{ name = 'allow-standard'; displayName = 'allow-standard'; value = ',x,' })
                secretsSkipped = @(); functions = @(); workbooks = @(); policy = $null
            } | ConvertTo-Json -Depth 6))
    Reset-ProjectionFixture
    $global:RestoreLiveSource = $case.Live
    $restoreText = & {
        function Invoke-RestMethod {
            param($Uri, $Headers, $Method, $Body, $ErrorAction, $ContentType)
            if ($Method -eq 'Put') { $global:FixtureCalls.Add("PUT $Uri"); return $null }
            [pscustomobject]@{ value = @(
                    [pscustomobject]@{ name = 'entitlement-source'; properties = [pscustomobject]@{ value = $global:RestoreLiveSource; secret = $false } }
                    [pscustomobject]@{ name = 'allow-standard'; properties = [pscustomobject]@{ value = ','; secret = $false } }) }
        }
        try { & $restoreScript -Path $backupFile -Apply *>&1 | Out-String -Width 400 } catch { "THREW $($_.Exception.Message)" }
    }
    $puts = @($FixtureCalls | Where-Object { $_ -like 'PUT *' })
    $wroteSource = @($puts | Where-Object { $_ -match 'namedValues/entitlement-source\?' }).Count -gt 0
    $ok = $restoreText -notmatch 'THREW' -and @($puts | Where-Object { $_ -match 'namedValues/allow-standard\?' }).Count -eq 1 -and $wroteSource -eq $case.Writes
    if (-not $case.Writes) { $ok = $ok -and $restoreText -match 'entitlement-source stays named-value' -and $restoreText -match 'Deploy-ClaudeProjection\.ps1 -FlipAfterCleanCompare' }
    Assert "restore: $($case.Name)" $ok "puts: $($puts -join ' | ') | $(($restoreText -split "`r?`n" | Where-Object { $_ -match 'entitlement|THREW' }) -join ' / ')"
}

Write-Host ''
Write-Host 'Projection switch - the guides describe the switch (AC7, AC8)' -ForegroundColor Cyan
$staleSwitch = '(?i)P84 refuses|refuses every (automated )?projection switch|refuses automated switching|returns the P86 refusal|switching is (blocked|unavailable)|unavailable in P84|blocked until P86|(switch( itself)?|switching|binding them[^.]*) is P95|until (a |the )?supported (projection )?switch exists|refused unconditionally|not P84-protected|proposed as \**P86|needs the supported P86'
$described = @(Get-Item -LiteralPath (Join-Path $root 'README.md'), (Join-Path $root 'Install-ClaudeGateway.ps1')) +
    @(Get-ChildItem -LiteralPath (Join-Path $root 'docs') -Filter '*.md' -File | Where-Object Name -notin 'ROADMAP.md', 'STATUS.md', 'UNKNOWNS.md') +
    @(Get-ChildItem -LiteralPath (Join-Path $root 'docs\architecture') -Filter '*.json' -File) +
    @(Get-ChildItem -LiteralPath (Join-Path $root 'scripts') -Filter '*.ps1' -File -Recurse)
$d10 = @('README.md', 'SETUP.md', 'UPDATE-AND-CHANGE.md', 'SECURE-PROJECTION.md', 'SCALE.md', 'GUIDED-FLOW.md', 'AZ-COMMANDS.md', 'TROUBLESHOOTING.md', 'ClaudeProjectionChecks.ps1', 'Deploy-ClaudeProjection.ps1')
$unread = @($d10 | Where-Object { @($described | ForEach-Object Name) -notcontains $_ })
$stale = @(foreach ($file in $described) {
    $n = 0
    foreach ($line in [IO.File]::ReadAllLines($file.FullName)) { $n++; if ($line -match $staleSwitch) { "$($file.Name):$n '$($Matches[0])'" } }
})
Assert 'no guide, diagram or script says the switch is unavailable or later work (D10)' (-not $unread.Count -and -not $stale.Count) "unread: $($unread -join ', '); stale: $($stale -join '; ')"

$secure = [IO.File]::ReadAllText((Join-Path $root 'docs\SECURE-PROJECTION.md'))
$section = [regex]::Match($secure, '(?ms)^### Switch to the projection \(P95\)\r?\n(.*?)(?=^### )').Groups[1].Value
$steps = @('^1\. The receipt''s values are checked before any call', '^2\. .*projection-resolver-<prefix>.*entitlement-resolver-url', '^3\. .*Compare-ClaudeEntitlement\.ps1 -FailOnDrift', '^4\. .*--compare', '^5\. Admission ', '^6\. .*onboarding/projection-switch-', '^7\. `entitlement-source` is set to `projection`')
$at = @($steps | ForEach-Object { $m = [regex]::Match($section, "(?m)$_"); if ($m.Success) { $m.Index } else { -1 } })
Assert 'the switch section lists the receipt and resolver checks, the drift check, the compare, admission, the backup and the one write, in that order' ($section -and $at -notcontains -1 -and (($at | Sort-Object) -join ',') -eq ($at -join ',')) "positions $($at -join ',')"
Assert 'the switch section names the backup and the rollback through a refresh and a compare' ($section -match 'Sync-ClaudeAccess\.ps1' -and $section -match 'Compare-ClaudeEntitlement\.ps1 -FailOnDrift' -and $section -match 'back to `named-value`')
$unknowns = [IO.File]::ReadAllText((Join-Path $root 'docs\UNKNOWNS.md'))
$rows = @([regex]::Matches($section, '(?m)^\| (\d)\. ') | ForEach-Object { $_.Groups[1].Value })
$unchecked = @('U17', 'U109', 'U113', 'U116' | Where-Object { $section -notmatch "\[$_\]\(UNKNOWNS\.md" -or $unknowns -notmatch "(?m)^\| $_ \|" })
Assert 'the owner-attended run lists steps 1-9 and checks U17, U109, U113 and U116 (AC8)' (($rows -join ',') -eq '1,2,3,4,5,6,7,8,9' -and -not $unchecked.Count) "rows $($rows -join ','); unchecked $($unchecked -join ', ')"

Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($fail) { Write-Host "$fail assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'Projection switch holds.' -ForegroundColor Green
exit 0
