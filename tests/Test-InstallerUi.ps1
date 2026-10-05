param(
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$ExpectedNodeTests = 131
$root = Split-Path $PSScriptRoot -Parent
$script:fail = 0
$script:checks = 0

function Assert($label, $condition, $detail = '') {
    $script:checks++
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $label$(if ($detail) { " - $detail" })" -ForegroundColor Red; $script:fail++ }
}

function ConvertFrom-InstallerUiTap {
    param(
        [Parameter(Mandatory)][string]$Tap,
        [Parameter(Mandatory)][int]$ExitCode,
        [Parameter(Mandatory)][int]$ExpectedTests
    )

    $summary = @{}
    foreach ($match in [regex]::Matches($Tap, '(?m)^# (tests|pass|fail|cancelled|skipped|todo)\s+(\d+)\s*$')) {
        $key = $match.Groups[1].Value
        if ($summary.ContainsKey($key)) {
            if (-not $summary.ContainsKey('__duplicateSummary')) { $summary['__duplicateSummary'] = @() }
            $summary['__duplicateSummary'] += $key
        }
        $summary[$key] = [int]$match.Groups[2].Value
    }

    $resultMatches = @([regex]::Matches($Tap, '(?m)^(not ok|ok)\s+(\d+)(?:\s+-\s*(.*))?$'))
    $seen = @{}
    $duplicates = @()
    $failedNames = @()
    $skippedResultLines = @()
    $todoResultLines = @()
    foreach ($match in $resultMatches) {
        $number = [int]$match.Groups[2].Value
        if ($seen.ContainsKey($number)) { $duplicates += $number }
        $seen[$number] = $true
        $name = $match.Groups[3].Value.Trim()
        if ($match.Groups[1].Value -eq 'not ok') { $failedNames += $name }
        if ($name -match '#\s*SKIP\b') { $skippedResultLines += $name }
        if ($name -match '#\s*TODO\b') { $todoResultLines += $name }
    }

    $errors = @()
    if ($ExitCode -ne 0) { $errors += "node:test exited $ExitCode" }
    foreach ($key in 'tests', 'fail', 'cancelled', 'skipped', 'todo') {
        if (-not $summary.ContainsKey($key)) { $errors += "missing # $key summary" }
    }
    if ($summary.ContainsKey('__duplicateSummary')) { $errors += "duplicate summary line(s): $($summary['__duplicateSummary'] -join ', ')" }
    if ($summary.ContainsKey('tests') -and $summary['tests'] -ne $ExpectedTests) {
        $errors += "expected $ExpectedTests subtests, TAP reported $($summary['tests'])"
    }
    if ($summary.ContainsKey('tests') -and $resultMatches.Count -ne $summary['tests']) {
        $errors += "result line count $($resultMatches.Count) does not equal # tests $($summary['tests'])"
    }
    if ($duplicates.Count) { $errors += "duplicate result line number(s): $((@($duplicates) | Sort-Object -Unique) -join ', ')" }
    foreach ($key in 'fail', 'cancelled', 'skipped', 'todo') {
        if ($summary.ContainsKey($key) -and $summary[$key] -ne 0) { $errors += "# $key is $($summary[$key])" }
    }
    if ($skippedResultLines.Count) { $errors += "SKIP result line(s): $($skippedResultLines -join '; ')" }
    if ($todoResultLines.Count) { $errors += "TODO result line(s): $($todoResultLines -join '; ')" }

    [pscustomobject]@{
        Passed = ($errors.Count -eq 0)
        Errors = $errors
        Tests = if ($summary.ContainsKey('tests')) { $summary['tests'] } else { -1 }
        ResultCount = $resultMatches.Count
        FailedNames = $failedNames
        OkNames = @($resultMatches | Where-Object { $_.Groups[1].Value -eq 'ok' } | ForEach-Object { $_.Groups[3].Value.Trim() })
    }
}

function Invoke-InstallerUiTapParserSelfTest {
    $clean = @'
TAP version 13
ok 1 - alpha
ok 2 - beta
1..2
# tests 2
# pass 2
# fail 0
# cancelled 0
# skipped 0
# todo 0
'@
    Assert 'TAP parser self-test accepts clean TAP' (ConvertFrom-InstallerUiTap -Tap $clean -ExitCode 0 -ExpectedTests 2).Passed

    $skipped = $clean -replace 'ok 2 - beta', 'ok 2 - beta # SKIP not on this platform' -replace '# skipped 0', '# skipped 1'
    Assert 'TAP parser self-test rejects skipped subtests' (-not (ConvertFrom-InstallerUiTap -Tap $skipped -ExitCode 0 -ExpectedTests 2).Passed)

    $todo = $clean -replace 'ok 2 - beta', 'ok 2 - beta # TODO pending' -replace '# todo 0', '# todo 1'
    Assert 'TAP parser self-test rejects todo subtests' (-not (ConvertFrom-InstallerUiTap -Tap $todo -ExitCode 0 -ExpectedTests 2).Passed)

    $cancelled = $clean -replace '# cancelled 0', '# cancelled 1'
    Assert 'TAP parser self-test rejects cancelled subtests' (-not (ConvertFrom-InstallerUiTap -Tap $cancelled -ExitCode 0 -ExpectedTests 2).Passed)

    $missing = $clean -replace '(?m)^ok 2 - beta\r?\n', ''
    Assert 'TAP parser self-test rejects missing result lines' (-not (ConvertFrom-InstallerUiTap -Tap $missing -ExitCode 0 -ExpectedTests 2).Passed)

    Assert 'TAP parser self-test rejects count mismatches' (-not (ConvertFrom-InstallerUiTap -Tap $clean -ExitCode 0 -ExpectedTests 3).Passed)

    $duplicate = $clean -replace 'ok 2 - beta', 'ok 1 - beta'
    Assert 'TAP parser self-test rejects duplicate result lines' (-not (ConvertFrom-InstallerUiTap -Tap $duplicate -ExitCode 0 -ExpectedTests 2).Passed)

    $loadFailure = @'
TAP version 13
1..0
# tests 0
# pass 0
# fail 0
# cancelled 0
# skipped 0
# todo 0
'@
    Assert 'TAP parser self-test rejects load failures' (-not (ConvertFrom-InstallerUiTap -Tap $loadFailure -ExitCode 1 -ExpectedTests 1).Passed)
}

Write-Host ''
Write-Host 'Installer UI server' -ForegroundColor Cyan
$watch = [Diagnostics.Stopwatch]::StartNew()
Invoke-InstallerUiTapParserSelfTest
if ($SelfTest) {
    Write-Host ''
    Write-Host ("{0} checks, {1} failed, {2:N1} s" -f $script:checks, $script:fail, $watch.Elapsed.TotalSeconds)
    if ($script:fail) { exit 1 }
    exit 0
}

$files = Get-ChildItem -Path $PSScriptRoot -Filter 'installer-ui*.test.mjs' | Sort-Object Name | ForEach-Object { $_.FullName }
$out = & node --test --test-reporter=tap @files 2>&1 | Out-String
$code = $LASTEXITCODE
$tap = ConvertFrom-InstallerUiTap -Tap $out -ExitCode $code -ExpectedTests $ExpectedNodeTests
Assert 'node:test TAP is exact, complete and clean' $tap.Passed (($tap.Errors -join '; ') + "`n$out")
Assert 'node:test reported the expected Installer UI subtest count' ($tap.Tests -eq $ExpectedNodeTests) "reported=$($tap.Tests) expected=$ExpectedNodeTests"
Assert 'node:test reported one unique result line per subtest' ($tap.ResultCount -eq $ExpectedNodeTests) "reported=$($tap.ResultCount) expected=$ExpectedNodeTests"
foreach ($name in $tap.OkNames) {
    Assert ("node:test: " + ($name -replace '\s+#\s*(SKIP|TODO)\b.*$', '').Trim()) $true
}
foreach ($name in $tap.FailedNames) {
    Assert ("node:test: " + $name) $false $out
}

Write-Host ''
Write-Host ("{0} checks, {1} failed, {2:N1} s" -f $script:checks, $script:fail, $watch.Elapsed.TotalSeconds)
if ($script:fail) { exit 1 }
