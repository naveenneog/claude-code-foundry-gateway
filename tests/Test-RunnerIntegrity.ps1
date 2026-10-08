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

# Each stub check writes one record. Windows reuses process ids, and under heavy process churn a later
# stub can receive the id of one that has exited, so a record named by process id alone can overwrite
# another check's record (observed 2026-09-28: 91 checks passed, 90 records).
$script:StubTemplate = @'
param([switch]$Check, [switch]$SkipLive, [string]$Shard, [string]$Token, [string]$Text)
$ErrorActionPreference = 'Stop'
$marks = 'MARKS'
$record = [ordered]@{ Script = (Split-Path $PSCommandPath -Leaf); Token = $Token; Pid = $PID
    Proc = "$PID-$([Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().Ticks)"
    Start = [datetime]::UtcNow.Ticks; End = $null; Check = [bool]$Check; SkipLive = [bool]$SkipLive
    Text = $Text; Shard = $Shard; Temp = [IO.Path]::GetTempPath() }
$recordPath = Join-Path $marks "$($record.Proc).json"
[IO.File]::WriteAllText($recordPath, ($record | ConvertTo-Json))
Write-Host "OUTPUT:$($record.Script):$Token"
try {
    BODY
} finally {
    $record.End = [datetime]::UtcNow.Ticks
    [IO.File]::WriteAllText($recordPath, ($record | ConvertTo-Json))
}
'@

