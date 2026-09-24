# Exercise a copy of the real runner beside isolated stub checks. No Azure calls.
# The full registration list is checked as well as small adversarial schedules.
$ErrorActionPreference = 'Stop'
$source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Test-All.ps1'))
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('runner-integrity-' + [guid]::NewGuid().ToString('N'))
$fail = 0

function Assert($label, $condition, $detail = '') {
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $label$(if ($detail) { " - $detail" })" -ForegroundColor Red; $script:fail++ }
}

function Get-Registered([string]$Text, [switch]$Azure) {
    $azureAt = $Text.IndexOf('if ($IncludeAzure)')
    @([regex]::Matches($Text, "(?m)^\s*Invoke-Check\s+'([^']+)'\s+'([^']+\.ps1)'") |
        Where-Object { $Azure -or $azureAt -lt 0 -or $_.Index -lt $azureAt } |
        ForEach-Object { [pscustomobject]@{ Name = $_.Groups[1].Value; Script = $_.Groups[2].Value } })
}

function Invoke-Scenario {
    param(
        [string]$RunnerText, [hashtable]$Behaviour = @{}, [string[]]$Missing = @(),
        [string[]]$Options = @('-ThrottleLimit', '3', '-CheckTimeoutSeconds', '60')
    )
    $dir = Join-Path $scratch ([guid]::NewGuid().ToString('N') + " space's")
    $tests = Join-Path $dir 'tests'
    $marks = Join-Path $dir 'marks'
    New-Item -ItemType Directory -Path $tests, $marks, (Join-Path $dir 'scripts') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $tests 'Test-All.ps1'), $RunnerText)
    $quotedMarks = $marks.Replace("'", "''")
    $stub = @'
param([switch]$Check, [switch]$SkipLive, [string]$Shard, [string]$Token, [string]$Text)
$ErrorActionPreference = 'Stop'
$marks = 'MARKS'
$record = [ordered]@{ Script = (Split-Path $PSCommandPath -Leaf); Token = $Token; Pid = $PID
    Start = [datetime]::UtcNow.Ticks; End = $null; Check = [bool]$Check; SkipLive = [bool]$SkipLive
    Text = $Text; Shard = $Shard; Temp = [IO.Path]::GetTempPath() }
$recordPath = Join-Path $marks "$PID.json"
[IO.File]::WriteAllText($recordPath, ($record | ConvertTo-Json))
Write-Host "OUTPUT:$($record.Script):$Token"
try {
    BODY
} finally {
    $record.End = [datetime]::UtcNow.Ticks
    [IO.File]::WriteAllText($recordPath, ($record | ConvertTo-Json))
}
'@
    foreach ($c in (Get-Registered $RunnerText -Azure | Sort-Object Script -Unique)) {
        if ($Missing -contains $c.Script) { continue }
        $body = if ($Behaviour.ContainsKey($c.Script)) { $Behaviour[$c.Script] } else { 'Start-Sleep -Milliseconds 200; exit 0' }
        [IO.File]::WriteAllText((Join-Path $tests $c.Script), $stub.Replace('MARKS', $quotedMarks).Replace('BODY', $body))
    }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $out = & pwsh -NoProfile -NonInteractive -File (Join-Path $tests 'Test-All.ps1') @Options 2>&1 | Out-String
    $code = $LASTEXITCODE
    $records = @(Get-ChildItem $marks -Filter '*.json' | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json })
    $timings = @()
    $match = [regex]::Match($out, '(?m)^\s*timings: ([^\r\n]+)')
    if ($match.Success -and (Test-Path -LiteralPath $match.Groups[1].Value.Trim())) {
        $timings = @(Get-Content -LiteralPath $match.Groups[1].Value.Trim() -Raw | ConvertFrom-Json)
    }
    [pscustomobject]@{ Exit = $code; Output = $out; Ran = $records; Timings = $timings; Marks = $marks; Seconds = $clock.Elapsed.TotalSeconds }
}

