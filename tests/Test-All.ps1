# Run offline checks in isolated pwsh processes, with ordered output.
# -Serial retains registration-order, one-at-a-time execution.
# -IncludeAzure adds live checks, always last and exclusive (they share a gateway).
# TEST_ALL_THROTTLE overrides the CPU-derived default; -ThrottleLimit wins over it.
param(
    [switch]$IncludeAzure,
    [switch]$Serial,
    [ValidateRange(1, 16)][int]$ThrottleLimit,
    [ValidateRange(1, 3600)][int]$CheckTimeoutSeconds = 600
)

$ErrorActionPreference = 'Stop'
if (-not $PSBoundParameters.ContainsKey('ThrottleLimit')) {
    $ThrottleLimit = [math]::Max(1, [math]::Min(4, [Environment]::ProcessorCount))
    if ($env:TEST_ALL_THROTTLE) {
        $configured = 0
        if (-not [int]::TryParse($env:TEST_ALL_THROTTLE, [ref]$configured) -or $configured -lt 1 -or $configured -gt 16) {
            throw 'TEST_ALL_THROTTLE must be an integer from 1 to 16.'
        }
        $ThrottleLimit = $configured
    }
}
if ($Serial) { $ThrottleLimit = 1 }
$root = Split-Path $PSScriptRoot -Parent
$scriptsDir = Join-Path $root 'scripts'
$pwsh = (Get-Command pwsh -ErrorAction Stop).Source
$checks = [Collections.Generic.List[object]]::new()
$active = [Collections.Generic.List[object]]::new()
$results = @()
$runDirectory = Join-Path ([IO.Path]::GetTempPath()) ('test-all-' + [guid]::NewGuid().ToString('N'))
$suiteClock = [Diagnostics.Stopwatch]::StartNew()

function Invoke-Check {
    param(
        [string]$Name, [string]$Script, [hashtable]$Params = @{},
        [switch]$SerialLane, [switch]$Azure, [string]$SkipReason,
        [ValidateRange(0, 3600)][int]$TimeoutSeconds = 0
    )
    $checks.Add([pscustomobject]@{
        Id = $checks.Count; Name = $Name; Script = $Script; Params = $Params
        Lane = $(if ($Azure) { 'Azure' } elseif ($SerialLane) { 'Exclusive' } else { 'Parallel' })
        SkipReason = $SkipReason
        Timeout = $(if ($TimeoutSeconds) { $TimeoutSeconds } else { $CheckTimeoutSeconds })
        Process = $null; Stdout = $null; Stderr = $null; Clock = $null
    })
}

function Set-CheckResult($check, [string]$Status, [string]$Output = '', $ExitCode = $null) {
    $seconds = if ($check.Clock) { [math]::Round($check.Clock.Elapsed.TotalSeconds, 1) } else { 0.0 }
    $result = [pscustomobject]@{
        Id = $check.Id; Name = $check.Name; Script = $check.Script
        Result = $Status; Seconds = $seconds; ExitCode = $ExitCode; Output = $Output
    }
    $script:results[$check.Id] = $result
}

function Stop-CheckProcess($check) {
    if ($check.Process) {
        try {
            if (-not $check.Process.HasExited) {
                # The wizard, Node and pytest launch descendants of their own.
                $check.Process.Kill($true)
                if (-not $check.Process.WaitForExit(5000)) { throw 'The check process did not stop.' }
            }
            foreach ($read in @($check.Stdout, $check.Stderr)) {
                if ($read) { [void]$read.Wait(1000) }
            }
        }
        finally { $check.Process.Dispose(); $check.Process = $null }
    }
}