function Invoke-Scenario {
    param(
        [string]$RunnerText, [hashtable]$Behaviour = @{}, [string[]]$Missing = @(),
        [string[]]$Options = @('-ThrottleLimit', '3', '-CheckTimeoutSeconds', '60'),
        [string]$PriceBookContent = ''
    )
    $dir = Join-Path $scratch ([guid]::NewGuid().ToString('N') + " space's")
    $tests = Join-Path $dir 'tests'
    $marks = Join-Path $dir 'marks'
    New-Item -ItemType Directory -Path $tests, $marks, (Join-Path $dir 'scripts') -Force | Out-Null
    if ($PriceBookContent) {
        New-Item -ItemType Directory -Path (Join-Path $dir 'config') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $dir 'config\price-book.json'), $PriceBookContent)
    }
    [IO.File]::WriteAllText((Join-Path $tests 'Test-All.ps1'), $RunnerText)
    foreach ($support in 'TestAll-Sharding.ps1', 'test-all-durations.json', 'test-all-local-only.json') {
        $supportPath = Join-Path $PSScriptRoot $support
        if (Test-Path -LiteralPath $supportPath) { Copy-Item -LiteralPath $supportPath -Destination $tests }
    }
    if ('-LocalOnly' -in $Options) {
        $timingPath = Join-Path $tests 'test-all-durations.json'
        $timing = Get-Content -LiteralPath $timingPath -Raw | ConvertFrom-Json -AsHashtable
        $timing.ShardCount = 2
        [IO.File]::WriteAllText($timingPath, ($timing | ConvertTo-Json -Depth 5))
        [IO.File]::WriteAllText((Join-Path $tests 'test-all-local-only.json'),
            '{"SchemaVersion":1,"Checks":[{"Name":"exclusive","Reason":"fixture local device"}]}')
    }
    $quotedMarks = $marks.Replace("'", "''")
    $stub = $script:StubTemplate
    foreach ($c in (Get-Registered $RunnerText -Azure | Sort-Object Script -Unique)) {
        if ($Missing -contains $c.Script) { continue }
        $body = if ($Behaviour.ContainsKey($c.Script)) { $Behaviour[$c.Script] } else { 'Start-Sleep -Milliseconds 200; exit 0' }
        [IO.File]::WriteAllText((Join-Path $tests $c.Script), $stub.Replace('MARKS', $quotedMarks).Replace('BODY', $body))
    }
    $fixtureCommit = ''; $fixtureTree = ''
    if ('-ShardIndex' -in $Options -or '-ShardCount' -in $Options -or '-LocalOnly' -in $Options) {
        [IO.File]::WriteAllText((Join-Path $dir '.gitignore'), "marks/`n")
        & git -C $dir init --quiet
        if ($LASTEXITCODE) { throw 'Could not initialize the shard fixture repository.' }
        & git -C $dir add .
        & git -C $dir -c user.name=Test -c user.email=test@example.invalid -c core.hooksPath=NUL commit --quiet `
            -m 'test: isolated runner fixture' `
            -m 'Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>' `
            -m 'Copilot-Session: 1c966b06-b3de-42c0-9254-3a62ae5081bc'
        if ($LASTEXITCODE) { throw 'Could not commit the shard fixture repository.' }
        $objects = @(& git -C $dir rev-parse HEAD 'HEAD^{tree}')
        if ($LASTEXITCODE -or $objects.Count -ne 2) { throw 'Could not read the committed fixture identity.' }
        $fixtureCommit = $objects[0]; $fixtureTree = $objects[1]
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
    $receipt = $null
    $match = [regex]::Match($out, '(?m)^\s*receipt: ([^\r\n]+)')
    if ($match.Success -and (Test-Path -LiteralPath $match.Groups[1].Value.Trim())) {
        $receipt = Get-Content -LiteralPath $match.Groups[1].Value.Trim() -Raw | ConvertFrom-Json
        Remove-Item -LiteralPath $match.Groups[1].Value.Trim() -Force
    }
    [pscustomobject]@{
        Exit = $code; Output = $out; Ran = $records; Timings = $timings; Receipt = $receipt
        SourceCommit = $fixtureCommit; SourceTree = $fixtureTree; Marks = $marks; Seconds = $clock.Elapsed.TotalSeconds
    }
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
# Get-Registered reads a name between single quotes with no quote inside. A registration it cannot read
# (for example an apostrophe written as '') gets no stub below, and the full run fails without naming it.
$registrationBlock = [regex]::Match($source, '(?s)# BEGIN CHECK REGISTRATION(.*?)# END CHECK REGISTRATION').Groups[1].Value
$unread = @($registrationBlock -split "`r?`n" | Where-Object { $_ -match '^\s*Invoke-Check\s' -and @(Get-Registered $_ -Azure).Count -ne 1 } | ForEach-Object { $_.Trim() })
Assert 'every Invoke-Check line in the registration is read' ($registrationBlock -match 'Invoke-Check' -and $unread.Count -eq 0) "not read; a check name is single-quoted with no apostrophe: $($unread -join '; ')"
$savedThrottle = $env:TEST_ALL_THROTTLE
try {
    # A stub run on its own shows how its record is named: by process id and that process's start time,
    # compared with the start time the operating system reports to the process that started the stub.
    $probeDir = Join-Path $scratch ('probe-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $probeDir -Force | Out-Null
    $probeStub = Join-Path $probeDir 'Probe.ps1'
    [IO.File]::WriteAllText($probeStub, $script:StubTemplate.Replace('MARKS', $probeDir.Replace("'", "''")).Replace('BODY', 'exit 0'))
    $probe = Start-Process pwsh -ArgumentList @('-NoProfile', '-NonInteractive', '-File', "`"$probeStub`"", '-Token', 'probe') -NoNewWindow -Wait -PassThru -RedirectStandardOutput (Join-Path $probeDir 'output.txt')
    $probeProc = "$($probe.Id)-$($probe.StartTime.ToUniversalTime().Ticks)"
    $probeFiles = @(Get-ChildItem -LiteralPath $probeDir -Filter '*.json')
    $probeRecord = if ($probeFiles.Count -eq 1) { Get-Content -LiteralPath $probeFiles[0].FullName -Raw | ConvertFrom-Json }
    Assert 'a stub record is named by process id and start time, so a reused process id keeps both records' (
        $probe.ExitCode -eq 0 -and $probeFiles.Count -eq 1 -and $probeRecord.Proc -eq $probeProc -and
        $probeFiles[0].Name -eq "$probeProc.json"
    ) "exit $($probe.ExitCode); files: $(($probeFiles | ForEach-Object Name) -join ', '); Proc: $($probeRecord.Proc); expected: $probeProc"

    $env:TEST_ALL_THROTTLE = $null
    $r = Invoke-Scenario $source
    $skipped = @($r.Timings | Where-Object Result -eq 'SKIP')
    $expectedRan = $registered.Count - $skipped.Count
    Assert 'a passing full offline registration passes' ($r.Exit -eq 0) "exit $($r.Exit): $($r.Output.Substring(0, [math]::Min(350, $r.Output.Length)))"
    Assert 'every registered check is summarized once in registration order' (Has-CompleteSummary $r $registered)
    Assert 'every non-skipped check runs in its own process' ($r.Ran.Count -eq $expectedRan -and @($r.Ran.Proc | Sort-Object -Unique).Count -eq $expectedRan) "$($r.Ran.Count) of $expectedRan"
    $expectedSkips = @('AUM service - authority, API and mutations') +
        @(0..3 | ForEach-Object { "AUM - commands, dashboard and pilot [$_/4]" })
    Assert 'both optional Python environments are explicit counted SKIPs' (
        $skipped.Count -eq $expectedSkips.Count -and
        ($skipped.Name -join '|') -ceq ($expectedSkips -join '|') -and
        $r.Output -match "\b$($expectedSkips.Count) check\(s\) skipped")
    Assert 'each result has a duration, including skips' (@($r.Timings | Where-Object { $null -eq $_.Seconds -or $_.Seconds -lt 0 }).Count -eq 0)
    Assert 'the five slowest checks and timings path remain visible' ($r.Output -match '(?s)slowest:\s*(?:[^\r\n]+\r?\n\s*){5}timings:')
    Assert 'several independent checks really overlap' ((Get-MaxOverlap $r.Ran) -gt 1)
    Assert 'the requested concurrency bound is respected' ((Get-MaxOverlap $r.Ran) -le 3)
    if ($fail) { throw 'Full-registration invariants failed; refusing to run synthetic scenarios on a broken runner.' }

    $allRegistered = @(Get-Registered $source -Azure)
    $r = Invoke-Scenario $source -Options @('-IncludeAzure', '-ThrottleLimit', '3', '-CheckTimeoutSeconds', '60')
    Assert 'IncludeAzure adds all registered live checks (stubs only)' ($r.Exit -eq 0 -and (Has-CompleteSummary $r $allRegistered) -and $r.Ran.Count -eq ($allRegistered.Count - $expectedSkips.Count))
    $azureScripts = @($allRegistered | Select-Object -Skip $registered.Count | ForEach-Object Script)
    $live = @($r.Ran | Where-Object { $_.Script -in $azureScripts -and -not $_.SkipLive })
    $offlineEnd = ($r.Ran | Where-Object { $_.Proc -notin $live.Proc } | Measure-Object End -Maximum).Maximum
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
    $overlap = @($r.Ran | Where-Object { $_.Proc -ne $exclusive.Proc -and $_.Start -lt $exclusive.End -and $_.End -gt $exclusive.Start })
    Assert 'an exclusive check never overlaps another check' ($exclusive -and $overlap.Count -eq 0)
    Assert 'every process has a private scratch directory' (@($r.Ran.Temp | Sort-Object -Unique).Count -eq $r.Ran.Count)
    $operatorBook = '{"models":{"keep":{"inputPerM":1,"outputPerM":5}}}'
    $deleteBook = Invoke-Scenario $mini -PriceBookContent $operatorBook -Behaviour @{
        'First.ps1' = "Remove-Item -LiteralPath (Join-Path (Split-Path `$PSScriptRoot -Parent) 'config\price-book.json') -Force; exit 0"
    }
    $deleteBookPath = Split-Path $deleteBook.Marks -Parent
    $deleteBookContent = [IO.File]::ReadAllText((Join-Path $deleteBookPath 'config\price-book.json'))
    Assert 'Test-All restores and fails the suite that deletes an operator price book' ($deleteBook.Exit -ne 0 -and $deleteBook.Output -match 'config\\price-book\.json was deleted by first' -and $deleteBookContent -ceq $operatorBook) $deleteBook.Output
    $changeBook = Invoke-Scenario $mini -PriceBookContent $operatorBook -Behaviour @{
        'Second.ps1' = "[IO.File]::WriteAllText((Join-Path (Split-Path `$PSScriptRoot -Parent) 'config\price-book.json'), 'changed'); exit 0"
    }
    $changeBookPath = Split-Path $changeBook.Marks -Parent
    $changeBookContent = [IO.File]::ReadAllText((Join-Path $changeBookPath 'config\price-book.json'))
    Assert 'Test-All restores and fails the suite that modifies an operator price book' ($changeBook.Exit -ne 0 -and $changeBook.Output -match 'config\\price-book\.json was modified by second' -and $changeBookContent -ceq $operatorBook) $changeBook.Output

    $shardRuns = @(
        Invoke-Scenario $mini -Options @('-ShardIndex', '0', '-ShardCount', '2', '-ThrottleLimit', '3')
        Invoke-Scenario $mini -Options @('-ShardIndex', '1', '-ShardCount', '2', '-ThrottleLimit', '3') -Behaviour @{
            'Exclusive.ps1' = '[IO.File]::WriteAllText((Join-Path $marks "exclusive.ready"), "ready"); Start-Sleep -Milliseconds 200; exit 0'
            'Second.ps1' = '$until = [datetime]::UtcNow.AddSeconds(20); while (-not (Test-Path (Join-Path $marks "exclusive.ready"))) { if ([datetime]::UtcNow -ge $until) { throw "Exclusive fixture did not start." }; Start-Sleep -Milliseconds 25 }; exit 0'
        }
    )
    $expectedParts = @(@('first', 'third', 'optional'), @('second', 'exclusive'))
    for ($part = 0; $part -lt 2; $part++) {
        $s = $shardRuns[$part]
        $owned = @($checks | Where-Object Name -In $expectedParts[$part])
        Assert "shard $part runs and summarizes only its deterministic ownership" (
            $s.Exit -eq 0 -and (Has-CompleteSummary $s $owned) -and
            ($s.Receipt.OwnedChecks -join '|') -ceq ($owned.Name -join '|')) $s.Output
        Assert "shard $part carries exact source and completion evidence" (
            $s.Receipt.Completed -eq $true -and $s.SourceCommit -cmatch '^[a-f0-9]{40}$' -and
            $s.Receipt.Commit -ceq $s.SourceCommit -and $s.Receipt.Tree -ceq $s.SourceTree -and
            $s.Receipt.ShardIndex -eq $part -and $s.Receipt.ShardCount -eq 2 -and
            ($s.Receipt.Results.Name -join '|') -ceq ($owned.Name -join '|'))
        $expectedIds = @(for ($i = 0; $i -lt $checks.Count; $i++) {
            if ($checks[$i].Name -in $expectedParts[$part]) { $i }
        })
        Assert "shard $part retains original registration IDs and script identities" (
            ($s.Receipt.Results.RegistrationId -join ',') -ceq ($expectedIds -join ',') -and
            ($s.Receipt.Results.Script -join '|') -ceq ($owned.Script -join '|'))
    }
    Assert 'the shard union owns every registered check once, including the counted SKIP' (
        @($shardRuns.Receipt.Results).Count -eq $checks.Count -and
        @($shardRuns.Receipt.Results.Name | Sort-Object -Unique).Count -eq $checks.Count)
    $optional = $shardRuns.Receipt.Results | Where-Object Name -eq 'optional'
    Assert 'the shard receipt preserves the prerequisite reason and absence of a process exit' (
        $optional.Result -ceq 'SKIP' -and $optional.ExitCode -eq $null -and
        $optional.SkipReason -ceq 'fixture prerequisite absent')
    $exclusive = $shardRuns[1].Ran | Where-Object Script -eq 'Exclusive.ps1'
    $overlap = @($shardRuns[1].Ran | Where-Object { $_.Proc -ne $exclusive.Proc -and $_.Start -lt $exclusive.End -and $_.End -gt $exclusive.Start })
    Assert 'SerialLane remains machine-exclusive inside a shard' ($exclusive -and $overlap.Count -eq 0)
    $s = Invoke-Scenario $mini -Options @('-ShardIndex', '0', '-ShardCount', '2') -Behaviour @{ 'First.ps1' = 'exit 9' }
    Assert 'a failing shard keeps a complete failure receipt and runs later owned checks' (
        $s.Exit -ne 0 -and $s.Receipt.Completed -eq $true -and $s.Receipt.Results.Count -eq 3 -and
        ($s.Receipt.Results | Where-Object Name -eq 'first').ExitCode -eq 9)
    . (Join-Path $PSScriptRoot 'TestAll-Sharding.ps1')
    $inventory = @(Get-TestAllRegistration -Text $mini)
    $weights = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'test-all-durations.json') -Raw | ConvertFrom-Json -AsHashtable
    $assignment = @(New-TestAllShardPlan $inventory $weights 2)
    $mergeFailure = ''
    try {
        Assert-TestAllReceiptSet @($s.Receipt) $inventory $assignment 2 $s.SourceCommit $s.SourceTree | Out-Null
    }
    catch { $mergeFailure = $_.Exception.Message }
    Assert 'the actual failing-check receipt is rejected for its failed check' (
        $mergeFailure -match 'Check did not pass \(result FAIL\): first') $mergeFailure
    $s = Invoke-Scenario $mini -Options @('-ShardIndex', '0', '-ShardCount', '2') -Behaviour @{
        'First.ps1' = '[IO.File]::WriteAllText((Join-Path (Split-Path $PSScriptRoot -Parent) "source-changed.txt"), "changed"); exit 0'
    }
    Assert 'a source change invalidates the receipt after all owned checks finish' (
        $s.Exit -ne 0 -and $s.Receipt.Completed -eq $false -and $s.Receipt.Results.Count -eq 3 -and
        $s.Output -match 'Receipt source check failed')
    $s = Invoke-Scenario $mini -Options @('-LocalOnly')
    Assert 'the explicit local-only lane emits its original identity without dropping CI registration' (
        $s.Exit -eq 0 -and $s.Receipt.Mode -ceq 'local' -and $s.Receipt.ShardIndex -eq -1 -and
        $s.Receipt.ShardCount -eq 2 -and $s.Receipt.Completed -eq $true -and
        ($s.Receipt.OwnedChecks -join '|') -ceq 'exclusive' -and
        $s.Receipt.Results[0].RegistrationId -eq 3 -and $s.Receipt.Commit -ceq $s.SourceCommit -and
        $s.Receipt.Tree -ceq $s.SourceTree -and $s.Output -match 'owns 1 of 5 registered checks') $s.Output
    foreach ($options in @(
        @('-ShardIndex', '0'), @('-ShardCount', '2'), @('-ShardIndex', '2', '-ShardCount', '2'),
        @('-ShardIndex', '0', '-ShardCount', '2', '-IncludeAzure'),
        @('-ShardIndex', '0', '-ShardCount', '2', '-LocalOnly'), @('-ReceiptPath', 'unused.json'),
        @('-LocalOnly', '-IncludeAzure')
    )) {
        $s = Invoke-Scenario $mini -Options $options
        Assert "invalid shard selection fails before any process starts: $($options -join ' ')" (
            $s.Exit -ne 0 -and $s.Ran.Count -eq 0)
    }

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
    Assert 'the default deadline leaves room inside the packet command budget' ($r.Output -match 'per-check timeout 600 s')
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
    Assert 'a timeout retains the output emitted before the hang' ($r.Output -match 'OUTPUT:Second.ps1:second')
    $childPidFile = Join-Path $r.Marks 'child.pid'
    $childId = if (Test-Path $childPidFile) { [int](Get-Content $childPidFile) } else { 0 }
    Assert 'the timeout terminates the descendant process as well' ($childId -gt 0 -and -not (Get-Process -Id $childId -ErrorAction SilentlyContinue))
    if ($childId -gt 0 -and (Get-Process -Id $childId -ErrorAction SilentlyContinue)) { Stop-Process -Id $childId -Force }

    $r = Invoke-Scenario $mini -Options @('-ThrottleLimit', '3', '-CheckTimeoutSeconds', '5') -Behaviour @{ 'Second.ps1' = $hang }
    Assert 'the global deadline also bounds checks without an individual override' (
        $r.Exit -ne 0 -and $r.Seconds -lt 40 -and $r.Output -match 'timed out after 5 s' -and
        @($r.Timings | Where-Object Result -eq 'FAIL').Count -eq 1 -and
        ($r.Timings | Where-Object Name -eq 'second').Result -eq 'FAIL' -and (Has-CompleteSummary $r $checks)
    )
    $globalChildId = [int](Get-Content (Join-Path $r.Marks 'child.pid'))
    Assert 'the global deadline also terminates the descendant' (-not (Get-Process -Id $globalChildId -ErrorAction SilentlyContinue))
    if (Get-Process -Id $globalChildId -ErrorAction SilentlyContinue) { Stop-Process -Id $globalChildId -Force }

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