function Has-CompleteSummary($Run, $Checks) {
    foreach ($c in $Checks) {
        $pattern = '(?m)^\s*(PASS|FAIL|SKIP)\s+' + [regex]::Escape($c.Name) + '(?:\s+\(|\s*$)'
        if ([regex]::Matches($Run.Output, $pattern).Count -ne 1) { return $false }
    }
    return $Run.Timings.Count -eq $Checks.Count -and
        (($Run.Timings.Name -join '|') -eq ($Checks.Name -join '|'))
}

function Get-MaxOverlap($Records) {
    $events = @()
    foreach ($r in $Records) {
        $events += [pscustomobject]@{ At = [long]$r.Start; Change = 1 }
        if ($r.End) { $events += [pscustomobject]@{ At = [long]$r.End; Change = -1 } }
    }
    $active = 0; $peak = 0
    foreach ($e in ($events | Sort-Object At, Change)) { $active += $e.Change; $peak = [math]::Max($peak, $active) }
    return $peak
}

function With-Checks([string]$Text, [string]$Registration) {
    $pattern = '(?s)(# BEGIN CHECK REGISTRATION).*?(# END CHECK REGISTRATION)'
    if ([regex]::Matches($Text, $pattern).Count -ne 1) { throw 'Registration boundaries missing or ambiguous.' }
    [regex]::Replace($Text, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{
        param($m) $m.Groups[1].Value + "`r`n" + $Registration + "`r`n    " + $m.Groups[2].Value
    })
}

function Mutate([string]$Text, [string]$From, [string]$To) {
    if ([regex]::Matches($Text, [regex]::Escape($From)).Count -ne 1) { throw "Mutation anchor missing or ambiguous: $From" }
    return $Text.Replace($From, $To)
}

