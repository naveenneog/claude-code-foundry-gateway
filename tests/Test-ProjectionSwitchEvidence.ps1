$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$fail = 0
function Assert($Label, [bool]$Condition, $Detail = '') {
    if ($Condition) { Write-Host "  [OK]   $Label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $Label$(if ($Detail) { " - $Detail" })" -ForegroundColor Red; $script:fail++ }
}
function Capture([scriptblock]$Block) { $script:Failure = $null; $script:Result = $null; try { $script:Result = & $Block } catch { $script:Failure = $_.Exception.Message } }
. (Join-Path $PSScriptRoot 'TestProjectionFixture.ps1')
. (Join-Path $root 'scripts\ClaudeRunner.ps1')
. (Join-Path $root 'scripts\ClaudeProjectionChecks.ps1')
. (Join-Path $root 'scripts\ClaudeProjectionSwitch.ps1')

Write-Host ''
Write-Host 'Projection switch evidence - runner admission and switch order' -ForegroundColor Cyan

Reset-ProjectionFixture
Capture { Assert-ClaudeProjectionAdmission -ResourceGroup rg-p84 -RunnerName aci-projtest-p84fixture -CosmosAccount cosmos-p84fixture -TenantId $FixtureTenant -AccountResourceId $FixtureCosmosId }
$calls = $FixtureCalls -join "`n"
Assert 'admission uses check-admission.mjs with the D11 switch-evidence flags only' (-not $Failure -and $Result.mode -eq 'switch-evidence' -and $calls -match 'check-admission\.mjs --cosmos https://cosmos-p84fixture\.documents\.azure\.com:443/ --tenant' -and $calls -match '--account-resource-id' -and $calls -match '--max-evidence-age-seconds 86400' -and $calls -notmatch 'image-digest|entrypoint|action-group|gateway-resource-id|standard-group-id') "$Failure | $calls"
Capture { ConvertFrom-ClaudeProjectionAdmissionResult -RawOutput '{"ok":true,"mode":"projection-admission","generations":3}' }
Assert 'old three-run projection-admission evidence is refused' ($Failure -match 'switch evidence was not accepted') $Failure

foreach ($case in @(
        @{ Fixture='admission-no-full-sync'; Label='no full sync within 24 hours refuses before backup/write with the Sync-ClaudeAccess remedy'; Expect='no full sync within 24 hours'; Extra='Sync-ClaudeAccess' }
        @{ Fixture='admission-user-mode'; Label='a status with mode user does not count as switch evidence'; Expect='mode user'; Extra='full counts' }
        @{ Fixture='admission-invalid-records'; Label='invalid records refuse with count and hashed samples'; Expect='Invalid projection records: 2'; Extra='aaaaaaaaaaaa.*bbbbbbbbbbbb' }
        @{ Fixture='admission-other-scope'; Label='evidence for another account or tenant does not count'; Expect='this account, database, container and tenant'; Extra='Sync-ClaudeAccess' }
    )) {
    Reset-ProjectionFixture $case.Fixture
    Capture { Assert-ClaudeProjectionAdmission -ResourceGroup rg-p84 -RunnerName aci-projtest-p84fixture -CosmosAccount cosmos-p84fixture -TenantId $FixtureTenant -AccountResourceId $FixtureCosmosId }
    Assert $case.Label ($Failure -match '^Projection switch refused' -and $Failure -match $case.Expect -and $Failure -match $case.Extra) $Failure
}
foreach ($case in @(@{Fixture='admission-no-json'; Count='0'}, @{Fixture='admission-two-json'; Count='2'})) {
    Reset-ProjectionFixture $case.Fixture
    Capture { Assert-ClaudeProjectionAdmission -ResourceGroup rg-p84 -RunnerName aci-projtest-p84fixture -CosmosAccount cosmos-p84fixture -TenantId $FixtureTenant -AccountResourceId $FixtureCosmosId }
    Assert "check-admission output with $($case.Count) JSON lines refuses" ($Failure -match "returned $($case.Count) JSON lines, not exactly one") $Failure
}

