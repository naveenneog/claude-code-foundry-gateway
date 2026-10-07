# Fast remote-boundary tests. All GitHub data below is synthetic.
$ErrorActionPreference = 'Stop'
$fail = 0
function Assert($Name, $Condition, $Detail = '') {
    if ($Condition) { Write-Host "  [OK]   $Name" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $Name - $Detail" -ForegroundColor Red; $script:fail++ }
}
function Rejects($Name, [scriptblock]$Action, [string]$Message) {
    $errorText = ''
    try { & $Action | Out-Null } catch { $errorText = $_.Exception.Message }
    Assert $Name ($errorText -match $Message) $errorText
}

$helper = Join-Path $PSScriptRoot 'Invoke-RemoteTestAll.ps1'
if (-not (Test-Path -LiteralPath $helper)) {
    Write-Host '[FAIL] Invoke-RemoteTestAll.ps1 is missing: exact-SHA remote validation is not implemented.'
    exit 1
}
. $helper
$commit = 'a' * 40
$runs = @(
    [pscustomobject]@{ id = 1; head_sha = $commit; path = '.github/workflows/test-all.yml'; event = 'push'; status = 'completed'; conclusion = 'success' }
    [pscustomobject]@{ id = 6; head_sha = ('b' * 40); path = '.github/workflows/test-all.yml'; event = 'push'; status = 'completed'; conclusion = 'success' }
    [pscustomobject]@{ id = 7; head_sha = $commit; path = '.github/workflows/other.yml'; event = 'push'; status = 'completed'; conclusion = 'success' }
    [pscustomobject]@{ id = 8; head_sha = $commit; path = '.github/workflows/test-all.yml'; event = 'pull_request'; status = 'completed'; conclusion = 'success' }
    [pscustomobject]@{ id = 5; head_sha = $commit; path = '.github/workflows/test-all.yml'; event = 'workflow_dispatch'; status = 'in_progress'; conclusion = $null }
)
$chosen = Get-RemoteTestAllRun -Runs $runs -Commit $commit
Assert 'only the exact-SHA test workflow is selected, newest attempt first' ($chosen.id -eq 5)
Assert 'no matching run is distinct from a successful run' (
    $null -eq (Get-RemoteTestAllRun -Runs $runs -Commit ('c' * 40)))
$runs[4].status = 'completed'; $runs[4].conclusion = 'failure'
Assert 'a newer failure cannot be hidden by an older green run' (
    (Get-RemoteTestAllRun -Runs $runs -Commit $commit).conclusion -eq 'failure')

$run = [pscustomobject]@{ id = 42; head_sha = $commit; run_attempt = 1; status = 'completed'; conclusion = 'success' }
$jobs = @(
    [pscustomobject]@{ name = 'Test-All shard 0/2'; status = 'completed'; conclusion = 'success' }
    [pscustomobject]@{ name = 'Test-All shard 1/2'; status = 'completed'; conclusion = 'success' }
    [pscustomobject]@{ name = 'Merge Test-All receipts'; status = 'completed'; conclusion = 'success' }
)
Assert-RemoteTestAllJobs -Run $run -Jobs $jobs -Commit $commit -ShardCount 2
Assert 'successful shards plus merge are accepted' $true
Rejects 'the remote run must name the exact commit' {
    Assert-RemoteTestAllJobs $run $jobs ('d' * 40) 2
} 'commit'
Rejects 'every shard job must be present' { Assert-RemoteTestAllJobs $run @($jobs[0], $jobs[2]) $commit 2 } 'shard'
Rejects 'duplicate jobs are not coverage' { Assert-RemoteTestAllJobs $run @($jobs + $jobs[0]) $commit 2 } 'duplicate'
Rejects 'the merge job must be present' { Assert-RemoteTestAllJobs $run @($jobs[0], $jobs[1]) $commit 2 } 'merge'
$jobs[1].conclusion = 'failure'
Rejects 'a failed shard fails even if the overall run says success' {
    Assert-RemoteTestAllJobs $run $jobs $commit 2
} 'shard'
$jobs[1].conclusion = 'skipped'
Rejects 'a skipped shard is missing evidence' { Assert-RemoteTestAllJobs $run $jobs $commit 2 } 'shard'
$jobs[1].conclusion = 'success'; $jobs[2].conclusion = 'failure'
Rejects 'a failed coverage merge fails the remote helper' {
    Assert-RemoteTestAllJobs $run $jobs $commit 2
} 'merge'
$jobs[2].conclusion = 'success'; $run.conclusion = 'cancelled'
Rejects 'cancellation is never retried into a false pass' {
    Assert-RemoteTestAllJobs $run $jobs $commit 2
} 'run'
$run.conclusion = 'success'; $run.status = 'in_progress'
Rejects 'a successful conclusion cannot hide an incomplete run' {
    Assert-RemoteTestAllJobs $run $jobs $commit 2
} 'run'
$run.status = 'completed'; $jobs[1].status = 'in_progress'
Rejects 'a successful conclusion cannot hide an incomplete shard' {
    Assert-RemoteTestAllJobs $run $jobs $commit 2
} 'shard'
$jobs[1].status = 'completed'; $jobs[2].status = 'in_progress'
Rejects 'a successful conclusion cannot hide an incomplete merge' {
    Assert-RemoteTestAllJobs $run $jobs $commit 2
} 'merge'
$jobs[2].status = 'completed'
$extra = [pscustomobject]@{ name = 'unregistered job'; status = 'completed'; conclusion = 'success' }
Rejects 'an extra workflow job is not part of the expected execution' {
    Assert-RemoteTestAllJobs $run @($jobs + $extra) $commit 2
} 'Unexpected'

function gh { $global:LASTEXITCODE = $script:ghExit; $script:ghArguments = @($args); 'fixture gh response' }
$script:ghExit = 0
Assert 'the gh boundary preserves successful output and argument boundaries' (
    (Invoke-RemoteGh @('api', 'fixture path', '--paginate')) -ceq 'fixture gh response' -and
    ($script:ghArguments -join '|') -ceq 'api|fixture path|--paginate')
$script:ghExit = 9
Rejects 'a failed gh request is not interpreted as successful JSON or artifact evidence' {
    Invoke-RemoteGh @('api', 'fixture path')
} 'gh api failed'
Remove-Item Function:\gh

$identity = [pscustomobject]@{ Commit = $commit; Tree = ('b' * 40); Dirty = $false }
Assert-RemoteTestAllSource -Identity $identity -Pushed $true
Assert 'a clean pushed source is accepted' $true
$identity.Dirty = $true
Rejects 'a dirty tree fails before consulting a workflow' {
    Assert-RemoteTestAllSource -Identity $identity -Pushed $true
} 'dirty'
$identity.Dirty = $false
Rejects 'an unpushed commit fails before dispatch' {
    Assert-RemoteTestAllSource -Identity $identity -Pushed $false
} 'pushed'

$wizard = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Test-On-PS51.ps1'))
$fixturePath = Join-Path $PSScriptRoot 'TestAzureFixture.ps1'
$nativeFixture = if (Test-Path -LiteralPath $fixturePath) { [IO.File]::ReadAllText($fixturePath) } else { '' }
Assert 'the PS 5.1 wizard retains a native shim with isolated configuration and transport records' (
    $wizard.Contains('TestAzureFixture.ps1') -and $nativeFixture.Contains("Join-Path `$scratch 'az.cmd'") -and
    $nativeFixture.Contains('AZURE_CONFIG_DIR') -and $nativeFixture.Contains('P78_AZ_CALLS') -and
    $nativeFixture.Contains('P78_UNEXPECTED_CALLS') -and $nativeFixture -notmatch 'function\s+(?:global:)?az\s*\{')
$preflight = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Test-PreflightBothHosts.ps1'))
Assert 'both-host preflight uses the same offline native and HTTP boundary' (
    $preflight.Contains('TestAzureFixture.ps1') -and $nativeFixture.Contains('function Invoke-WebRequest') -and
    $nativeFixture.Contains('function Invoke-RestMethod'))
$projection = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Test-ProjectionNegative.ps1'))
Assert 'a failed projection baseline preserves the diagnostic instead of suppressing the cause' (
    $projection -match '(?s)if \(\(Run-Suite \$suite\) -ne 0\) \{\s+Get-Content -LiteralPath \$suiteLog \| Write-Host\s+throw' -and
    $projection -match 'node --test --test-timeout=1500 --test-reporter=tap .+>\s*\$suiteLog' -and
    $projection -match 'node --test --test-timeout=120000 --test-force-exit --test-reporter=tap @processes \*>>\s*\$suiteLog' -and
    $projection -match '\$processes = @\(\$tests \| Where-Object Name -in \$cli \| ForEach-Object FullName\)')
# Node 22 applies --test-timeout to a whole file, and a file that starts processes needs more than 1.5 s on a
# busy hosted runner (job-settings.test.mjs timed out there at 1,501 ms), so it runs in the long-timeout group.
$repoRoot = Split-Path $PSScriptRoot -Parent
$processGroup = [regex]::Match($projection, '(?m)^\s*\$cli = @\((?<names>[^)]*)\)')
$processNames = @([regex]::Matches($processGroup.Groups['names'].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
$startsProcesses = @(foreach ($package in 'resolver', 'sync') {
    Get-ChildItem -LiteralPath (Join-Path $repoRoot "$package\test") -Filter '*.test.mjs' -File |
        Where-Object { [IO.File]::ReadAllText($_.FullName) -match "from\s+['""](?:node:)?child_process['""]" } |
        ForEach-Object Name
})
$inUnitGroup = @($startsProcesses | Where-Object { $_ -cnotin $processNames })
Assert 'every projection test file that starts processes runs in the long-timeout group' (
    $processGroup.Success -and $startsProcesses -ccontains 'apply-projection-cli.test.mjs' -and -not $inUnitGroup.Count
) "in the 1.5 s unit group: $($inUnitGroup -join ', ')"

$workflowPath = Join-Path (Split-Path $PSScriptRoot -Parent) '.github\workflows\test-all.yml'
Assert 'the hosted workflow exists' (Test-Path -LiteralPath $workflowPath)
if (Test-Path -LiteralPath $workflowPath) {
    $workflow = [IO.File]::ReadAllText($workflowPath)
    $uses = @([regex]::Matches($workflow, '(?m)^\s*-?\s*uses:\s*(\S+)'))
    Assert 'all Actions references are pinned to full commit SHAs' (
        $uses.Count -ge 5 -and @($uses | Where-Object { $_.Groups[1].Value -cnotmatch '^[\w/-]+@[a-f0-9]{40}$' }).Count -eq 0)
    Assert 'the tested checkout retains release tags and their reachable history' (
        $workflow -match '(?s)ref: \$\{\{ github\.sha \}\}\s+fetch-depth: 0\s+persist-credentials: false' -and
        $workflow -notmatch 'git fetch[^\r\n]*--depth')
    Assert 'workflow tokens are read-only and no secret or privileged PR context is used' (
        $workflow -match '(?m)^permissions:\s*\r?\n\s+contents: read\s*$' -and
        $workflow -notmatch 'secrets\.|pull_request_target|azure/login|contents: write|actions: write')
    Assert 'each shard uses a hosted Windows VM and is not fail-fast' (
        [regex]::Matches($workflow, '(?m)^\s+runs-on: windows-latest\s*$').Count -eq 2 -and
        $workflow -notmatch 'self-hosted' -and $workflow -match 'fail-fast: false')
    Assert 'the merge evaluates failure paths and artifacts upload even after failure' (
        [regex]::Matches($workflow, 'if: \$\{\{ always\(\) \}\}').Count -eq 3 -and
        $workflow -match '(?m)^    if: \$\{\{ always\(\) \}\}\s*$')
    Assert 'CI runs all infrastructure negative proofs rather than baseline-only diagnostics' (
        $workflow.Contains('Test-InfrastructureProof.ps1') -and
        $workflow.Contains("@('Core', 'Runner', 'Wizard')") -and
        $workflow.Contains('matrix.shard < 3') -and
        $workflow -notmatch 'BaselineOnly|continue-on-error')
    Assert 'superseded runs are cancelled per ref' (
        $workflow -match 'group:.*github\.ref' -and $workflow -match 'cancel-in-progress: true')
    Assert 'push is limited to main and approved P78 branches, with PR and dispatch enabled' (
        $workflow -match 'push:' -and $workflow.Contains('p78-parallel-tests') -and
        $workflow.Contains('p78-ci-experiment-*') -and -not $workflow.Contains('p[0-9]*-*') -and
        $workflow -match 'pull_request:' -and $workflow -match 'workflow_dispatch:')
    $timing = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'test-all-durations.json') -Raw | ConvertFrom-Json
    $matrix = [regex]::Match($workflow, 'shard:\s*\[([\d,\s]+)\]')
    $indices = @($matrix.Groups[1].Value -split ',' | ForEach-Object { [int]$_.Trim() })
    Assert 'the committed timing table and workflow agree on every shard index' (
        $matrix.Success -and ($indices -join ',') -ceq ((0..($timing.ShardCount - 1)) -join ',') -and
        $workflow.Contains("-ShardCount $($timing.ShardCount)"))
    Assert 'both worktree Python environments and manifest-keyed pip/npm caches are wired' (
        $workflow -match '(?m)^\s+python -m venv \.venv-finops\s*$' -and
        $workflow -match '(?m)^\s+python -m venv \.venv-aum-service\s*$' -and
        $workflow -match '(?m)^\s+\.\\\.venv-finops\\Scripts\\python\.exe -m pip install .+cli\\finops\[test\]' -and
        $workflow -match '(?m)^\s+\.\\\.venv-aum-service\\Scripts\\python\.exe -m pip install .+service\\aum\\requirements\.txt' -and
        $workflow -match 'cache: pip' -and
        $workflow -match 'cache: npm' -and $workflow.Contains('cli/finops/pyproject.toml') -and
        $workflow.Contains('service/aum/requirements.txt') -and $workflow.Contains('package-lock.json'))
    Assert 'the actual Playwright Chromium executable is installed for offline browser checks' (
        $workflow -match '(?m)^\s+npx --no-install playwright install chromium\s*$' -and
        $workflow -match "if \(\`$LASTEXITCODE\) \{ throw 'Playwright Chromium installation failed\.' \}")
    $manifestPaths = @([regex]::Matches($workflow, '(?:tests[\\/][\w-]+\.lock|cli/finops/pyproject\.toml|service/aum/requirements\.txt|package-lock\.json)') |
        ForEach-Object { $_.Value.Replace('/', '\') } | Sort-Object -Unique)
    Assert 'every referenced dependency manifest exists in the checkout' (
        $manifestPaths.Count -ge 3 -and @($manifestPaths | Where-Object {
            -not (Test-Path -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) $_))
        }).Count -eq 0)
}

if ($fail) { Write-Host "$fail remote assertion(s) failed."; exit 1 }
Write-Host 'Remote exact-source and hosted-workflow contracts passed.' -ForegroundColor Green
exit 0