Write-Host 'Test-All - isolated processes, complete receipts, bounded failures' -ForegroundColor Cyan
$registered = @(Get-Registered $source)
Assert 'at least ten offline checks are registered' ($registered.Count -ge 10)
$savedThrottle = $env:TEST_ALL_THROTTLE
try {
    $env:TEST_ALL_THROTTLE = $null
    $r = Invoke-Scenario $source
    $skipped = @($r.Timings | Where-Object Result -eq 'SKIP')
    $expectedRan = $registered.Count - $skipped.Count
    Assert 'a passing full offline registration passes' ($r.Exit -eq 0) "exit $($r.Exit): $($r.Output.Substring(0, [math]::Min(350, $r.Output.Length)))"
    Assert 'every registered check is summarized once in registration order' (Has-CompleteSummary $r $registered)
    Assert 'every non-skipped check runs in its own process' ($r.Ran.Count -eq $expectedRan -and @($r.Ran.Pid | Sort-Object -Unique).Count -eq $expectedRan) "$($r.Ran.Count) of $expectedRan"
    Assert 'FinOps without its venv is an explicit counted SKIP' ($skipped.Count -eq 1 -and $skipped[0].Name -like 'Terminal FinOps*' -and $r.Output -match '1 check\(s\) skipped')
    Assert 'each result has a duration, including skips' (@($r.Timings | Where-Object { $null -eq $_.Seconds -or $_.Seconds -lt 0 }).Count -eq 0)
    Assert 'the five slowest checks and timings path remain visible' ($r.Output -match '(?s)slowest:\s*(?:[^\r\n]+\r?\n\s*){5}timings:')
    Assert 'several independent checks really overlap' ((Get-MaxOverlap $r.Ran) -gt 1)
    Assert 'the requested concurrency bound is respected' ((Get-MaxOverlap $r.Ran) -le 3)
    if ($fail) { throw 'Full-registration invariants failed; refusing to run synthetic scenarios on a broken runner.' }

    $allRegistered = @(Get-Registered $source -Azure)
    $r = Invoke-Scenario $source -Options @('-IncludeAzure', '-ThrottleLimit', '3', '-CheckTimeoutSeconds', '60')
    Assert 'IncludeAzure adds all registered live checks (stubs only)' ($r.Exit -eq 0 -and (Has-CompleteSummary $r $allRegistered) -and $r.Ran.Count -eq ($allRegistered.Count - 1))
    $azureScripts = @($allRegistered | Select-Object -Skip $registered.Count | ForEach-Object Script)
    $live = @($r.Ran | Where-Object { $_.Script -in $azureScripts -and -not $_.SkipLive })
    $offlineEnd = ($r.Ran | Where-Object { $_.Pid -notin $live.Pid } | Measure-Object End -Maximum).Maximum
    Assert 'live registrations are last and mutually exclusive' ($live.Count -eq $azureScripts.Count -and (Get-MaxOverlap $live) -eq 1 -and ($live | Measure-Object Start -Minimum).Minimum -ge $offlineEnd)

    $mini = With-Checks $source @'
    Invoke-Check 'first' 'First.ps1' @{ Token = 'first'; Check = $true; SkipLive = $false; Text = 'space ; $literal & quote"' }
    Invoke-Check 'second' 'Second.ps1' @{ Token = 'second' }
    Invoke-Check 'third' 'Third.ps1' @{ Token = 'third' }
    Invoke-Check 'exclusive' 'Exclusive.ps1' -SerialLane
    Invoke-Check 'optional' 'Optional.ps1' -SkipReason 'fixture prerequisite absent'
'@
    $checks = @(Get-Registered $mini)
    $r = Invoke-Scenario $mini
    $first = $r.Ran | Where-Object Token -eq 'first'
    $exclusive = $r.Ran | Where-Object Script -eq 'Exclusive.ps1'
    Assert 'named switch and string arguments survive native quoting' ($first.Check -and -not $first.SkipLive -and $first.Text -ceq 'space ; $literal & quote"')
    $overlap = @($r.Ran | Where-Object { $_.Pid -ne $exclusive.Pid -and $_.Start -lt $exclusive.End -and $_.End -gt $exclusive.Start })
    Assert 'an exclusive check never overlaps another check' ($exclusive -and $overlap.Count -eq 0)
    Assert 'every process has a private scratch directory' (@($r.Ran.Temp | Sort-Object -Unique).Count -eq $r.Ran.Count)

    $r = Invoke-Scenario $mini -Options @('-Serial', '-ThrottleLimit', '3')
    Assert 'Serial means one process at a time in registration order' ($r.Exit -eq 0 -and (Get-MaxOverlap $r.Ran) -eq 1 -and (($r.Ran | Sort-Object Start | ForEach-Object Script) -join '|') -eq 'First.ps1|Second.ps1|Third.ps1|Exclusive.ps1')
    $env:TEST_ALL_THROTTLE = '1'
    $r = Invoke-Scenario $mini -Options @()
    Assert 'the environment can reduce the throttle to one' ($r.Exit -eq 0 -and (Get-MaxOverlap $r.Ran) -eq 1)
    $env:TEST_ALL_THROTTLE = 'invalid'
    $r = Invoke-Scenario $mini -Options @()
    Assert 'invalid environment configuration fails before running any check' ($r.Exit -ne 0 -and $r.Ran.Count -eq 0)
    $r = Invoke-Scenario $mini
    Assert 'an explicit throttle takes precedence over the environment' ($r.Exit -eq 0)
    $env:TEST_ALL_THROTTLE = $null
    $r = Invoke-Scenario $mini -Options @()
    $cpuLimit = [math]::Max(1, [math]::Min(4, [Environment]::ProcessorCount))
    Assert 'the default follows logical CPUs and is capped at four' ($r.Exit -eq 0 -and $r.Output -match "throttle $cpuLimit;" -and (Get-MaxOverlap $r.Ran) -le $cpuLimit)
    foreach ($option in @(@('-ThrottleLimit', '0'), @('-CheckTimeoutSeconds', '0'))) {
        $r = Invoke-Scenario $mini -Options $option
        Assert "$($option[0]) rejects zero" ($r.Exit -ne 0 -and $r.Ran.Count -eq 0)
    }

    # Each child writes its own marker; no shared append file can hide a race.
    $meet = @'
[IO.File]::WriteAllText((Join-Path $marks "$Token.ready"), 'ready')
$other = if ($Token -eq 'first') { 'second' } else { 'first' }
$until = [datetime]::UtcNow.AddSeconds(20)
while (-not (Test-Path (Join-Path $marks "$other.ready"))) {
    if ([datetime]::UtcNow -gt $until) { throw 'The two checks never ran concurrently.' }
    Start-Sleep -Milliseconds 25
}
Start-Sleep -Milliseconds 200
'@
    $r = Invoke-Scenario $mini -Behaviour @{ 'First.ps1' = $meet + "`r`nexit 7"; 'Second.ps1' = $meet + "`r`nthrow 'simulated abort'" }
    Assert 'two concurrent failures are both reported and counted' ($r.Exit -ne 0 -and $r.Output -match 'FAIL\s+first' -and $r.Output -match 'FAIL\s+second' -and $r.Output -match '2 check\(s\) failed')
    Assert 'concurrent failing checks actually overlapped' ((Get-MaxOverlap ($r.Ran | Where-Object { $_.Token -in 'first', 'second' })) -eq 2)
    Assert 'all later checks still run after both failures' ($r.Ran.Count -eq 4 -and (Has-CompleteSummary $r $checks))
    Assert 'a failing summary still counts explicit skips' ($r.Output -match '1 check\(s\) skipped' -and $r.Output -notmatch 'All checks passed')
    Assert 'all exit codes are preserved independently' (($r.Timings | Where-Object Name -eq 'first').ExitCode -eq 7 -and ($r.Timings | Where-Object Name -eq 'second').ExitCode -ne 0)
    $firstAt = $r.Output.IndexOf('OUTPUT:First.ps1:first')
    $secondAt = $r.Output.IndexOf('OUTPUT:Second.ps1:second')
    $exclusiveAt = $r.Output.IndexOf('OUTPUT:Exclusive.ps1:')
    Assert 'buffered check output follows registration order, not completion order' ($firstAt -ge 0 -and $secondAt -gt $firstAt -and $exclusiveAt -gt $secondAt)

    $lockedWrite = @'
$locked = Join-Path $marks 'locked.txt'
$held = [IO.File]::Open($locked, 'OpenOrCreate', 'ReadWrite', 'None')
try { 'y' | Set-Content -LiteralPath $locked -Encoding ASCII } finally { $held.Dispose() }
exit 0
'@
    $r = Invoke-Scenario $mini -Behaviour @{ 'First.ps1' = $lockedWrite; 'Second.ps1' = '[Diagnostics.Process]::GetCurrentProcess().Kill()' }
    Assert 'the original locked-file abort and an abrupt crash each fail alone' ($r.Exit -ne 0 -and @($r.Timings | Where-Object Result -eq 'FAIL').Count -eq 2 -and $r.Ran.Count -eq 4)

    $r = Invoke-Scenario $mini -Missing @('Third.ps1')
    Assert 'a missing registered script fails and is named' ($r.Exit -ne 0 -and $r.Output -match 'Third.ps1 not found' -and ($r.Timings | Where-Object Name -eq 'third').Result -eq 'FAIL')
    Assert 'a missing script does not stop the other checks' ($r.Ran.Count -eq 3 -and (Has-CompleteSummary $r $checks))
    $r = Invoke-Scenario $mini -Missing @('Optional.ps1')
    Assert 'a skip prerequisite cannot hide a missing registered script' ($r.Exit -ne 0 -and ($r.Timings | Where-Object Name -eq 'optional').Result -eq 'FAIL')

    $hang = @'
$childFile = Join-Path $marks 'child.ps1'
$childCode = '[IO.File]::WriteAllText(''' + (Join-Path $marks 'child.pid').Replace("'", "''") + ''', [string]$PID); Start-Sleep -Seconds 300'
[IO.File]::WriteAllText($childFile, $childCode)
$child = [Diagnostics.ProcessStartInfo]::new((Get-Command pwsh).Source)
foreach ($a in @('-NoProfile', '-NonInteractive', '-File', $childFile)) { $child.ArgumentList.Add($a) }
$child.UseShellExecute = $false
$null = [Diagnostics.Process]::Start($child)
Start-Sleep -Seconds 300
'@
    $timedMini = Mutate $mini "Invoke-Check 'second' 'Second.ps1' @{ Token = 'second' }" "Invoke-Check 'second' 'Second.ps1' @{ Token = 'second' } -TimeoutSeconds 5"
    $r = Invoke-Scenario $timedMini -Behaviour @{ 'Second.ps1' = $hang }
    Assert 'a hung check hits its own deadline without stalling the suite' ($r.Exit -ne 0 -and $r.Seconds -lt 40 -and $r.Output -match 'timed out after 5 s')
    Assert 'only the hung check fails and later checks finish' (@($r.Timings | Where-Object Result -eq 'FAIL').Count -eq 1 -and ($r.Timings | Where-Object Name -eq 'second').Result -eq 'FAIL' -and (Has-CompleteSummary $r $checks))
    $childPidFile = Join-Path $r.Marks 'child.pid'
    $childId = if (Test-Path $childPidFile) { [int](Get-Content $childPidFile) } else { 0 }
    Assert 'the timeout terminates the descendant process as well' ($childId -gt 0 -and -not (Get-Process -Id $childId -ErrorAction SilentlyContinue))
    if ($childId -gt 0 -and (Get-Process -Id $childId -ErrorAction SilentlyContinue)) { Stop-Process -Id $childId -Force }

    $r = Invoke-Scenario $mini -Behaviour @{ 'First.ps1' = '[Console]::Out.WriteLine(("o" * 100000)); [Console]::Error.WriteLine(("e" * 100000)); exit 0' }
    Assert 'large stdout and stderr drain concurrently rather than deadlock' ($r.Exit -eq 0 -and $r.Output.Contains(('o' * 100000)) -and $r.Output.Contains(('e' * 100000)))

    # A child throw is an exit code now. Inject a parent-side process-start
    # error to exercise the per-check catch, rather than mutate dead code.
    $startFailure = Mutate $mini '[void]$process.Start()' "if (`$check.Name -eq 'first') { throw 'simulated process start error' }; [void]`$process.Start()"
    $r = Invoke-Scenario $startFailure
    Assert 'a process-start exception records FAIL and the rest still run' ($r.Exit -ne 0 -and $r.Ran.Count -eq 3 -and (Has-CompleteSummary $r $checks))

    $catchPattern = '(?m)^\s*catch \{ Set-CheckFailure .*# per-check failure\s*$'
    $noCatch = [regex]::Replace($startFailure, $catchPattern, '        finally { }')
    Assert 'mutation applied: both per-check catches removed' ([regex]::Matches($startFailure, $catchPattern).Count -eq 2 -and $noCatch -ne $startFailure)
    $r = Invoke-Scenario $noCatch
    Assert 'without catches the completion guard still fails the interrupted run' ($r.Exit -ne 0 -and $r.Output -match 'stopped before every check ran')

    $guardPattern = '(?m)^if \(-not \$completed.*$'
    $noGuard = [regex]::Replace($noCatch, $guardPattern, '')
    Assert 'mutation applied: completion guard removed too' ([regex]::Matches($noCatch, $guardPattern).Count -eq 1 -and $noGuard -ne $noCatch)
    $r = Invoke-Scenario $noGuard
    Assert 'both removals reproduce a false pass which the summary invariant rejects' ($r.Exit -eq 0 -and $r.Ran.Count -lt 4 -and -not (Has-CompleteSummary $r $checks))

    $lost = Mutate $mini '$script:results[$check.Id] = $result' '$script:results[0] = $result'
    $r = Invoke-Scenario $lost -Behaviour @{ 'First.ps1' = $meet + "`r`nexit 7"; 'Second.ps1' = $meet + "`r`nexit 8" }
    Assert 'mutation: concurrent results overwritten is caught even though every child ran' ($r.Exit -ne 0 -and $r.Ran.Count -eq 4 -and $r.Output -match 'stopped before every check ran' -and -not (Has-CompleteSummary $r $checks))
    $wrongIdentity = Mutate $mini 'Id = $check.Id; Name = $check.Name; Script = $check.Script' "Id = `$check.Id; Name = 'wrong check'; Script = `$check.Script"
    $r = Invoke-Scenario $wrongIdentity
    Assert 'mutation: a full count with the wrong result identities cannot pass' ($r.Exit -ne 0 -and $r.Timings.Count -eq $checks.Count -and $r.Output -match 'stopped before every check ran')
}
catch { Assert 'integrity scenarios complete' $false $_.Exception.Message }
finally {
    $env:TEST_ALL_THROTTLE = $savedThrottle
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}

if ($fail) { Write-Host "$fail assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'Test-All counts every check, including concurrent failures.' -ForegroundColor Green
exit 0
