# P72: the guided flow's invariants over action x record state x mode, with the real orchestrator,
# discovery and Foundation step, a stub installer and a stub Azure CLI (the shadow repository of
# tests/Test-FlowStart.ps1); Foundation's installer arguments over the foundation choices, in
# process; a recorded foundation fed back to the installer; and one plan's fingerprint on
# PowerShell 7 and Windows PowerShell 5.1.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$fail = 0
function Assert($label, $condition, $detail = '') {
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $label$(if ($detail) { " - $detail" })" -ForegroundColor Red; $script:fail++ }
}

Write-Host ''
Write-Host 'Guided flow - action, record state and mode permutations' -ForegroundColor Cyan

$script:pwsh = (Get-Process -Id $PID).Path
$ps51 = if ($env:SystemRoot) { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' } else { '' }
$has51 = [bool]($ps51 -and (Test-Path -LiteralPath $ps51))
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('flow-permutations-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch -Force | Out-Null
$script:azBin = Join-Path $scratch 'azbin'
New-Item -ItemType Directory -Path $script:azBin -Force | Out-Null

# A stub Azure CLI in its own process, as az.cmd is. P72_AZ_MODE picks what the recorded gateway looks like.
Set-Content -LiteralPath (Join-Path $script:azBin 'az.cmd') -Encoding ASCII -Value @'
@echo off
"%P72_PWSH%" -NoProfile -NonInteractive -File "%~dp0az-stub.ps1" %*
exit /b %ERRORLEVEL%
'@
Set-Content -LiteralPath (Join-Path $script:azBin 'az-stub.ps1') -Encoding UTF8 -Value @'
$ErrorActionPreference = 'Stop'
if ($env:P72_AZ_LOG) { Add-Content -LiteralPath $env:P72_AZ_LOG -Value ([ordered]@{ ticks = [DateTime]::UtcNow.Ticks; args = ($args -join ' ') } | ConvertTo-Json -Compress) }
$joined = $args -join ' '
if ($joined -like 'apim show *') {
    switch ($env:P72_AZ_MODE) {
        'missing' { [Console]::Error.WriteLine("ERROR: (ResourceNotFound) The Resource 'Microsoft.ApiManagement/service/apim-p72' under resource group 'rg-p72' was not found."); exit 3 }
        'signedout' { [Console]::Error.WriteLine("ERROR: Please run 'az login' to setup account."); exit 1 }
        default {
            $url = if ($env:P72_AZ_MODE -eq 'drift') { 'https://apim-other.azure-api.net' } else { 'https://apim-p72.azure-api.net' }
            [Console]::Out.WriteLine((@{ name = 'apim-p72'; resourceGroup = 'rg-p72'; location = 'East US 2'; publisherEmail = 'ops@contoso.com'; sku = @{ name = 'BasicV2' }; gatewayUrl = $url } | ConvertTo-Json -Compress)); exit 0
        }
    }
}
if ($joined -like 'account show*') { [Console]::Out.WriteLine('{"user":{"name":"admin@contoso.com"},"tenantId":"00000000-0000-0000-0000-000000000000","id":"00000000-0000-0000-0000-000000000001","name":"p72"}'); exit 0 }
[Console]::Error.WriteLine("stub az: unexpected call: $joined")
exit 2
'@

# The stub installer takes the real installer's parameter block, so a value the installer would
# refuse at binding is refused here too, and writes its record in the real installer's shape.
$installerAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Install-ClaudeGateway.ps1'), [ref]$null, [ref]$null)
$installerParams = @{}
foreach ($p in $installerAst.ParamBlock.Parameters) {
    $sets = @($p.Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateSet' } | ForEach-Object { $_.PositionalArguments | ForEach-Object { $_.Value } })
    $installerParams[$p.Name.VariablePath.UserPath] = $sets
}
$stubInstaller = @(
    '[CmdletBinding(SupportsShouldProcess)]'
    $installerAst.ParamBlock.Extent.Text
    '$started = [DateTime]::UtcNow.Ticks'
    '$bound = [ordered]@{}; foreach ($k in $PSBoundParameters.Keys) { $bound[$k] = [string]$PSBoundParameters[$k] }'
    "`$answer = if (`$Yes) { '(Yes)' } else { Read-Host 'stub installer question' }"
    '[ordered]@{ started = $started; bound = $bound; answer = $answer } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $env:P72_INSTALLER_LOG -Encoding UTF8'
    "if (`$answer -eq 'cancel') { return }"
    @'
$kind = if ($DesktopSignInKind) { $DesktopSignInKind } else { 'helper-script' }
$desktop = [ordered]@{ kind = 'helper-script' }
if ($kind -ne 'helper-script') {
    $desktop = [ordered]@{ kind = 'external-idp'; flow = $(if ($kind -eq 'external-idp-broker') { 'broker' } else { 'browser' }); bearerTokenType = $DesktopBearerTokenType; clientId = $DesktopEntraClientId; issuer = 'https://login.microsoftonline.com/00000000-0000-0000-0000-000000000000/v2.0' }
    if ($DesktopEntraScopes) { $desktop['scopes'] = $DesktopEntraScopes }
    if ($DesktopEntraAudience) { $desktop['audience'] = $DesktopEntraAudience }
}
$name = if ($ExistingApimName) { $ExistingApimName } else { 'apim-p72' }
function Pick($value, $default) { if ($value) { $value } else { $default } }
[ordered]@{
    mode = 'gateway'; gatewayUrl = "https://$name.azure-api.net"; tenantId = '00000000-0000-0000-0000-000000000000'; apimName = $name; resourceGroup = (Pick $ResourceGroup 'rg-p72')
    sku = (Pick $Sku 'BasicV2'); location = 'eastus2'; foundryAccount = 'ai-p72'; foundryResourceGroup = 'rg-ai-p72'; standardGroup = $StandardGroup; premiumGroup = $PremiumGroup
    authMode = (Pick $AuthMode 'interactive'); entitlementStore = (Pick $EntitlementStore 'named-value'); resolverInboundAccess = (Pick $ResolverInboundAccess 'private'); desktopSignIn = $desktop
    tiers = [ordered]@{ standard = [ordered]@{ tokensPerMinute = (Pick $TpmStandard 20000); tokensPerDay = (Pick $QuotaStandard 500000) }; premium = [ordered]@{ tokensPerMinute = (Pick $TpmPremium 80000); tokensPerDay = (Pick $QuotaPremium 5000000) } }
    organisation = [ordered]@{ tokensPerMonth = (Pick $QuotaOrg 100000000); shared = $true; softCap = $true }
    requestsPerMinute = (Pick $CallsPerMinute 120)
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'onboarding\claude-gateway.json') -Encoding UTF8
'@
) -join "`n"
$fakeFinOps = @'
function Get-ClaudeFlowStepInfo { [pscustomobject]@{ Name = 'FinOps'; Title = 'FinOps tooling'; DecisionKey = 'finops'; DependsOn = @('Foundation'); Actions = @('Setup', 'Change') } }
function Get-ClaudeFlowStepQuestions {
    param($Record, $Discovery)
    if (Get-ClaudeDecision -Record $Record -Key finops) { return @() }
    @([pscustomobject]@{ Key = 'finops.tool'; Question = 'Which FinOps tool?'; Options = @((New-ClaudeChoiceOption -Value 'Direct' -Label 'AUM Direct' -Recommended -Reason 'test default'), (New-ClaudeChoiceOption -Value 'None' -Label 'None')); AcceptRecommendedWithoutConsole = $true })
}
function Get-ClaudeFlowStepPlan { param($Record, $Discovery) New-ClaudeFlowPlan -Step FinOps -Summary 'Configure AUM Direct' -Actions @(New-ClaudeFlowAction -Verb Write -Target 'AUM profile' -Detail 'test') -Costs @(New-ClaudeFlowCost -Item 'AUM Direct' -MonthlyUsd 0 -Source 'test') -Reversible $true -Rollback 'Delete the AUM profile' }
function Invoke-ClaudeFlowStep { param($Record, $Plan) if ($env:P72_FINOPS_FAIL -eq '1') { $null.NotAMethod() }; @{ finops = [pscustomobject]@{ tool = 'Direct' } } }
function Test-ClaudeFlowStep { param($Record) [pscustomobject]@{ Step = 'FinOps'; Passed = $true; Checks = @() } }
'@
$priceStub = @'
function Get-AzureRetailMeter { param($ServiceName, $Region, $TimeoutSec) , @() }
function Get-AzureRetailPriceAcrossRegions { param($ServiceName, $MeterName, $TimeoutSec) , @() }
function Get-AzureRetailPrice {
    param($ServiceName, $Region, $MeterName, $SkuName, $ProductName, [switch]$IncludeFreeTier, $Tier)
    $rate = @{ 'Basic v2 Unit' = 0.21; 'Standard v2 Unit' = 0.96; 'Premium v2 Unit' = 3.84 }[[string]$MeterName]
    if ($null -eq $rate) { return $null }
    [pscustomobject]@{ UnitPrice = [decimal]$rate; Currency = 'USD'; RetrievedUtc = '2026-09-28T00:00:00Z'; MeterName = $MeterName }
}
function Get-AzureRetailPriceUnavailableReason { '' }
function ConvertTo-MonthlyPrice { param([decimal]$HourlyPrice, [int]$Units = 1) [math]::Round($HourlyPrice * 730 * $Units, 2) }
'@
$shadowFiles = @('Start-ClaudeGateway.ps1', 'scripts\ClaudeChoice.ps1', 'scripts\ClaudeGatewayRegion.ps1', 'scripts\ClaudeGatewayAddressInput.ps1', 'scripts\Update-ClaudeGateway.ps1', 'scripts\flow\FlowContract.ps1', 'scripts\flow\Discovery.ps1', 'scripts\flow\Foundation.ps1', 'scripts\flow\lib\LifecycleCommon.ps1')
function New-Shadow([string]$Dir) {
    foreach ($d in 'scripts\flow\lib', 'onboarding') { New-Item -ItemType Directory -Force -Path (Join-Path $Dir $d) | Out-Null }
    foreach ($f in $shadowFiles) { if (Test-Path -LiteralPath (Join-Path $root $f)) { Copy-Item -LiteralPath (Join-Path $root $f) -Destination (Join-Path $Dir $f) } }
    Set-Content -LiteralPath (Join-Path $Dir 'scripts\AzureRetailPrice.ps1') -Encoding UTF8 -Value $priceStub
    Set-Content -LiteralPath (Join-Path $Dir 'Install-ClaudeGateway.ps1') -Encoding UTF8 -Value $stubInstaller
    Set-Content -LiteralPath (Join-Path $Dir 'scripts\flow\FinOps.ps1') -Encoding UTF8 -Value $fakeFinOps
}
function New-RecordFile([string]$Path, [string]$Store = 'named-value') {
    [ordered]@{
        schemaVersion = 2; mode = 'gateway'; gatewayUrl = 'https://apim-p72.azure-api.net'; apimName = 'apim-p72'; resourceGroup = 'rg-p72'
        decisions = [ordered]@{ foundation = [ordered]@{ sku = 'BasicV2'; entitlementStore = $Store; authMode = 'interactive'; desktopSignInKind = 'helper-script' }; finops = [ordered]@{ tool = 'Direct' } }
        history = @()
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Path -Encoding UTF8
}
function Get-FileText([string]$Path) { if (Test-Path -LiteralPath $Path) { [IO.File]::ReadAllText($Path) } else { $null } }

# One run: its own shadow, record and logs, so runs can go in parallel.
function New-Run([string]$Id, [string]$Action, [string]$Record, [string]$Mode, [string]$Shell = '7', [string]$Store = 'named-value', [hashtable]$Answers = $null, [string]$RecordFrom = '', [string]$Fingerprint = '', [hashtable]$Env = @{}, [string[]]$InputLines = @('stub-answer', '', 'nomatch1'), [string]$Caller = '') {
    $dir = Join-Path $scratch "runs\$Id"
    New-Shadow $dir
    $recordPath = Join-Path $dir 'record.json'
    if ($RecordFrom) { Copy-Item -LiteralPath $RecordFrom -Destination $recordPath }
    elseif ($Record -ne 'none') { New-RecordFile $recordPath $Store }
    $argv = @('-Action', $Action, '-RecordPath', $recordPath)
    if ($Action -eq 'Change') { $argv += @('-Change', 'foundation') }
    if ($Mode -eq 'planonly') { $argv += '-PlanOnly' }
    if ($Mode -eq 'whatif') { $argv += '-WhatIf' }
    if ($Mode -eq 'apply') { $argv += @('-ApprovedPlanFingerprint', $Fingerprint) }
    $answersPath = ''
    if ($Answers) { $answersPath = Join-Path $dir 'answers.json'; $Answers | ConvertTo-Json | Set-Content -LiteralPath $answersPath -Encoding UTF8; $argv += @('-AnswersPath', $answersPath) }
    # A caller script runs the flow in process (&) or dot-sourced (.), catches what it raises and goes on.
    # -Caller 'prompt' dot-sources it at global scope through -Command, as a console prompt does.
    $script = Join-Path $dir 'Start-ClaudeGateway.ps1'
    $command = ''
    if ($Caller -eq 'prompt') {
        $quoted = @($argv | ForEach-Object { $a = [string]$_; if ($a -match '^-[A-Za-z]+$') { $a } else { "'" + $a.Replace("'", "''") + "'" } }) -join ' '
        $command = "try { . '$script' $quoted; 'CALLER NOTHING RAISED' } catch { ""CALLER CAUGHT: `$(`$_.Exception.GetType().FullName): `$(`$_.Exception.Message)"" }; 'CALLER CONTINUED'"
        $argv = @()
    }
    elseif ($Caller) {
        $quoted = @($argv | ForEach-Object { $a = [string]$_; if ($a -match '^-[A-Za-z]+$') { $a } else { "'" + $a.Replace("'", "''") + "'" } }) -join ' '
        $callerPath = Join-Path $dir 'caller.ps1'
        Set-Content -LiteralPath $callerPath -Encoding UTF8 -Value @(
            '$ErrorActionPreference = ''Stop'''
            "try { $Caller '$script' $quoted; 'CALLER NOTHING RAISED' }"
            'catch { "CALLER CAUGHT: $($_.Exception.GetType().FullName): $($_.Exception.Message)" }'
            "'CALLER CONTINUED'"
        )
        $script = $callerPath; $argv = @()
    }
    [pscustomobject]@{
        Id = $Id; Action = $Action; Record = $Record; Mode = $Mode; Shell = $Shell; Store = $Store; Dir = $dir; RecordPath = $recordPath; Args = $argv; Script = $script; Command = $command; Env = $Env; Caller = $Caller
        Before = (Get-FileText $recordPath); InstallerLog = (Join-Path $dir 'installer.json'); AzLog = (Join-Path $dir 'az.log')
        Input = $InputLines
    }
}
function Start-Run($Run) {
    $exe = if ($Run.Shell -eq '5.1') { $ps51 } else { $script:pwsh }
    $psi = [Diagnostics.ProcessStartInfo]::new($exe)
    $psi.ArgumentList.Add('-NoProfile')
    if ($Run.Mode -ne 'attended') { $psi.ArgumentList.Add('-NonInteractive') }
    if ($Run.Command) {
        $psi.ArgumentList.Add('-Command')
        $psi.ArgumentList.Add($Run.Command)
    }
    else {
        $psi.ArgumentList.Add('-File')
        $psi.ArgumentList.Add($Run.Script)
        foreach ($a in $Run.Args) { $psi.ArgumentList.Add([string]$a) }
    }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    # Each run starts from the same environment: nothing inherited from the shell that runs the suite.
    foreach ($name in @($psi.Environment.Keys | Where-Object { $_ -like 'P72_*' -or $_ -in 'CLAUDE_FLOW_SKIP_AZ_DISCOVERY', 'CLAUDE_INTERACTIVE', 'CLAUDE_NONINTERACTIVE', 'CLAUDE_FLOW_DEBUG' })) { [void]$psi.Environment.Remove($name) }
    $psi.Environment['PATH'] = $(if ($Run.Record -eq 'noaz') { Join-Path $env:SystemRoot 'System32' } else { $script:azBin + [IO.Path]::PathSeparator + $env:PATH })
    $psi.Environment['P72_PWSH'] = $script:pwsh
    $psi.Environment['P72_AZ_MODE'] = $Run.Record
    $psi.Environment['P72_AZ_LOG'] = $Run.AzLog
    $psi.Environment['P72_INSTALLER_LOG'] = $Run.InstallerLog
    if ($Run.Mode -eq 'attended') { $psi.Environment['CLAUDE_INTERACTIVE'] = '1' }
    foreach ($k in $Run.Env.Keys) { $psi.Environment[$k] = [string]$Run.Env[$k] }
    $process = [Diagnostics.Process]::Start($psi)
    foreach ($line in $Run.Input) { $process.StandardInput.WriteLine($line) }
    $process.StandardInput.Close()
    [pscustomobject]@{ Run = $Run; Process = $process; Out = $process.StandardOutput.ReadToEndAsync(); Err = $process.StandardError.ReadToEndAsync(); Clock = [Diagnostics.Stopwatch]::StartNew() }
}
function Invoke-Runs([object[]]$Runs, [int]$Throttle = 6, [int]$TimeoutSeconds = 150) {
    $queue = [System.Collections.Generic.Queue[object]]::new()
    foreach ($r in $Runs) { $queue.Enqueue($r) }
    $running = [System.Collections.Generic.List[object]]::new()
    $done = @{}
    while ($queue.Count -or $running.Count) {
        while ($queue.Count -and $running.Count -lt $Throttle) { $running.Add((Start-Run $queue.Dequeue())) }
        Start-Sleep -Milliseconds 100
        foreach ($h in @($running)) {
            $timedOut = $h.Clock.Elapsed.TotalSeconds -gt $TimeoutSeconds
            if (-not $h.Process.HasExited -and -not $timedOut) { continue }
            if (-not $h.Process.HasExited) { try { $h.Process.Kill($true) } catch { } }
            [void]$h.Process.WaitForExit(10000)
            $out = if ($h.Out.Wait(5000)) { $h.Out.Result -replace "`e\[[0-9;]*m", '' } else { '' }
            $err = if ($h.Err.Wait(5000)) { $h.Err.Result -replace "`e\[[0-9;]*m", '' } else { '' }
            $r = $h.Run
            $installer = if (Test-Path -LiteralPath $r.InstallerLog) { Get-Content -LiteralPath $r.InstallerLog -Raw | ConvertFrom-Json } else { $null }
            $done[$r.Id] = [pscustomobject]@{
                Run = $r; Text = $out; All = ($out + "`n" + $err); ExitCode = $(if ($h.Process.HasExited) { $h.Process.ExitCode } else { -1 }); TimedOut = $timedOut
                Installer = $installer; AzCalls = @(if (Test-Path -LiteralPath $r.AzLog) { Get-Content -LiteralPath $r.AzLog | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json } }); After = (Get-FileText $r.RecordPath)
                Fingerprint = [regex]::Match($out, 'Fingerprint:\s+([a-f0-9]{64})').Groups[1].Value
            }
            [void]$running.Remove($h)
        }
    }
    return $done
}

$failures = [ordered]@{}
$checked = [ordered]@{}
function Test-Case([string]$Name, $Result, [bool]$Condition, [string]$Detail = '') {
    if (-not $checked.Contains($Name)) { $checked[$Name] = 0 }
    $checked[$Name]++
    if ($Condition) { return }
    if (-not $failures.Contains($Name)) { $failures[$Name] = [System.Collections.Generic.List[string]]::new() }
    $failures[$Name].Add("$($Result.Run.Id)$(if ($Detail) { " ($Detail)" })")
}
$excerpt = 'Line \||CategoryInfo|FullyQualifiedErrorId|At .+:\d+ char:\d+'

try {
    # ------------------------------------------------------------------ action x record state x mode
    $actions = @('Setup', 'Change', 'Guide')
    $records = @('none', 'match', 'drift', 'missing', 'signedout', 'noaz')
    $first = [System.Collections.Generic.List[object]]::new()
    foreach ($a in $actions) { foreach ($r in $records) { foreach ($m in 'planonly', 'attended') { $first.Add((New-Run "$a-$r-$m" $a $r $m)) } } }
    foreach ($r in $records) { $first.Add((New-Run "Status-$r" 'Status' $r 'status')) }
    # A record without a gateway, as a cancelled attended Setup leaves it (activeRun, no gateway).
    $noGateway = Join-Path $scratch 'record-no-gateway.json'
    [ordered]@{ schemaVersion = 2; decisions = [ordered]@{ foundation = [ordered]@{ sku = 'BasicV2' } }; activeRun = [ordered]@{ id = 'run1'; action = 'Setup'; phase = 'lead' }; history = @() } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $noGateway -Encoding UTF8
    $first.Add((New-Run 'Status-nogateway' 'Status' 'nogateway' 'status' -RecordFrom $noGateway))
    # The same plans on Windows PowerShell 5.1: their fingerprints must match those from PowerShell 7.
    if ($has51) { foreach ($a in $actions) { foreach ($r in 'none', 'match', 'signedout', 'noaz') { if ($a -eq 'Guide' -and $r -eq 'none') { continue }; $first.Add((New-Run "$a-$r-planonly-51" $a $r 'planonly' '5.1')) } } }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $results = Invoke-Runs @($first)
    # Unattended apply with the fingerprint -PlanOnly printed for the same combination.
    $second = [System.Collections.Generic.List[object]]::new()
    foreach ($a in $actions) { foreach ($r in $records) { $second.Add((New-Run "$a-$r-apply" $a $r 'apply' -Fingerprint $(if ($results["$a-$r-planonly"].Fingerprint) { $results["$a-$r-planonly"].Fingerprint } else { '0' * 64 }))) } }
    # The fingerprint of another plan changes nothing.
    $second.Add((New-Run 'Setup-none-wrongfp' 'Setup' 'none' 'apply' -Fingerprint ('0' * 64)))
    $second.Add((New-Run 'Change-match-wrongfp' 'Change' 'match' 'apply' -Fingerprint ('0' * 64)))
    # Applied on Windows PowerShell 5.1 too, in a copy that is not a git repository.
    if ($has51) { foreach ($pair in @(@('Setup', 'none'), @('Setup', 'match'), @('Change', 'match'))) { $id = "$($pair[0])-$($pair[1])"; $second.Add((New-Run "$id-apply-51" $pair[0] $pair[1] 'apply' '5.1' -Fingerprint $results["$id-planonly-51"].Fingerprint)) } }
    $apply = Invoke-Runs @($second)
    foreach ($k in $apply.Keys) { $results[$k] = $apply[$k] }
    Write-Host ("  {0} runs in {1:N1} s" -f $results.Count, $clock.Elapsed.TotalSeconds) -ForegroundColor DarkGray

    foreach ($res in $results.Values) {
        $r = $res.Run
        if ($r.Id -like '*-wrongfp') { continue }
        $recorded = $r.Record -ne 'none'
        $drift = $r.Record -in 'drift', 'missing'
        $unknown = $r.Record -in 'signedout', 'noaz'
        Test-Case 'every run ends, without a timeout' $res (-not $res.TimedOut) ''
        if ($res.ExitCode -ne 0) { Test-Case 'a refusal prints its reason and no PowerShell code excerpt' $res ($res.All -notmatch $excerpt) (($res.All -split "`n" | Where-Object { $_ -match $excerpt } | Select-Object -First 1)) }
        if ($res.ExitCode -ne 0) { Test-Case 'a deliberate refusal shows no debugging hint' $res ($res.All -notmatch 'does not expect') '' }
        if ($r.Action -eq 'Status') {
            Test-Case 'Status writes nothing' $res ($res.After -eq $r.Before) ''
            Test-Case 'Status ends without an error' $res ($res.ExitCode -eq 0) ($res.All -split "`n" | Select-Object -Last 2)
            $want = switch ($r.Record) { 'none' { 'No decision record at' } 'nogateway' { 'no gateway is recorded, so nothing is recorded to compare' } 'match' { 'none detected' } { $_ -in 'drift', 'missing' } { 'DRIFT' } default { 'not checked' } }
            Test-Case 'Status reports the comparison for each record state' $res ($res.Text -match $want) "want '$want'"
            continue
        }
        $guideNothing = $r.Action -eq 'Guide' -and -not $recorded
        $refuses = ($r.Action -in 'Setup', 'Change' -and $drift) -or $guideNothing
        $runsInstaller = -not $refuses -and $r.Mode -ne 'planonly' -and ($r.Action -eq 'Change' -or ($r.Action -eq 'Setup' -and -not $recorded))
        Test-Case 'the installer runs only for Change foundation or a Setup with no gateway recorded' $res ([bool]$res.Installer -eq $runsInstaller) "ran=$([bool]$res.Installer) want=$runsInstaller"
        if ($res.Installer) {
            $bound = @($res.Installer.bound.PSObject.Properties.Name)
            Test-Case '-Yes is passed exactly when unattended' $res (($bound -contains 'Yes') -eq ($r.Mode -eq 'apply')) ($bound -join ',')
            if ($r.Action -eq 'Change' -and $recorded) {
                Test-Case 'Change foundation names the recorded gateway, and not its region, tier, name or publisher' $res ($res.Installer.bound.ExistingApimName -eq 'apim-p72' -and $res.Installer.bound.ResourceGroup -eq 'rg-p72' -and -not @($bound | Where-Object { $_ -in 'Location', 'NamePrefix', 'PublisherEmail', 'Sku' }).Count) ($bound -join ',')
            }
        }
        if ($refuses) {
            if ($guideNothing) { Test-Case 'Guide with nothing recorded stops before planning and says why' $res ($res.ExitCode -ne 0 -and $res.All -match 'No gateway is recorded, so there is no deployment' -and -not $res.Fingerprint -and $res.After -eq $r.Before) "exit=$($res.ExitCode)" }
            else { Test-Case 'drift stops Setup and Change before planning' $res ($res.ExitCode -ne 0 -and $res.All -match 'does not match live state' -and -not $res.Fingerprint -and $res.After -eq $r.Before) "exit=$($res.ExitCode)" }
            continue
        }
        if ($r.Action -eq 'Guide' -and $drift -and $r.Mode -ne 'attended') {
            Test-Case 'Guide goes on over drift and names it' $res ($res.ExitCode -eq 0 -and $res.Text -match 'differs from live|was not found') "exit=$($res.ExitCode)"
        }
        if ($unknown) {
            Test-Case 'a read that failed is reported as not read, never as drift' $res ($res.All -match 'not read|not installed|not on PATH' -and $res.All -notmatch 'does not match live state') ''
        }
        if (-not $recorded) {
            # Every Azure CLI call, in order: none before the installer starts, and none at all without it.
            $early = @($res.AzCalls | Where-Object { -not $res.Installer -or [long]$_.ticks -lt [long]$res.Installer.started })
            Test-Case 'with nothing recorded, nothing is read from Azure before the installer' $res ($early.Count -eq 0) (@($early | ForEach-Object args) -join '; ')
        }
        switch ($r.Mode) {
            'planonly' {
                Test-Case '-PlanOnly prints a fingerprint and writes nothing' $res ($res.ExitCode -eq 0 -and $res.Fingerprint -and $res.After -eq $r.Before) "exit=$($res.ExitCode) $(($res.All -split "`n" | Select-Object -Last 1))"
            }
            'apply' {
                $rec = if ($res.After) { $res.After | ConvertFrom-Json } else { $null }
                Test-Case 'an unattended apply of the reviewed plan completes and leaves no active run' $res ($res.ExitCode -eq 0 -and $rec -and @($rec.history).Count -ge 1 -and -not ($rec.PSObject.Properties.Name -contains 'activeRun')) "exit=$($res.ExitCode) $(($res.All -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 1))"
            }
            'attended' {
                if ($r.Action -eq 'Change') {
                    Test-Case 'attended Change foundation ends after the installer' $res ($res.ExitCode -eq 0) (($res.All -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 1))
                }
                else {
                    $said = if ($runsInstaller) { 'gateway foundation is set up' } else { 'nothing was written' }
                    Test-Case 'a mistyped fingerprint says what was and was not applied' $res ($res.ExitCode -ne 0 -and $res.All -match $said) "want '$said'"
                }
            }
        }
    }
    foreach ($id in 'Setup-none-wrongfp', 'Change-match-wrongfp') {
        $res = $results[$id]
        Test-Case 'the fingerprint of another plan changes nothing' $res ($res.ExitCode -ne 0 -and $res.All -match 'does not match plan fingerprint' -and -not $res.Installer -and $res.After -eq $res.Run.Before) "exit=$($res.ExitCode)"
        Test-Case 'a refusal prints its reason and no PowerShell code excerpt' $res ($res.All -notmatch $excerpt) (($res.All -split "`n" | Where-Object { $_ -match $excerpt } | Select-Object -First 1))
        Test-Case 'a deliberate refusal shows no debugging hint' $res ($res.All -notmatch 'does not expect') ''
    }
    if ($has51) {
        foreach ($a in $actions) {
            foreach ($r in 'none', 'match', 'signedout', 'noaz') {
                if ($a -eq 'Guide' -and $r -eq 'none') { continue }
                $p7 = $results["$a-$r-planonly"]; $p5 = $results["$a-$r-planonly-51"]
                Test-Case 'the same plan has the same fingerprint on PowerShell 7 and Windows PowerShell 5.1' $p5 ($p5.Fingerprint -and $p5.Fingerprint -eq $p7.Fingerprint) "7=$($p7.Fingerprint.Substring(0, [Math]::Min(8, $p7.Fingerprint.Length))) 5.1=$($p5.Fingerprint.Substring(0, [Math]::Min(8, $p5.Fingerprint.Length))) $(($p5.All -split "`n" | Where-Object { $_ -match 'Exception|Error' } | Select-Object -First 1))"
            }
        }
    }

    # ------------------------------------------------------------------ -WhatIf, Update, callers and unexpected errors
    $edge = [System.Collections.Generic.List[object]]::new()
    foreach ($pair in @(@('Setup', 'none'), @('Setup', 'match'), @('Change', 'match'), @('Guide', 'match'))) { $edge.Add((New-Run "$($pair[0])-$($pair[1])-whatif" $pair[0] $pair[1] 'whatif')) }
    $edge.Add((New-Run 'Update-none' 'Update' 'none' 'planonly'))
    $edge.Add((New-Run 'Setup-none-cancel' 'Setup' 'none' 'attended' -InputLines @('cancel')))
    foreach ($shell in @('7') + $(if ($has51) { @('5.1') } else { @() })) {
        $edge.Add((New-Run "inprocess-cancel-$shell" 'Setup' 'none' 'attended' $shell -InputLines @('cancel') -Caller '&'))
        $edge.Add((New-Run "dotsource-cancel-$shell" 'Setup' 'none' 'attended' $shell -InputLines @('cancel') -Caller '.'))
        $edge.Add((New-Run "inprocess-mistyped-$shell" 'Setup' 'none' 'attended' $shell -Caller '&'))
        $edge.Add((New-Run "prompt-dotsource-cancel-$shell" 'Setup' 'none' 'attended' $shell -InputLines @('cancel') -Caller 'prompt'))
    }
    $matchFp = $results['Setup-match-planonly'].Fingerprint
    $edge.Add((New-Run 'unexpected-error' 'Setup' 'match' 'apply' -Fingerprint $matchFp -Env @{ P72_FINOPS_FAIL = '1' }))
    $edge.Add((New-Run 'unexpected-error-debug' 'Setup' 'match' 'apply' -Fingerprint $matchFp -Env @{ P72_FINOPS_FAIL = '1'; CLAUDE_FLOW_DEBUG = '1' }))
    $edges = Invoke-Runs @($edge)
    foreach ($id in @($edges.Keys | Where-Object { $_ -like '*-whatif' })) {
        $res = $edges[$id]
        Test-Case '-WhatIf prints the review, runs no installer and writes nothing' $res ($res.ExitCode -eq 0 -and $res.Text -match 'WhatIf: no guided flow changes were written' -and -not $res.Installer -and $res.After -eq $res.Run.Before) "exit=$($res.ExitCode) $(($res.All -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 1))"
    }
    $res = $edges['Update-none']
    Test-Case 'Update with no record says that nothing can be updated and writes nothing' $res ($res.ExitCode -eq 0 -and $res.All -match 'Nothing can be updated' -and -not $res.After) "exit=$($res.ExitCode)"
    $res = $edges['Setup-none-cancel']
    Test-Case 'a cancelled installer ends a top-level run with its reason, exit 1, no code excerpt and no debugging hint' $res ($res.ExitCode -eq 1 -and $res.All -match 'finished without writing' -and $res.All -notmatch $excerpt -and $res.All -notmatch 'does not expect') "exit=$($res.ExitCode)"
    foreach ($id in @($edges.Keys | Where-Object { $_ -like 'inprocess-*' -or $_ -like 'dotsource-*' -or $_ -like 'prompt-dotsource-*' })) {
        $res = $edges[$id]
        $want = if ($id -like '*mistyped*') { 'CALLER CAUGHT: System.OperationCanceledException: Confirmation did not match, so the steps in this review were not applied' } else { 'CALLER CAUGHT: System.OperationCanceledException: Install-ClaudeGateway.ps1 finished without writing' }
        Test-Case 'called in process or dot-sourced, a cancel reaches the caller as an exception and the caller goes on' $res ($res.ExitCode -eq 0 -and $res.Text -match [regex]::Escape($want) -and $res.Text -match 'CALLER CONTINUED' -and $res.Text -notmatch 'CALLER NOTHING RAISED') "exit=$($res.ExitCode) $(($res.Text -split "`n" | Where-Object { $_ -match 'CALLER' }) -join ' | ')"
    }
    $res = $edges['unexpected-error']
    Test-Case 'an unexpected error names itself and how to see where it stopped, in PowerShell syntax' $res ($res.ExitCode -eq 1 -and $res.All -match 'does not expect' -and $res.All -match [regex]::Escape("`$env:CLAUDE_FLOW_DEBUG = '1'") -and $res.All -notmatch $excerpt) "exit=$($res.ExitCode)"
    $res = $edges['unexpected-error-debug']
    Test-Case 'with CLAUDE_FLOW_DEBUG=1 an unexpected error prints where it stopped' $res ($res.ExitCode -eq 1 -and $res.All -match '(?m)^at ' -and $res.All -notmatch 'does not expect') "exit=$($res.ExitCode)"

    # ------------------------------------------------------------------ store, unattended, in child processes
    $storeRuns = [System.Collections.Generic.List[object]]::new()
    foreach ($store in 'named-value', 'projection') {
        $answers = @{ 'foundation.sku' = 'StandardV2'; 'foundation.entitlementStore' = $store; 'foundation.authMode' = 'interactive'; 'foundation.desktopSignInKind' = 'helper-script' }
        $storeRuns.Add((New-Run "store-$store-setup" 'Setup' 'none' 'planonly' -Answers $answers))
        $storeRuns.Add((New-Run "store-$store-change" 'Change' 'match' 'planonly' -Store $store))
    }
    $storePlans = Invoke-Runs @($storeRuns)
    $storeApplies = [System.Collections.Generic.List[object]]::new()
    foreach ($store in 'named-value', 'projection') {
        $answers = @{ 'foundation.sku' = 'StandardV2'; 'foundation.entitlementStore' = $store; 'foundation.authMode' = 'interactive'; 'foundation.desktopSignInKind' = 'helper-script' }
        $storeApplies.Add((New-Run "store-$store-setup-apply" 'Setup' 'none' 'apply' -Answers $answers -Fingerprint $storePlans["store-$store-setup"].Fingerprint))
        $storeApplies.Add((New-Run "store-$store-change-apply" 'Change' 'match' 'apply' -Store $store -Fingerprint $storePlans["store-$store-change"].Fingerprint))
    }
    $stores = Invoke-Runs @($storeApplies)
    foreach ($res in $stores.Values) {
        $wantDeploy = $res.Run.Id -like 'store-projection-*'
        Test-Case '-DeployProjection is passed exactly when unattended with the projection store' $res ($res.Installer -and (@($res.Installer.bound.PSObject.Properties.Name) -contains 'DeployProjection') -eq $wantDeploy) "exit=$($res.ExitCode) $(($res.All -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 1))"
    }

    # ------------------------------------------------------------------ a recorded foundation, fed back to the installer
    # Setup unattended with every foundation choice, then Change foundation unattended over the record it
    # wrote: the installer is given back the same choices, each valid for its parameter.
    $full = @{
        'foundation.sku' = 'StandardV2'; 'foundation.entitlementStore' = 'projection'; 'foundation.authMode' = 'device'
        'foundation.desktopSignInKind' = 'external-idp-broker'; 'foundation.desktopEntraClientId' = '11111111-2222-4333-8444-555555555555'
        'foundation.desktopBearerTokenType' = 'access_token'; 'foundation.desktopEntraScopes' = 'api://p72-gateway/user_impersonation'; 'foundation.desktopEntraAudience' = 'api://p72-gateway'
        'foundation.standardGroup' = 'eng-claude-standard'; 'foundation.premiumGroup' = 'eng-claude-premium'
        'foundation.tpmStandard' = 30000; 'foundation.quotaStandard' = 600000; 'foundation.tpmPremium' = 90000; 'foundation.quotaPremium' = 6000000; 'foundation.quotaOrg' = 200000000; 'foundation.callsPerMinute' = 90
    }
    $rtPlan = Invoke-Runs @((New-Run 'roundtrip-setup' 'Setup' 'none' 'planonly' -Answers $full))
    $rtSetup = Invoke-Runs @((New-Run 'roundtrip-setup-apply' 'Setup' 'none' 'apply' -Answers $full -Fingerprint $rtPlan['roundtrip-setup'].Fingerprint))
    $setupRes = $rtSetup['roundtrip-setup-apply']
    $expected = [ordered]@{ EntitlementStore = 'projection'; AuthMode = 'device'; DesktopSignInKind = 'external-idp-broker'; DesktopEntraClientId = '11111111-2222-4333-8444-555555555555'; DesktopBearerTokenType = 'access_token'; DesktopEntraScopes = 'api://p72-gateway/user_impersonation'; DesktopEntraAudience = 'api://p72-gateway'; StandardGroup = 'eng-claude-standard'; PremiumGroup = 'eng-claude-premium'; TpmStandard = '30000'; QuotaStandard = '600000'; TpmPremium = '90000'; QuotaPremium = '6000000'; QuotaOrg = '200000000'; CallsPerMinute = '90' }
    function Get-Mismatch($Bound) { @(foreach ($k in $expected.Keys) { $got = if ($Bound -and ($Bound.PSObject.Properties.Name -contains $k)) { [string]$Bound.$k } else { '(not passed)' }; if ($got -ne $expected[$k]) { "$k=$got" } }) }
    $setupMismatch = Get-Mismatch $setupRes.Installer.bound
    Test-Case 'an unattended Setup passes every recorded foundation choice to the installer' $setupRes ($setupRes.ExitCode -eq 0 -and $setupRes.Installer -and -not $setupMismatch.Count) ("exit=$($setupRes.ExitCode) " + ($setupMismatch -join ', ') + ' ' + (($setupRes.All -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 1)))
    if ($setupRes.ExitCode -eq 0 -and $setupRes.After) {
        $rtRecord = Join-Path $scratch 'roundtrip-record.json'
        Set-Content -LiteralPath $rtRecord -Value $setupRes.After -Encoding UTF8
        $changePlan = Invoke-Runs @((New-Run 'roundtrip-change' 'Change' 'match' 'planonly' -RecordFrom $rtRecord))
        $changeApply = Invoke-Runs @((New-Run 'roundtrip-change-apply' 'Change' 'match' 'apply' -RecordFrom $rtRecord -Fingerprint $changePlan['roundtrip-change'].Fingerprint))
        $changeRes = $changeApply['roundtrip-change-apply']
        $changeMismatch = Get-Mismatch $changeRes.Installer.bound
        Test-Case 'Change foundation gives the installer back the choices the record holds, each valid for its parameter' $changeRes ($changeRes.ExitCode -eq 0 -and $changeRes.Installer -and -not $changeMismatch.Count) ("exit=$($changeRes.ExitCode) " + ($changeMismatch -join ', ') + ' ' + (($changeRes.All -split "`n" | Where-Object { $_ -match 'Cannot validate|does not belong|not in the set|Exception' } | Select-Object -First 1)))
    }
    else { Test-Case 'Change foundation gives the installer back the choices the record holds, each valid for its parameter' $setupRes $false 'the Setup before it did not complete' }

    # ------------------------------------------------------------------ Foundation's installer arguments, in process
    $inProcess = & {
        $env:CLAUDE_FLOW_SKIP_AZ_DISCOVERY = '1'
        try {
            . (Join-Path $root 'scripts\flow\FlowContract.ps1')
            . (Join-Path $root 'scripts\ClaudeChoice.ps1')
            . (Join-Path $root 'scripts\flow\Foundation.ps1')
            $out = [System.Collections.Generic.List[object]]::new()
            foreach ($store in 'named-value', 'projection') { foreach ($desktop in 'helper-script', 'external-idp-browser', 'external-idp-broker') { foreach ($auth in 'interactive', 'device', 'helper') { foreach ($tier in 'BasicV2', 'StandardV2', 'PremiumV2') {
                foreach ($attended in $false, $true) { foreach ($recorded in $false, $true) { foreach ($action in 'Setup', 'Change') {
                    $decision = [ordered]@{ sku = $tier; entitlementStore = $store; authMode = $auth; desktopSignInKind = $desktop }
                    if ($desktop -ne 'helper-script') { $decision.desktopEntraClientId = '11111111-2222-4333-8444-555555555555' }
                    $record = [pscustomobject]@{ schemaVersion = 2; decisions = [pscustomobject]@{ foundation = [pscustomobject]$decision }; history = @() }
                    if ($recorded) { $record | Add-Member -NotePropertyName apimName -NotePropertyValue 'apim-p72'; $record | Add-Member -NotePropertyName resourceGroup -NotePropertyValue 'rg-p72' }
                    $discovery = [pscustomobject]@{ action = $action; attended = $attended; gateway = $null }
                    $plan = $null; $err = ''
                    try { $plan = Get-ClaudeFlowStepPlan -Record $record -Discovery $discovery } catch { $err = $_.Exception.Message }
                    $out.Add([pscustomobject]@{ Store = $store; Desktop = $desktop; Auth = $auth; Tier = $tier; Attended = $attended; Recorded = $recorded; Action = $action; Plan = $plan; Error = $err; Fingerprint = $(if ($plan) { Get-ClaudeFlowFingerprint -Plans @($plan) } else { '' }) })
                } } }
            } } } }
            # An external IdP Desktop sign-in without its app, unattended: refused by the plan, before approval.
            $missing = [System.Collections.Generic.List[object]]::new()
            foreach ($desktop in 'external-idp-browser', 'external-idp-broker') { foreach ($recorded in $false, $true) {
                $record = [pscustomobject]@{ schemaVersion = 2; decisions = [pscustomobject]@{ foundation = [pscustomobject]@{ sku = 'BasicV2'; entitlementStore = 'named-value'; authMode = 'interactive'; desktopSignInKind = $desktop } }; history = @() }
                if ($recorded) { $record | Add-Member -NotePropertyName apimName -NotePropertyValue 'apim-p72'; $record | Add-Member -NotePropertyName resourceGroup -NotePropertyValue 'rg-p72' }
                $err = ''
                try { $null = Get-ClaudeFlowStepPlan -Record $record -Discovery ([pscustomobject]@{ action = $(if ($recorded) { 'Change' } else { 'Setup' }); attended = $false; gateway = $null }) } catch { $err = $_.Exception.Message }
                $missing.Add([pscustomobject]@{ Desktop = $desktop; Recorded = $recorded; Error = $err })
            } }
            # The record each Desktop sign-in leaves, in the real installer's shape, merged into a decision
            # that holds none of it, as after an attended Setup where the installer asked everything.
            $typed = [ordered]@{ standardGroup = 'eng-claude-standard'; premiumGroup = 'eng-claude-premium'; resolverInboundAccess = 'public'; requestsPerMinute = 90; tiers = [pscustomobject]@{ standard = [pscustomobject]@{ tokensPerMinute = 30000; tokensPerDay = 600000 }; premium = [pscustomobject]@{ tokensPerMinute = 90000; tokensPerDay = 6000000 } }; organisation = [pscustomobject]@{ tokensPerMonth = 200000000; shared = $true; softCap = $true } }
            $shapes = @(
                [pscustomobject]@{ Kind = 'helper-script'; Config = [pscustomobject]@{ kind = 'helper-script' } }
                [pscustomobject]@{ Kind = 'external-idp-browser'; Config = [pscustomobject]@{ kind = 'external-idp'; flow = 'browser'; bearerTokenType = 'id_token'; clientId = '11111111-2222-4333-8444-555555555555'; issuer = 'https://login.microsoftonline.com/00000000-0000-0000-0000-000000000000/v2.0' } }
                [pscustomobject]@{ Kind = 'external-idp-broker'; Config = [pscustomobject]@{ kind = 'external-idp'; flow = 'broker'; bearerTokenType = 'access_token'; clientId = '11111111-2222-4333-8444-555555555555'; issuer = 'https://login.microsoftonline.com/00000000-0000-0000-0000-000000000000/v2.0'; scopes = 'api://p72-gateway/user_impersonation'; audience = 'api://p72-gateway' } }
            )
            $merged = foreach ($s in $shapes) {
                $config = [pscustomobject]([ordered]@{ sku = 'BasicV2'; entitlementStore = 'projection'; desktopSignIn = $s.Config } + $typed)
                $d = Merge-ClaudeFlowFoundationDecision -Decision ([pscustomobject]@{ sku = 'BasicV2' }) -Config $config
                $record = [pscustomobject]@{ schemaVersion = 2; apimName = 'apim-p72'; resourceGroup = 'rg-p72'; decisions = [pscustomobject]@{ foundation = $d }; history = @() }
                $merge = $null; $err = ''
                try { $merge = Get-ClaudeFlowFoundationInstallerArgs -Decision $d -Attended $false -Record $record -UpdateRecorded $true } catch { $err = $_.Exception.Message }
                [pscustomobject]@{ Kind = $s.Kind; Config = $s.Config; Args = $merge; Error = $err }
            }
            [pscustomobject]@{ Plans = @($out); Missing = @($missing); Merged = @($merged); NamedValueResolver = $(
                $d = Merge-ClaudeFlowFoundationDecision -Decision ([pscustomobject]@{ sku = 'BasicV2'; resolverInboundAccess = 'private' }) -Config ([pscustomobject]@{ sku = 'BasicV2'; entitlementStore = 'named-value'; resolverInboundAccess = 'private'; desktopSignIn = [pscustomobject]@{ kind = 'helper-script' } })
                $record = [pscustomobject]@{ schemaVersion = 2; apimName = 'apim-p72'; resourceGroup = 'rg-p72'; decisions = [pscustomobject]@{ foundation = $d }; history = @() }
                Get-ClaudeFlowFoundationInstallerArgs -Decision $d -Attended $false -Record $record -UpdateRecorded $true
            ) }
        }
        finally { Remove-Item Env:\CLAUDE_FLOW_SKIP_AZ_DISCOVERY -ErrorAction SilentlyContinue }
    }
    foreach ($p in $inProcess.Plans) {
        $res = [pscustomobject]@{ Run = [pscustomobject]@{ Id = "$($p.Action)/$($p.Store)/$($p.Desktop)/$($p.Auth)/$($p.Tier)/$(if ($p.Attended) { 'attended' } else { 'unattended' })/$(if ($p.Recorded) { 'recorded' } else { 'new' })" } }
        if (-not $p.Plan) { Test-Case 'Foundation plans every combination of the foundation choices' $res $false $p.Error; continue }
        Test-Case 'Foundation plans every combination of the foundation choices' $res $true
        $runs = [bool]$p.Plan.Data.runsInstaller
        Test-Case 'Foundation runs the installer only for Change or a Setup with no gateway recorded' $res ($runs -eq ($p.Action -eq 'Change' -or -not $p.Recorded)) "runs=$runs"
        if (-not $runs) { continue }
        $ia = $p.Plan.Data.installerArgs
        $keys = @($ia.Keys | ForEach-Object { [string]$_ })
        Test-Case 'every argument names an installer parameter and holds a value it accepts' $res (-not @($keys | Where-Object { -not $installerParams.ContainsKey($_) -or ($installerParams[$_].Count -and [string]$ia[$_] -notin $installerParams[$_]) }).Count) (@($keys | Where-Object { -not $installerParams.ContainsKey($_) -or ($installerParams[$_].Count -and [string]$ia[$_] -notin $installerParams[$_]) } | ForEach-Object { "-$_ $($ia[$_])" }) -join ', ')
        Test-Case 'Foundation passes -Yes exactly when unattended' $res (($keys -contains 'Yes') -ne $p.Attended) ($keys -join ',')
        Test-Case 'Foundation passes -DeployProjection exactly when unattended with the projection store' $res (($keys -contains 'DeployProjection') -eq (-not $p.Attended -and $p.Store -eq 'projection')) ($keys -join ',')
        if ($p.Recorded) {
            Test-Case 'with -ExistingApimName, the recorded region, tier, name and publisher are not passed' $res ($ia['ExistingApimName'] -eq 'apim-p72' -and $ia['ResourceGroup'] -eq 'rg-p72' -and -not @($keys | Where-Object { $_ -in 'Location', 'NamePrefix', 'PublisherEmail', 'Sku' }).Count) ($keys -join ',')
            if ($p.Attended) { Test-Case 'attended over a recorded gateway, only the gateway is named and the installer asks the rest' $res ((@($keys | Sort-Object) -join ',') -eq 'ExistingApimName,ResourceGroup,SkipFinOpsOffer') ($keys -join ',') }
        }
        if (-not $p.Attended) {
            $want = @('EntitlementStore', 'AuthMode', 'DesktopSignInKind') + $(if ($p.Recorded) { @() } else { @('Sku') }) + $(if ($p.Desktop -ne 'helper-script') { @('DesktopEntraClientId') } else { @() })
            Test-Case 'unattended, every recorded foundation choice reaches the installer' $res (-not @($want | Where-Object { $keys -notcontains $_ }).Count) ("missing: " + (@($want | Where-Object { $keys -notcontains $_ }) -join ','))
        }
    }
    $byArgs = @{}
    foreach ($p in @($inProcess.Plans | Where-Object { $_.Plan -and $_.Plan.Data.runsInstaller })) {
        $key = ConvertTo-Json -InputObject ([ordered]@{} + $p.Plan.Data.installerArgs) -Compress
        if (-not $byArgs.ContainsKey($p.Fingerprint)) { $byArgs[$p.Fingerprint] = @{} }
        $byArgs[$p.Fingerprint][$key] = $true
    }
    $shared = @($byArgs.Keys | Where-Object { $byArgs[$_].Count -gt 1 })
    Assert "different installer arguments never share a fingerprint ($($byArgs.Count) fingerprints)" ($shared.Count -eq 0 -and $byArgs.Count -gt 1) "$($shared.Count) fingerprint(s) cover more than one argument set"
    foreach ($m in $inProcess.Missing) {
        $res = [pscustomobject]@{ Run = [pscustomobject]@{ Id = "$($m.Desktop)/$(if ($m.Recorded) { 'Change' } else { 'Setup' })" } }
        Test-Case 'unattended, an external IdP Desktop sign-in without its app is refused by the plan, before approval' $res ($m.Error -match 'desktopEntraClientId') $m.Error
    }
    foreach ($m in $inProcess.Merged) {
        $res = [pscustomobject]@{ Run = [pscustomobject]@{ Id = "merged-$($m.Kind)" } }
        $ia = $m.Args
        $ok = $ia -and [string]$ia['DesktopSignInKind'] -eq $m.Kind -and $m.Kind -in $installerParams['DesktopSignInKind']
        if ($ok -and $m.Kind -ne 'helper-script') { $ok = [string]$ia['DesktopEntraClientId'] -eq $m.Config.clientId -and [string]$ia['DesktopBearerTokenType'] -eq $m.Config.bearerTokenType -and [string]$ia['DesktopEntraIssuer'] -eq $m.Config.issuer }
        if ($ok -and $m.Config.PSObject.Properties.Name -contains 'scopes') { $ok = [string]$ia['DesktopEntraScopes'] -eq $m.Config.scopes -and [string]$ia['DesktopEntraAudience'] -eq $m.Config.audience }
        Test-Case 'the installer''s Desktop sign-in record, merged into the decision, gives the installer back that sign-in' $res $ok $(if ($m.Error) { $m.Error } elseif ($ia) { "kind=$($ia['DesktopSignInKind']) client=$($ia['DesktopEntraClientId']) bearer=$($ia['DesktopBearerTokenType'])" } else { 'no arguments' })
        $typedWant = [ordered]@{ StandardGroup = 'eng-claude-standard'; PremiumGroup = 'eng-claude-premium'; ResolverInboundAccess = 'public'; EntitlementStore = 'projection'; CallsPerMinute = '90'; TpmStandard = '30000'; QuotaStandard = '600000'; TpmPremium = '90000'; QuotaPremium = '6000000'; QuotaOrg = '200000000' }
        $typedMiss = @(foreach ($k in $typedWant.Keys) { $got = if ($ia -and $ia.Contains($k)) { [string]$ia[$k] } else { '(not passed)' }; if ($got -ne $typedWant[$k]) { "$k=$got" } })
        Test-Case 'the budgets, groups, request ceiling and resolver access the installer recorded come back through the merge' $res (-not $typedMiss.Count) ($typedMiss -join ', ')
    }

    # The merge reads what the installer writes: every field it maps back is a key of the record the
    # real installer builds (its $config hashtable), so the stub installer's shape cannot drift alone.
    $configAst = $installerAst.Find({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$config' -and $n.Right.Extent.Text -match '^\[ordered\]@\{' }, $true)
    $configKeys = @()
    if ($configAst) {
        $table = $configAst.Right.Find({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true)
        foreach ($pair in $table.KeyValuePairs) {
            $key = $pair.Item1.Extent.Text.Trim("'", '"')
            $configKeys += $key
            $inner = $pair.Item2.Find({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true)
            if ($inner) { foreach ($sub in $inner.KeyValuePairs) { $configKeys += "$key.$($sub.Item1.Extent.Text.Trim("'", '"'))" } }
        }
    }
    $merges = @('sku', 'location', 'foundryAccount', 'foundryResourceGroup', 'resourceGroup', 'entitlementStore', 'resolverInboundAccess', 'authMode', 'standardGroup', 'premiumGroup', 'desktopSignIn', 'tiers', 'tiers.standard', 'tiers.premium', 'organisation', 'organisation.tokensPerMonth', 'requestsPerMinute')
    $absent = @($merges | Where-Object { $configKeys -notcontains $_ })
    Assert "the installer's record holds every field the merge reads ($($merges.Count))" ($configKeys.Count -gt 10 -and $absent.Count -eq 0) ("absent: " + ($absent -join ', '))

    $nvArgs = $inProcess.NamedValueResolver
    Assert 'a named-value store keeps no resolver access, so a later switch to the projection on Basic v2 is not refused for it' ($nvArgs -and -not $nvArgs.Contains('ResolverInboundAccess') -and [string]$nvArgs['EntitlementStore'] -eq 'named-value') ((@($nvArgs.Keys) | ForEach-Object { "$_=$($nvArgs[$_])" }) -join ', ')

    foreach ($name in $checked.Keys) {
        $detail = if ($failures.Contains($name)) { "$($failures[$name].Count) of $($checked[$name]): " + (@($failures[$name] | Select-Object -First 3) -join '; ') } else { '' }
        Assert "$name ($($checked[$name]))" (-not $failures.Contains($name)) $detail
    }
}
finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail) { Write-Host "$fail check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'The guided flow holds its invariants across the permutations.' -ForegroundColor Green
exit 0