$work = Join-Path $root '.test-work\p97-switch-test'
Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
$backupDir = Join-Path $work 'onboarding'
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
$compareStub = Join-Path $work 'compare-stub.ps1'
[IO.File]::WriteAllText($compareStub, @'
param([string]$ResourceGroup, [string]$ApimName, [string]$StandardGroup, [string]$PremiumGroup, [string]$ExportGatewayPath, [bool]$FailOnDrift = $true)
$global:FixtureCalls.Add("compare-stub $ResourceGroup $ApimName $StandardGroup $PremiumGroup")
if ($global:CompareDrift) { exit 1 }
[IO.File]::WriteAllText($ExportGatewayPath, '{"kind":"claude-gateway-decisions","premium":[],"standard":[]}')
exit 0
'@)
$syncStub = Join-Path $work 'sync-stub.ps1'
[IO.File]::WriteAllText($syncStub, @'
param([string]$ApimName, [string]$ResourceGroup, [string]$StandardGroup, [string]$PremiumGroup, [string]$ExportPath)
$global:FixtureCalls.Add("sync-export $ResourceGroup $ApimName $StandardGroup $PremiumGroup")
[IO.File]::WriteAllText($ExportPath, '{"scope":"full","records":[]}')
exit 0
'@)
function Invoke-Switch([hashtable]$Extra = @{}) {
    $params = @{ ResourceGroup = 'rg-p84'; ApimName = 'apim-p84'; NamePrefix = 'p84fixture'; StandardGroup = 'claude-code-standard'; PremiumGroup = 'none'; BackupDirectory = $backupDir; CompareScript = $compareStub; SyncProjectionScript = $syncStub }
    foreach ($key in $Extra.Keys) { $params[$key] = $Extra[$key] }
    Invoke-ClaudeProjectionSwitch @params
}
function At([string]$Pattern) { for ($i = 0; $i -lt $FixtureCalls.Count; $i++) { if ($FixtureCalls[$i] -match $Pattern) { return $i } }; return -1 }
function Writes { @($FixtureCalls | Where-Object { $_ -match '^az (deployment group create|apim nv (update|create)|cosmosdb sql role assignment create|functionapp|ad app create|ad sp create)' }) }
function Backups { @(Get-ChildItem -LiteralPath $backupDir -Filter 'projection-switch-apim-p84-*.json' -ErrorAction SilentlyContinue) }

Reset-ProjectionFixture
$global:CompareDrift = $false
Get-ChildItem -LiteralPath $backupDir -Filter '*.json' -ErrorAction SilentlyContinue | Remove-Item -Force
Capture { Invoke-Switch }
$order = @((At '^az ad sp show --id 00000000-0000-4000-8000-000000000086'), (At '^compare-stub'), (At '^az container show -g rg-p84 -n aci-projtest-p84fixture --query instanceView\.state'), (At 'apply-projection\.mjs .*--compare /work/gateway-decisions\.json'), (At 'check-admission\.mjs'), (At '^az apim nv update .*entitlement-source --value projection'))
Assert 'switch takes prefix, confirms resolver SP, starts runner, compares, checks evidence and writes once' (-not $Failure -and ($order -notcontains -1) -and (@(0..4 | Where-Object { $order[$_] -lt $order[$_ + 1] }).Count -eq 5) -and @(Writes).Count -eq 1 -and @(Get-ChildItem -LiteralPath $backupDir -Filter '*.json' -ErrorAction SilentlyContinue).Count -eq 1) "$Failure | $($order -join ',') | $(($FixtureCalls -join '; '))"
Assert 'its only Azure write is entitlement-source' (@(Writes).Count -eq 1 -and @(Writes)[0] -match 'entitlement-source --value projection') ((Writes) -join ' | ')
Assert 'nothing is deployed, published, registered, role-assigned or applied in switch mode' ((($FixtureCalls -join "`n") -notmatch 'deployment group create|functionapp|ad app create|role assignment|--snapshot ') -and (($FixtureCalls -join "`n") -notmatch 'Sync-ClaudeProjection')) ($FixtureCalls -join ' | ')
$backup = @(Backups)[0]
$backupJson = if ($backup) { Get-Content -LiteralPath $backup.FullName -Raw | ConvertFrom-Json } else { $null }
Assert 'the backup holds the entitlement named values from before the write' ($backupJson -and $backupJson.kind -eq 'claude-projection-switch-backup' -and $backupJson.namedValues.'entitlement-source' -eq 'named-value' -and @('allow-standard','allow-premium','bu-members' | Where-Object { $backupJson.namedValues.PSObject.Properties.Name -contains $_ }).Count -eq 3) "backups $(@(Backups).Count)"
Assert 'the result names the backup and rollback through Sync-ClaudeAccess -Store named-value' ($Result.Switched -eq $true -and $Result.BackupPath -eq $backup.FullName -and $Result.Rollback -match 'Sync-ClaudeAccess\.ps1 -Store named-value' -and $Result.Rollback -match 'Compare-ClaudeEntitlement\.ps1 -FailOnDrift') ($Result | ConvertTo-Json -Compress)
Assert 'switch no longer reads renewal job/action group/digest evidence' (($FixtureCalls -join "`n") -notmatch 'actionGroups|Microsoft.App/jobs|image-digest|entrypoint') ($FixtureCalls -join ' | ')

Reset-ProjectionFixture
Backups | Remove-Item -Force
$switchLines = @(try { Invoke-Switch 6>&1 | Where-Object { $_ -is [Management.Automation.InformationRecord] } | ForEach-Object { [string]$_.MessageData } } catch { "THREW $($_.Exception.Message)" })
Assert 'the success line names the full sync finish time and executor' (($switchLines -join "`n") -match 'full sync finished 2026-10-05T11:00:00.000Z by runner') (($switchLines | Select-Object -Last 4) -join ' / ')

foreach ($case in @(
        @{ Name='drift between the lists and Entra'; Fixture='healthy'; Drift=$true; Expect='drift'; RunnerIdle=$true }
        @{ Name='a projection that differs from the gateway'; Fixture='compare-differs'; Drift=$false; Expect='comparison found 1 differences'; RunnerIdle=$false }
        @{ Name='a runner compare that fails'; Fixture='compare-error'; Drift=$false; Expect='runner compare did not complete'; RunnerIdle=$false }
        @{ Name='a runner answer that is not a compare'; Fixture='compare-no-mode'; Drift=$false; Expect='runner compare did not complete'; RunnerIdle=$false }
        @{ Name='missing full-sync evidence'; Fixture='admission-no-full-sync'; Drift=$false; Expect='no full sync within 24 hours'; RunnerIdle=$false }
    )) {
    Reset-ProjectionFixture $case.Fixture
    $global:CompareDrift = $case.Drift
    Backups | Remove-Item -Force
    Capture { Invoke-Switch }
    $runnerRan = ($FixtureCalls -join "`n") -match 'container exec'
    Assert "a refusal for $($case.Name) leaves entitlement-source and writes no backup" ($Failure -match '^Projection switch refused' -and $Failure -match $case.Expect -and @(Writes).Count -eq 0 -and @(Backups).Count -eq 0 -and (-not $case.RunnerIdle -or -not $runnerRan)) "$Failure | writes $(@(Writes).Count) backups $(@(Backups).Count)"
}

Reset-ProjectionFixture
$global:CompareDrift = $false
Backups | Remove-Item -Force
Capture { Invoke-Switch @{ WhatIf = $true } }
Assert '-WhatIf runs the compare and evidence and stops before backup/write' (-not $Failure -and $Result.Switched -eq $false -and (At 'check-admission\.mjs') -ge 0 -and @(Writes).Count -eq 0 -and @(Backups).Count -eq 0) $Failure

Reset-ProjectionFixture 'new-gateway'
Get-ChildItem -LiteralPath $backupDir -Filter '*.json' -ErrorAction SilentlyContinue | Remove-Item -Force
Capture { Invoke-Switch }
$calls = $FixtureCalls -join "`n"
Assert 'new gateway skips drift export and uses compare-snapshot against a fresh full snapshot' (-not $Failure -and $calls -notmatch '(?m)^compare-stub' -and $calls -match '(?m)^sync-export rg-p84 apim-p84' -and $calls -match '--compare-snapshot /work/snapshot\.json') "$Failure | $calls"

Reset-ProjectionFixture 'sp-missing'
Get-ChildItem -LiteralPath $backupDir -Filter '*.json' -ErrorAction SilentlyContinue | Remove-Item -Force
Capture { Invoke-Switch }
Assert 'missing resolver service principal refuses before compare and backup, and the switch does not create it' ($Failure -match '^Projection switch refused' -and $Failure -match 'service principal' -and $Failure -match 'Deploy-ClaudeProjection\.ps1' -and (At '^compare-stub') -lt 0 -and (At '^az ad sp create') -lt 0 -and @(Writes).Count -eq 0 -and -not @(Get-ChildItem -LiteralPath $backupDir -Filter '*.json' -ErrorAction SilentlyContinue).Count) "$Failure | $(($FixtureCalls | Select-Object -Last 4) -join ' | ')"
Reset-ProjectionFixture 'sp-missing'
Capture { Invoke-Switch @{ WhatIf = $true } }
Assert '-WhatIf with a missing resolver service principal refuses and makes no Entra write' ($Failure -match 'service principal' -and (At '^az ad sp create') -lt 0 -and @(Writes).Count -eq 0) "$Failure | $(($FixtureCalls | Select-Object -Last 4) -join ' | ')"
Reset-ProjectionFixture 'runner-stopped'
$global:CompareDrift = $false
Backups | Remove-Item -Force
Capture { Invoke-Switch }
$runnerOrder = @((At '^az container show -g rg-p84 -n aci-projtest-p84fixture --query instanceView\.state'), (At '^az container start -g rg-p84 -n aci-projtest-p84fixture'), (At 'apply-projection\.mjs .*--compare /work/gateway-decisions\.json'), (At '^az apim nv update .*entitlement-source --value projection'))
Assert 'a stopped runner is started before the compare, and the switch still writes once' (-not $Failure -and ($runnerOrder -notcontains -1) -and (@(0..2 | Where-Object { $runnerOrder[$_] -lt $runnerOrder[$_ + 1] }).Count -eq 3) -and @(Writes).Count -eq 1) "$Failure | $($runnerOrder -join ',')"

$confirmShell = [powershell]::Create()
$null = $confirmShell.AddScript({
        param($Root, $CompareStub, $SyncStub, $BackupDir)
        $ErrorActionPreference = 'Stop'
        . (Join-Path $Root 'tests\TestProjectionFixture.ps1')
        . (Join-Path $Root 'scripts\ClaudeProjectionSwitch.ps1')
        Reset-ProjectionFixture
        $failure = try {
            Invoke-ClaudeProjectionSwitch -ResourceGroup rg-p84 -ApimName apim-p84 -NamePrefix p84fixture -StandardGroup claude-code-standard -PremiumGroup none -BackupDirectory $BackupDir -CompareScript $CompareStub -SyncProjectionScript $SyncStub -Confirm
            ''
        } catch { $_.Exception.Message }
        [pscustomobject]@{ Failure=$failure; Calls=@($global:FixtureCalls) }
    }).AddArgument($root).AddArgument($compareStub).AddArgument($syncStub).AddArgument($backupDir)
$confirmRun = @($confirmShell.Invoke())[0]
$confirmShell.Dispose()
$confirmCalls = @($confirmRun.Calls) -join "`n"
Assert '-Confirm asks only about the entitlement-source write after evidence' ($confirmRun.Failure -match 'prompts the user' -and $confirmRun.Failure -match 'entitlement-source' -and $confirmCalls -match 'check-admission\.mjs' -and $confirmCalls -notmatch 'apim nv update') "$($confirmRun.Failure) | $confirmCalls"

$runnerRefusals = @(foreach ($case in @(
            @{ ResourceGroup='rg-p84'; Name='runner-p84'; Command='node "x"' }
            @{ ResourceGroup='rg-p84'; Name='runner-p84'; Command='node a+b' }
            @{ ResourceGroup='rg-p84'; Name='runner-p84'; Command='node a%20b' }
            @{ ResourceGroup='rg-p84&whoami'; Name='runner-p84'; Command='node --version' }
            @{ ResourceGroup='rg-p84'; Name='runner^p84'; Command='node --version' }
        )) {
        Reset-ProjectionFixture
        Capture { Invoke-RunnerCommand @case }
        if (-not ($Failure -match '^Runner command refused' -and $FixtureCalls.Count -eq 0)) { "$($case.ResourceGroup) $($case.Name) $($case.Command): $Failure calls $($FixtureCalls.Count)" }
    })
Assert 'a runner command or target that the runner or cmd.exe would alter is refused before az' (-not $runnerRefusals.Count) ($runnerRefusals -join ' || ')
$callerRefusals = @(foreach ($case in @(@{ ResourceGroup='rg-p84&whoami' }, @{ ApimName='apim-p84^x' }, @{ NamePrefix='P84Fixture' })) {
        Reset-ProjectionFixture
        Capture { Invoke-Switch $case }
        if (-not ($Failure -match '^Projection switch refused' -and $FixtureCalls.Count -eq 0)) { "$(@($case.Values)[0]): $Failure calls $($FixtureCalls.Count)" }
    })
Assert 'resource group, gateway name and prefix are validated before any az call' (-not $callerRefusals.Count) ($callerRefusals -join ' || ')
Reset-ProjectionFixture; Capture { Invoke-Switch @{ ResourceGroup='rg-claude(prod)' } }; $groupRefusal = $Failure
Reset-ProjectionFixture; Capture { Invoke-Switch @{ ApimName='apim_p84' } }; $nameRefusal = $Failure
Assert 'a resource group the switch cannot pass to az.cmd is refused as a stated limitation, and a gateway name as not an API Management name' ($groupRefusal -match 'ADR-0050' -and $groupRefusal -notmatch 'as the Azure portal shows' -and $nameRefusal -match 'not an API Management name') "$groupRefusal || $nameRefusal"
$siteId = "$FixtureRgId/providers/Microsoft.Web/sites/func-resolver-p84fixture"
Capture { Get-ClaudeProjectionArmUrl -ResourceId $siteId -ApiVersion '2024-04-01' -SubPath 'config/appsettings/list' }
$settingsUrl = $Result
$loose = @(foreach ($subPath in '../../providers/x','config/appsettings/list?x=1','@attacker.example','config//list','/config','config.appsettings') {
        Capture { Get-ClaudeProjectionArmUrl -ResourceId $siteId -ApiVersion '2024-04-01' -SubPath $subPath }
        if (-not $Failure) { $subPath }
    })
Capture { Get-ClaudeProjectionArmUrl -ResourceId "$FixtureRgId/providers/Microsoft.Web/sites/.." -ApiVersion '2024-04-01' }
if (-not $Failure) { $loose += 'resource id ending in /..' }
Assert 'the switch builds every management URL through Get-ClaudeProjectionArmUrl, whose sub-path stays under the resource' ((Get-Content -LiteralPath (Join-Path $root 'scripts\ClaudeProjectionSwitch.ps1') -Raw) -notmatch 'https://management\.azure\.com' -and $settingsUrl -ceq "https://management.azure.com$siteId/config/appsettings/list?api-version=2024-04-01" -and -not $loose.Count) "url '$settingsUrl'; accepted $($loose -join ', ')"
Capture { Get-ClaudeProjectionArmUrl -ResourceId '@attacker.example/subscriptions/x' -ApiVersion '2024-04-01' }
Assert 'the management token is sent only to management.azure.com where a token is still sent' ($Failure -match '^Projection switch refused' -and $Failure -match 'not an Azure resource id' -and $FixtureCalls.Count -eq 0) "$Failure | calls $($FixtureCalls.Count)"
Reset-ProjectionFixture 'standard-missing'
Backups | Remove-Item -Force
Capture { Invoke-Switch }
Assert 'a tier group that Microsoft Graph does not find refuses before the drift check' ($Failure -match "standard tier group 'claude-code-standard' was not found" -and (At '^compare-stub') -lt 0 -and @(Writes).Count -eq 0 -and @(Backups).Count -eq 0) $Failure
Reset-ProjectionFixture 'apim-empty'
Capture { Invoke-Switch }
Assert 'a gateway read that returns no id refuses before anything else is read' ($Failure -match 'API Management apim-p84 in rg-p84 could not be read' -and $Failure -match 'Remedy:' -and $FixtureCalls.Count -eq 1) "$Failure | calls $($FixtureCalls.Count)"
foreach ($case in @(
        @{ Name='a gateway that still calls the resolver placeholder'; Fixture='resolver-placeholder'; Expect='entitlement-resolver-url' }
        @{ Name='a gateway that calls another resolver'; Fixture='resolver-other-url'; Expect='entitlement-resolver-url' }
        @{ Name='a gateway that asks for another token audience'; Fixture='resolver-other-audience'; Expect='entitlement-resolver-audience' }
        @{ Name='a resolver that reads another Cosmos account'; Fixture='resolver-other-cosmos'; Expect='not cosmos-other.documents.azure.com' }
        @{ Name='no resolver deployment'; Fixture='resolver-missing'; Expect='could not read the resolver deployment projection-resolver-p84fixture' }
        @{ Name='a resolver site whose live settings read another tenant'; Fixture='resolver-live-tenant'; Expect="tenant '00000000-0000-4000-8000-0000000000ff'" }
    )) {
    Reset-ProjectionFixture $case.Fixture
    Backups | Remove-Item -Force
    Capture { Invoke-Switch }
    Assert "the switch refuses $($case.Name), before the drift check" ($Failure -match '^Projection switch refused' -and $Failure -match [regex]::Escape($case.Expect) -and (At '^compare-stub') -lt 0 -and @(Writes).Count -eq 0 -and @(Backups).Count -eq 0) $Failure
}
Reset-ProjectionFixture
Backups | Remove-Item -Force
Capture { $a = Save-ClaudeProjectionSwitchBackup -ResourceGroup rg-p84 -ApimName apim-p84 -GatewayResourceId $FixtureGatewayId -Directory $backupDir; $b = Save-ClaudeProjectionSwitchBackup -ResourceGroup rg-p84 -ApimName apim-p84 -GatewayResourceId $FixtureGatewayId -Directory $backupDir; @($a,$b) }
Assert 'two backups in the same second are two files; neither overwrites the other' (-not $Failure -and @($Result | Select-Object -Unique).Count -eq 2 -and @($Result | Where-Object { Test-Path -LiteralPath $_ }).Count -eq 2) "$Failure | $($Result -join ', ')"

Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
if ($fail) { Write-Host "$fail assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'Projection switch evidence holds.' -ForegroundColor Green
exit 0
