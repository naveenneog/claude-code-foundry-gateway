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
    foreach ($d in 'scripts\flow\lib', 'onboarding', 'schemas') { New-Item -ItemType Directory -Force -Path (Join-Path $shadow $d) | Out-Null }
    Copy-Item -LiteralPath (Join-Path $root 'Start-ClaudeGateway.ps1') -Destination $shadow
    foreach ($f in 'scripts\ClaudeChoice.ps1', 'scripts\ClaudeGatewayAddressInput.ps1', 'scripts\AzureRetailPrice.ps1', 'scripts\ClaudeGatewayRegion.ps1', 'scripts\flow\FlowContract.ps1', 'scripts\flow\Discovery.ps1', 'scripts\flow\Foundation.ps1', 'scripts\flow\lib\LifecycleCommon.ps1',
        # The installer's answers schema and preflight, which the flow runs for a plan that runs the installer unattended (ADR-0047).
        'scripts\ClaudeInstallerAnswers.ps1', 'scripts\ClaudeInstallerPreflight.ps1', 'scripts\ClaudeInstallResume.ps1', 'scripts\Test-Prerequisites.ps1', 'schemas\claude-gateway.answers.schema.json') {
        if (Test-Path -LiteralPath (Join-Path $root $f)) { Copy-Item -LiteralPath (Join-Path $root $f) -Destination (Join-Path $shadow $f) }
    }
    # Offline and deterministic: the shadow prices API Management from fixed rates, not the Retail Prices API.
    Set-Content -LiteralPath (Join-Path $shadow 'scripts\AzureRetailPrice.ps1') -Encoding UTF8 -Value @'
