# P99 (ADR-0053): Send-RunnerFile sends a file to the in-network runner gzip-compressed, in parts written in
# parallel, and assembles and checks it there. A local emulator stands in for the runner: like the runner,
# it splits each exec command on spaces and URL-decodes it (scripts/ClaudeRunner.ps1, header; measured
# 2026-09-23), maps /work to a scratch folder and runs the node program here. The in-process path uses an az
# function; the parallel path uses a fake az.cmd, which runs each exec in its own process.
param([string]$RepositoryRoot)
$ErrorActionPreference = 'Stop'
$root = if ($RepositoryRoot) { $RepositoryRoot } else { Split-Path $PSScriptRoot -Parent }
$script:assertions = 0
$script:failures = 0
function Assert($Name, $Condition, $Detail = '') {
    $script:assertions++
    if ($Condition) { Write-Host "  [OK] $Name" }
    else { $script:failures++; Write-Host "  [FAIL] $Name $Detail" }
}
function Capture([scriptblock]$Action) {
    $script:CapturedError = ''
    $script:CapturedResult = $null
    try { $script:CapturedResult = & $Action 6>$null }
    catch { $script:CapturedError = $_.Exception.Message }
}

$scratch = Join-Path ([IO.Path]::GetTempPath()) ('p99-transfer-' + [guid]::NewGuid().ToString('N'))
$work = Join-Path $scratch 'work'
$logDir = Join-Path $scratch 'execs'
$bin = Join-Path $scratch 'bin'
$null = New-Item -ItemType Directory -Force -Path $work, $logDir, $bin
$emulator = Join-Path $bin 'runner-emulator.ps1'
[IO.File]::WriteAllText($emulator, @'
param([Parameter(Mandatory)][string]$Command, [Parameter(Mandatory)][string]$Work, [Parameter(Mandatory)][string]$LogDir)
$started = [DateTime]::UtcNow.Ticks
if ([int]$env:P99_DELAY_MS) { [Threading.Thread]::Sleep([int]$env:P99_DELAY_MS) }
$part = if ($Command -match '\.xfer-[0-9a-f]{16}/(\d{6})''') { $Matches[1] } else { '' }
$fault = [string]$env:P99_FAULT
function Done([string]$Output, [int]$Code) {
    $record = @{ start = $started; end = [DateTime]::UtcNow.Ticks; command = $Command; code = $Code } | ConvertTo-Json -Compress
    [IO.File]::WriteAllText((Join-Path $LogDir ("exec-{0}-{1}.json" -f $started, [guid]::NewGuid().ToString('N'))), $record)
    if ($Output) { $Output }
    exit $Code
}
if ($part -and $fault -match "^transient:${part}:(\d+)$") {
    $counter = Join-Path $LogDir "fault-$part.count"
    $seen = if (Test-Path -LiteralPath $counter) { [int](Get-Content -LiteralPath $counter -Raw) } else { 0 }
    if ($seen -lt [int]$Matches[1]) { Set-Content -LiteralPath $counter -Value ($seen + 1); Done 'ERROR: simulated transient failure' 1 }
}
if ($part -and $fault -eq "always:$part") { Done 'ERROR: simulated failure' 1 }
if ($part -and $fault -eq "noack:$part") { Done '' 0 }
if ($part -and $fault -eq "drop:$part" -and $Command -match "f\.writeFileSync\(p,'([A-Za-z0-9_-]*)'\)") { Done "ok $part $($Matches[1].Length)" 0 }
# The runner: split on spaces with no quoting, URL-decode each token, run without a shell.
$tokens = @($Command -split ' ' | ForEach-Object { [Net.WebUtility]::UrlDecode($_) })
$tokens = @($tokens | ForEach-Object { $_.Replace("'/work", "'" + $Work.Replace('\', '/')) })
if ($tokens[0] -ne 'node') { Done "ERROR: emulator runs node only, not $($tokens[0])" 2 }
# The runner runs each exec in a terminal, where node's console.log colours numbers (measured live
# 2026-10-06: "ok 000001 ESC[33m4856ESC[39m"). FORCE_COLOR makes node colour a pipe the same way.
$savedColor = $env:FORCE_COLOR
$env:FORCE_COLOR = '1'
$output = (& node @($tokens[1..($tokens.Count - 1)]) 2>&1 | Out-String).Trim()
$code = $LASTEXITCODE
$env:FORCE_COLOR = $savedColor
if ($fault -eq 'badhash' -and $Command -match 'gunzipSync') { $output = '0' * 64 }
if ($part -and $fault -eq "colorack:$part") { $output = $output -replace '^ok (\d{6}) (\d+)$', ("ok `$1 " + [char]27 + '[33m$2' + [char]27 + '[39m') }
Done $output $code
'@)

function Get-ExecRecords { @(Get-ChildItem -LiteralPath $logDir -Filter 'exec-*.json' | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json }) }
function Get-MaxOverlap($Records) {
    $events = foreach ($r in $Records) { [pscustomobject]@{ t = [long]$r.start; d = 1 }; [pscustomobject]@{ t = [long]$r.end; d = -1 } }
    $now = 0; $max = 0
    foreach ($e in ($events | Sort-Object t, d)) { $now += $e.d; if ($now -gt $max) { $max = $now } }
    return $max
}
function Reset-Runner { Get-ChildItem -LiteralPath $logDir | Remove-Item -Force; Get-ChildItem -LiteralPath $work -Force | Remove-Item -Recurse -Force; $env:P99_FAULT = ''; $env:P99_DELAY_MS = '' }
function Get-PartPayload($Records) {
    $parts = @($Records | Where-Object { $_.command -match "\.xfer-[0-9a-f]{16}/(\d{6})';f\.writeFileSync\(p,'([A-Za-z0-9_-]*)'\)" -and $_.code -eq 0 } |
        ForEach-Object { $null = $_.command -match "/(\d{6})';f\.writeFileSync\(p,'([A-Za-z0-9_-]*)'\)"; [pscustomobject]@{ i = $Matches[1]; s = $Matches[2] } } |
        Sort-Object i -Unique)
    return $parts
}
function ConvertFrom-Base64Url([string]$Text) {
    $b64 = $Text.Replace('-', '+').Replace('_', '/'); $b64 += '=' * ((4 - $b64.Length % 4) % 4)
    return [Convert]::FromBase64String($b64)
}
function Expand-Gzip([byte[]]$Bytes) {
    $in = [IO.MemoryStream]::new($Bytes); $gz = [IO.Compression.GZipStream]::new($in, [IO.Compression.CompressionMode]::Decompress)
    $out = [IO.MemoryStream]::new(); $gz.CopyTo($out); $gz.Dispose(); return $out.ToArray()
}
function Get-Sha256([byte[]]$Bytes) { [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($Bytes)).Replace('-', '').ToLower() }

$global:Waits = [Collections.Generic.List[int]]::new()
$global:AzCalls = 0
$global:FakeNow = $null
function Start-Sleep { param([int]$Seconds, [int]$Milliseconds) $global:Waits.Add($Seconds) }
function az {
    $argv = @($args)
    $global:AzCalls++
    if ($argv[0] -eq 'container' -and $argv[1] -eq 'exec') {
        if ($global:FakeNow) { $global:FakeNow = $global:FakeNow.AddSeconds(30) }
        $command = [string]$argv[[array]::IndexOf($argv, '--exec-command') + 1]
        return (& $emulator -Command $command -Work $work -LogDir $logDir)
    }
    throw "unexpected az call: $($argv -join ' ')"
}

. (Join-Path $root 'scripts\ClaudeRunner.ps1')
function Get-ClaudeRunnerNow { if ($global:FakeNow) { return $global:FakeNow }; return [DateTimeOffset]::UtcNow }

$rng = [Random]::new(99)
$random = New-Object byte[] 16000; $rng.NextBytes($random)
$jsonish = [Text.Encoding]::UTF8.GetBytes((1..1500 | ForEach-Object { '{"oid":"00000000-0000-4000-8000-0000000' + ('{0:d5}' -f $_) + '","tier":"standard","businessUnit":"bu-01"},' }) -join "`n")
$source = Join-Path $scratch 'source.bin'
[IO.File]::WriteAllBytes($source, [byte[]]($random + $jsonish))
$sourceBytes = [IO.File]::ReadAllBytes($source)
$sourceSha = Get-Sha256 $sourceBytes
$allCommands = [Collections.Generic.List[string]]::new()

try {
    Write-Host 'P99 runner transfer - in-process (az is a PowerShell function)'
    Reset-Runner
    Capture { Send-RunnerFile -ResourceGroup rg-p99 -Name aci-projtest-p99 -Path $source -Destination /work/sub/snapshot.json -ChunkSize 1200 }
    $records = Get-ExecRecords
    $records.command | ForEach-Object { $allCommands.Add($_) }
    $arrived = Join-Path $work 'sub\snapshot.json'
    Assert 'the file arrives byte for byte' (-not $CapturedError -and (Test-Path -LiteralPath $arrived) -and (Get-Sha256 ([IO.File]::ReadAllBytes($arrived))) -eq $sourceSha) $CapturedError
    Assert 'the result reports the SHA-256 of the file' ($CapturedResult.Sha256 -eq $sourceSha) "$($CapturedResult.Sha256)"
    Assert 'the part directory is removed after assembly' (@(Get-ChildItem -LiteralPath (Join-Path $work 'sub') -Force -Filter '.xfer-*').Count -eq 0)
    $payload = Get-PartPayload $records
    $joined = -join @($payload.s)
    Capture { Expand-Gzip (ConvertFrom-Base64Url $joined) }
    Assert 'the parts carry the file gzip-compressed as base64url, in index order' ($CapturedResult -and (Get-Sha256 ([byte[]]$CapturedResult)) -eq $sourceSha) $CapturedError
    Assert 'compression shrinks a compressible file' ($joined.Length -gt 0 -and $joined.Length -lt [Math]::Ceiling($sourceBytes.Length * 4 / 3) * 0.8) "payload $($joined.Length) vs raw base64 $([Math]::Ceiling($sourceBytes.Length * 4 / 3))"
    Assert 'every part but the last is full, so the part count is the payload length over the part size, rounded up' (
        $payload.Count -ge 3 -and @($payload | Select-Object -SkipLast 1 | Where-Object { $_.s.Length -ne $payload[0].s.Length }).Count -eq 0 -and $payload[-1].s.Length -le $payload[0].s.Length -and
        $CapturedResult -ne $null -and $payload.Count -eq [Math]::Ceiling($joined.Length / $payload[0].s.Length)) "$($payload.Count) parts"
    Assert 'one exec at a time when az is a function' ((Get-MaxOverlap $records) -eq 1) "overlap $(Get-MaxOverlap $records)"
    Capture { Send-RunnerFile -ResourceGroup rg-p99 -Name aci-projtest-p99 -Path $source -Destination /work/sub/snapshot.json -ChunkSize 1200 }
    Assert 'the result reports the effective parallelism, the parts and the compressed size' (
        $CapturedResult.Parallel -eq 1 -and $CapturedResult.Parts -eq $payload.Count -and $CapturedResult.CompressedBytes -gt 0 -and $CapturedResult.CompressedBytes -lt $sourceBytes.Length) ($CapturedResult | Out-String)

    $empty = Join-Path $scratch 'empty.json'; [IO.File]::WriteAllBytes($empty, [byte[]]@())
    Reset-Runner
    Capture { Send-RunnerFile -ResourceGroup rg-p99 -Name aci-projtest-p99 -Path $empty -Destination /work/empty.json }
    Assert 'an empty file arrives empty' (-not $CapturedError -and (Test-Path -LiteralPath (Join-Path $work 'empty.json')) -and (Get-Item -LiteralPath (Join-Path $work 'empty.json')).Length -eq 0) $CapturedError

    Write-Host 'P99 runner transfer - progress'
    function Get-Said([scriptblock]$Action) {
        try { @(& $Action 6>&1 | Where-Object { $_ -is [Management.Automation.InformationRecord] } | ForEach-Object { [string]$_.MessageData }) }
        catch { @("ERROR: $($_.Exception.Message)") }
    }
    Reset-Runner
    $global:FakeNow = [DateTimeOffset]::UtcNow
    $said = Get-Said { Send-RunnerFile -ResourceGroup rg-p99 -Name aci-projtest-p99 -Path $source -Destination /work/progress.json -ChunkSize 1200 }
    $global:FakeNow = $null
    $opening = @($said | Where-Object { $_ -match "^Sending source\.bin: $($payload.Count) parts, 1 at a time, about \d+ minutes\.$" })
    $ticks = @($said | Where-Object { $_ -match '^Sending source\.bin: \d+ of \d+ parts \(\d+%\), about \d+ minutes left at [\d.]+ parts a second\.$' })
    Assert 'a transfer estimated at a minute or more gives its parts and minutes before it starts' ($opening.Count -eq 1) ($said -join ' | ')
    Assert 'while it runs it reports its progress about once a minute' ($ticks.Count -ge 5 -and $ticks.Count -le [Math]::Ceiling($payload.Count / 2)) "$($ticks.Count) progress line(s) for $($payload.Count) parts"
    $small = Join-Path $scratch 'small.json'; [IO.File]::WriteAllText($small, '{"records":[]}')
    Reset-Runner
    $said = Get-Said { Send-RunnerFile -ResourceGroup rg-p99 -Name aci-projtest-p99 -Path $small -Destination /work/small.json }
    Assert 'a transfer estimated under a minute prints nothing' ($said.Count -eq 0 -and (Test-Path -LiteralPath (Join-Path $work 'small.json'))) ($said -join ' | ')

    Write-Host 'P99 runner transfer - failures stop the transfer with nothing assembled'
    Reset-Runner; $global:Waits.Clear()
    $env:P99_FAULT = 'transient:000001:1'
    Capture { Send-RunnerFile -ResourceGroup rg-p99 -Name aci-projtest-p99 -Path $source -Destination /work/snapshot.json -ChunkSize 1200 }
    Assert 'a part that fails once is retried and the file still arrives' (-not $CapturedError -and $CapturedResult.Retries -eq 1 -and (Get-Sha256 ([IO.File]::ReadAllBytes((Join-Path $work 'snapshot.json')))) -eq $sourceSha) "$CapturedError retries=$($CapturedResult.Retries)"
    Assert 'the retry waits 2 seconds first' ($global:Waits -contains 2) ($global:Waits -join ',')

    Reset-Runner; $global:Waits.Clear()
    $env:P99_FAULT = 'always:000002'
    Capture { Send-RunnerFile -ResourceGroup rg-p99 -Name aci-projtest-p99 -Path $source -Destination /work/snapshot.json -ChunkSize 1200 }
    $records = Get-ExecRecords
    $records.command | ForEach-Object { $allCommands.Add($_) }
    Assert 'a part that fails 3 times stops the transfer and names the part, the attempts and a remedy' (
        $CapturedError -match 'part 2 of \d+' -and $CapturedError -match '3 attempts' -and $CapturedError -match 'Remedy:') $CapturedError
    Assert 'the waits between attempts are 2 then 4 seconds' (($global:Waits -join ',') -eq '2,4') ($global:Waits -join ',')
    Assert 'nothing is assembled after a failed part' (@($records | Where-Object { $_.command -match 'gunzipSync' }).Count -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $work 'snapshot.json')))
    Assert 'the part directory is removed after a failed part' (@(Get-ChildItem -LiteralPath $work -Force -Filter '.xfer-*').Count -eq 0 -and @($records | Where-Object { $_.command -match 'rmSync' }).Count -eq 1)

    Reset-Runner
    $env:P99_FAULT = 'noack:000001'
    Capture { Send-RunnerFile -ResourceGroup rg-p99 -Name aci-projtest-p99 -Path $source -Destination /work/snapshot.json -ChunkSize 1200 }
    Assert 'an exec that exits 0 without the part acknowledgement counts as failed' ($CapturedError -match 'part 1 of \d+' -and -not (Test-Path -LiteralPath (Join-Path $work 'snapshot.json'))) $CapturedError
    Assert 'the failure names the acknowledgement it expected' ($CapturedError -match "no acknowledgement 'ok 000001 \d+'") $CapturedError

    Reset-Runner
    $env:P99_FAULT = 'colorack:000001'
    Capture { Send-RunnerFile -ResourceGroup rg-p99 -Name aci-projtest-p99 -Path $source -Destination /work/snapshot.json -ChunkSize 1200 }
    Assert 'an acknowledgement in terminal colours counts' (-not $CapturedError -and $CapturedResult.Retries -eq 0) "$CapturedError retries=$($CapturedResult.Retries)"

    Reset-Runner
    $env:P99_FAULT = 'badhash'
    Capture { Send-RunnerFile -ResourceGroup rg-p99 -Name aci-projtest-p99 -Path $source -Destination /work/snapshot.json -ChunkSize 1200 }
    Assert 'an assembly whose hash differs fails' ($CapturedError -match 'did not arrive intact') $CapturedError

    Reset-Runner
    $env:P99_FAULT = 'drop:000002'
    Capture { Send-RunnerFile -ResourceGroup rg-p99 -Name aci-projtest-p99 -Path $source -Destination /work/snapshot.json -ChunkSize 1200 }
    Assert 'a part acknowledged but missing at assembly fails, with nothing written and the parts removed' (
        $CapturedError -match 'did not arrive intact' -and $CapturedError -match 'incomplete-parts' -and -not (Test-Path -LiteralPath (Join-Path $work 'snapshot.json')) -and
        @(Get-ChildItem -LiteralPath $work -Force -Filter '.xfer-*').Count -eq 0) $CapturedError

    Reset-Runner; $global:AzCalls = 0
    Capture { Send-RunnerFile -ResourceGroup rg-p99 -Name aci-projtest-p99 -Path $source -Destination '/work/a b.json' }
    Assert 'a destination with a space is refused before any exec' ($CapturedError -match 'space' -and $global:AzCalls -eq 0) $CapturedError
    Capture { Send-RunnerFile -ResourceGroup rg-p99 -Name aci-projtest-p99 -Path $source -Destination "/work/x';process.exit();'.json" }
    Assert 'a destination that would break out of the program''s quotes is refused before any exec' ($CapturedError -match 'absolute runner path' -and $global:AzCalls -eq 0) $CapturedError
    Capture { Send-RunnerFile -ResourceGroup rg-p99 -Name aci-projtest-p99 -Path $source -Destination /work/x.json -Parallel 25 }
    Assert 'more than 24 parts at once is refused' ($CapturedError -match '25' -and $global:AzCalls -eq 0) $CapturedError

    Write-Host 'P99 runner transfer - the apply-by time'
    $big = Join-Path $scratch 'incompressible.json'
    $noise = New-Object byte[] 1500000; $rng.NextBytes($noise)
    [IO.File]::WriteAllText($big, '{"kind":"claude-entitlement-snapshot","expiresAt": 1,"records":["' + [Convert]::ToBase64String($noise) + '"]}')
    Reset-Runner; $global:AzCalls = 0
    Capture { Send-RunnerFile -ResourceGroup rg-p97 -Name aci-projtest-p97 -Path $big -Destination /work/snapshot.json -Deadline ([DateTimeOffset]::UtcNow.AddMinutes(10)) -ReserveSeconds 0 }
    Assert 'a transfer estimated past the apply-by time is refused before the first exec' (
        $CapturedError -match 'apply-by' -and $CapturedError -match 'was not sent' -and $global:AzCalls -eq 0) $CapturedError
    Assert 'the refusal gives the measured 500,000-developer figure, not the old bound' ($CapturedError -match '500,000' -and $CapturedError -notmatch '40,000') $CapturedError
    Assert 'the refusal names the sync job command' (
        $CapturedError -match [regex]::Escape('.\scripts\Deploy-ClaudeProjectionRenewal.ps1 -ResourceGroup rg-p97 -ApimName <apim> -NamePrefix p97 -AlertEmail <address>') -and
        $CapturedError -match 'az containerapp job start') $CapturedError
    $tiny = Join-Path $scratch 'tiny.json'
    [IO.File]::WriteAllText($tiny, '{"kind":"claude-entitlement-snapshot","expiresAt": 1,"records":[]}')
    Reset-Runner; $global:AzCalls = 0
    Capture { Send-RunnerFile -ResourceGroup rg-p97 -Name aci-projtest-p97 -Path $tiny -Destination /work/snapshot.json -Deadline ([DateTimeOffset]::UtcNow.AddMinutes(5)) }
    Assert 'ten minutes before the apply-by time are kept for the steps after the transfer' (
        $CapturedError -match 'apply-by' -and $CapturedError -match '10 minutes' -and $global:AzCalls -eq 0) $CapturedError
    Reset-Runner; $global:AzCalls = 0
    Capture { Send-RunnerFile -ResourceGroup rg-p97 -Name aci-projtest-p97 -Path $tiny -Destination /work/snapshot.json -Deadline ([DateTimeOffset]::UtcNow.AddMinutes(5)) -ReserveSeconds 0 }
    Assert 'the same transfer without the reserve is sent' (-not $CapturedError -and $global:AzCalls -ge 3) "$CapturedError | $($global:AzCalls) call(s)"

    Reset-Runner; $global:Waits.Clear()
    $global:FakeNow = [DateTimeOffset]::UtcNow
    $deadline = $global:FakeNow.AddSeconds(200)
    Capture { Send-RunnerFile -ResourceGroup rg-p97 -Name aci-projtest-p97 -Path $source -Destination /work/snapshot.json -ChunkSize 1200 -Deadline $deadline -SecondsPerExec 1 -ReserveSeconds 0 }
    $records = Get-ExecRecords
    $global:FakeNow = $null
    Assert 'a transfer whose measured rate projects past the apply-by time stops' (
        $CapturedError -match 'Stopped sending' -and $CapturedError -match 'apply-by' -and $CapturedError -match 'nothing was written') $CapturedError
    Assert 'it stops after the first wave, removes the parts and assembles nothing' (
        @($records | Where-Object { $_.command -match "writeFileSync\(p," }).Count -eq 1 -and @($records | Where-Object { $_.command -match 'rmSync' }).Count -eq 1 -and
        @($records | Where-Object { $_.command -match 'gunzipSync' }).Count -eq 0 -and @(Get-ChildItem -LiteralPath $work -Force -Filter '.xfer-*').Count -eq 0) "$($records.Count) exec(s)"

    Write-Host 'P99 runner transfer - parallel (az is an application)'
    Remove-Item Function:\az
    $fakeAz = @'
$argv = @($args)
if ($argv[0] -eq 'container' -and $argv[1] -eq 'exec') {
    $command = [string]$argv[[array]::IndexOf($argv, '--exec-command') + 1]
    & (Join-Path $PSScriptRoot 'runner-emulator.ps1') -Command $command -Work $env:P99_WORK -LogDir $env:P99_LOGDIR
    exit $LASTEXITCODE
}
[Console]::Error.WriteLine('unexpected az call: ' + ($argv -join ' '))
exit 97
'@
    [IO.File]::WriteAllText((Join-Path $bin 'az-fake.ps1'), $fakeAz)
    $pwshPath = (Get-Process -Id $PID).Path
    [IO.File]::WriteAllText((Join-Path $bin 'az.cmd'), "@echo off`r`n`"$pwshPath`" -NoProfile -NonInteractive -File `"%~dp0az-fake.ps1`" %*`r`nexit /b %errorlevel%`r`n", [Text.Encoding]::ASCII)
    $savedPath = $env:PATH
    $env:PATH = $bin + ';' + $env:PATH
    $env:P99_WORK = $work; $env:P99_LOGDIR = $logDir
    try {
        Assert 'the fake az.cmd is the az that runs' ((Microsoft.PowerShell.Core\Get-Command az).Source -eq (Join-Path $bin 'az.cmd'))
        Reset-Runner
        $env:P99_DELAY_MS = '400'
        Capture { Send-RunnerFile -ResourceGroup rg-p99 -Name aci-projtest-p99 -Path $source -Destination /work/snapshot.json -ChunkSize 1200 -Parallel 4 }
        $records = Get-ExecRecords
        $records.command | ForEach-Object { $allCommands.Add($_) }
        $overlap = Get-MaxOverlap $records
        Assert 'in parallel the file arrives byte for byte' (-not $CapturedError -and (Get-Sha256 ([IO.File]::ReadAllBytes((Join-Path $work 'snapshot.json')))) -eq $sourceSha) $CapturedError
        Assert 'more than one exec runs at once, never more than -Parallel' ($overlap -ge 2 -and $overlap -le 4) "overlap $overlap"
        Assert 'the result reports the parallelism used' ($CapturedResult.Parallel -eq 4) "$($CapturedResult.Parallel)"
        Reset-Runner
        $env:P99_FAULT = 'transient:000003:2'
        Capture { Send-RunnerFile -ResourceGroup rg-p99 -Name aci-projtest-p99 -Path $source -Destination /work/snapshot.json -ChunkSize 1200 -Parallel 4 }
        Assert 'in parallel a part that fails twice is retried and the file arrives' (
            -not $CapturedError -and $CapturedResult.Retries -eq 2 -and (Get-Sha256 ([IO.File]::ReadAllBytes((Join-Path $work 'snapshot.json')))) -eq $sourceSha) "$CapturedError retries=$($CapturedResult.Retries)"
        Reset-Runner
        $env:P99_FAULT = 'always:000002'
        Capture { Send-RunnerFile -ResourceGroup rg-p99 -Name aci-projtest-p99 -Path $source -Destination /work/snapshot.json -ChunkSize 1200 -Parallel 4 }
        $records = Get-ExecRecords
        Assert 'in parallel a part that fails 3 times stops the transfer with nothing assembled' (
            $CapturedError -match 'part 2 of \d+' -and @($records | Where-Object { $_.command -match 'gunzipSync' }).Count -eq 0 -and
            @(Get-ChildItem -LiteralPath $work -Force -Filter '.xfer-*').Count -eq 0) $CapturedError
    }
    finally { $env:PATH = $savedPath; $env:P99_WORK = ''; $env:P99_LOGDIR = '' }

    Write-Host 'P99 runner transfer - every exec command passes the runner and cmd.exe unchanged'
    $long = @($allCommands | Where-Object { $_.Length -ge 5000 })
    $spaced = @($allCommands | Where-Object { ($_ -replace '^node -e ', '') -match ' ' })
    $unsafe = @($allCommands | Where-Object { $_ -match '["%+&|<>^!\r\n]' })
    Assert 'commands were recorded' ($allCommands.Count -ge 20) "$($allCommands.Count)"
    Assert 'every exec command is under 5,000 characters' ($long.Count -eq 0) "$($long.Count) too long"
    Assert 'no program contains a space' ($spaced.Count -eq 0) ($spaced | Select-Object -First 1)
    Assert 'no command contains a quote, %, +, &, |, <, >, ^, ! or a line break' ($unsafe.Count -eq 0) ($unsafe | Select-Object -First 1)
}
finally {
    $env:P99_FAULT = ''; $env:P99_DELAY_MS = ''
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "P99_TRANSFER assertions=$assertions failed=$failures"
exit ([int]($failures -gt 0))