function Set-CheckFailure($check, [string]$Message) {
    # Killing the process closes its pipes. Collect after that, or a timed-out
    # check loses all the diagnostic output it printed before hanging.
    try { Stop-CheckProcess $check } catch { $Message += " Cleanup: $($_.Exception.Message)" }
    $output = ''
    if ($check.Stdout -and $check.Stdout.IsCompletedSuccessfully) { $output += $check.Stdout.Result }
    if ($check.Stderr -and $check.Stderr.IsCompletedSuccessfully) { $output += $check.Stderr.Result }
    Set-CheckResult $check 'FAIL' ($output + "`n  FAIL - $Message")
}

function Start-Check($check) {
    $check.Clock = [Diagnostics.Stopwatch]::StartNew()
    $path = Join-Path $PSScriptRoot $check.Script
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $path = Join-Path $scriptsDir $check.Script }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Set-CheckFailure $check "$($check.Script) not found"
        return
    }
    if ($check.SkipReason) {
        Set-CheckResult $check 'SKIP' ("  SKIP - " + $check.SkipReason)
        return
    }
    $scratch = Join-Path $runDirectory ([string]$check.Id)
    New-Item -ItemType Directory -Path $scratch -Force | Out-Null
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $pwsh
    $startInfo.WorkingDirectory = $root
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.StandardOutputEncoding = [Text.Encoding]::UTF8
    $startInfo.StandardErrorEncoding = [Text.Encoding]::UTF8
    foreach ($key in 'TEMP', 'TMP', 'TMPDIR') { $startInfo.Environment[$key] = $scratch }
    foreach ($arg in @('-NoProfile', '-NonInteractive', '-File', $path)) { $startInfo.ArgumentList.Add($arg) }
    foreach ($key in $check.Params.Keys) {
        $value = $check.Params[$key]
        if ($value -is [bool] -or $value -is [switch]) {
            $startInfo.ArgumentList.Add(('-{0}:${1}' -f $key, ([bool]$value).ToString().ToLowerInvariant()))
        }
        else {
            $startInfo.ArgumentList.Add("-$key")
            $startInfo.ArgumentList.Add([string]$value)
        }
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $check.Process = $process
    [void]$process.Start()
    $process.StandardInput.Close()
    # Drain BOTH pipes immediately. Reading one synchronously deadlocks once
    # the other fills (especially a verbose mutation or exception).
    $check.Stdout = $process.StandardOutput.ReadToEndAsync()
    $check.Stderr = $process.StandardError.ReadToEndAsync()
    $active.Add($check)
}

function Receive-Check($check) {
    if ($check.Process.HasExited -and $check.Stdout.IsCompleted -and $check.Stderr.IsCompleted) {
        $code = $check.Process.ExitCode
        $output = $check.Stdout.GetAwaiter().GetResult() + $check.Stderr.GetAwaiter().GetResult()
        if ($code -ne 0) { $output += "`n  FAIL - process exited $code" }
        Set-CheckResult $check $(if ($code -eq 0) { 'PASS' } else { 'FAIL' }) $output $code
        Stop-CheckProcess $check
    }
    elseif ($check.Clock.Elapsed.TotalSeconds -ge $check.Timeout) {
        Set-CheckFailure $check "timed out after $($check.Timeout) s"
    }
}

$nextOutput = 0
function Write-CompletedOutput {
    while ($script:nextOutput -lt $results.Count -and $null -ne $results[$script:nextOutput]) {
        $r = $results[$script:nextOutput]
        Write-Host ''
        Write-Host ('=' * 72) -ForegroundColor DarkGray
        Write-Host " $($r.Name)" -ForegroundColor Cyan
        Write-Host ('=' * 72) -ForegroundColor DarkGray
        if ($r.Output) { Write-Host $r.Output.TrimEnd() }
        $script:nextOutput++
    }
}

