#Requires -Version 7
# Count-preserving detector proofs; baseline-only diagnostics do not claim mutation evidence.
param(
    [ValidateSet('Core', 'Runner', 'Wizard')][string]$Mode = 'Core',
    [string]$Root = (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent),
    [string]$EvidenceDirectory = (Join-Path ([IO.Path]::GetTempPath()) ('test-infrastructure-evidence-' + [guid]::NewGuid().ToString('N'))),
    [switch]$BaselineOnly
)
$ErrorActionPreference = 'Stop'
$lock = Join-Path (Split-Path $Root -Parent) '.gate-lock'
$hosted = $env:GITHUB_ACTIONS -ceq 'true' -and $env:RUNNER_ENVIRONMENT -ceq 'github-hosted'
$needsLock = -not $hosted -and -not $BaselineOnly
$token = 'P78-' + [guid]::NewGuid().ToString('N')
$ownedLock = $false
$sandbox = Join-Path ([IO.Path]::GetTempPath()) ('p78-negative-' + [guid]::NewGuid().ToString('N'))
$logs = Join-Path $EvidenceDirectory ("infrastructure-$($Mode.ToLowerInvariant())-" + [guid]::NewGuid().ToString('N'))
$cases = [Collections.Generic.List[object]]::new()
function Add-Case($Name, $File, $From, $To, $Suite, [int]$Matches = 1) {
    $cases.Add([pscustomobject]@{ Name = $Name; File = $File; From = $From; To = $To; Suite = $Suite; Matches = $Matches })
}
function Ignore-Guard($Name, $Literal) {
    Add-Case $Name 'tests\TestAll-Sharding.ps1' ('throw ' + $Literal) ('$null = ' + $Literal) 'Test-TestAllSharding.ps1'
}
function Measure-Suite($Suite, $LogName) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $output = & pwsh -NoProfile -File (Join-Path (Join-Path $sandbox 'tests') $Suite) 2>&1 | Out-String
    $code = $LASTEXITCODE
    $pattern = '(?m)^\s*\[(?:OK|FAIL)\]'
    $failedPattern = '(?m)^\s*\[FAIL\]'
    if ($Suite -eq 'Test-On-PS51.ps1') {
        $pattern = '(?m)^\s*\[(?:OK|FAIL)\]\s+PS51:'
        $failedPattern = '(?m)^\s*\[FAIL\]\s+PS51:'
    }
    if ($Suite -eq 'Test-PreflightBothHosts.ps1') {
        $pattern = '(?m)^\s+(?:returned (?:True|False) on|FAIL - preflight .* on)'
        $failedPattern = '(?m)^\s+FAIL - preflight'
    }
    $output | Set-Content -LiteralPath (Join-Path $logs $LogName)
    [pscustomobject]@{
        ExitCode = $code; Count = [regex]::Matches($output, $pattern).Count
        Failed = [regex]::Matches($output, $failedPattern).Count
        Seconds = [math]::Round($watch.Elapsed.TotalSeconds, 2)
        Diagnostics = @($output -split "`r?`n" | Where-Object { $_ -match $failedPattern } | Select-Object -First 4)
    }
}
try {
    while ($needsLock -and -not $ownedLock) {
        if (Test-Path -LiteralPath $lock) {
            Write-Host "$(Get-Date -Format o) P78 $Mode waiting for the shared lock; retry in 60 s."
            Start-Sleep -Seconds 60
            continue
        }
        try {
            New-Item -ItemType File -Path $lock -Value $token -ErrorAction Stop | Out-Null
            $ownedLock = $true
        }
        catch {
            if ($_.CategoryInfo.Category -ne 'ResourceExists') { throw }
            Start-Sleep -Seconds 60
        }
    }
    if ($ownedLock) { Write-Host "$(Get-Date -Format o) P78 $Mode acquired the lock." }
    elseif ($BaselineOnly) { Write-Host 'Targeted baseline diagnostics only; no mutations will run.' }
    else { Write-Host 'Negative proofs run on this isolated GitHub-hosted VM.' }
    New-Item -ItemType Directory -Path $sandbox, $logs | Out-Null
    $files = @(
        'tests\Test-All.ps1', 'tests\Test-RunnerIntegrity.ps1', 'tests\TestAll-Sharding.ps1',
        'tests\Test-TestAllSharding.ps1', 'tests\Test-RemoteTestAll.ps1',
        'tests\Invoke-RemoteTestAll.ps1', 'tests\Merge-TestAllReceipts.ps1',
        'tests\test-all-durations.json', 'tests\test-all-local-only.json',
        'tests\requirements-finops.lock', 'tests\requirements-aum-service.lock',
        'tests\Test-On-PS51.ps1', 'tests\Test-PreflightBothHosts.ps1', 'tests\TestAzureFixture.ps1',
        'tests\Test-ProjectionNegative.ps1',
        '.github\workflows\test-all.yml', 'cli\finops\pyproject.toml', 'service\aum\requirements.txt', 'package-lock.json'
    )
    foreach ($file in $files) {
        $destination = Join-Path $sandbox $file
        New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $Root $file) -Destination $destination
    }
    if ($Mode -eq 'Core') {
        Ignore-Guard 'ambiguous registration markers' "'Missing or ambiguous check registration markers.'"
        Ignore-Guard 'literal registration labels' "'Every check registration needs literal name and script arguments.'"
        Ignore-Guard 'literal script containment' "'Invalid literal check identity.'"
        Ignore-Guard 'duplicate registrations' '"Duplicate registered check: $name"'
        Ignore-Guard 'declared skip reasons' '"Skip reason for ''$name'' must have one literal-branch declaration."'
        Ignore-Guard 'empty registration' "'The check registration is empty.'"
        Ignore-Guard 'timing schema and default' "'Invalid timing schema or default weight.'"
        Ignore-Guard 'positive timing weights' "'Every committed timing weight must be a positive number.'"
        Ignore-Guard 'local evidence reason' "'Every local-only check needs a reason.'"
        Ignore-Guard 'registered local evidence' '"Local-only check is not registered: $($entry.Name)"'
        Ignore-Guard 'duplicate local declarations' '"Duplicate local-only entry: $($entry.Name)"'
        Ignore-Guard 'bounded shard count' "'ShardCount must be 1-64 and no greater than the number of CI checks.'"
        Ignore-Guard 'local manifest schema' "'Invalid local-only manifest schema.'"
        Ignore-Guard 'configured integer count' "'ShardCount must be an integer.'"
        Ignore-Guard 'full expected Git IDs' "'Expected commit and tree must be full Git object IDs.'"
        Ignore-Guard 'receipt schema' "'Unsupported receipt schema.'"
        Ignore-Guard 'foreign commit' '"Receipt commit differs from expected commit $Commit."'
        Ignore-Guard 'foreign tree' '"Receipt tree differs from expected tree $Tree."'
        Ignore-Guard 'receipt completion' "'A receipt is not complete.'"
        Ignore-Guard 'integer receipt coordinates' "'Invalid receipt shard coordinates.'"
        Ignore-Guard 'array receipt shape' "'Receipt ownership and results must be JSON arrays, including single-check shards.'"
        Ignore-Guard 'shard coordinate range' "'Receipt shard index is out of range.'"
        Ignore-Guard 'workflow run identity' "'Receipts belong to different workflow runs.'"
        Ignore-Guard 'workflow attempt identity' "'Receipts belong to invalid or different workflow run attempts.'"
        Ignore-Guard 'receipt mode' "'Receipt mode must be ci or local.'"
        Ignore-Guard 'duplicate shard receipt' '"Duplicate shard receipt: $index"'
        Ignore-Guard 'receipt wall duration' "'Invalid receipt wall duration.'"
        Ignore-Guard 'receipt time interval' "'Invalid receipt time interval.'"
        Ignore-Guard 'owned check list' '"Shard $index ownership does not match the committed plan."'
        Ignore-Guard 'registered result' '"Unregistered result: $($result.Name)"'
        Ignore-Guard 'duplicate result' '"Duplicate result: $($result.Name)"'
        Ignore-Guard 'result registration identity' '"Result identity differs from registration: $($result.Name)"'
        Ignore-Guard 'result duration' '"Invalid duration: $($result.Name)"'
        Ignore-Guard 'PASS exit code' '"PASS needs exit code zero: $($result.Name)"'
        Ignore-Guard 'PASS skip reason' '"PASS cannot carry a skip reason: $($result.Name)"'
        Ignore-Guard 'SKIP prerequisite and exit' '"SKIP needs this check''s registered reason and no process exit: $($result.Name)"'
        Ignore-Guard 'failed check' '"Check did not pass (result $($result.Result)): $($result.Name)"'
        Ignore-Guard 'missing shard' '"Missing shard receipt: $i/$ShardCount"'
        Ignore-Guard 'missing local evidence' "'Missing local-only evidence; CI alone is not complete coverage.'"
        Add-Case 'LPT least loaded bin' 'tests\TestAll-Sharding.ps1' '$loads[$i] -lt $loads[$bin]' '$loads[$i] -gt $loads[$bin]' 'Test-TestAllSharding.ps1'
        Add-Case 'committed default weight' 'tests\TestAll-Sharding.ps1' '$weight = $Timing.DefaultSeconds' '$weight = 1' 'Test-TestAllSharding.ps1'
        Add-Case 'committed measured weight' 'tests\TestAll-Sharding.ps1' '$weight = $Timing.Seconds[$key]' '$weight = 1' 'Test-TestAllSharding.ps1'
        Add-Case 'ordered ownership comparison' 'tests\TestAll-Sharding.ps1' '$Left[$i] -cne $Right[$i]' '$false' 'Test-TestAllSharding.ps1'
        Add-Case 'configured shard count' 'tests\TestAll-Sharding.ps1' '$ShardCount = $timing.ShardCount' '$ShardCount = 1' 'Test-TestAllSharding.ps1'
        $remote = 'tests\Invoke-RemoteTestAll.ps1'; $suite = 'Test-RemoteTestAll.ps1'
        Add-Case 'select exact SHA' $remote '$_.head_sha -ceq $Commit' '$true' $suite
        Add-Case 'select exact workflow' $remote '$_.path -ceq ''.github/workflows/test-all.yml''' '$true' $suite
        Add-Case 'select trusted run event' $remote '$_.event -in ''push'', ''workflow_dispatch''' '$true' $suite
        Add-Case 'select newest run' $remote 'Sort-Object { [long]$_.id } -Descending' 'Sort-Object { [long]$_.id }' $suite
        Add-Case 'reject dirty source' $remote 'if ($Identity.Dirty)' 'if ($false)' $suite
        Add-Case 'reject unpushed source' $remote 'if (-not $Pushed)' 'if ($false)' $suite
        Add-Case 'bind completed run SHA' $remote 'if ($Run.head_sha -cne $Commit)' 'if ($false)' $suite
        Add-Case 'require successful complete run' $remote 'throw "Workflow run $($Run.id) is $($Run.status)/$($Run.conclusion), not successful."' '$null = "ignored failure"' $suite
        Add-Case 'require all shard jobs' $remote 'throw "Missing, incomplete or failed shard job: $name"' '$null = "ignored shard"' $suite
        Add-Case 'require successful merge job' $remote "throw 'Missing, incomplete or failed merge job.'" '$null = "ignored merge"' $suite
        Add-Case 'reject extra jobs' $remote "throw 'Unexpected jobs in the test workflow.'" '$null = "ignored extra job"' $suite
        Add-Case 'honor gh failure' $remote 'if ($LASTEXITCODE -ne 0)' 'if ($false)' $suite
        $workflow = '.github\workflows\test-all.yml'
        Add-Case 'pin every action' $workflow 'actions/setup-python@5fda3b95a4ea91299a34e894583c3862153e4b97' 'actions/setup-python@v7' $suite
        Add-Case 'read-only token' $workflow 'contents: read' 'contents: write' $suite
        Add-Case 'release tags and history' $workflow 'fetch-depth: 0' 'fetch-depth: 1' $suite
        Add-Case 'no later shallow fetch' $workflow '$modes = @(' "git fetch --depth=1 origin main`n          `$modes = @(" $suite
        Add-Case 'hosted Windows only' $workflow "runs-on: windows-latest`n    timeout-minutes: 20" "runs-on: self-hosted`n    timeout-minutes: 20" $suite
        Add-Case 'no fail-fast' $workflow 'fail-fast: false' 'fail-fast: true' $suite
        Add-Case 'always evaluate merge' $workflow "`n    if: `${{ always() }}" "`n    if: `${{ success() }}" $suite
        Add-Case 'ref scoped cancellation' $workflow 'cancel-in-progress: true' 'cancel-in-progress: false' $suite
        Add-Case 'approved branch scope' $workflow 'p78-parallel-tests' 'unapproved-branch' $suite
        Add-Case 'complete matrix' $workflow 'shard: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]' 'shard: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10]' $suite
        Add-Case 'FinOps environment creation' $workflow 'python -m venv .venv-finops' 'python -m venv .wrong-finops' $suite
        Add-Case 'AUM environment creation' $workflow 'python -m venv .venv-aum-service' 'python -m venv .wrong-aum' $suite
        Add-Case 'browser runtime installation' $workflow 'npx --no-install playwright install chromium' 'npx --no-install playwright --version' $suite
        Add-Case 'existing setup manifests' $workflow 'tests/requirements-finops.lock' 'tests/missing-finops.lock' $suite
        Add-Case 'wizard uses offline native fixture' 'tests\Test-On-PS51.ps1' 'TestAzureFixture.ps1' 'MissingAzureFixture.ps1' $suite
        Add-Case 'preflight uses offline native fixture' 'tests\Test-PreflightBothHosts.ps1' 'TestAzureFixture.ps1' 'MissingAzureFixture.ps1' $suite
        Add-Case 'projection baseline diagnostic' 'tests\Test-ProjectionNegative.ps1' 'Get-Content -LiteralPath $suiteLog | Write-Host' '$null = "suppressed baseline output"' $suite
        Add-Case 'all hosted proof groups' $workflow "@('Core', 'Runner', 'Wizard')" "@('Core', 'Core', 'Wizard')" $suite
    }
    elseif ($Mode -eq 'Runner') {
        $integrity = [IO.File]::ReadAllText((Join-Path $sandbox 'tests\Test-RunnerIntegrity.ps1')).Replace("`r`n", "`n")
        $prefix = $integrity.Substring(0, $integrity.IndexOf("Write-Host 'Test-All - isolated processes"))
        $miniAt = $integrity.IndexOf('    $mini = With-Checks $source')
        $miniEnd = $integrity.IndexOf('    $r = Invoke-Scenario $mini', $miniAt)
        $mini = $integrity.Substring($miniAt, $miniEnd - $miniAt)
        $at = $integrity.IndexOf('    $shardRuns = @(')
        $end = $integrity.IndexOf("    `$r = Invoke-Scenario `$mini -Options @('-Serial'", $at)
        if ($miniAt -lt 0 -or $at -lt 0 -or $end -lt $at) { throw 'Runner shard test anchors changed.' }
        $body = $prefix + "`ntry {`n" + $mini + $integrity.Substring($at, $end - $at) + @'

} catch { Assert 'P78 scenarios complete' $false $_.Exception.Message }
finally { if (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force } }
if ($fail) { Write-Host "$fail assertion(s) failed."; exit 1 }
Write-Host 'P78 isolated shard scenarios passed.'
exit 0
'@
        [IO.File]::WriteAllText((Join-Path $sandbox 'tests\P78-RunnerShards.ps1'), $body)
        $runner = 'tests\Test-All.ps1'; $suite = 'P78-RunnerShards.ps1'
        $currentRunner = [IO.File]::ReadAllText((Join-Path $sandbox $runner)).Replace("`r`n", "`n")
        $priorRunner = (& git -C $Root show '0345e85020b25d2f3595832b9453a174f253be64:tests/Test-All.ps1' | Out-String).Replace("`r`n", "`n")
        if ($LASTEXITCODE -or $priorRunner.Contains('[int]$ShardCount')) { throw 'The pre-P78 runner could not be read from 0345e85.' }
        Add-Case 'pre-P78 runner has no sharded evidence' $runner $currentRunner $priorRunner $suite
        Add-Case 'all checks wrongly assigned to each shard' $runner '$ownedIds.Contains($check.RegistrationId)' '$true' $suite
        Add-Case 'inverted shard ownership' $runner '$planned.ShardIndex -eq $selectedIndex' '$planned.ShardIndex -ne $selectedIndex' $suite
        Add-Case 'local lane index' $runner '$selectedIndex = -1' '$selectedIndex = 0' $suite
        Add-Case 'invented receipt commit' $runner 'Commit = $identity.Commit; Tree = $identity.Tree;' "Commit = ('c' * 40); Tree = `$identity.Tree;" $suite
        Add-Case 'invented receipt tree' $runner 'Commit = $identity.Commit; Tree = $identity.Tree;' "Commit = `$identity.Commit; Tree = ('c' * 40);" $suite
        Add-Case 'renumbered registration identity' $runner 'RegistrationId = $check.RegistrationId; SkipReason' 'RegistrationId = $check.Id; SkipReason' $suite
        Add-Case 'lost prerequisite reason' $runner "SkipReason = `$(if (`$Status -eq 'SKIP') { `$check.SkipReason } else { '' })" "SkipReason = ''" $suite
        Add-Case 'lost failure exit code' $runner 'Result = $Status; Seconds = $seconds; ExitCode = $ExitCode;' 'Result = $Status; Seconds = $seconds; ExitCode = 0;' $suite
        Add-Case 'ignored source change' $runner 'catch { $completed = $false; Write-Host "Receipt source check failed:' 'catch { Write-Host "Receipt source check failed:' $suite
        Add-Case 'lost exclusive lane' $runner "elseif (`$SerialLane) { 'Exclusive' }" "elseif (`$SerialLane) { 'Parallel' }" $suite
        Add-Case 'missing coordinate pairing' $runner "if (`$PSBoundParameters.ContainsKey('ShardIndex') -xor `$PSBoundParameters.ContainsKey('ShardCount'))" 'if ($false)' $suite
    }
    else {
        Copy-Item -LiteralPath (Join-Path $Root 'Install-ClaudeGateway.ps1') -Destination $sandbox
        Copy-Item -LiteralPath (Join-Path $Root 'scripts') -Destination $sandbox -Recurse
        $fixture = 'tests\TestAzureFixture.ps1'; $suite = 'Test-On-PS51.ps1'
        Add-Case 'failed wizard process' $fixture "`nexit 0`n'@" "`nexit 9`n'@" $suite
        Add-Case 'unexpected native transport' $fixture "`$joined = `$args -join ' '" "`$joined = `$args -join ' '; [IO.File]::WriteAllText(`$env:P78_UNEXPECTED_CALLS, 'unexpected fixture call')" $suite
        Add-Case 'missing summary' 'Install-ClaudeGateway.ps1' "Write-Head 'Summary'" "Write-Head 'No summary'" $suite
        Add-Case 'missing WhatIf stop evidence' 'Install-ClaudeGateway.ps1' 'WhatIf - stopping before any change.' 'Fixture stopped before changes.' $suite
        Add-Case 'native error visible after summary' $fixture "`nexit 0`n'@" "`nWrite-Host 'NativeCommandError: injected fixture diagnostic'`nexit 0`n'@" $suite
        Add-Case 'revocation lookup loses PS51 optional-error guard' 'Install-ClaudeGateway.ps1' '$liveWindow = Invoke-AzOptional { az apim nv show -g $ResourceGroup --service-name $windowTarget --named-value-id entitlement-cache-seconds --query value -o tsv }' '$liveWindow = az apim nv show -g $ResourceGroup --service-name $windowTarget --named-value-id entitlement-cache-seconds --query value -o tsv 2>$null' $suite
        Add-Case 'preflight exit status' $fixture "`nexit 0`n'@" "`nexit 9`n'@" 'Test-PreflightBothHosts.ps1'
        Add-Case 'preflight boolean result missing' $fixture 'Write-Host "RESULT=$result"' 'Write-Host "RESULT="' 'Test-PreflightBothHosts.ps1'
        Add-Case 'preflight HTTP boundary not recorded' $fixture '[IO.File]::AppendAllText((Join-Path $PSScriptRoot ''http.calls''), "management HEAD`n")' '$null = "no HTTP boundary record"' 'Test-PreflightBothHosts.ps1'
    }
    $originals = @{}
    foreach ($file in @($cases.File | Sort-Object -Unique)) {
        $originals[$file] = [IO.File]::ReadAllText((Join-Path $sandbox $file)).Replace("`r`n", "`n")
    }
    foreach ($case in $cases) {
        $matches = [regex]::Matches($originals[$case.File], [regex]::Escape($case.From)).Count
        if ($matches -ne $case.Matches) { throw "Anchor '$($case.Name)' matched $matches instead of $($case.Matches): $($case.From)" }
    }
    $baselines = @{}
    foreach ($suite in @($cases.Suite | Sort-Object -Unique)) {
        $baseline = Measure-Suite $suite ("baseline-$suite.log")
        $baselines[$suite] = $baseline
        Write-Host "BASELINE $suite exit=$($baseline.ExitCode), count=$($baseline.Count), $($baseline.Seconds) s"
        if ($baseline.ExitCode -ne 0 -or $baseline.Count -eq 0) { throw "Baseline failed: $suite; $logs" }
    }
    if ($BaselineOnly) {
        Write-Host "Baselines passed; this invocation contains no negative-proof evidence. $logs"
        return
    }
    $results = [Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $cases.Count; $i++) {
        $case = $cases[$i]; $text = $originals[$case.File]
        $matches = [regex]::Matches($text, [regex]::Escape($case.From)).Count
        if ($matches -ne $case.Matches) { throw "Anchor '$($case.Name)' matched $matches instead of $($case.Matches): $($case.From)" }
        $mutated = $text.Replace($case.From, $case.To)
        if ($case.File.EndsWith('.ps1')) {
            $parseErrors = $null
            $null = [Management.Automation.Language.Parser]::ParseInput($mutated, [ref]$null, [ref]$parseErrors)
            if ($parseErrors.Count) { throw "Invalid mutation syntax: $($case.Name): $($parseErrors[0].Message)" }
        }
        $path = Join-Path $sandbox $case.File
        try {
            [IO.File]::WriteAllText($path, $mutated, [Text.UTF8Encoding]::new($true))
            $result = Measure-Suite $case.Suite ("{0:D2}.log" -f $i)
            $caught = $result.ExitCode -ne 0 -and $result.Count -eq $baselines[$case.Suite].Count -and $result.Failed -gt 0
            $results.Add([pscustomobject]@{ Name = $case.Name; Suite = $case.Suite; Caught = $caught; Observation = $result })
            Write-Host "$(if ($caught) { 'CAUGHT' } else { 'NOT CAUGHT' }) $($case.Name): exit=$($result.ExitCode), count=$($result.Count), failures=$($result.Failed)"
        }
        finally { [IO.File]::WriteAllText($path, $text, [Text.UTF8Encoding]::new($true)) }
    }
    $restored = @{}
    foreach ($suite in $baselines.Keys) {
        $restored[$suite] = Measure-Suite $suite ("restored-$suite.log")
        if ($restored[$suite].ExitCode -ne 0 -or $restored[$suite].Count -ne $baselines[$suite].Count) { throw "Restored suite failed: $suite" }
    }
    [ordered]@{ Mode = $Mode; RecordedAt = [datetime]::UtcNow.ToString('o'); Root = $Root
        Baselines = $baselines; Mutations = $results.ToArray(); Restored = $restored; Logs = $logs
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $EvidenceDirectory "negative-$($Mode.ToLowerInvariant()).txt")
    if (@($results | Where-Object { -not $_.Caught }).Count) { throw "Some mutations did not meet the full-count catch criterion; $logs" }
    Write-Host "P78 ${Mode}: $($results.Count)/$($results.Count) mutations caught with baseline counts; restored suites green. $logs"
}
finally {
    if (Test-Path -LiteralPath $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force }
    if ($ownedLock) {
        if ((Get-Content -LiteralPath $lock -Raw) -cne $token) { throw 'The shared lock changed owner; P78 did not remove it.' }
        Remove-Item -LiteralPath $lock -Force
    }
}
