# Every AUM test file runs in exactly one registered shard of Test-FinOps.ps1, and a shard runs
# the files it lists. The pytest parts need the worktree .venv-finops and SKIP without it.
$ErrorActionPreference = 'Stop'
$fail = 0
function Assert($label, $condition, $detail = '') {
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $label$(if ($detail) { " - $detail" })" -ForegroundColor Red; $script:fail++ }
}
function Join-Names([string[]]$Names) {
    $sorted = [string[]]@($Names)
    [Array]::Sort($sorted, [StringComparer]::Ordinal)
    $sorted -join '|'
}
# Terminal control sequences (ECMA-48 CSI), such as pytest's colours.
function Remove-Ansi([string]$Text) { [regex]::Replace($Text, '\x1b\[[0-9;?]*[ -/]*[@-~]', '') }
function Read-Listing([string]$Script, [string]$Shard = '') {
    $options = @('-NoProfile', '-NonInteractive', '-File', $Script, '-ListFiles')
    if ($Shard) { $options += @('-Shard', $Shard) }
    $text = & pwsh @options 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "Listing failed for $Script ${Shard}: $text" }
    @($text | ConvertFrom-Json)
}

$root = Split-Path $PSScriptRoot -Parent
$tests = Join-Path $root 'cli\finops\tests'
$runner = Join-Path $PSScriptRoot 'Test-FinOps.ps1'
. (Join-Path $PSScriptRoot 'Select-FinOpsShard.ps1')
$work = Join-Path ([IO.Path]::GetTempPath()) ('finops-shards-' + [guid]::NewGuid().ToString('N'))
$link = Join-Path $work 'sandbox\.venv-finops'
New-Item -ItemType Directory -Path $work | Out-Null
try {
    # Test-All registers shards 0/n to n-1/n of Test-FinOps.ps1, once each, and no unsharded run.
    $allAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Test-All.ps1'), [ref]$null, [ref]$null)
    $registered = @($allAst.FindAll({
        param($node)
        $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Invoke-Check' -and
        $node.CommandElements.Count -ge 3 -and
        $node.CommandElements[2] -is [Management.Automation.Language.StringConstantExpressionAst] -and
        $node.CommandElements[2].Value -ceq 'Test-FinOps.ps1'
    }, $true) | ForEach-Object {
        $shard = ''
        foreach ($table in @($_.CommandElements | Where-Object { $_ -is [Management.Automation.Language.HashtableAst] })) {
            foreach ($pair in $table.KeyValuePairs) {
                $value = if ($pair.Item2 -is [Management.Automation.Language.PipelineAst]) { $pair.Item2.GetPureExpression() }
                if ($pair.Item1.Value -ceq 'Shard' -and $value -is [Management.Automation.Language.StringConstantExpressionAst]) { $shard = $value.Value }
            }
        }
        $shard
    })
    $count = if ($registered.Count -and $registered[0] -match '\A[0-9]+/([0-9]+)\z') { [int]$Matches[1] } else { 0 }
    $expected = @(for ($i = 0; $i -lt $count; $i++) { "$i/$count" })
    $ordered = @($registered | Sort-Object { if ($_ -match '\A([0-9]+)/') { [int]$Matches[1] } else { -1 } })
    Assert 'Test-All registers shards 0/n to n-1/n of Test-FinOps.ps1 once each, and no unsharded run' (
        $count -ge 1 -and ($ordered -join ',') -ceq ($expected -join ',')
    ) "registered: $(($registered | ForEach-Object { if ($_) { $_ } else { '(unsharded)' } }) -join ', ')"

    # The listings: every test file on disk, each in exactly one shard.
    $onDisk = @(Get-ChildItem -LiteralPath $tests -Recurse -File |
        Where-Object { ($_.Name -like 'test_*.py' -or $_.Name -like '*_test.py') -and
            [IO.Path]::GetRelativePath($tests, $_.FullName) -notmatch '(\A|[\\/])(\.[^\\/]*|__pycache__)[\\/]' } |
        ForEach-Object { [IO.Path]::GetRelativePath($tests, $_.FullName).Replace('\', '/') })
    $full = @(Read-Listing $runner)
    Assert "the unsharded listing names every test file on disk, at any depth ($($onDisk.Count))" (
        $onDisk.Count -gt 0 -and (Join-Names @($full.Name)) -ceq (Join-Names $onDisk)
    ) "listed $($full.Count), on disk $($onDisk.Count)"
    $union = [Collections.Generic.List[string]]::new()
    $loads = @()
    $listed = @{}
    foreach ($shard in $expected) {
        $part = @(Read-Listing $runner $shard)
        Assert "shard $shard lists at least one test file" ($part.Count -gt 0)
        foreach ($name in @($part.Name)) { $union.Add($name) }
        $listed[$shard] = Join-Names @($part.Name)
        $loads += [pscustomobject]@{ Shard = $shard; Files = $part.Count; Seconds = [long](($part | Measure-Object Seconds -Sum).Sum) }
    }
    Assert 'the registered shards list every test file exactly once' (
        $union.Count -eq $full.Count -and (Join-Names $union.ToArray()) -ceq (Join-Names @($full.Name))
    ) "$($union.Count) listed across shards, $($full.Count) test files"
    if ($expected.Count) {
        $again = @(Read-Listing $runner $expected[-1])
        Assert 'listing a shard twice gives the same files' ((Join-Names @($again.Name)) -ceq $listed[$expected[-1]])
    }

    # A planned shard stays within half of Test-All's per-check timeout; the gate runs four checks at once.
    $timeoutAst = @($allAst.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -ceq 'CheckTimeoutSeconds' })
    $timeout = if ($timeoutAst.Count -eq 1 -and $timeoutAst[0].DefaultValue -is [Management.Automation.Language.ConstantExpressionAst]) { [int]$timeoutAst[0].DefaultValue.Value } else { 0 }
    $heaviest = [long]($loads | Measure-Object Seconds -Maximum).Maximum
    Assert "each shard plans at most half of Test-All's $timeout s per-check timeout" (
        $timeout -gt 0 -and $loads.Count -gt 0 -and $heaviest * 2 -le $timeout
    ) "planned: $(($loads | ForEach-Object { "$($_.Shard) $($_.Seconds) s" }) -join '; ')"
    Write-Host "  Plan: $(($loads | ForEach-Object { "$($_.Shard) $($_.Files) files $($_.Seconds) s" }) -join '; ')."
    $timing = Read-FinOpsTiming (Join-Path $PSScriptRoot 'finops-test-durations.json')
    $stale = @($timing.Seconds.PSObject.Properties.Name | Where-Object { $_ -cnotin @($full.Name) })
    Assert 'every committed weight names an existing test file' ($stale.Count -eq 0) "no such file: $($stale -join ', ')"
    $unweighted = @($full | Where-Object { $_.Name -cnotin @($timing.Seconds.PSObject.Properties.Name) })
    if ($unweighted.Count) { Write-Host "  $($unweighted.Count) file(s) take the default $($timing.DefaultSeconds) s: $(($unweighted.Name) -join ', ')." }

    # The planner, the coordinates and the timing reader, on fixed input.
    $fixed = [pscustomobject]@{ SchemaVersion = 1; DefaultSeconds = 2; Seconds = [pscustomobject]@{ 'test_a.py' = 5; 'test_b.py' = 4; 'test_c.py' = 3 } }
    $plan = @(Get-FinOpsShardPlan -File 'test_d.py', 'test_c.py', 'test_b.py', 'test_a.py' -Timing $fixed -Count 2)
    Assert 'the planner places the longest file first on the least-loaded shard; an unweighted file takes the default' (
        (($plan | ForEach-Object { "$($_.Name):$($_.Seconds):$($_.Shard)" }) -join ',') -ceq 'test_a.py:5:0,test_b.py:4:1,test_c.py:3:1,test_d.py:2:0')
    $even = [pscustomobject]@{ SchemaVersion = 1; DefaultSeconds = 1; Seconds = [pscustomobject]@{} }
    $ties = @(Get-FinOpsShardPlan -File 'test_b.py', 'test_c.py', 'test_a.py' -Timing $even -Count 2)
    Assert 'equal weights keep ordinal file order, and equal loads choose the lower shard' (
        (($ties | ForEach-Object { "$($_.Name):$($_.Shard)" }) -join ',') -ceq 'test_a.py:0,test_b.py:1,test_c.py:0')
    $threw = $false
    try { Get-FinOpsShardPlan -File 'test_a.py', 'test_a.py' -Timing $fixed -Count 2 | Out-Null } catch { $threw = $true }
    Assert 'the planner rejects a duplicate file name' $threw
    foreach ($bad in '0/0', '-1/4', '4/4', '0/17', 'a/2', '1', ' 0/4') {
        $threw = $false
        try { ConvertFrom-FinOpsShard $bad | Out-Null } catch { $threw = $true }
        Assert "invalid shard '$bad' is rejected" $threw
    }
    Assert "a valid shard '3/4' is accepted" ((ConvertFrom-FinOpsShard '3/4').Index -eq 3)
    $out = & pwsh -NoProfile -NonInteractive -File $runner -Shard "$count/$count" 2>&1 | Out-String
    Assert 'Test-FinOps.ps1 refuses an out-of-range shard before it runs tests' ($LASTEXITCODE -ne 0 -and $out -match 'Shard must be')
    $tables = [ordered]@{
        'a zero default'          = '{"SchemaVersion":1,"DefaultSeconds":0,"Seconds":{}}'
        'a fractional weight'     = '{"SchemaVersion":1,"DefaultSeconds":10,"Seconds":{"test_a.py":1.5}}'
        'a text weight'           = '{"SchemaVersion":1,"DefaultSeconds":10,"Seconds":{"test_a.py":"5"}}'
        'another schema version'  = '{"SchemaVersion":2,"DefaultSeconds":10,"Seconds":{}}'
        'weights that are not an object' = '{"SchemaVersion":1,"DefaultSeconds":10,"Seconds":5}'
    }
    foreach ($case in $tables.GetEnumerator()) {
        $path = Join-Path $work 'timing.json'
        [IO.File]::WriteAllText($path, $case.Value)
        $threw = $false
        try { Read-FinOpsTiming $path | Out-Null } catch { $threw = $true }
        Assert "the timing reader rejects $($case.Key)" $threw
    }
    [IO.File]::WriteAllText($path, '{"SchemaVersion":1,"DefaultSeconds":10,"Seconds":{"test_a.py":5}}')
    Assert 'the timing reader accepts a valid table' ((Read-FinOpsTiming $path).Seconds.'test_a.py' -eq 5)

    # The updater sums a file's test cases, rounds up to whole seconds and refuses unknown modules.
    $suite = Join-Path $work 'updater\tests'
    New-Item -ItemType Directory -Path $suite | Out-Null
    foreach ($name in 'test_a.py', 'test_b.py', 'test_c.py', 'helper.py') { [IO.File]::WriteAllText((Join-Path $suite $name), '') }
    $report = Join-Path $work 'report.xml'
    [IO.File]::WriteAllText($report, '<testsuites><testsuite><testcase classname="tests.test_a" name="one" time="0.25"/><testcase classname="tests.test_a" name="two" time="0.5"/><testcase classname="tests.test_b.TestGroup" name="three" time="2.01"/></testsuite></testsuites>')
    $written = Join-Path $work 'written.json'
    $null = & pwsh -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot 'Update-FinOpsDurations.ps1') -JUnitXml $report -OutputPath $written -TestDirectory $suite 2>&1
    $result = if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $written)) { Read-FinOpsTiming $written }
    Assert 'the updater writes whole seconds rounded up per file, and no weight for an unmeasured file' (
        $null -ne $result -and $result.DefaultSeconds -eq 10 -and
        (($result.Seconds.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ',') -ceq 'test_a.py=1,test_b.py=3')
    [IO.File]::WriteAllText($report, '<testsuites><testsuite><testcase classname="tests.test_gone" name="one" time="1"/></testsuite></testsuites>')
    $out = & pwsh -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot 'Update-FinOpsDurations.ps1') -JUnitXml $report -OutputPath $written -TestDirectory $suite 2>&1 | Out-String
    Assert 'the updater refuses a test case from no known file' ($LASTEXITCODE -ne 0 -and $out -match 'names no file')

    $python = @((Join-Path $root '.venv-finops\Scripts\python.exe'), (Join-Path $root '.venv-finops\bin\python')) |
        Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $python) {
        Write-Host '  [SKIP] pytest comparisons: this worktree has no .venv-finops (docs/AUM.md).' -ForegroundColor Yellow
    }
    else {
        # pytest's own collection, unsharded, finds exactly the listed files.
        $collection = & $python -m pytest $tests --collect-only -q -p no:cacheprovider 2>&1 | Out-String
        $collectExit = $LASTEXITCODE
        $collected = @([regex]::Matches($collection, '(?m)^tests/([^:\s]+\.py)::') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
        Assert "pytest collects tests from exactly the listed files ($($collected.Count))" (
            $collectExit -eq 0 -and (Join-Names $collected) -ceq (Join-Names @($full.Name))
        ) "exit $collectExit; collected $($collected.Count) files, listed $($full.Count)"

        # File k holds 2^k tests, so each shard's passed count names exactly the files it ran.
        $sandbox = Join-Path $work 'sandbox'
        $synthetic = Join-Path $sandbox 'cli\finops\tests'
        New-Item -ItemType Directory -Path (Join-Path $sandbox 'tests'), $synthetic | Out-Null
        foreach ($name in 'Test-FinOps.ps1', 'Select-FinOpsShard.ps1') {
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $sandbox 'tests')
        }
        [IO.File]::WriteAllText((Join-Path $sandbox 'cli\finops\pyproject.toml'), "[tool.pytest.ini_options]`ntestpaths = [`"tests`"]`n")
        $weights = [ordered]@{}
        for ($k = 0; $k -lt 5; $k++) {
            $body = (0..([int][math]::Pow(2, $k) - 1) | ForEach-Object { "def test_$_():`n    pass`n" }) -join "`n"
            [IO.File]::WriteAllText((Join-Path $synthetic "test_synthetic_$k.py"), $body)
            $weights["test_synthetic_$k.py"] = 5 - $k
        }
        [IO.File]::WriteAllText((Join-Path $sandbox 'tests\finops-test-durations.json'),
            (ConvertTo-Json -InputObject ([ordered]@{ SchemaVersion = 1; DefaultSeconds = 1; Seconds = $weights })))
        $linkType = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
        New-Item -ItemType $linkType -Path $link -Target (Split-Path (Split-Path $python -Parent) -Parent) | Out-Null
        $sandboxRunner = Join-Path $sandbox 'tests\Test-FinOps.ps1'
        $ran = 0
        # The packet gate runs Test-All with FORCE_COLOR=0 (.ironclad/gate.mjs:340), and pytest colours its
        # output for any non-empty FORCE_COLOR. PY_COLORS takes precedence, so one shard runs coloured and
        # one plain, whatever the caller's environment.
        $modes = @{}
        foreach ($case in @(@{ Shard = '0/2'; Colours = '1' }, @{ Shard = '1/2'; Colours = '0' })) {
            $shard = $case.Shard
            $rows = @(Read-Listing $sandboxRunner $shard)
            $expectedPassed = 0
            foreach ($row in $rows) { $expectedPassed += [int][math]::Pow(2, [int]($row.Name -replace '\D', '')) }
            $saved = $env:PY_COLORS
            $env:PY_COLORS = $case.Colours
            try {
                $out = & pwsh -NoProfile -NonInteractive -File $sandboxRunner -Shard $shard 2>&1 | Out-String
                $exit = $LASTEXITCODE
            }
            finally { $env:PY_COLORS = $saved }
            $coloured = $out.Contains([string][char]27)
            if ($case.Colours -eq '1') {
                Assert "pytest colours the output of synthetic shard $shard when PY_COLORS=1" $coloured
                if ($coloured) { $modes['coloured'] = $true }
            }
            else {
                Assert "pytest writes plain output for synthetic shard $shard when PY_COLORS=0" (-not $coloured)
                if (-not $coloured) { $modes['plain'] = $true }
            }
            $passed = if ((Remove-Ansi $out) -match '(?m)\b([0-9]+) passed\b') { [int]$Matches[1] } else { -1 }
            Assert "a synthetic shard $shard runs exactly the files it lists ($expectedPassed tests)" (
                $exit -eq 0 -and $rows.Count -gt 0 -and $passed -eq $expectedPassed
            ) "exit $exit; $passed passed"
            $ran += [math]::Max(0, $passed)
        }
        Assert 'the synthetic shards read one coloured and one plain pytest output' ($modes['coloured'] -and $modes['plain'])
        Assert 'the two synthetic shards together run all 31 tests once' ($ran -eq 31) "$ran ran"
    }
}
finally {
    # Remove the link itself first; the venv it points to must survive.
    if (Test-Path -LiteralPath $link) { [IO.Directory]::Delete($link, $false) }
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
if ($fail) { Write-Host "$fail assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'The AUM shards run every test file exactly once.' -ForegroundColor Green
exit 0