$completed = $false
try {
    $azureConfig = if ($env:AZURE_CONFIG_DIR) { $env:AZURE_CONFIG_DIR } else { Join-Path $HOME '.azure' }
    $compilerName = if ($IsWindows) { 'bicep.exe' } else { 'bicep' }
    $bicepNeedsAz = -not (Test-Path -LiteralPath (Join-Path (Join-Path $azureConfig 'bin') $compilerName))
    # BEGIN CHECK REGISTRATION
    # Recursive source scans and native Azure CLI users run before sandboxes.
    Invoke-Check 'Script encoding (PowerShell 5.1 safety)' 'Repair-ScriptEncoding.ps1' @{ Check = $true } -SerialLane
    Invoke-Check 'Test-All counts every check'             'Test-RunnerIntegrity.ps1'
    Invoke-Check 'Mutation shards preserve every case'     'Test-MutationShards.ps1'
    Invoke-Check 'Format strings parse and run'            'Test-FormatStrings.ps1'
    Invoke-Check 'Screenshots and the docs that show them' 'Test-Screenshots.ps1'
    Invoke-Check 'Resolver - the entitlement read path'   'Test-Resolver.ps1'
    Invoke-Check 'Named value writes fail loudly'          'Test-NamedValueWrites.ps1' @{ SkipLive = $true }
    Invoke-Check 'Release log hygiene'                     'Test-ReleaseLog.ps1'
    Invoke-Check 'Azure CLI arguments vs cmd.exe'          'Test-AzArguments.ps1' -SerialLane
    Invoke-Check 'Shell scripts - syntax and banner'       'Test-ShellScripts.ps1' -SerialLane
    Invoke-Check 'Preflight on both PowerShell hosts'      'Test-PreflightBothHosts.ps1' -SerialLane
    Invoke-Check 'Wizard reaches summary on PS 5.1'        'Test-On-PS51.ps1' -SerialLane
    Invoke-Check 'Analytics query contract'                'Test-Analytics.ps1' @{ SkipLive = $true }
    Invoke-Check 'Org spend ceiling'                       'Test-OrgCeiling.ps1' @{ SkipLive = $true }
    Invoke-Check 'Per-user budget control'                 'Test-BudgetControl.ps1' @{ SkipLive = $true }
    Invoke-Check 'Capability scoping per tier'             'Test-CapabilityScoping.ps1' @{ SkipLive = $true }
    Invoke-Check 'Compliance retrieval and deletion'       'Test-Compliance.ps1' @{ SkipLive = $true }
    Invoke-Check 'Chargeback ledger'                       'Test-Ledger.ps1' @{ SkipLive = $true }
    Invoke-Check 'Chargeback report generation'            'Test-ChargebackReports.ps1'
    Invoke-Check 'Chargeback recipients and attachments'   'Test-ChargebackDelivery.ps1'
    Invoke-Check 'Chargeback durable email outbox'         'Test-ChargebackOutbox.ps1'
    Invoke-Check 'Chargeback queue preserves attachments'  'Test-ChargebackQueue.ps1'
    Invoke-Check 'Chargeback configuration and archive'    'Test-ChargebackStorage.ps1'
    Invoke-Check 'Chargeback private administration'       'Test-ChargebackAdministration.ps1'
    Invoke-Check 'Chargeback selectable discovery'         'Test-ChargebackDiscovery.ps1'
    Invoke-Check 'Chargeback portal redaction'             'Test-ChargebackCapture.ps1'
    Invoke-Check 'Chargeback scheduled jobs'               'Test-ChargebackSchedule.ps1'
    Invoke-Check 'Chargeback mutations detect breakage'    'Test-ChargebackNegative.ps1'
    Invoke-Check 'Business unit chargeback'                'Test-BusinessUnits.ps1'
    Invoke-Check 'Teams and the budget cascade'            'Test-Teams.ps1'
    Invoke-Check 'Model discovery and deployment'          'Test-ModelDeployment.ps1'
    Invoke-Check 'Client attribution and the workbook'     'Test-Observability.ps1'
    Invoke-Check 'Business unit checks detect breakage [0/4]' 'Test-BusinessUnitsNegative.ps1' @{ Shard = '0/4' }
    Invoke-Check 'Business unit checks detect breakage [1/4]' 'Test-BusinessUnitsNegative.ps1' @{ Shard = '1/4' }
    Invoke-Check 'Business unit checks detect breakage [2/4]' 'Test-BusinessUnitsNegative.ps1' @{ Shard = '2/4' }
    Invoke-Check 'Business unit checks detect breakage [3/4]' 'Test-BusinessUnitsNegative.ps1' @{ Shard = '3/4' }
    Invoke-Check 'Admin surface - SKU, groups, tiers'      'Test-AdminSurface.ps1'
    Invoke-Check 'Scale ceilings and the load envelope'    'Test-Scale.ps1'
    Invoke-Check 'Secure projection and the migration'     'Test-SecureProjection.ps1' -SerialLane
    Invoke-Check 'Projection checks detect breakage'        'Test-ProjectionNegative.ps1'
    Invoke-Check 'Adding models, and plugin governance'    'Test-ModelsAndPlugins.ps1'
    Invoke-Check 'Backup and restore'                      'Test-Backup.ps1'
    Invoke-Check 'Turnstile - usage mapping and its rules' 'Test-Turnstile.ps1'
    Invoke-Check 'Turnstile - governance and connection'   'Test-TurnstileGovernance.ps1' -SerialLane:$bicepNeedsAz
    Invoke-Check 'Turnstile checks detect breakage [0/2]'   'Test-TurnstileNegative.ps1' @{ Shard = '0/2' } -SerialLane:$bicepNeedsAz
    Invoke-Check 'Turnstile checks detect breakage [1/2]'   'Test-TurnstileNegative.ps1' @{ Shard = '1/2' } -SerialLane:$bicepNeedsAz
    Invoke-Check 'No deployment written into the code'     'Test-NoDeploymentValues.ps1'
    Invoke-Check 'Foundry bypass audit'                    'Test-Bypass.ps1' @{ SkipLive = $true }

    $finopsPython = Join-Path $root '.venv-finops\Scripts\python.exe'
    $finopsUnixPython = Join-Path $root '.venv-finops\bin\python'
    $finopsSkip = if (-not ((Test-Path $finopsPython) -or (Test-Path $finopsUnixPython))) {
        'FinOps: Python or the worktree .venv-finops is missing. See docs/CLI-FINOPS.md to install.'
    } else { '' }
    Invoke-Check 'Terminal FinOps - commands, rules and pilot' 'Test-FinOps.ps1' -SkipReason $finopsSkip

    if ($IncludeAzure) {
        Invoke-Check 'Foundry discovery is selective'      'Test-Discovery.ps1' -Azure
        Invoke-Check 'Wizard reuses an existing gateway'   'Test-ApimReuse.ps1' -Azure
        Invoke-Check 'Analytics query against live data'   'Test-Analytics.ps1' -Azure
        Invoke-Check 'Org ceiling on the live gateway'     'Test-OrgCeilingLive.ps1' -Azure
        Invoke-Check 'Budget control on the live gateway'  'Test-BudgetControlLive.ps1' -Azure
        Invoke-Check 'Model allowlist on the live gateway' 'Test-CapabilityScopingLive.ps1' -Azure
        Invoke-Check 'Named value writes against Azure'    'Test-NamedValueWrites.ps1' -Azure
    }
    # END CHECK REGISTRATION

    $results = [object[]]::new($checks.Count)
    # The first phase avoids source-scan/sandbox and Azure CLI config races.
    # Azure's mutable deployment is never part of the parallel phase.
    $schedule = if ($Serial) { @($checks.ToArray()) } else {
        @($checks | Where-Object Lane -eq 'Exclusive') +
        @($checks | Where-Object Lane -eq 'Parallel') +
        @($checks | Where-Object Lane -eq 'Azure')
    }
    Write-Host ("Running {0} checks; throttle {1}; per-check timeout {2} s{3}." -f $checks.Count, $ThrottleLimit, $CheckTimeoutSeconds, $(if ($Serial) { '; serial' } else { '' }))
    $next = 0
    while ($next -lt $schedule.Count -or $active.Count) {
        foreach ($check in @($active.ToArray())) {
            try { Receive-Check $check }
            catch { Set-CheckFailure $check $_.Exception.Message } # per-check failure
            if ($null -ne $results[$check.Id] -or -not $check.Process) { [void]$active.Remove($check) }
        }
        while ($next -lt $schedule.Count -and $active.Count -lt $ThrottleLimit) {
            $check = $schedule[$next]
            if ($active.Count -and ($check.Lane -ne 'Parallel' -or @($active | Where-Object Lane -ne 'Parallel').Count)) { break }
            $next++
            try { Start-Check $check }
            catch { Set-CheckFailure $check $_.Exception.Message } # per-check failure
            if ($check.Lane -ne 'Parallel' -and $check.Process) { break }
        }
        Write-CompletedOutput
        if ($active.Count) { Start-Sleep -Milliseconds 50 }
    }
    $valid = @($checks | Where-Object {
        $r = $results[$_.Id]
        $null -ne $r -and $r.Id -eq $_.Id -and $r.Name -ceq $_.Name -and $r.Result -in 'PASS', 'FAIL', 'SKIP'
    })
    $completed = $checks.Count -gt 0 -and $valid.Count -eq $checks.Count
}
catch { Write-Host "Runner stopped: $($_.Exception.Message)" -ForegroundColor Red }
finally {
    foreach ($check in @($active.ToArray())) {
        try { Stop-CheckProcess $check } catch { Write-Warning $_.Exception.Message }
    }
    Remove-Item -LiteralPath $runDirectory -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host ('=' * 72) -ForegroundColor DarkGray
Write-Host ' Summary' -ForegroundColor Cyan
Write-Host ('=' * 72) -ForegroundColor DarkGray
$reported = @($results | Where-Object { $null -ne $_ })
foreach ($r in $reported) {
    $colour = switch ($r.Result) { 'PASS' { 'Green' } 'FAIL' { 'Red' } default { 'Yellow' } }
    Write-Host ("  {0,-4}  {1}  ({2} s)" -f $r.Result, $r.Name, $r.Seconds) -ForegroundColor $colour
}
Write-Host ''
Write-Host ("  {0:N1} s wall; {1:N1} s in checks; slowest:" -f $suiteClock.Elapsed.TotalSeconds, ($reported | Measure-Object -Property Seconds -Sum).Sum) -ForegroundColor DarkGray
$reported | Sort-Object Seconds -Descending | Select-Object -First 5 | ForEach-Object { Write-Host ("    {0,7:N1} s  {1}" -f $_.Seconds, $_.Name) -ForegroundColor DarkGray }
$timings = Join-Path ([IO.Path]::GetTempPath()) ('test-all-timings-{0}-{1}-{2}.json' -f (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmss'), $PID, [guid]::NewGuid().ToString('N'))
ConvertTo-Json -InputObject @($reported | Select-Object Name, Result, Seconds, ExitCode) | Set-Content -LiteralPath $timings -Encoding ASCII
Write-Host "  timings: $timings" -ForegroundColor DarkGray
if (-not $IncludeAzure) { Write-Host '  Azure checks not run. Add -IncludeAzure once you are signed in.' -ForegroundColor DarkGray }

Write-Host ''
if (-not $completed) { Write-Host 'The run stopped before every check ran, so it proves nothing.' -ForegroundColor Red; exit 1 }
$skippedCount = @($reported | Where-Object Result -eq 'SKIP').Count
if ($skippedCount) { Write-Host "$skippedCount check(s) skipped - the summary names them, and each said why." -ForegroundColor Yellow }
$failed = @($reported | Where-Object Result -eq 'FAIL').Count
if ($failed) { Write-Host "$failed check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'All checks passed.' -ForegroundColor Green
exit 0
