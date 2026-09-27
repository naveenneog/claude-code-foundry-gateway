# P68 (ADR-0032): the guided flow starts at once, gives the foundation to the installer in an
# attended run, and the installer prices its region and tier choices. Offline: az, the installer
# and the Azure Retail Prices API are stubbed.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$fail = 0
function Assert($label, $condition, $detail = '') {
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $label$(if ($detail) { " - $detail" })" -ForegroundColor Red; $script:fail++ }
}
function Test-Key($Map, [string]$Key) { [bool]($Map -and $Map.Contains($Key)) }
function Read-Json($Path) { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
function Read-JsonLines($Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    @(Get-Content -LiteralPath $Path | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
}

Write-Host ''
Write-Host 'Guided flow - start, foundation hand-over and installer prices' -ForegroundColor Cyan

$script:pwsh = (Get-Process -Id $PID).Path
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('flow-start-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch -Force | Out-Null
$script:azBin = Join-Path $scratch 'azbin'
New-Item -ItemType Directory -Path $script:azBin -Force | Out-Null

# A stub Azure CLI that runs as its own process, as az.cmd does: stdout, stderr and an exit code.
Set-Content -LiteralPath (Join-Path $script:azBin 'az.cmd') -Encoding ASCII -Value @'
@echo off
"%P68_PWSH%" -NoProfile -NonInteractive -File "%~dp0az-stub.ps1" %*
exit /b %ERRORLEVEL%
'@
Set-Content -LiteralPath (Join-Path $script:azBin 'az-stub.ps1') -Encoding UTF8 -Value @'
$ErrorActionPreference = 'Stop'
if ($env:P68_AZ_LOG) { Add-Content -LiteralPath $env:P68_AZ_LOG -Value ([ordered]@{ ticks = [DateTime]::UtcNow.Ticks; args = @($args) } | ConvertTo-Json -Compress) }
$joined = $args -join ' '
if ($joined -like 'apim show *') {
    switch ($env:P68_AZ_MODE) {
        'missing' { [Console]::Error.WriteLine("ERROR: (ResourceNotFound) The Resource 'Microsoft.ApiManagement/service/apim-p68' under resource group 'rg-p68' was not found."); exit 3 }
        'signedout' { [Console]::Error.WriteLine("ERROR: Please run 'az login' to setup account."); exit 1 }
        default { [Console]::Out.WriteLine((@{ name = 'apim-p68'; resourceGroup = 'rg-p68'; location = 'East US 2'; publisherEmail = 'ops@contoso.com'; sku = @{ name = 'BasicV2' }; gatewayUrl = $env:P68_AZ_URL } | ConvertTo-Json -Compress)); exit 0 }
    }
}
if ($joined -like 'account show*') { [Console]::Out.WriteLine('{"user":{"name":"admin@contoso.com"},"tenantId":"00000000-0000-0000-0000-000000000000","id":"00000000-0000-0000-0000-000000000001","name":"p68"}'); exit 0 }
[Console]::Error.WriteLine("stub az: unexpected call: $joined")
exit 2
'@

function Invoke-Child {
    param(
        [Parameter(Mandatory = $true)][string]$Script,
        [string[]]$Arguments = @(),
        [hashtable]$Environment = @{},
        [string[]]$InputLines = @(),
        [switch]$Attended,
        [switch]$NoAz,
        [int]$TimeoutSeconds = 120
    )
    $psi = [Diagnostics.ProcessStartInfo]::new($script:pwsh)
    $psi.ArgumentList.Add('-NoProfile')
    if (-not $Attended) { $psi.ArgumentList.Add('-NonInteractive') }
    $psi.ArgumentList.Add('-File')
    $psi.ArgumentList.Add($Script)
    foreach ($a in $Arguments) { $psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    foreach ($name in 'CLAUDE_FLOW_SKIP_AZ_DISCOVERY', 'CLAUDE_INTERACTIVE', 'CLAUDE_NONINTERACTIVE') { [void]$psi.Environment.Remove($name) }
    $psi.Environment['PATH'] = $(if ($NoAz) { Join-Path $env:SystemRoot 'System32' } else { $script:azBin + [IO.Path]::PathSeparator + $env:PATH })
    $psi.Environment['P68_PWSH'] = $script:pwsh
    if ($Attended) { $psi.Environment['CLAUDE_INTERACTIVE'] = '1' }
    foreach ($k in $Environment.Keys) {
        if ($null -eq $Environment[$k]) { [void]$psi.Environment.Remove($k) } else { $psi.Environment[$k] = [string]$Environment[$k] }
    }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $process = [Diagnostics.Process]::Start($psi)
    foreach ($line in $InputLines) { $process.StandardInput.WriteLine($line) }
    $process.StandardInput.Close()
    $stderr = $process.StandardError.ReadToEndAsync()
    $lines = [Collections.Generic.List[object]]::new()
    $timedOut = $false
    while ($true) {
        $next = $process.StandardOutput.ReadLineAsync()
        $left = [int][Math]::Max(1, $TimeoutSeconds * 1000 - $clock.ElapsedMilliseconds)
        if (-not $next.Wait($left)) { $timedOut = $true; try { $process.Kill($true) } catch { }; break }
        if ($null -eq $next.Result) { break }
        $lines.Add([pscustomobject]@{ Ms = $clock.ElapsedMilliseconds; Text = ($next.Result -replace "`e\[[0-9;]*m", '') })
    }
    [void]$process.WaitForExit(15000)
    $err = if ($stderr.Wait(5000)) { $stderr.Result -replace "`e\[[0-9;]*m", '' } else { '' }
    [pscustomobject]@{
        Lines = @($lines)
        Text = (@($lines | ForEach-Object Text) -join "`n")
        Error = $err
        All = ((@($lines | ForEach-Object Text) -join "`n") + "`n" + $err)
        ExitCode = $(if ($process.HasExited) { $process.ExitCode } else { -1 })
        TimedOut = $timedOut
    }
}
function Get-Fingerprint([string]$Text) { [regex]::Match($Text, 'Fingerprint:\s+([a-f0-9]{64})').Groups[1].Value }
function Get-LineIndex($Result, [string]$Pattern) {
    for ($i = 0; $i -lt $Result.Lines.Count; $i++) { if ($Result.Lines[$i].Text -match $Pattern) { return $i } }
    return -1
}

try {
    # ------------------------------------------------------------------ discovery, real modules
    $answersPath = Join-Path $scratch 'answers.json'
    @{ 'foundation.sku' = 'BasicV2'; 'foundation.entitlementStore' = 'named-value'; 'foundation.authMode' = 'interactive'; 'foundation.desktopSignInKind' = 'helper-script'; 'deviceProfiles.conversationStorage' = 'local' } |
        ConvertTo-Json | Set-Content -LiteralPath $answersPath -Encoding UTF8
    $azLog = Join-Path $scratch 'az-empty.log'
    $start = Join-Path $root 'Start-ClaudeGateway.ps1'
    $empty = Invoke-Child -Script $start -Arguments @('-Action', 'Setup', '-PlanOnly', '-RecordPath', (Join-Path $scratch 'empty-record.json'), '-AnswersPath', $answersPath) -Environment @{ P68_AZ_LOG = $azLog }
    Assert 'an empty record: Setup -PlanOnly completes' ((Get-Fingerprint $empty.Text) -and -not $empty.TimedOut) ($empty.All | Select-Object -Last 1)
    Assert 'an empty record: no Azure CLI call is made' (@(Read-JsonLines $azLog).Count -eq 0) ((@(Read-JsonLines $azLog) | ForEach-Object { $_.args -join ' ' }) -join '; ')
    $firstLine = @($empty.Lines | Where-Object { $_.Text.Trim() })[0]
    Assert 'an empty record: the first line says that nothing is read from Azure' ($firstLine.Text -match 'No gateway is recorded' -and $firstLine.Text -match 'nothing is read from Azure') $firstLine.Text
    Assert 'an empty record: the first line appears within 3 s' ($firstLine.Ms -lt 3000) "$($firstLine.Ms) ms"

    # ------------------------------------------------------------------ a shadow repository
    # Real orchestrator, discovery and Foundation step; a stub installer and a fake FinOps step.
    $shadow = Join-Path $scratch 'shadow'
    foreach ($d in 'scripts\flow\lib', 'onboarding') { New-Item -ItemType Directory -Force -Path (Join-Path $shadow $d) | Out-Null }
    Copy-Item -LiteralPath (Join-Path $root 'Start-ClaudeGateway.ps1') -Destination $shadow
    foreach ($f in 'scripts\ClaudeChoice.ps1', 'scripts\AzureRetailPrice.ps1', 'scripts\ClaudeGatewayRegion.ps1', 'scripts\flow\FlowContract.ps1', 'scripts\flow\Discovery.ps1', 'scripts\flow\Foundation.ps1', 'scripts\flow\lib\LifecycleCommon.ps1') {
        if (Test-Path -LiteralPath (Join-Path $root $f)) { Copy-Item -LiteralPath (Join-Path $root $f) -Destination (Join-Path $shadow $f) }
    }
    $installerParams = @('SubscriptionId', 'FoundryAccount', 'FoundryResourceGroup', 'ResourceGroup', 'Location', 'NamePrefix', 'PublisherEmail', 'Sku', 'EntitlementStore', 'AuthMode', 'DesktopSignInKind', 'DesktopEntraClientId', 'DesktopEntraIssuer', 'DesktopEntraScopes', 'DesktopEntraAudience', 'DesktopEntraResource', 'ModelOrganizationName', 'ModelIndustry', 'ModelCountryCode', 'TpmStandard', 'QuotaStandard', 'TpmPremium', 'QuotaPremium', 'QuotaOrg', 'CallsPerMinute', 'StandardGroup', 'PremiumGroup')
    $stubInstaller = @(
        '[CmdletBinding(SupportsShouldProcess)]'
        'param('
        (($installerParams | ForEach-Object { "    [string]`$$_" }) -join ",`n") + ','
        '    [switch]$DeployProjection, [switch]$SkipFinOpsOffer, [switch]$ChooseFinOps, [switch]$Yes'
        ')'
        '$started = [DateTime]::UtcNow.Ticks'
        "Write-Host 'stub installer running'"
        '$bound = [ordered]@{}; foreach ($k in $PSBoundParameters.Keys) { $bound[$k] = [string]$PSBoundParameters[$k] }'
        "`$answer = if (`$Yes) { '(Yes)' } else { Read-Host 'stub installer question' }"
        '[ordered]@{ started = $started; bound = $bound; answer = $answer } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $env:P68_INSTALLER_LOG -Encoding UTF8'
        "if (`$answer -eq 'cancel') { Write-Host 'Cancelled.'; return }"
        "`$store = if (`$EntitlementStore) { `$EntitlementStore } else { 'named-value' }"
        "[ordered]@{ mode = 'gateway'; gatewayUrl = 'https://apim-p68.azure-api.net'; tenantId = '00000000-0000-0000-0000-000000000000'; apimName = 'apim-p68'; resourceGroup = 'rg-p68'; sku = 'StandardV2'; location = 'eastus2'; foundryAccount = 'ai-p68'; foundryResourceGroup = 'rg-ai-p68'; authMode = 'device'; entitlementStore = `$store; desktopSignIn = @{ kind = 'external-idp-browser' } } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path `$PSScriptRoot 'onboarding\claude-gateway.json') -Encoding UTF8"
        "Write-Host 'stub installer wrote its record'"
    ) -join "`n"
    Set-Content -LiteralPath (Join-Path $shadow 'Install-ClaudeGateway.ps1') -Value $stubInstaller -Encoding UTF8
    $fakeFinOps = Join-Path $shadow 'scripts\flow\FinOps.ps1'
    Set-Content -LiteralPath $fakeFinOps -Encoding UTF8 -Value @'
function Get-ClaudeFlowStepInfo { [pscustomobject]@{ Name = 'FinOps'; Title = 'FinOps tooling'; DecisionKey = 'finops'; DependsOn = @('Foundation'); Actions = @('Setup', 'Change') } }
function Get-ClaudeFlowStepQuestions {
    param($Record, $Discovery)
    if ($env:P68_FINOPS_LOG) {
        Add-Content -LiteralPath $env:P68_FINOPS_LOG -Value ([ordered]@{ ticks = [DateTime]::UtcNow.Ticks; apimName = [string]$Record.apimName; region = [string]$Discovery.Region; attended = [bool]$Discovery.attended; action = [string]$Discovery.action } | ConvertTo-Json -Compress)
    }
    if (Get-ClaudeDecision -Record $Record -Key finops) { return @() }
    @([pscustomobject]@{ Key = 'finops.tool'; Question = 'Which FinOps tool?'; Options = @((New-ClaudeChoiceOption -Value 'Direct' -Label 'AUM Direct' -Recommended -Reason 'test default'), (New-ClaudeChoiceOption -Value 'None' -Label 'None')); AcceptRecommendedWithoutConsole = $true })
}
function Get-ClaudeFlowStepPlan { param($Record, $Discovery) New-ClaudeFlowPlan -Step FinOps -Summary 'Configure AUM Direct' -Actions @(New-ClaudeFlowAction -Verb Write -Target 'AUM profile' -Detail 'test') -Costs @(New-ClaudeFlowCost -Item 'AUM Direct' -MonthlyUsd 0 -Source 'test') -Reversible $true -Rollback 'Delete the AUM profile' }
function Invoke-ClaudeFlowStep { param($Record, $Plan) if ($env:P68_FINOPS_LOG) { Add-Content -LiteralPath $env:P68_FINOPS_LOG -Value '{"applied":true}' }; @{ finops = [pscustomobject]@{ tool = 'Direct' } } }
function Test-ClaudeFlowStep { param($Record) [pscustomobject]@{ Step = 'FinOps'; Passed = $true; Checks = @() } }
'@
    $shadowStart = Join-Path $shadow 'Start-ClaudeGateway.ps1'
    $shadowConfig = Join-Path $shadow 'onboarding\claude-gateway.json'
    $installerLog = Join-Path $scratch 'installer.json'
    $finopsLog = Join-Path $scratch 'finops.log'
    function Reset-Shadow {
        foreach ($f in $shadowConfig, $installerLog, $finopsLog) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    }
    $recorded = [ordered]@{
        schemaVersion = 2; mode = 'gateway'; gatewayUrl = 'https://apim-p68.azure-api.net'; apimName = 'apim-p68'; resourceGroup = 'rg-p68'
        decisions = [ordered]@{ foundation = [ordered]@{ sku = 'BasicV2'; entitlementStore = 'named-value'; authMode = 'interactive'; desktopSignInKind = 'helper-script' }; finops = [ordered]@{ tool = 'Direct' } }
        history = @()
    }
    function New-RecordedGateway([string]$Name) {
        $path = Join-Path $scratch $Name
        $recorded | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path -Encoding UTF8
        return $path
    }

    # ------------------------------------------------------------------ discovery of a recorded gateway
    $azLog = Join-Path $scratch 'az-recorded.log'
    $match = Invoke-Child -Script $shadowStart -Arguments @('-Action', 'Setup', '-PlanOnly', '-RecordPath', (New-RecordedGateway 'recorded-match.json')) -Environment @{ P68_AZ_LOG = $azLog; P68_AZ_URL = 'https://apim-p68.azure-api.net' }
    $calls = @(Read-JsonLines $azLog)
    Assert 'a recorded gateway: exactly one Azure CLI call, apim show for that gateway' ($calls.Count -eq 1 -and ($calls[0].args -join ' ') -eq 'apim show -g rg-p68 -n apim-p68 -o json') (($calls | ForEach-Object { $_.args -join ' ' }) -join '; ')
    $readAt = Get-LineIndex $match 'Reading API Management rg-p68/apim-p68 from Azure \(about \d+ s\)'
    $doneAt = Get-LineIndex $match 'read in \d+(\.\d)? s'
    Assert 'a recorded gateway: the read is announced with an estimate, then timed' ($readAt -ge 0 -and $doneAt -gt $readAt) $match.Text
    Assert 'a recorded gateway that matches: the plan completes' ([bool](Get-Fingerprint $match.Text)) ($match.All | Select-Object -Last 1)
    Assert 'a recorded gateway in Setup: Foundation checks it and names -Change foundation' ($match.Text -match '\[Foundation\]' -and $match.Text -match 'Check\s+rg-p68/apim-p68' -and $match.Text -match '-Action Change -Change foundation')

    $drift = Invoke-Child -Script $shadowStart -Arguments @('-Action', 'Setup', '-PlanOnly', '-RecordPath', (New-RecordedGateway 'recorded-drift.json')) -Environment @{ P68_AZ_URL = 'https://apim-other.azure-api.net' }
    Assert 'a live gateway URL that differs from the record is drift, and Setup refuses' ($drift.ExitCode -ne 0 -and $drift.All -match 'does not match live state' -and $drift.All -match 'differs from live') ($drift.All | Select-Object -Last 1)
    $missing = Invoke-Child -Script $shadowStart -Arguments @('-Action', 'Setup', '-PlanOnly', '-RecordPath', (New-RecordedGateway 'recorded-missing.json')) -Environment @{ P68_AZ_MODE = 'missing' }
    Assert 'a recorded gateway that Azure reports missing is drift, and Setup refuses' ($missing.ExitCode -ne 0 -and $missing.All -match 'does not match live state' -and $missing.All -match 'not found') $missing.All
    $signedOut = Invoke-Child -Script $shadowStart -Arguments @('-Action', 'Setup', '-PlanOnly', '-RecordPath', (New-RecordedGateway 'recorded-signedout.json')) -Environment @{ P68_AZ_MODE = 'signedout' }
    Assert 'a read that fails for another reason is reported with its reason and is not drift' ((Get-Fingerprint $signedOut.Text) -and $signedOut.Text -match 'not read' -and $signedOut.Text -match 'az login') $signedOut.All
    $status = Invoke-Child -Script $shadowStart -Arguments @('-Action', 'Status', '-RecordPath', (New-RecordedGateway 'recorded-status.json')) -Environment @{ P68_AZ_MODE = 'signedout' }
    Assert 'Status after a failed read says drift was not checked, not that none was found' ($status.Text -match 'not checked' -and $status.Text -notmatch 'none detected') $status.Text
    $noAz = Invoke-Child -Script $shadowStart -Arguments @('-Action', 'Setup', '-PlanOnly', '-RecordPath', (New-RecordedGateway 'recorded-noaz.json')) -NoAz
    Assert 'without the Azure CLI the read is reported as not installed and the plan completes' ((Get-Fingerprint $noAz.Text) -and $noAz.Text -match 'Azure CLI' -and $noAz.Text -match 'not (installed|on PATH)') $noAz.All

    # ------------------------------------------------------------------ attended run, empty record
    Reset-Shadow
    $expectedFp = & {
        . (Join-Path $root 'scripts\flow\FlowContract.ps1')
        . (Join-Path $root 'scripts\ClaudeChoice.ps1')
        . $fakeFinOps
        Get-ClaudeFlowFingerprint -Plans @(Get-ClaudeFlowStepPlan -Record $null -Discovery $null)
    }
    $azLog = Join-Path $scratch 'az-attended.log'
    $attendedRecord = Join-Path $scratch 'attended-record.json'
    $attended = Invoke-Child -Script $shadowStart -Attended -Arguments @('-Action', 'Setup', '-RecordPath', $attendedRecord) -InputLines @('stub-answer', '', $expectedFp.Substring(0, 8)) -Environment @{ P68_AZ_LOG = $azLog; P68_AZ_URL = 'https://apim-p68.azure-api.net'; P68_INSTALLER_LOG = $installerLog; P68_FINOPS_LOG = $finopsLog }
    Assert 'attended Setup completes' ($attended.ExitCode -eq 0 -and -not $attended.TimedOut) ($attended.All | Select-Object -Last 1)
    $installerRun = if (Test-Path -LiteralPath $installerLog) { Read-Json $installerLog } else { $null }
    Assert 'attended Setup runs the installer without -Yes, so the installer asks its questions' ($installerRun -and -not ($installerRun.bound.PSObject.Properties.Name -contains 'Yes') -and $installerRun.answer -eq 'stub-answer') ($installerRun | ConvertTo-Json -Compress -Depth 4)
    Assert 'attended Setup tells the installer that the FinOps step follows' ($installerRun -and $installerRun.bound.SkipFinOpsOffer -eq 'True')
    Assert 'attended Setup with an empty record passes the installer no decision values' ($installerRun -and @($installerRun.bound.PSObject.Properties.Name | Where-Object { $_ -ne 'SkipFinOpsOffer' }).Count -eq 0) (($installerRun.bound.PSObject.Properties.Name) -join ',')
    $reviewAt = Get-LineIndex $attended 'Install-ClaudeGateway\.ps1 asks'
    $installerAt = Get-LineIndex $attended 'stub installer running'
    $fingerprintAt = Get-LineIndex $attended 'Fingerprint:'
    Assert 'the Foundation review names the installer''s questions before the installer starts' ($reviewAt -ge 0 -and $installerAt -gt $reviewAt) "review=$reviewAt installer=$installerAt"
    Assert 'no fingerprint is asked for before the installer' ($installerAt -ge 0 -and $fingerprintAt -gt $installerAt) "installer=$installerAt fingerprint=$fingerprintAt"
    $asked = @(Read-JsonLines $finopsLog | Where-Object { $_.PSObject.Properties.Name -contains 'ticks' })
    Assert 'the FinOps question is asked only after the installer created the gateway' ($asked.Count -ge 1 -and @($asked | Where-Object { $_.ticks -lt $installerRun.started -or -not $_.apimName }).Count -eq 0) ($asked | ConvertTo-Json -Compress)
    Assert 'the FinOps step sees the new gateway''s region and an attended Setup' ($asked.Count -ge 1 -and $asked[0].region -eq 'eastus2' -and $asked[0].attended -and $asked[0].action -eq 'Setup') ($asked | ConvertTo-Json -Compress)
    $calls = @(Read-JsonLines $azLog)
    $showCalls = @($calls | Where-Object { ($_.args -join ' ') -like 'apim show*' })
    Assert 'no Azure CLI call runs before the installer; the new gateway is read after it' ($installerRun -and @($calls | Where-Object { $_.ticks -lt $installerRun.started }).Count -eq 0 -and $showCalls.Count -eq 1) (($calls | ForEach-Object { $_.args -join ' ' }) -join '; ')
    $final = if (Test-Path -LiteralPath $attendedRecord) { Read-Json $attendedRecord } else { $null }
    Assert 'the record keeps what the installer created: tier, region and Foundry account' ($final -and $final.decisions.foundation.sku -eq 'StandardV2' -and $final.decisions.foundation.location -eq 'eastus2' -and $final.decisions.foundation.foundryAccount -eq 'ai-p68' -and $final.decisions.foundation.foundryResourceGroup -eq 'rg-ai-p68') ($final.decisions.foundation | ConvertTo-Json -Compress)
    Assert 'the record keeps the installer''s sign-in and store choices in the foundation decision' ($final -and $final.decisions.foundation.authMode -eq 'device' -and $final.decisions.foundation.desktopSignInKind -eq 'external-idp-browser' -and $final.decisions.foundation.entitlementStore -eq 'named-value')
    Assert 'the record has both steps in its history and no active run' ($final -and (@($final.history | ForEach-Object decision) -join ',') -eq 'foundation,finops' -and -not ($final.PSObject.Properties.Name -contains 'activeRun') -and $final.decisions.finops.tool -eq 'Direct') ((@($final.history | ForEach-Object decision)) -join ',')

    # Cancelled at the installer's summary: nothing after the foundation runs.
    Reset-Shadow
    $cancelRecord = Join-Path $scratch 'cancel-record.json'
    $cancel = Invoke-Child -Script $shadowStart -Attended -Arguments @('-Action', 'Setup', '-RecordPath', $cancelRecord) -InputLines @('cancel') -Environment @{ P68_INSTALLER_LOG = $installerLog; P68_FINOPS_LOG = $finopsLog }
    Assert 'an installer that writes no record stops the flow with the reason and no stack trace' ($cancel.ExitCode -ne 0 -and $cancel.All -match 'Install-ClaudeGateway\.ps1 finished without writing' -and $cancel.All -notmatch 'Line \|' -and -not $cancel.TimedOut) ($cancel.All | Select-Object -Last 3)
    Assert 'after a cancelled installer no FinOps question is asked' (@(Read-JsonLines $finopsLog).Count -eq 0)

    # Change foundation over a recorded gateway, attended: the installer runs and asks.
    Reset-Shadow
    $change = Invoke-Child -Script $shadowStart -Attended -Arguments @('-Action', 'Change', '-Change', 'foundation', '-RecordPath', (New-RecordedGateway 'recorded-change.json')) -InputLines @('stub-answer') -Environment @{ P68_AZ_URL = 'https://apim-p68.azure-api.net'; P68_INSTALLER_LOG = $installerLog }
    $changeRun = if (Test-Path -LiteralPath $installerLog) { Read-Json $installerLog } else { $null }
    Assert 'attended -Change foundation over a recorded gateway runs the installer without -Yes' ($change.ExitCode -eq 0 -and $changeRun -and -not ($changeRun.bound.PSObject.Properties.Name -contains 'Yes') -and $changeRun.answer -eq 'stub-answer') ($change.All | Select-Object -Last 3)

    # ------------------------------------------------------------------ unattended runs
    Reset-Shadow
    $projectionAnswers = Join-Path $scratch 'projection-answers.json'
    @{ 'foundation.sku' = 'BasicV2'; 'foundation.entitlementStore' = 'projection'; 'foundation.authMode' = 'interactive'; 'foundation.desktopSignInKind' = 'helper-script' } | ConvertTo-Json | Set-Content -LiteralPath $projectionAnswers -Encoding UTF8
    $uRecord = Join-Path $scratch 'unattended-record.json'
    $uPlan = Invoke-Child -Script $shadowStart -Arguments @('-Action', 'Setup', '-PlanOnly', '-RecordPath', $uRecord, '-AnswersPath', $projectionAnswers) -Environment @{ P68_INSTALLER_LOG = $installerLog }
    $uFp = Get-Fingerprint $uPlan.Text
    $uApply = Invoke-Child -Script $shadowStart -Arguments @('-Action', 'Setup', '-RecordPath', $uRecord, '-AnswersPath', $projectionAnswers, '-ApprovedPlanFingerprint', $uFp) -Environment @{ P68_AZ_URL = 'https://apim-p68.azure-api.net'; P68_INSTALLER_LOG = $installerLog; P68_FINOPS_LOG = $finopsLog }
    $uRun = if (Test-Path -LiteralPath $installerLog) { Read-Json $installerLog } else { $null }
    Assert 'without a console Setup passes -Yes' ($uApply.ExitCode -eq 0 -and $uRun -and $uRun.bound.Yes -eq 'True') ($uApply.All | Select-Object -Last 3)
    Assert 'without a console the Cosmos store adds -DeployProjection, so the installer deploys it' ($uRun -and $uRun.bound.DeployProjection -eq 'True' -and $uRun.bound.EntitlementStore -eq 'projection')

    Reset-Shadow
    $rRecord = New-RecordedGateway 'recorded-apply.json'
    $rPlan = Invoke-Child -Script $shadowStart -Arguments @('-Action', 'Setup', '-PlanOnly', '-RecordPath', $rRecord) -Environment @{ P68_AZ_URL = 'https://apim-p68.azure-api.net' }
    $rApply = Invoke-Child -Script $shadowStart -Arguments @('-Action', 'Setup', '-RecordPath', $rRecord, '-ApprovedPlanFingerprint', (Get-Fingerprint $rPlan.Text)) -Environment @{ P68_AZ_URL = 'https://apim-p68.azure-api.net'; P68_INSTALLER_LOG = $installerLog }
    Assert 'Setup over a recorded gateway never runs the installer' ($rApply.ExitCode -eq 0 -and -not (Test-Path -LiteralPath $installerLog)) ($rApply.All | Select-Object -Last 3)
    $gRecord = New-RecordedGateway 'recorded-guide.json'
    $gPlan = Invoke-Child -Script $shadowStart -Arguments @('-Action', 'Guide', '-PlanOnly', '-RecordPath', $gRecord) -Environment @{ P68_AZ_URL = 'https://apim-p68.azure-api.net' }
    $gApply = Invoke-Child -Script $shadowStart -Arguments @('-Action', 'Guide', '-RecordPath', $gRecord, '-ApprovedPlanFingerprint', (Get-Fingerprint $gPlan.Text)) -Environment @{ P68_AZ_URL = 'https://apim-p68.azure-api.net'; P68_INSTALLER_LOG = $installerLog }
    Assert 'Guide never runs the installer' ($gApply.ExitCode -eq 0 -and -not (Test-Path -LiteralPath $installerLog)) ($gApply.All | Select-Object -Last 3)

    # ------------------------------------------------------------------ Foundation step, in process
    $f = & {
        . (Join-Path $root 'scripts\flow\FlowContract.ps1')
        . (Join-Path $root 'scripts\ClaudeChoice.ps1')
        . (Join-Path $root 'scripts\flow\Foundation.ps1')
        $emptyRecord = [pscustomobject]@{ schemaVersion = 2; decisions = [pscustomobject]@{}; history = @() }
        $withDecision = { param($store) [pscustomobject]@{ schemaVersion = 2; decisions = [pscustomobject]@{ foundation = [pscustomobject]@{ sku = 'BasicV2'; entitlementStore = $store; authMode = 'interactive'; desktopSignInKind = 'helper-script' } }; history = @() } }
        $gatewayRecord = [pscustomobject]@{ schemaVersion = 2; apimName = 'apim-p68'; resourceGroup = 'rg-p68'; gatewayUrl = 'https://apim-p68.azure-api.net'; decisions = [pscustomobject]@{ foundation = [pscustomobject]@{ sku = 'BasicV2' } }; history = @() }
        $oddRecord = [pscustomobject]@{ schemaVersion = 2; apimName = 'contoso-gateway'; resourceGroup = 'rg-p68'; gatewayUrl = 'https://contoso-gateway.azure-api.net'; decisions = [pscustomobject]@{ foundation = [pscustomobject]@{ sku = 'BasicV2' } }; history = @() }
        $live = [pscustomobject]@{ name = 'apim-p68'; resourceGroup = 'rg-p68'; sku = 'StandardV2'; location = 'eastus2'; publisherEmail = 'ops@contoso.com'; gatewayUrl = 'https://apim-p68.azure-api.net' }
        $ctx = { param($action, $attended, $gateway) [pscustomobject]@{ action = $action; attended = $attended; gateway = $gateway; Region = $null } }
        $oddThrown = try { Get-ClaudeFlowStepPlan -Record $oddRecord -Discovery (& $ctx 'Change' $false $null) | Out-Null; '' } catch { $_.Exception.Message }
        $attendedPlan = Get-ClaudeFlowStepPlan -Record $emptyRecord -Discovery (& $ctx 'Setup' $true $null)
        [pscustomobject]@{
            Info = Get-ClaudeFlowStepInfo
            AttendedQuestions = @(Get-ClaudeFlowStepQuestions -Record $emptyRecord -Discovery (& $ctx 'Setup' $true $null))
            UnattendedQuestions = @(Get-ClaudeFlowStepQuestions -Record $emptyRecord -Discovery (& $ctx 'Setup' $false $null))
            Attended = $attendedPlan
            AttendedReview = (Format-ClaudeFlowReview -Plans @($attendedPlan))
            Projection = Get-ClaudeFlowStepPlan -Record (& $withDecision 'projection') -Discovery (& $ctx 'Setup' $false $null)
            NamedValue = Get-ClaudeFlowStepPlan -Record (& $withDecision 'named-value') -Discovery (& $ctx 'Setup' $false $null)
            NoContext = Get-ClaudeFlowStepPlan -Record (& $withDecision 'named-value') -Discovery $null
            Recorded = Get-ClaudeFlowStepPlan -Record $gatewayRecord -Discovery (& $ctx 'Setup' $true $live)
            RecordedUnattended = Get-ClaudeFlowStepPlan -Record $gatewayRecord -Discovery (& $ctx 'Setup' $false $live)
            GuideRecorded = Get-ClaudeFlowStepPlan -Record $gatewayRecord -Discovery (& $ctx 'Guide' $true $live)
            GuideEmpty = Get-ClaudeFlowStepPlan -Record $emptyRecord -Discovery (& $ctx 'Guide' $false $null)
            ChangeAttended = Get-ClaudeFlowStepPlan -Record $gatewayRecord -Discovery (& $ctx 'Change' $true $live)
            ChangeUnattended = Get-ClaudeFlowStepPlan -Record $gatewayRecord -Discovery (& $ctx 'Change' $false $live)
            OddThrown = $oddThrown
        }
    }
    Assert 'Foundation declares that an attended run may apply it first' ([bool]$f.Info.AttendedFirst)
    Assert 'in an attended run the flow asks no foundation question itself' ($f.AttendedQuestions.Count -eq 0) (($f.AttendedQuestions | ForEach-Object Key) -join ',')
    Assert 'without a console the four foundation questions stay' ((($f.UnattendedQuestions | ForEach-Object Key) -join ',') -eq 'foundation.sku,foundation.entitlementStore,foundation.authMode,foundation.desktopSignInKind')
    Assert 'the attended plan runs the installer, which asks, with no -Yes' ($f.Attended.Data.runsInstaller -and $f.Attended.Data.asksInConsole -and @($f.Attended.Actions)[0].Verb -eq 'Run' -and @($f.Attended.Actions)[0].Target -eq 'Install-ClaudeGateway.ps1' -and -not (Test-Key $f.Attended.Data.installerArgs 'Yes') -and $f.Attended.Data.installerArgs['SkipFinOpsOffer'] -eq $true)
    Assert 'the attended review says the installer creates nothing until its summary is confirmed' ($f.AttendedReview -match 'creates nothing until you confirm its summary') $f.AttendedReview
    Assert 'the unattended plan passes -Yes and -DeployProjection with the Cosmos store' ($f.Projection.Data.runsInstaller -and -not $f.Projection.Data.asksInConsole -and $f.Projection.Data.installerArgs['Yes'] -eq $true -and $f.Projection.Data.installerArgs['DeployProjection'] -eq $true -and $f.Projection.Data.installerArgs['EntitlementStore'] -eq 'projection')
    Assert 'named values add no -DeployProjection' (-not (Test-Key $f.NamedValue.Data.installerArgs 'DeployProjection') -and $f.NamedValue.Data.installerArgs['Yes'] -eq $true)
    Assert 'a plan without flow context is the unattended Setup plan' ($f.NoContext.Data.runsInstaller -and $f.NoContext.Data.installerArgs['Yes'] -eq $true -and @($f.NoContext.Actions)[0].Verb -eq 'Create')
    Assert 'Setup over a recorded gateway checks it, attended or not' (-not $f.Recorded.Data.runsInstaller -and -not $f.RecordedUnattended.Data.runsInstaller -and @($f.Recorded.Actions)[0].Verb -eq 'Check')
    Assert 'the cost of a recorded gateway is named as already running, not as a new cost' ([string]@($f.Recorded.Costs)[0].Item -match 'already running') ([string]@($f.Recorded.Costs)[0].Item)
    Assert 'Guide never runs the installer, with or without a recorded gateway' (-not $f.GuideRecorded.Data.runsInstaller -and -not $f.GuideEmpty.Data.runsInstaller)
    Assert 'attended -Change foundation runs the installer, which asks' ($f.ChangeAttended.Data.runsInstaller -and $f.ChangeAttended.Data.asksInConsole -and -not (Test-Key $f.ChangeAttended.Data.installerArgs 'Yes'))
    $cu = $f.ChangeUnattended.Data.installerArgs
    Assert 'unattended -Change foundation targets the recorded gateway, keeping its live tier, region and publisher' ($f.ChangeUnattended.Data.runsInstaller -and $cu['Yes'] -eq $true -and $cu['NamePrefix'] -eq 'p68' -and $cu['ResourceGroup'] -eq 'rg-p68' -and $cu['Sku'] -eq 'StandardV2' -and $cu['Location'] -eq 'eastus2' -and $cu['PublisherEmail'] -eq 'ops@contoso.com') ($cu | ConvertTo-Json -Compress)
    Assert 'unattended -Change foundation refuses a gateway the installer cannot name' ($f.OddThrown -match 'contoso-gateway' -and $f.OddThrown -match 'console') $f.OddThrown
    $installerCommand = Get-Command (Join-Path $root 'Install-ClaudeGateway.ps1')
    $unknownArgs = @(foreach ($plan in $f.Attended, $f.Projection, $f.NamedValue, $f.ChangeUnattended) { foreach ($k in @(if ($plan.Data.installerArgs) { $plan.Data.installerArgs.Keys })) { if (-not $installerCommand.Parameters.ContainsKey([string]$k)) { $k } } })
    Assert 'every installer argument the plans pass is a parameter of Install-ClaudeGateway.ps1' ($unknownArgs.Count -eq 0) ($unknownArgs -join ',')

    # Every installer section that asks something is named in the attended Foundation review.
    $installerText = [IO.File]::ReadAllText((Join-Path $root 'Install-ClaudeGateway.ps1'))
    $asksNothing = @('Summary', 'Deploying', 'Resource group', 'Entra groups', 'Sync entitlement', 'Projection deployment', 'Onboarding package', 'Verifying the controls', 'Done')
    $named = [ordered]@{
        'Azure sign-in' = 'subscription'; 'Foundry account' = 'Foundry account'; 'Which models each tier may call' = 'models each tier may call'
        'Where to put the gateway' = 'region'; 'Choices' = 'entitlement store'; 'Budgets' = 'token budgets'; 'Standard tier' = 'token budgets for each tier'
        'Premium tier' = 'token budgets for each tier'; 'Organisation ceiling' = 'organisation ceiling'; 'Safety valve' = 'request ceiling'
        'Entitlement groups' = 'Entra groups'; 'Business units (optional)' = 'business units'
    }
    $headings = @([regex]::Matches($installerText, "(?m)Write-(?:Step|Head)\s+'([^']+)'") | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    $unnamed = @($headings | Where-Object { $_ -notin $asksNothing -and -not $named.Contains($_) })
    $detail = [string]@($f.Attended.Actions)[0].Detail
    $missingTopics = @($named.Keys | Where-Object { $detail -notmatch [regex]::Escape($named[$_]) })
    Assert 'every installer section is either named by the Foundation review or asks nothing' ($unnamed.Count -eq 0) ($unnamed -join ', ')
    Assert 'the Foundation review names the topic of every installer section that asks' ($missingTopics.Count -eq 0) ($missingTopics -join ', ')

    # ------------------------------------------------------------------ Test-ClaudeInteractive
    # Each case in its own process: the process that runs this test is started with -NonInteractive.
    $probe = Join-Path $scratch 'probe-interactive.ps1'
    Set-Content -LiteralPath $probe -Encoding UTF8 -Value (". '" + (Join-Path $root 'scripts\ClaudeChoice.ps1').Replace("'", "''") + "'; Write-Host ('interactive=' + (Test-ClaudeInteractive))")
    $forced = Invoke-Child -Script $probe -Attended
    $both = Invoke-Child -Script $probe -Attended -Environment @{ CLAUDE_NONINTERACTIVE = '1' }
    $noni = Invoke-Child -Script $probe -Environment @{ CLAUDE_INTERACTIVE = '1' }
    Assert 'CLAUDE_INTERACTIVE=1 treats a process with redirected input as a console' ($forced.Text -match 'interactive=True') $forced.All
    Assert 'CLAUDE_INTERACTIVE=1 does not override -NonInteractive' ($noni.Text -match 'interactive=False') $noni.All

    Assert 'CLAUDE_NONINTERACTIVE=1 wins over CLAUDE_INTERACTIVE=1' ($both.Text -match 'interactive=False') $both.All

    # ------------------------------------------------------------------ region and tier prices
    $pricePage = @(
        foreach ($row in @(
            @('eastus2', 'Basic v2 Unit', 0.21), @('eastus2', 'Standard v2 Unit', 0.96), @('eastus2', 'Premium v2 Unit', 3.84),
            @('eastus', 'Basic v2 Unit', 0.21), @('eastus', 'Standard v2 Unit', 0.96), @('eastus', 'Premium v2 Unit', 3.84),
            @('westus3', 'Basic v2 Unit', 0.20), @('westus3', 'Standard v2 Unit', 0.90),
            @('westeurope', 'Basic v2 Unit', 0.25), @('westeurope', 'Standard v2 Unit', 1.10), @('westeurope', 'Premium v2 Unit', 4.40))) {
            [pscustomobject]@{ armRegionName = $row[0]; meterName = $row[1]; retailPrice = $row[2]; unitOfMeasure = '1 Hour'; currencyCode = 'USD'; tierMinimumUnits = 0; type = 'Consumption'; skuName = ($row[1] -replace ' Unit$', ''); productName = 'API Management' }
        }
        [pscustomobject]@{ armRegionName = 'eastus'; meterName = 'Basic v2 Unit'; retailPrice = 0; unitOfMeasure = '1 Hour'; currencyCode = 'USD'; tierMinimumUnits = 0; type = 'Consumption'; skuName = 'Free Tier'; productName = 'API Management' }
    )
    $locations = @(
        [pscustomobject]@{ name = 'eastus2'; displayName = 'East US 2'; metadata = [pscustomobject]@{ regionType = 'Physical'; geographyGroup = 'US' } }
        [pscustomobject]@{ name = 'eastus'; displayName = 'East US'; metadata = [pscustomobject]@{ regionType = 'Physical'; geographyGroup = 'US' } }
        [pscustomobject]@{ name = 'westus3'; displayName = 'West US 3'; metadata = [pscustomobject]@{ regionType = 'Physical'; geographyGroup = 'US' } }
        [pscustomobject]@{ name = 'eastus2euap'; displayName = 'East US 2 EUAP'; metadata = [pscustomobject]@{ regionType = 'Physical'; geographyGroup = 'US' } }
        [pscustomobject]@{ name = 'unitedstates'; displayName = 'United States'; metadata = [pscustomobject]@{ regionType = 'Logical'; geographyGroup = 'US' } }
        [pscustomobject]@{ name = 'westeurope'; displayName = 'West Europe'; metadata = [pscustomobject]@{ regionType = 'Physical'; geographyGroup = 'Europe' } }
    )
    $prices = & {
        . (Join-Path $root 'scripts\AzureRetailPrice.ps1')
        . (Join-Path $root 'scripts\ClaudeGatewayRegion.ps1')
        $script:uris = [Collections.Generic.List[string]]::new()
        $script:page = 0
        function Invoke-RestMethod {
            param($Uri, $TimeoutSec, $ErrorAction)
            $script:uris.Add([string]$Uri)
            $script:page++
            if ($script:page -eq 1) { return [pscustomobject]@{ Items = @($pricePage | Select-Object -First 6); NextPageLink = 'https://prices.azure.com/api/retail/prices?page=2' } }
            return [pscustomobject]@{ Items = @($pricePage | Select-Object -Skip 6); NextPageLink = $null }
        }
        $read = Get-ClaudeApimV2Prices
        $options = @(Get-ClaudeGatewayRegionOptions -FoundryRegion 'eastus2' -Locations $locations -Prices $read)
        $nestedOptions = @(Get-ClaudeGatewayRegionOptions -FoundryRegion 'eastus2' -Locations @(, $locations) -Prices $read)
        $table = @(Format-ClaudeGatewayRegionTable -Options $options -Prices $read)
        $tiers = @(Format-ClaudeApimTierPriceLines -Region 'westus3' -Prices $read)
        $known = @($locations | ForEach-Object name)
        $resolved = [ordered]@{}
        foreach ($answer in '1', '2', '3', 'WestUS3', 'westeurope', 'nowhere', '9', '') { $resolved[$answer] = Resolve-ClaudeGatewayRegionAnswer -Answer $answer -Options $options -KnownRegions $known }
        function Invoke-RestMethod { param($Uri, $TimeoutSec, $ErrorAction) throw 'simulated outage' }
        . (Join-Path $root 'scripts\AzureRetailPrice.ps1')
        $down = Get-ClaudeApimV2Prices
        [pscustomobject]@{ Uris = @($script:uris); Read = $read; Options = $options; Nested = $nestedOptions; Table = $table; Tiers = $tiers; Resolved = $resolved; Down = $down; Arm = (ConvertTo-ClaudeArmRegionName 'East US 2') }
    }
    $filter = [uri]::UnescapeDataString(([string]$prices.Uris[0] -split '\$filter=', 2)[1])
    Assert 'one Retail Prices API query reads the three v2 unit meters in every region, eq and or only' ($filter -match "serviceName eq 'API Management'" -and $filter -match "meterName eq 'Basic v2 Unit' or meterName eq 'Standard v2 Unit' or meterName eq 'Premium v2 Unit'" -and $filter -notmatch 'armRegionName' -and $filter -notmatch 'contains\(') $filter
    Assert 'the price read follows NextPageLink' ($prices.Uris.Count -eq 2)
    Assert 'a v2 tier is priced monthly at 730 hours and a free-tier row does not shadow it' ($prices.Read.ByRegion['eastus2']['BasicV2'] -eq 153.30 -and $prices.Read.ByRegion['eastus2']['PremiumV2'] -eq 2803.20 -and $prices.Read.ByRegion['eastus']['BasicV2'] -eq 153.30)
    Assert 'a tier the API does not publish is null, never zero' ($null -eq $prices.Read.ByRegion['westus3']['PremiumV2'])
    Assert 'an unreachable price API returns no prices and the reason' ($null -eq $prices.Down.ByRegion -and $prices.Down.Unreachable -match 'simulated outage') $prices.Down.Unreachable
    $order = @($prices.Options | ForEach-Object Region) -join ','
    Assert 'region options: the Foundry region first, then its geography by price, without unpriced or logical regions' ($order -eq 'eastus2,westus3,eastus') $order
    Assert 'region options from locations passed as one nested array, as Windows PowerShell 5.1 parses them' ((@($prices.Nested | ForEach-Object Region) -join ',') -eq 'eastus2,westus3,eastus') (@($prices.Nested | ForEach-Object Region) -join ',')
    Assert 'the Foundry region is marked as such' ($prices.Options[0].SameAsFoundry -and -not $prices.Options[1].SameAsFoundry)
    $tableText = $prices.Table -join "`n"
    Assert 'the region table shows each tier''s monthly list price' ($tableText -match 'USD 153\.30' -and $tableText -match 'USD 700\.80' -and $tableText -match 'USD 2,803\.20' -and $tableText -match 'USD 146\.00') $tableText
    Assert 'the region table shows an unpublished price as not published' ($tableText -match 'not published') $tableText
    Assert 'the region table names list prices, 730 hours, the source and when it was read' ($tableText -match 'list price' -and $tableText -match '730 hours' -and $tableText -match 'Azure Retail Prices API' -and $tableText -match '\d{4}-\d{2}-\d{2} \d{2}:\d{2} UTC') $tableText
    Assert 'the region table names the agreement''s price sheet as the authority and the billing role it needs' ($tableText -match 'price sheet' -and $tableText -match 'billing role') $tableText
    $tierText = $prices.Tiers -join "`n"
    Assert 'the tier lines price each tier in the chosen region' ($tierText -match 'BasicV2\s+USD 146\.00' -and $tierText -match 'StandardV2\s+USD 657\.00' -and $tierText -match 'PremiumV2\s+not published') $tierText
    $r = $prices.Resolved
    Assert 'a region answer may be a number or a name in any case' ($r['1'] -eq 'eastus2' -and $r['2'] -eq 'westus3' -and $r['3'] -eq 'eastus' -and $r['WestUS3'] -eq 'westus3') ($r | ConvertTo-Json -Compress)
    Assert 'a region outside the table is accepted by name; unknown names and numbers are not' ($r['westeurope'] -eq 'westeurope' -and $null -eq $r['nowhere'] -and $null -eq $r['9'] -and $null -eq $r['']) ($r | ConvertTo-Json -Compress)
    Assert 'a display name converts to the ARM region name' ($prices.Arm -eq 'eastus2') $prices.Arm

    # ------------------------------------------------------------------ the installer's own prompts
    $ast = [Management.Automation.Language.Parser]::ParseInput($installerText, [ref]$null, [ref]$null)
    $fnText = @{}
    foreach ($fn in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) { $fnText[$fn.Name] = $fn.Extent.Text }
    $needed = @('Read-Default', 'Write-Note', 'Write-Warn2', 'Invoke-AzOptional', 'Read-GatewayRegion', 'Show-GatewayTierPrices', 'Write-NextSteps')
    $absent = @($needed | Where-Object { -not $fnText.ContainsKey($_) })
    Assert 'the installer defines its region, tier price and next-step helpers' ($absent.Count -eq 0) ($absent -join ', ')
    if (-not $absent.Count) {
        $prompt = & {
            . (Join-Path $root 'scripts\AzureRetailPrice.ps1')
            . (Join-Path $root 'scripts\ClaudeGatewayRegion.ps1')
            foreach ($name in $needed) { . ([scriptblock]::Create($fnText[$name])) }
            $Yes = $false
            $script:azCalls = 0
            $script:priceCalls = 0
            $script:replies = [Collections.Generic.Queue[string]]::new()
            function az { $script:azCalls++; $global:LASTEXITCODE = 0; $locations | ConvertTo-Json -Depth 5 }
            function Invoke-RestMethod { param($Uri, $TimeoutSec, $ErrorAction) $script:priceCalls++; [pscustomobject]@{ Items = $pricePage; NextPageLink = $null } }
            function Read-Host { if ($script:replies.Count) { $script:replies.Dequeue() } else { '' } }
            $run = {
                param([string[]]$Replies, [string]$Default)
                $script:replies.Clear(); foreach ($x in $Replies) { $script:replies.Enqueue($x) }
                $out = @(Read-GatewayRegion -Default $Default 6>&1)
                [pscustomobject]@{ Region = [string]@($out | Where-Object { $_ -is [string] })[-1]; Text = (@($out | ForEach-Object { [string]$_ }) -join "`n") }
            }
            $byNumber = & $run @('3') 'eastus2'
            $retry = & $run @('nowhere', 'westeurope') 'eastus2'
            $tier = @(Show-GatewayTierPrices -Region 'eastus2' 6>&1 | ForEach-Object { [string]$_ }) -join "`n"
            $steps = @(Write-NextSteps -Steps @([pscustomobject]@{ Title = 'a'; Detail = @(); Warn = $false }, [pscustomobject]@{ Title = 'b'; Detail = @('      detail b'); Warn = $true }, [pscustomobject]@{ Title = 'c'; Detail = @(); Warn = $false }) 6>&1 | ForEach-Object { [string]$_ })
            $callsBeforeYes = $script:azCalls + $script:priceCalls
            $Yes = $true
            $unattended = Read-GatewayRegion -Default 'eastus2' 6>&1 | Where-Object { $_ -is [string] } | Select-Object -Last 1
            $callsAfterYes = $script:azCalls + $script:priceCalls
            $Yes = $false
            function Invoke-RestMethod { param($Uri, $TimeoutSec, $ErrorAction) throw 'simulated outage' }
            . (Join-Path $root 'scripts\AzureRetailPrice.ps1')
            $offline = & $run @('') 'eastus2'
            [pscustomobject]@{ ByNumber = $byNumber; Retry = $retry; Tier = $tier; Steps = $steps; Unattended = $unattended; YesCalls = ($callsAfterYes - $callsBeforeYes); Offline = $offline }
        }
        Assert 'the region prompt shows the priced table and takes a number' ($prompt.ByNumber.Region -eq 'eastus' -and $prompt.ByNumber.Text -match 'USD 153\.30' -and $prompt.ByNumber.Text -match 'not published') $prompt.ByNumber.Text
        Assert 'the region prompt refuses an unknown region and takes a known one by name' ($prompt.Retry.Region -eq 'westeurope' -and $prompt.Retry.Text -match 'nowhere') $prompt.Retry.Text
        Assert 'with -Yes the region prompt takes the default and reads nothing' ($prompt.Unattended -eq 'eastus2' -and $prompt.YesCalls -eq 0) "calls=$($prompt.YesCalls)"
        Assert 'with the price API unreachable the region prompt says so and still takes the default' ($prompt.Offline.Region -eq 'eastus2' -and $prompt.Offline.Text -match 'could not be read') $prompt.Offline.Text
        Assert 'the tier prompt lists each tier''s monthly list price in the region' ($prompt.Tier -match 'BasicV2\s+USD 153\.30' -and $prompt.Tier -match 'StandardV2\s+USD 700\.80' -and $prompt.Tier -match 'PremiumV2\s+USD 2,803\.20') $prompt.Tier
        $stepText = $prompt.Steps -join "`n"
        Assert 'next steps are numbered 1, 2, 3 in order' ($stepText -match '(?m)^\s+1\. a$' -and $stepText -match '(?m)^\s+2\. b$' -and $stepText -match '(?m)^\s+3\. c$' -and $stepText -match 'detail b') $stepText

        # Windows PowerShell 5.1 holds a parsed JSON array as one element; measured 2026-09-27, the
        # region table then listed only the Foundry region.
        $ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (Test-Path -LiteralPath $ps51) {
            $pricesJson = Join-Path $scratch 'prices51.json'
            $locationsJson = Join-Path $scratch 'locations51.json'
            [IO.File]::WriteAllText($pricesJson, ($pricePage | ConvertTo-Json -Depth 5))
            [IO.File]::WriteAllText($locationsJson, ($locations | ConvertTo-Json -Depth 5))
            $probe51 = Join-Path $scratch 'probe-region-51.ps1'
            $lit = { param($s) "'" + $s.Replace("'", "''") + "'" }
            $probeText = @(
                ". $(& $lit (Join-Path $root 'scripts\AzureRetailPrice.ps1'))"
                ". $(& $lit (Join-Path $root 'scripts\ClaudeGatewayRegion.ps1'))"
                @('Read-Default', 'Write-Note', 'Write-Warn2', 'Invoke-AzOptional', 'Read-GatewayRegion') | ForEach-Object { $fnText[$_] }
                '$Yes = $false'
                "function az { `$global:LASTEXITCODE = 0; [IO.File]::ReadAllText($(& $lit $locationsJson)) }"
                "function Invoke-RestMethod { param(`$Uri, `$TimeoutSec, `$ErrorAction) `$rows = [IO.File]::ReadAllText($(& $lit $pricesJson)) | ConvertFrom-Json; [pscustomobject]@{ Items = @(`$rows); NextPageLink = `$null } }"
                '$script:replyCount = 0', "function Read-Host { `$script:replyCount++; if (`$script:replyCount -eq 1) { 'westeurope' } else { 'eastus2' } }"
                '$region = Read-GatewayRegion -Default ''eastus2'''
                'Write-Host ("REGION=" + $region)'
            ) -join "`r`n"
            [IO.File]::WriteAllText($probe51, $probeText, (New-Object Text.UTF8Encoding($true)))
            $out51 = (& $ps51 -NoProfile -NonInteractive -File $probe51 2>&1 | ForEach-Object { "$_" }) -join "`n"
            Assert 'on Windows PowerShell 5.1 the region table lists the whole geography and takes a region by name' ($out51 -match 'REGION=westeurope\b' -and $out51 -match '(?m)^\s+3\. eastus\s' -and $out51 -match '(?m)^\s+2\. westus3\s') $out51
        }
        else { Assert 'Windows PowerShell 5.1 is present for the region prompt check' $false $ps51 }
    }
    $nextSection = $installerText.Substring([Math]::Max(0, $installerText.IndexOf('# ----------------------------------------------------------------- 10. next')))
    Assert 'no next step carries a hard-coded number' ($nextSection -notmatch "Write-Host\s+'\s+\d+\.\s") ([regex]::Matches($nextSection, "Write-Host\s+'\s+\d+\.\s[^']*") | ForEach-Object Value | Select-Object -First 3)
    Assert 'the installer offers the FinOps tool in a console unless -Yes or -SkipFinOpsOffer' ($nextSection -match 'Set up a FinOps tool now\?' -and $nextSection -match '-not \$SkipFinOpsOffer' -and $nextSection -match '-not \$Yes' -and $nextSection -match 'Test-ClaudeInteractive')
    Assert 'the installer records sku, location and the Foundry account in its record' ($installerText -match '(?m)^\s+sku\s+=\s+\$Sku' -and $installerText -match '(?m)^\s+location\s+=\s+' -and $installerText -match '(?m)^\s+foundryAccount\s+=\s+\$FoundryAccount' -and $installerText -match '(?m)^\s+foundryResourceGroup\s+=\s+\$FoundryResourceGroup')
    Assert 'the installer''s Location prompt is the priced region prompt' ($installerText -notmatch "Read-Default -Prompt 'Location'" -and $installerText -match 'Read-GatewayRegion -Default \$Location')
    Assert 'the installer''s Foundry account search states an estimate and reports each account as it is read' ($installerText -match 'candidate account\(s\), about 4 s each' -and $installerText -match '\[\{0\}/\{1\}\] \{2\}: \{3\} \(\{4:N1\} s\)')

    # ------------------------------------------------------------------ FinOps pricing in the flow
    $finops = & {
        . (Join-Path $root 'scripts\flow\FinOps.ps1')
        $script:aumCalls = 0
        function Get-ClaudeAumPrices { param($Region) $script:aumCalls++; [pscustomobject]@{ Region = $Region } }
        function Get-ClaudeFinOpsComparisonPrice { param($Region, $AumPrices) $null }
        $first = @(Get-FinOpsFlowChoices -Discovery ([pscustomobject]@{ Region = 'eastus2' }) 6>&1)
        $second = @(Get-FinOpsFlowChoices -Discovery ([pscustomobject]@{ Region = 'eastus2' }) 6>&1)
        $none = @(Get-FinOpsFlowChoices -Discovery ([pscustomobject]@{ Region = $null }) 6>&1)
        [pscustomobject]@{ Calls = $script:aumCalls; First = (@($first | Where-Object { $_ -is [Management.Automation.InformationRecord] } | ForEach-Object { [string]$_ }) -join "`n"); Second = (@($second | Where-Object { $_ -is [Management.Automation.InformationRecord] } | ForEach-Object { [string]$_ }) -join "`n"); None = (@($none | Where-Object { $_ -is [Management.Automation.InformationRecord] } | ForEach-Object { [string]$_ }) -join "`n") }
    }
    Assert 'the FinOps step announces its price read with an estimate and the time it took' ($finops.First -match 'Pricing the FinOps tools in eastus2 .*\(about \d+ s\)' -and $finops.First -match 'priced in \d+(\.\d)? s') $finops.First
    Assert 'the FinOps step prices a region once per run' ($finops.Calls -eq 1 -and -not $finops.Second.Trim()) "calls=$($finops.Calls) second='$($finops.Second)'"
    Assert 'without a region the FinOps step reads no prices and prints nothing' ($finops.Calls -eq 1 -and -not $finops.None.Trim())
}
finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail) { Write-Host "$fail assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'The guided flow starts at once and the installer prices its choices.' -ForegroundColor Green
exit 0
