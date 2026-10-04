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
        $map = @{ 'allow-standard' = $standard; 'allow-premium' = ','; 'bu-members' = ','; 'entitlement-source' = 'named-value' }
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
$global:ListMode = $null

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
$steps = @('^1\. .*Compare-ClaudeEntitlement\.ps1 -FailOnDrift', '^2\. .*--compare', '^3\. Admission ', '^4\. .*onboarding/projection-switch-', '^5\. `entitlement-source` is set to `projection`')
$at = @($steps | ForEach-Object { $m = [regex]::Match($section, "(?m)$_"); if ($m.Success) { $m.Index } else { -1 } })
Assert 'the switch section lists the drift check, the compare, admission, the backup and the one write, in that order' ($section -and $at -notcontains -1 -and (($at | Sort-Object) -join ',') -eq ($at -join ',')) "positions $($at -join ',')"
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