function Get-AzureRetailMeter { param($ServiceName, $Region, $TimeoutSec) , @() }
function Get-AzureRetailPriceAcrossRegions { param($ServiceName, $MeterName, $TimeoutSec) , @() }
function Get-AzureRetailPrice {
    param($ServiceName, $Region, $MeterName, $SkuName, $ProductName, [switch]$IncludeFreeTier, $Tier)
    $rate = @{ 'Basic v2 Unit' = 0.21; 'Standard v2 Unit' = 0.96; 'Premium v2 Unit' = 3.84 }[[string]$MeterName]
    if ($null -eq $rate) { return $null }
    [pscustomobject]@{ UnitPrice = [decimal]$rate; Currency = 'USD'; RetrievedUtc = '2026-09-27T00:00:00Z'; MeterName = $MeterName }
}
function Get-AzureRetailPriceUnavailableReason { '' }
function ConvertTo-MonthlyPrice { param([decimal]$HourlyPrice, [int]$Units = 1) [math]::Round($HourlyPrice * 730 * $Units, 2) }
'@
    $installerParams = @('SubscriptionId', 'FoundryAccount', 'FoundryResourceGroup', 'ResourceGroup', 'Location', 'NamePrefix', 'PublisherEmail', 'Sku', 'ExistingApimName', 'EntitlementStore', 'AuthMode', 'DesktopSignInKind', 'DesktopEntraClientId', 'DesktopEntraIssuer', 'DesktopEntraScopes', 'DesktopEntraAudience', 'DesktopEntraResource', 'ModelOrganizationName', 'ModelIndustry', 'ModelCountryCode', 'TpmStandard', 'QuotaStandard', 'TpmPremium', 'QuotaPremium', 'QuotaOrg', 'CallsPerMinute', 'StandardGroup', 'PremiumGroup', 'AddressMode')
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
        "[ordered]@{ mode = 'gateway'; gatewayUrl = 'https://apim-p68.azure-api.net'; tenantId = '00000000-0000-0000-0000-000000000000'; apimName = 'apim-p68'; resourceGroup = 'rg-p68'; sku = 'StandardV2'; location = 'eastus2'; foundryAccount = 'ai-p68'; foundryResourceGroup = 'rg-ai-p68'; authMode = 'device'; entitlementStore = `$store; desktopSignIn = @{ kind = 'external-idp'; flow = 'browser'; bearerTokenType = 'id_token'; clientId = '11111111-2222-4333-8444-555555555555'; issuer = 'https://login.microsoftonline.com/00000000-0000-0000-0000-000000000000/v2.0' } } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path `$PSScriptRoot 'onboarding\claude-gateway.json') -Encoding UTF8"
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
    $budgetsLog = Join-Path $scratch 'budgets.log'
    function Reset-Shadow {
        foreach ($f in $shadowConfig, $installerLog, $finopsLog, $budgetsLog) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
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

    # az is a .cmd shim on Windows: cmd.exe re-reads & | < > ^ ( ) in an unquoted argument, so a
    # recorded name carrying them would run another command. Such a name is not passed to az.
    $unsafeLog = Join-Path $scratch 'az-unsafe.log'
    $marker = Join-Path $scratch 'injected.txt'
    $unsafePath = Join-Path $scratch 'recorded-unsafe.json'
    $unsafe = [ordered]@{ schemaVersion = 2; gatewayUrl = 'https://apim-p68.azure-api.net'; apimName = 'apim-p68'; resourceGroup = "rg-p68&echo injected>`"$marker`""; subscriptionId = 'Contoso (Prod) & Test'; decisions = [ordered]@{ foundation = [ordered]@{ sku = 'BasicV2' } }; history = @() }
    $unsafe | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $unsafePath -Encoding UTF8
    $unsafeRun = Invoke-Child -Script $shadowStart -Arguments @('-Action', 'Setup', '-PlanOnly', '-RecordPath', $unsafePath) -Environment @{ P68_AZ_LOG = $unsafeLog }
    Assert 'a recorded name with cmd.exe metacharacters is not passed to the Azure CLI' (@(Read-JsonLines $unsafeLog).Count -eq 0 -and -not (Test-Path -LiteralPath $marker)) ((@(Read-JsonLines $unsafeLog) | ForEach-Object { $_.args -join ' ' }) -join '; ')
    Assert 'that record is reported as not read, and it is not drift' ((Get-Fingerprint $unsafeRun.Text) -and $unsafeRun.Text -match 'not read' -and $unsafeRun.Text -match 'cmd\.exe') $unsafeRun.All
    $namedSubPath = Join-Path $scratch 'recorded-subscription-name.json'
    $namedSub = [ordered]@{ schemaVersion = 2; gatewayUrl = 'https://apim-p68.azure-api.net'; apimName = 'apim-p68'; resourceGroup = 'rg-p68'; subscriptionId = 'Contoso (Prod) & Test'; decisions = [ordered]@{ foundation = [ordered]@{ sku = 'BasicV2' } }; history = @() }
    $namedSub | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $namedSubPath -Encoding UTF8
    $subLog = Join-Path $scratch 'az-subscription.log'
    $subRun = Invoke-Child -Script $shadowStart -Arguments @('-Action', 'Setup', '-PlanOnly', '-RecordPath', $namedSubPath) -Environment @{ P68_AZ_LOG = $subLog; P68_AZ_URL = 'https://apim-p68.azure-api.net' }
    $subCalls = @(Read-JsonLines $subLog)
    Assert 'a recorded subscription that is not an id is left out of the az call' ($subCalls.Count -eq 1 -and ($subCalls[0].args -join ' ') -eq 'apim show -g rg-p68 -n apim-p68 -o json' -and (Get-Fingerprint $subRun.Text)) (($subCalls | ForEach-Object { $_.args -join ' ' }) -join '; ')
    $guidSubPath = Join-Path $scratch 'recorded-subscription-id.json'
    $namedSub.subscriptionId = '00000000-0000-0000-0000-00000000abcd'
    $namedSub | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $guidSubPath -Encoding UTF8
    $guidLog = Join-Path $scratch 'az-subscription-id.log'
    $null = Invoke-Child -Script $shadowStart -Arguments @('-Action', 'Setup', '-PlanOnly', '-RecordPath', $guidSubPath) -Environment @{ P68_AZ_LOG = $guidLog; P68_AZ_URL = 'https://apim-p68.azure-api.net' }
    $guidCalls = @(Read-JsonLines $guidLog)
    Assert 'a recorded subscription id is passed with --subscription' ($guidCalls.Count -eq 1 -and ($guidCalls[0].args -join ' ') -eq 'apim show -g rg-p68 -n apim-p68 --subscription 00000000-0000-0000-0000-00000000abcd -o json') (($guidCalls | ForEach-Object { $_.args -join ' ' }) -join '; ')

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

    # Change foundation over a recorded gateway, attended: the installer updates that gateway and asks the rest.
    Reset-Shadow
    $change = Invoke-Child -Script $shadowStart -Attended -Arguments @('-Action', 'Change', '-Change', 'foundation', '-RecordPath', (New-RecordedGateway 'recorded-change.json')) -InputLines @('stub-answer') -Environment @{ P68_AZ_URL = 'https://apim-p68.azure-api.net'; P68_INSTALLER_LOG = $installerLog }
    $changeRun = if (Test-Path -LiteralPath $installerLog) { Read-Json $installerLog } else { $null }
    Assert 'attended -Change foundation over a recorded gateway runs the installer without -Yes' ($change.ExitCode -eq 0 -and $changeRun -and -not ($changeRun.bound.PSObject.Properties.Name -contains 'Yes') -and $changeRun.answer -eq 'stub-answer') ($change.All | Select-Object -Last 3)
    Assert 'attended -Change foundation names the recorded gateway to the installer, and nothing else it could ask' ($changeRun -and ((@($changeRun.bound.PSObject.Properties.Name) | Sort-Object) -join ',') -eq 'ExistingApimName,ResourceGroup,SkipFinOpsOffer' -and $changeRun.bound.ExistingApimName -eq 'apim-p68' -and $changeRun.bound.ResourceGroup -eq 'rg-p68') ($changeRun.bound | ConvertTo-Json -Compress)

    # A mistyped fingerprint after the installer created the gateway: the message says what exists.
    Reset-Shadow
    $mistyped = Invoke-Child -Script $shadowStart -Attended -Arguments @('-Action', 'Setup', '-RecordPath', (Join-Path $scratch 'mistyped-record.json')) -InputLines @('stub-answer', '', 'nomatch1') -Environment @{ P68_AZ_URL = 'https://apim-p68.azure-api.net'; P68_INSTALLER_LOG = $installerLog; P68_FINOPS_LOG = $finopsLog }
    Assert 'a mistyped fingerprint after the installer says the foundation is set up and the rest was not applied' ($mistyped.ExitCode -ne 0 -and $mistyped.All -match 'gateway foundation is set up' -and $mistyped.All -match 'not applied' -and $mistyped.All -notmatch 'nothing was written' -and $mistyped.All -notmatch 'Line \|') ($mistyped.All | Select-Object -Last 3)

    # A step after the installer fails: the next run resumes that run instead of starting another.
    Reset-Shadow
    $fakeBudgets = Join-Path $shadow 'scripts\flow\Budgets.ps1'
    Set-Content -LiteralPath $fakeBudgets -Encoding UTF8 -Value @'
function Get-ClaudeFlowStepInfo { [pscustomobject]@{ Name = 'Budgets'; Title = 'Budgets'; DecisionKey = 'budgets'; DependsOn = @('FinOps'); Actions = @('Setup', 'Change') } }
function Get-ClaudeFlowStepQuestions { param($Record, $Discovery) @() }
function Get-ClaudeFlowStepPlan { param($Record, $Discovery) New-ClaudeFlowPlan -Step Budgets -Summary 'Configure budgets' -Actions @(New-ClaudeFlowAction -Verb Write -Target 'budgets' -Detail 'test') -Costs @(New-ClaudeFlowCost -Item 'Budgets' -MonthlyUsd 0 -Source 'test') -Reversible $true -Rollback 'none' }
function Invoke-ClaudeFlowStep { param($Record, $Plan) Add-Content -LiteralPath $env:P68_BUDGETS_LOG -Value 'applied'; if ($env:P68_BUDGETS_FAIL -eq '1') { throw 'budgets apply failed (test)' }; @{ budgets = [pscustomobject]@{ mode = 'tokens' } } }
function Test-ClaudeFlowStep { param($Record) [pscustomobject]@{ Step = 'Budgets'; Passed = $true; Checks = @() } }
'@
    try {
        $phaseTwoFp = & {
            . (Join-Path $root 'scripts\flow\FlowContract.ps1')
            . (Join-Path $root 'scripts\ClaudeChoice.ps1')
            $finPlan = & { . $fakeFinOps; Get-ClaudeFlowStepPlan -Record $null -Discovery $null }
            $budPlan = & { . $fakeBudgets; Get-ClaudeFlowStepPlan -Record $null -Discovery $null }
            Get-ClaudeFlowFingerprint -Plans @($finPlan, $budPlan)
        }
        $resumeRecord = Join-Path $scratch 'resume-record.json'
        $resumeEnv = @{ P68_AZ_URL = 'https://apim-p68.azure-api.net'; P68_INSTALLER_LOG = $installerLog; P68_FINOPS_LOG = $finopsLog; P68_BUDGETS_LOG = $budgetsLog; P68_BUDGETS_FAIL = '1' }
        $firstTry = Invoke-Child -Script $shadowStart -Attended -Arguments @('-Action', 'Setup', '-RecordPath', $resumeRecord) -InputLines @('stub-answer', '', $phaseTwoFp.Substring(0, 8)) -Environment $resumeEnv
        $finAppliedFirst = @(Get-Content -LiteralPath $finopsLog -ErrorAction SilentlyContinue | Where-Object { $_ -match '"applied"' }).Count
        $resumeEnv.P68_BUDGETS_FAIL = $null
        $secondTry = Invoke-Child -Script $shadowStart -Attended -Arguments @('-Action', 'Setup', '-RecordPath', $resumeRecord) -InputLines @($phaseTwoFp.Substring(0, 8)) -Environment $resumeEnv
        $finAppliedSecond = @(Get-Content -LiteralPath $finopsLog -ErrorAction SilentlyContinue | Where-Object { $_ -match '"applied"' }).Count
        $budApplied = @(Get-Content -LiteralPath $budgetsLog -ErrorAction SilentlyContinue).Count
        $resumed = if (Test-Path -LiteralPath $resumeRecord) { Read-Json $resumeRecord } else { $null }
        $finEntry = @($resumed.history | Where-Object decision -eq 'finops')
        $budEntry = @($resumed.history | Where-Object decision -eq 'budgets')
        Assert 'a failed step after the installer ends the first run after FinOps applied' ($firstTry.ExitCode -ne 0 -and $finAppliedFirst -eq 1 -and $firstTry.All -match 'budgets apply failed') ($firstTry.All | Select-Object -Last 2)
        Assert 'the next run resumes that run: FinOps is not applied again and Budgets is' ($secondTry.ExitCode -eq 0 -and $finAppliedSecond -eq 1 -and $budApplied -eq 2 -and $secondTry.Text -match 'Resuming') ("exit=$($secondTry.ExitCode) finops=$finAppliedSecond budgets=$budApplied; " + ($secondTry.All | Select-Object -Last 2))
        Assert 'the resumed run keeps one run id for the steps after the installer and ends without an active run' ($resumed -and $finEntry.Count -eq 1 -and $budEntry.Count -eq 1 -and $finEntry[0].runId -eq $budEntry[0].runId -and -not ($resumed.PSObject.Properties.Name -contains 'activeRun')) ((@($resumed.history | ForEach-Object { "$($_.decision):$($_.runId)" })) -join ',')

        # The steps change before the retry: Budgets gains a prerequisite that did not exist. Resuming the
        # recorded steps would leave it out, so the retry plans every step again.
        Reset-Shadow
        $bootstrapLog = Join-Path $scratch 'bootstrap.log'
        Remove-Item -LiteralPath $bootstrapLog -Force -ErrorAction SilentlyContinue
        $changedRecord = Join-Path $scratch 'changed-record.json'
        $changedEnv = @{ P68_AZ_URL = 'https://apim-p68.azure-api.net'; P68_INSTALLER_LOG = $installerLog; P68_FINOPS_LOG = $finopsLog; P68_BUDGETS_LOG = $budgetsLog; P68_BOOTSTRAP_LOG = $bootstrapLog; P68_BUDGETS_FAIL = '1' }
        $null = Invoke-Child -Script $shadowStart -Attended -Arguments @('-Action', 'Setup', '-RecordPath', $changedRecord) -InputLines @('stub-answer', '', $phaseTwoFp.Substring(0, 8)) -Environment $changedEnv
        $fakeBootstrap = Join-Path $shadow 'scripts\flow\Bootstrap.ps1'
        Set-Content -LiteralPath $fakeBootstrap -Encoding UTF8 -Value @'
function Get-ClaudeFlowStepInfo { [pscustomobject]@{ Name = 'Bootstrap'; Title = 'Bootstrap'; DecisionKey = 'bootstrap'; DependsOn = @('FinOps'); Actions = @('Setup', 'Change') } }
function Get-ClaudeFlowStepQuestions { param($Record, $Discovery) @() }
function Get-ClaudeFlowStepPlan { param($Record, $Discovery) New-ClaudeFlowPlan -Step Bootstrap -Summary 'Bootstrap' -Actions @(New-ClaudeFlowAction -Verb Write -Target 'bootstrap' -Detail 'test') -Costs @(New-ClaudeFlowCost -Item 'Bootstrap' -MonthlyUsd 0 -Source 'test') -Reversible $true -Rollback 'none' }
function Invoke-ClaudeFlowStep { param($Record, $Plan) Add-Content -LiteralPath $env:P68_BOOTSTRAP_LOG -Value 'applied'; @{ bootstrap = [pscustomobject]@{ done = $true } } }
function Test-ClaudeFlowStep { param($Record) [pscustomobject]@{ Step = 'Bootstrap'; Passed = $true; Checks = @() } }
'@
        Set-Content -LiteralPath $fakeBudgets -Encoding UTF8 -Value @'
function Get-ClaudeFlowStepInfo { [pscustomobject]@{ Name = 'Budgets'; Title = 'Budgets'; DecisionKey = 'budgets'; DependsOn = @('FinOps', 'Bootstrap'); Actions = @('Setup', 'Change') } }
function Get-ClaudeFlowStepQuestions { param($Record, $Discovery) @() }
function Get-ClaudeFlowStepPlan { param($Record, $Discovery) New-ClaudeFlowPlan -Step Budgets -Summary 'Configure budgets' -Actions @(New-ClaudeFlowAction -Verb Write -Target 'budgets' -Detail 'test') -Costs @(New-ClaudeFlowCost -Item 'Budgets' -MonthlyUsd 0 -Source 'test') -Reversible $true -Rollback 'none' }
function Invoke-ClaudeFlowStep { param($Record, $Plan) Add-Content -LiteralPath $env:P68_BUDGETS_LOG -Value 'applied'; if (-not (Get-ClaudeDecision -Record $Record -Key bootstrap)) { throw 'budgets needs bootstrap first (test)' }; @{ budgets = [pscustomobject]@{ mode = 'tokens' } } }
function Test-ClaudeFlowStep { param($Record) [pscustomobject]@{ Step = 'Budgets'; Passed = $true; Checks = @() } }
'@
        $changedEnv.P68_BUDGETS_FAIL = $null
        $changedPlan = Invoke-Child -Script $shadowStart -Arguments @('-Action', 'Setup', '-PlanOnly', '-RecordPath', $changedRecord) -Environment $changedEnv
        $changedApply = Invoke-Child -Script $shadowStart -Arguments @('-Action', 'Setup', '-RecordPath', $changedRecord, '-ApprovedPlanFingerprint', (Get-Fingerprint $changedPlan.Text)) -Environment $changedEnv
        $changedFinal = if (Test-Path -LiteralPath $changedRecord) { Read-Json $changedRecord } else { $null }
        $bootApplied = @(Get-Content -LiteralPath $bootstrapLog -ErrorAction SilentlyContinue).Count
        Assert 'when the steps changed after a failed second phase, the retry says so and plans every step again' ($changedPlan.Text -match 'every step is planned again' -and $changedPlan.Text -match '\[Bootstrap\]' -and $changedPlan.Text -notmatch 'Resuming') ($changedPlan.All | Select-Object -Last 3)
        Assert 'that retry applies the new prerequisite before the step that needs it and ends without an active run' ($changedApply.ExitCode -eq 0 -and $bootApplied -eq 1 -and $changedFinal -and $changedFinal.decisions.budgets.mode -eq 'tokens' -and -not ($changedFinal.PSObject.Properties.Name -contains 'activeRun')) ("exit=$($changedApply.ExitCode) bootstrap=$bootApplied; " + ($changedApply.All | Select-Object -Last 2))
    }
    finally {
        Remove-Item -LiteralPath $fakeBudgets -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path $shadow 'scripts\flow\Bootstrap.ps1') -Force -ErrorAction SilentlyContinue
    }

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
    # The stub az.cmd first on PATH, so the cmd.exe guard is active on any machine; prices stubbed per region.
    $savedPath = $env:PATH
    $env:PATH = $script:azBin + [IO.Path]::PathSeparator + $env:PATH
    try {
    $f = & {
        . (Join-Path $root 'scripts\flow\FlowContract.ps1')
        . (Join-Path $root 'scripts\ClaudeChoice.ps1')
        . (Join-Path $root 'scripts\flow\Foundation.ps1')
        function Invoke-RestMethod {
            param($Uri, $TimeoutSec, $ErrorAction)
            $rates = if ([uri]::UnescapeDataString([string]$Uri) -match "armRegionName eq 'westus'") { @(0.20, 0.90, 3.60) } else { @(0.21, 0.96, 3.84) }
            $rows = for ($i = 0; $i -lt 3; $i++) { [pscustomobject]@{ meterName = @('Basic v2 Unit', 'Standard v2 Unit', 'Premium v2 Unit')[$i]; retailPrice = $rates[$i]; type = 'Consumption'; skuName = 'v2'; productName = 'API Management'; tierMinimumUnits = 0; unitOfMeasure = '1 Hour'; currencyCode = 'USD' } }
            [pscustomobject]@{ Items = @($rows); NextPageLink = $null }
        }
        $emptyRecord = [pscustomobject]@{ schemaVersion = 2; decisions = [pscustomobject]@{}; history = @() }
        $withDecision = { param($store) [pscustomobject]@{ schemaVersion = 2; decisions = [pscustomobject]@{ foundation = [pscustomobject]@{ sku = 'BasicV2'; entitlementStore = $store; authMode = 'interactive'; desktopSignInKind = 'helper-script' } }; history = @() } }
        $gatewayRecord = [pscustomobject]@{ schemaVersion = 2; apimName = 'apim-p68'; resourceGroup = 'rg-p68'; gatewayUrl = 'https://apim-p68.azure-api.net'; decisions = [pscustomobject]@{ foundation = [pscustomobject]@{ sku = 'BasicV2'; location = 'westus'; resourceGroup = 'rg-p68'; namePrefix = 'p68'; publisherEmail = 'old@contoso.com'; entitlementStore = 'named-value' } }; history = @() }
        $oddRecord = [pscustomobject]@{ schemaVersion = 2; apimName = 'contoso-gateway'; resourceGroup = 'rg-p68'; gatewayUrl = 'https://contoso-gateway.azure-api.net'; decisions = [pscustomobject]@{ foundation = [pscustomobject]@{ sku = 'BasicV2' } }; history = @() }
        $live = [pscustomobject]@{ name = 'apim-p68'; resourceGroup = 'rg-p68'; sku = 'StandardV2'; location = 'eastus2'; publisherEmail = 'ops&calc@contoso.com'; gatewayUrl = 'https://apim-p68.azure-api.net' }
        $ctx = { param($action, $attended, $gateway) [pscustomobject]@{ action = $action; attended = $attended; gateway = $gateway; Region = $null } }
        $thrown = { param($record, $discovery) try { Get-ClaudeFlowStepPlan -Record $record -Discovery $discovery | Out-Null; '' } catch { $_.Exception.Message } }
        $unsafeRecord = [pscustomobject]@{ schemaVersion = 2; apimName = 'apim-p68'; resourceGroup = 'rg-p68&calc'; gatewayUrl = 'https://apim-p68.azure-api.net'; decisions = [pscustomobject]@{ foundation = [pscustomobject]@{ sku = 'BasicV2' } }; history = @() }
        $withFoundation = { param($values) $d = [ordered]@{ sku = 'BasicV2'; entitlementStore = 'named-value' }; foreach ($k in $values.Keys) { $d[$k] = $values[$k] }; [pscustomobject]@{ schemaVersion = 2; decisions = [pscustomobject]@{ foundation = [pscustomobject]$d }; history = @() } }
        $orgDecision = & $withFoundation @{ modelOrganizationName = 'AT&T' }
        $unsafeAccount = & $withFoundation @{ foundryAccount = 'ai&calc' }
        $arrayAccount = & $withFoundation @{ foundryAccount = @('ai&echo.P68_ARRAY_MARKER') }
        $withSubscription = { param($sub) [pscustomobject]@{ schemaVersion = 2; subscriptionId = $sub; apimName = 'apim-p68'; resourceGroup = 'rg-p68'; gatewayUrl = 'https://apim-p68.azure-api.net'; decisions = [pscustomobject]@{ foundation = [pscustomobject]@{ sku = 'BasicV2' } }; history = @() } }
        $subscriptionOnly = [pscustomobject]@{ schemaVersion = 2; subscriptionId = '00000000-0000-0000-0000-00000000000a'; decisions = [pscustomobject]@{}; history = @() }
        $attendedPlan = Get-ClaudeFlowStepPlan -Record $emptyRecord -Discovery (& $ctx 'Setup' $true $null)
        $changeAttended = Get-ClaudeFlowStepPlan -Record $gatewayRecord -Discovery (& $ctx 'Change' $true $live)
        $subA = Get-ClaudeFlowStepPlan -Record (& $withSubscription '00000000-0000-0000-0000-00000000000a') -Discovery (& $ctx 'Change' $false $live)
        $subB = Get-ClaudeFlowStepPlan -Record (& $withSubscription '00000000-0000-0000-0000-00000000000b') -Discovery (& $ctx 'Change' $false $live)
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
            GuideEmpty = $(try { Get-ClaudeFlowStepPlan -Record $emptyRecord -Discovery (& $ctx 'Guide' $false $null) } catch { "refused: $($_.Exception.Message)" })
            ChangeAttended = $changeAttended
            ChangeAttendedReview = (Format-ClaudeFlowReview -Plans @($changeAttended))
            ChangeUnattended = Get-ClaudeFlowStepPlan -Record $gatewayRecord -Discovery (& $ctx 'Change' $false $live)
            Odd = Get-ClaudeFlowStepPlan -Record $oddRecord -Discovery (& $ctx 'Change' $false $null)
            UnsafeThrown = & $thrown $unsafeRecord (& $ctx 'Change' $false $null)
            OrgPlan = & { try { Get-ClaudeFlowStepPlan -Record $orgDecision -Discovery (& $ctx 'Setup' $false $null) } catch { $_.Exception.Message } }
            UnsafeAccountUnattended = & $thrown $unsafeAccount (& $ctx 'Setup' $false $null)
            UnsafeAccountAttended = & $thrown $unsafeAccount (& $ctx 'Setup' $true $null)
            ArrayAccountUnattended = & $thrown $arrayAccount (& $ctx 'Setup' $false $null)
            ArrayAccountAttended = & $thrown $arrayAccount (& $ctx 'Setup' $true $null)
            SubA = $subA
            SubB = $subB
            SubFingerprints = @((Get-ClaudeFlowFingerprint -Plans @($subA)), (Get-ClaudeFlowFingerprint -Plans @($subB)))
            SubSetupAttended = Get-ClaudeFlowStepPlan -Record $subscriptionOnly -Discovery (& $ctx 'Setup' $true $null)
            SubNameThrown = & $thrown (& $withSubscription 'Contoso Prod') (& $ctx 'Change' $false $live)
        }
    }
    }
    finally { $env:PATH = $savedPath }
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
    Assert 'Guide never runs the installer: it checks a recorded gateway, and with none recorded it refuses (P72)' (-not $f.GuideRecorded.Data.runsInstaller -and $f.GuideEmpty -is [string] -and $f.GuideEmpty -match 'No gateway is recorded') ([string]$f.GuideEmpty)
    $ca = $f.ChangeAttended.Data.installerArgs
    Assert 'attended -Change foundation runs the installer, which asks' ($f.ChangeAttended.Data.runsInstaller -and $f.ChangeAttended.Data.asksInConsole -and -not (Test-Key $ca 'Yes'))
    Assert 'attended -Change foundation names the recorded gateway, and passes nothing the installer asks' (((@($ca.Keys) | Sort-Object) -join ',') -eq 'ExistingApimName,ResourceGroup,SkipFinOpsOffer' -and $ca['ExistingApimName'] -eq 'apim-p68' -and $ca['ResourceGroup'] -eq 'rg-p68') ($ca | ConvertTo-Json -Compress)
    Assert 'the attended -Change review says the installer updates the recorded gateway, and promises no reuse menu' ($f.ChangeAttendedReview -match 'updates rg-p68/apim-p68' -and $f.ChangeAttendedReview -notmatch 'reuse') $f.ChangeAttendedReview
    $cu = $f.ChangeUnattended.Data.installerArgs
    Assert 'unattended -Change foundation targets the recorded gateway by name, and passes no tier, region, name or live publisher' ($f.ChangeUnattended.Data.runsInstaller -and $cu['Yes'] -eq $true -and $cu['ExistingApimName'] -eq 'apim-p68' -and $cu['ResourceGroup'] -eq 'rg-p68' -and @($cu.Keys | Where-Object { $_ -in 'NamePrefix', 'Sku', 'Location', 'PublisherEmail' }).Count -eq 0) ($cu | ConvertTo-Json -Compress)
    $cuCost = @($f.ChangeUnattended.Costs)[0]
    Assert 'the -Change review prices the live gateway the installer keeps, as already running' ($cuCost.MonthlyUsd -eq 700.80 -and [string]$cuCost.Item -match 'StandardV2' -and [string]$cuCost.Item -match 'already running') ("$($cuCost.Item): $($cuCost.MonthlyUsd)")
    Assert 'unattended -Change foundation targets a gateway of any name through -ExistingApimName' ($f.Odd.Data.installerArgs['ExistingApimName'] -eq 'contoso-gateway' -and -not (Test-Key $f.Odd.Data.installerArgs 'NamePrefix')) ($f.Odd.Data.installerArgs | ConvertTo-Json -Compress)
    Assert 'unattended -Change foundation refuses a recorded name with cmd.exe metacharacters' ($f.UnsafeThrown -match 'cmd\.exe' -and $f.UnsafeThrown -match 'rg-p68&calc') $f.UnsafeThrown
    Assert 'a value that reaches az with a cmd.exe metacharacter is refused before the installer, attended or not' ($f.UnsafeAccountUnattended -match 'FoundryAccount' -and $f.UnsafeAccountUnattended -match 'cmd\.exe' -and $f.UnsafeAccountAttended -match 'FoundryAccount') "unattended: $($f.UnsafeAccountUnattended) | attended: $($f.UnsafeAccountAttended)"
    Assert 'an organisation name with & is passed: it goes to Azure in a JSON body, not to az' ($f.OrgPlan -isnot [string] -and $f.OrgPlan.Data.installerArgs['ModelOrganizationName'] -eq 'AT&T') $(if ($f.OrgPlan -is [string]) { $f.OrgPlan } else { $f.OrgPlan.Data.installerArgs | ConvertTo-Json -Compress })
    Assert 'a list where the installer takes one value is refused, attended or not, whatever its parts hold' ($f.ArrayAccountUnattended -match 'FoundryAccount' -and $f.ArrayAccountUnattended -match 'list or an object' -and $f.ArrayAccountAttended -match 'list or an object') "unattended: $($f.ArrayAccountUnattended) | attended: $($f.ArrayAccountAttended)"
    Assert 'the recorded subscription id reaches the installer, so discovery and the install use one subscription' ($f.SubA.Data.installerArgs['SubscriptionId'] -eq '00000000-0000-0000-0000-00000000000a' -and $f.SubSetupAttended.Data.installerArgs['SubscriptionId'] -eq '00000000-0000-0000-0000-00000000000a') "change: $($f.SubA.Data.installerArgs['SubscriptionId']) setup: $($f.SubSetupAttended.Data.installerArgs['SubscriptionId'])"
    Assert 'a different recorded subscription gives a different fingerprint' ($f.SubFingerprints[0] -ne $f.SubFingerprints[1])
    Assert 'a recorded subscription that is not an id is refused before the installer' ($f.SubNameThrown -match 'subscription id' -and $f.SubNameThrown -match 'Contoso Prod') $f.SubNameThrown
    $installerCommand = Get-Command (Join-Path $root 'Install-ClaudeGateway.ps1')
    $unknownArgs = @(foreach ($plan in $f.Attended, $f.Projection, $f.NamedValue, $f.ChangeAttended, $f.ChangeUnattended, $f.SubA) { foreach ($k in @(if ($plan.Data.installerArgs) { $plan.Data.installerArgs.Keys })) { if (-not $installerCommand.Parameters.ContainsKey([string]$k)) { $k } } })
    Assert 'every installer argument the plans pass is a parameter of Install-ClaudeGateway.ps1' ($unknownArgs.Count -eq 0) ($unknownArgs -join ',')

    # Every installer section that asks something is named in the attended Foundation review.
    $installerText = [IO.File]::ReadAllText((Join-Path $root 'Install-ClaudeGateway.ps1'))
    # 'Business units' applies the units given as answers (ADR-0047); 'Business units (optional)' is the section that asks.
    $asksNothing = @('Summary', 'Deploying', 'Claude deployment', 'Resource group', 'Entra groups', 'Sync entitlement', 'Projection deployment', 'Business units', 'Onboarding package', 'Verifying the controls', 'Done')
    $named = [ordered]@{
        'Azure sign-in' = 'subscription'; 'Foundry account' = 'Foundry account'; 'Which models each tier may call' = 'models each tier may call'
        'Where to put the gateway' = 'region'; 'Choices' = 'entitlement store'; 'Budgets' = 'token budgets'; 'Standard tier' = 'token budgets for each tier'
        'Premium tier' = 'token budgets for each tier'; 'Organisation ceiling' = 'organisation ceiling'; 'Safety valve' = 'request ceiling'
        'Entitlement groups' = 'Entra groups'; 'Business units (optional)' = 'business units'
        'Company address, certificate and DNS' = 'certificate source and DNS hosting'
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

    # ------------------------------------------------------------------ the installer's approval boundary
    # The attended flow asks for no fingerprint before the installer: its summary is the approval, so
    # nothing may be written before it, the Claude deployment of a subscription that has none included.
    $installerAst = [Management.Automation.Language.Parser]::ParseInput($installerText, [ref]$null, [ref]$null)
    $top = @($installerAst.EndBlock.Statements)
    $topIndexOf = { param($node) for ($i = 0; $i -lt $top.Count; $i++) { if ($node.Extent.StartOffset -ge $top[$i].Extent.StartOffset -and $node.Extent.EndOffset -le $top[$i].Extent.EndOffset) { return $i } }; return -1 }
    $deployCalls = @($installerAst.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'New-ClaudeDeployment' }, $true))
    $confirmAt = -1; $whatIfAt = -1
    for ($i = 0; $i -lt $top.Count; $i++) {
        if ($confirmAt -lt 0 -and $top[$i].Extent.Text -match 'Read-YesNo' -and $top[$i].Extent.Text -match 'Create these resources\?') { $confirmAt = $i }
        if ($whatIfAt -lt 0 -and $top[$i].Extent.Text -match '^if \(\$WhatIfPreference\)' -and $top[$i].Extent.Text -match '\breturn\b') { $whatIfAt = $i }
    }
    $deployAts = @($deployCalls | ForEach-Object { & $topIndexOf $_ })
    Assert 'the installer creates a Claude deployment only after its summary is confirmed, and never under -WhatIf' ($deployCalls.Count -ge 1 -and $confirmAt -ge 0 -and $whatIfAt -ge 0 -and @($deployAts | Where-Object { $_ -le $confirmAt -or $_ -le $whatIfAt }).Count -eq 0) "deploy at $($deployAts -join ',') confirm at $confirmAt whatif at $whatIfAt"
    Assert 'the summary names the Claude deployment it will create, and the tier lists include it' ($installerText -match "'Claude deployment'" -and $installerText -match '\$deployed \+= \$pendingDeployment')

    # az.cmd: a value the installer passes to the Azure CLI must not hold what cmd.exe re-reads.
    $guard = & {
        foreach ($name in 'Write-Bad', 'Assert-AzArgumentsSafe') { if ($fnText.ContainsKey($name)) { . ([scriptblock]::Create($fnText[$name])) } }
        if (-not (Get-Command Assert-AzArgumentsSafe -ErrorAction SilentlyContinue)) { return [pscustomobject]@{ Missing = $true } }
        $try = { param($values, $shim) try { Assert-AzArgumentsSafe -Values $values -Shim $shim 6>$null; '' } catch { $_.Exception.Message } }
        [pscustomobject]@{
            Missing = $false
            Safe = & $try ([ordered]@{ PublisherEmail = 'ops@contoso.com'; ResourceGroup = 'rg-claude.gw_1'; Location = 'eastus2' }) $true
            Unsafe = & $try ([ordered]@{ ResourceGroup = 'rg-ok'; PublisherEmail = 'ops&calc@contoso.com' }) $true
            Paren = & $try ([ordered]@{ ResourceGroup = 'rg (prod)' }) $true
            NoShim = & $try ([ordered]@{ PublisherEmail = 'ops&calc@contoso.com' }) $false
        }
    }
    Assert 'the installer refuses a value that holds a cmd.exe metacharacter, naming it, when az is a .cmd shim' (-not $guard.Missing -and $guard.Safe -eq '' -and $guard.Unsafe -match 'PublisherEmail' -and $guard.Unsafe -match 'Nothing was created' -and $guard.Paren -match 'ResourceGroup') ("safe='$($guard.Safe)' unsafe='$($guard.Unsafe)' paren='$($guard.Paren)'")
    Assert 'the check is off where az is not a .cmd shim' (-not $guard.Missing -and $guard.NoShim -eq '') $guard.NoShim
    $guardCalls = @($top | Where-Object { $_.Extent.Text -match '^Assert-AzArgumentsSafe' } | Sort-Object { $_.Extent.StartOffset })
    $summaryAt = -1; for ($i = 0; $i -lt $top.Count; $i++) { if ($top[$i].Extent.Text -match "^Write-Head 'Summary'") { $summaryAt = $i; break } }
    $preSummary = @($guardCalls | Where-Object { $_.Extent.Text -match 'PublisherEmail\s*=\s*\$PublisherEmail' -and $_.Extent.Text -match 'ExistingApimName\s*=\s*\$ExistingApim\b' })
    Assert 'the installer checks the values it passes to az, adopted and derived ones included, before its summary' ($preSummary.Count -eq 1 -and [array]::IndexOf($top, $preSummary[0]) -lt $summaryAt -and $preSummary[0].Extent.Text -match 'SubscriptionId\s*=\s*\$SubscriptionId' -and $preSummary[0].Extent.Text -match 'DesktopGatewayAudience\s*=\s*\$desktopGatewayAudience') "summary at $summaryAt"
    # Bound parameters are checked before the first az call that uses one: a list passed to one of
    # them arrives as text joined by binding, and the first az calls come long before the summary.
    $azBound = @('SubscriptionId', 'FoundryAccount', 'FoundryResourceGroup', 'ResourceGroup', 'Location', 'NamePrefix', 'PublisherEmail', 'ExistingApimName', 'StandardGroup', 'PremiumGroup', 'DesktopEntraClientId', 'DesktopEntraAudience')
    $boundPattern = '\$(' + ($azBound -join '|') + ')\b'
    $firstAzUse = -1
    for ($i = 0; $i -lt $top.Count; $i++) {
        if ($top[$i] -is [Management.Automation.Language.FunctionDefinitionAst]) { continue }
        $uses = @($top[$i].FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'az' -and $n.Extent.Text -match $boundPattern }, $true))
        if ($uses.Count) { $firstAzUse = $i; break }
    }
    $early = if ($guardCalls.Count) { $guardCalls[0] } else { $null }
    $earlyMissing = @($azBound | Where-Object { -not $early -or $early.Extent.Text -notmatch ($_ + '\s*=\s*\$' + $_ + '\b') })
    Assert 'the installer checks every bound parameter that reaches az before its first az call that uses one' ($early -and $firstAzUse -ge 0 -and [array]::IndexOf($top, $early) -lt $firstAzUse -and $earlyMissing.Count -eq 0) "early at $(if ($early) { [array]::IndexOf($top, $early) }), first use at $firstAzUse, missing $($earlyMissing -join ',')"

    # -ExistingApimName takes the installer's own reuse path for a named gateway, with no menu.
    $adoptAssign = @($installerAst.FindAll({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$useExistingGateway' }, $false))
    $adopted = $null
    if ($adoptAssign.Count -eq 1) {
        $adopt = & ([scriptblock]::Create($adoptAssign[0].Right.Extent.Text))
        $adopted = & {
            . (Join-Path $root 'scripts\ClaudeGatewayRegion.ps1')
            . (Join-Path $root 'scripts\ClaudeInstallerPreflight.ps1')
            function Write-Note { param($t) }; function Write-Ok { param($t) }; function Write-Warn2 { param($t) }
            $ResourceGroup = 'rg-typed'; $ExistingApim = ''; $Location = 'westus'; $Sku = ''; $PublisherEmail = ''; $NamePrefix = ''
            . $adopt ([pscustomobject]@{ name = 'contoso-gateway'; resourceGroup = 'rg-live'; location = 'East US 2'; sku = [pscustomobject]@{ name = 'StandardV2' }; publisherEmail = 'ops@contoso.com'; identity = [pscustomobject]@{ type = 'SystemAssigned' } })
            [pscustomobject]@{ ExistingApim = $ExistingApim; ResourceGroup = $ResourceGroup; Location = $Location; Sku = $Sku; PublisherEmail = $PublisherEmail; NamePrefix = $NamePrefix }
        }
    }
    Assert 'reusing a gateway adopts its name, group, region, tier and publisher' ($adopted -and $adopted.ExistingApim -eq 'contoso-gateway' -and $adopted.ResourceGroup -eq 'rg-live' -and $adopted.Location -eq 'eastus2' -and $adopted.Sku -eq 'StandardV2' -and $adopted.PublisherEmail -eq 'ops@contoso.com' -and $adopted.NamePrefix -eq 'contoso-gateway') ($adopted | ConvertTo-Json -Compress)
    Assert 'the installer takes -ExistingApimName, adopts it before the placement prompts, and skips the region prompt for it' ($installerText -match '\[string\]\$ExistingApimName' -and $installerText -match '(?s)if \(\$ExistingApimName\) \{.*?\. \$useExistingGateway.*?Read-Default -Prompt ''Resource group''' -and $installerText -match '\$Location = if \(\$ExistingApim\) \{ \$Location \} else \{ Read-GatewayRegion -Default \$Location \}')
    Assert 'the reuse menu adopts its choice the same way' ($installerText -match '(?s)-Prompt ''Which''.*?\. \$useExistingGateway \$reusable\[')

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
