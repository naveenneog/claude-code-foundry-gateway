<#
.SYNOPSIS
Waits for complete hosted Test-All evidence for this clean, pushed HEAD.
.DESCRIPTION
Uses the GitHub CLI's existing authentication. Never pushes, changes Azure, or runs local checks.
#>
param(
    [ValidateRange(1, 120)][int]$WaitMinutes = 30,
    [ValidateRange(5, 120)][int]$PollSeconds = 30,
    [long]$RunId = 0,
    [string]$ArtifactDirectory,
    [string]$LocalReceiptDirectory
)

function Get-RemoteTestAllRun {
    param([object[]]$Runs, [string]$Commit)
    $Runs | Where-Object {
        $_.head_sha -ceq $Commit -and $_.path -ceq '.github/workflows/test-all.yml' -and
        $_.event -in 'push', 'workflow_dispatch'
    } | Sort-Object { [long]$_.id } -Descending | Select-Object -First 1
}

function Assert-RemoteTestAllSource {
    param($Identity, [bool]$Pushed)
    if ($Identity.Dirty) { throw 'The tree is dirty; remote evidence must describe the current source.' }
    if (-not $Pushed) { throw 'HEAD is not pushed to origin. Push this branch, then request remote evidence.' }
}

function Assert-RemoteTestAllJobs {
    param($Run, [object[]]$Jobs, [string]$Commit, [int]$ShardCount)
    if ($Run.head_sha -cne $Commit) { throw 'The workflow run is for another commit.' }
    if ($Run.status -cne 'completed' -or $Run.conclusion -cne 'success') {
        throw "Workflow run $($Run.id) is $($Run.status)/$($Run.conclusion), not successful."
    }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($job in $Jobs) { if (-not $seen.Add($job.name)) { throw "Duplicate workflow job: $($job.name)" } }
    for ($index = 0; $index -lt $ShardCount; $index++) {
        $name = "Test-All shard $index/$ShardCount"
        $job = @($Jobs | Where-Object name -CEQ $name)
        if ($job.Count -ne 1 -or $job[0].status -cne 'completed' -or $job[0].conclusion -cne 'success') {
            throw "Missing, incomplete or failed shard job: $name"
        }
    }
    $merge = @($Jobs | Where-Object name -CEQ 'Merge Test-All receipts')
    if ($merge.Count -ne 1 -or $merge[0].status -cne 'completed' -or $merge[0].conclusion -cne 'success') {
        throw 'Missing, incomplete or failed merge job.'
    }
    if ($Jobs.Count -ne $ShardCount + 1) { throw 'Unexpected jobs in the test workflow.' }
}

function Invoke-RemoteGh {
    param([string[]]$Arguments)
    $output = & gh @Arguments 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "gh $($Arguments[0]) failed: $($output.Trim())" }
    $output.Trim()
}

function Find-RemoteTestAllRun {
    param([string]$Repository, [string]$Commit)
    $pages = Invoke-RemoteGh @('api', "repos/$Repository/actions/runs?head_sha=$Commit&per_page=100", '--paginate', '--slurp') | ConvertFrom-Json
    Get-RemoteTestAllRun -Runs @($pages | ForEach-Object workflow_runs) -Commit $Commit
}

if ($MyInvocation.InvocationName -eq '.') { return }
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestAll-Sharding.ps1')
try {
    $root = Split-Path $PSScriptRoot -Parent
    $identity = Get-TestAllIdentity -Root $root -RequireClean
    $origin = Invoke-TestAllGit $root @('remote', 'get-url', 'origin')
    if ($origin -notmatch '^(?:https://github\.com/|git@github\.com:)([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+?)(?:\.git)?/?$') {
        throw 'origin must be a GitHub HTTPS or SSH repository URL.'
    }
    $repository = $Matches[1]
    $branch = Invoke-TestAllGit $root @('symbolic-ref', '--quiet', '--short', 'HEAD')
    $remoteRef = "refs/heads/$branch"
    $remote = Invoke-TestAllGit $root @('ls-remote', '--heads', 'origin', $remoteRef)
    $remoteCommit = if ($remote) { ($remote -split '\s+')[0] } else { '' }
    $pushed = $remoteCommit -ceq $identity.Commit
    if ($remoteCommit -and -not $pushed) {
        # An older clean HEAD may have a valid run, but must be reachable from origin.
        Invoke-TestAllGit $root @('fetch', '--quiet', 'origin', $remoteRef) | Out-Null
        & git -C $root merge-base --is-ancestor $identity.Commit FETCH_HEAD
        if ($LASTEXITCODE -notin 0, 1) { throw 'Could not establish whether HEAD is on origin.' }
        $pushed = $LASTEXITCODE -eq 0
    }
    Assert-RemoteTestAllSource -Identity $identity -Pushed $pushed
    $config = Get-TestAllConfiguration
    $estimate = 180 + (($config.Plan | Where-Object ShardIndex -ge 0 | Group-Object ShardIndex |
        ForEach-Object { ($_.Group | Measure-Object EstimatedSeconds -Sum).Sum } | Measure-Object -Maximum).Maximum)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    if ($RunId) {
        $run = Invoke-RemoteGh @('api', "repos/$repository/actions/runs/$RunId") | ConvertFrom-Json
        if (-not (Get-RemoteTestAllRun -Runs @($run) -Commit $identity.Commit)) { throw 'Requested run is not this exact-commit test workflow.' }
    }
    else { $run = Find-RemoteTestAllRun $repository $identity.Commit }
    if (-not $run) {
        if ($remoteCommit -cne $identity.Commit) { throw 'No exact-SHA run exists and the remote branch has advanced; cannot dispatch a different SHA.' }
        Write-Host "Dispatching Test-All for $($identity.Commit) on $branch."
        Invoke-RemoteGh @('workflow', 'run', 'test-all.yml', '--repo', $repository, '--ref', $branch,
            '-f', "expected_sha=$($identity.Commit)") | Out-Host
        $dispatchDeadline = [datetime]::UtcNow.AddSeconds(120)
        while (-not $run -and [datetime]::UtcNow -lt $dispatchDeadline) {
            Write-Host "Waiting for the exact-SHA dispatch to appear; next check in $PollSeconds s."
            Start-Sleep -Seconds $PollSeconds
            $run = Find-RemoteTestAllRun $repository $identity.Commit
        }
        if (-not $run) { throw 'The dispatch did not produce a run for the requested SHA within 120 s. The branch may have moved.' }
    }
    $runUrl = $run.html_url
    Write-Host "Remote Test-All: $runUrl"
    Write-Host ("Initial estimate: about {0:N0} minutes including setup, plus any runner queue." -f ($estimate / 60))
    while ($run.status -cne 'completed') {
        if ($watch.Elapsed.TotalMinutes -ge $WaitMinutes) { throw "Remote wait exceeded $WaitMinutes minutes; inspect $runUrl. Hosted job timeouts still apply." }
        $pages = Invoke-RemoteGh @('api', "repos/$repository/actions/runs/$($run.id)/jobs?per_page=100", '--paginate', '--slurp') | ConvertFrom-Json
        $jobs = @($pages | ForEach-Object jobs)
        $done = @($jobs | Where-Object status -eq 'completed').Count
        $remaining = $estimate - $watch.Elapsed.TotalSeconds
        $estimateText = if ($remaining -gt 0) { "about $([math]::Ceiling($remaining / 60)) min remaining, excluding queue" } else { 'past the initial estimate; still waiting for GitHub' }
        Write-Host ("{0}/{1} jobs complete; {2:N0} s waiting; {3}; next check in {4} s." -f $done, ($config.ShardCount + 1), $watch.Elapsed.TotalSeconds, $estimateText, $PollSeconds)
        Start-Sleep -Seconds $PollSeconds
        $run = Invoke-RemoteGh @('api', "repos/$repository/actions/runs/$($run.id)") | ConvertFrom-Json
        if ($run.head_sha -cne $identity.Commit) { throw 'Workflow commit changed while waiting.' }
    }
    $attempt = [int]$run.run_attempt
    $pages = Invoke-RemoteGh @('api', "repos/$repository/actions/runs/$($run.id)/attempts/$attempt/jobs?per_page=100", '--paginate', '--slurp') | ConvertFrom-Json
    $jobs = @($pages | ForEach-Object jobs)
    Assert-RemoteTestAllJobs -Run $run -Jobs $jobs -Commit $identity.Commit -ShardCount $config.ShardCount
    $after = Get-TestAllIdentity -Root $root -RequireClean
    if ($after.Commit -cne $identity.Commit -or $after.Tree -cne $identity.Tree) { throw 'HEAD changed while waiting; this run cannot gate the new source.' }
    if (-not $ArtifactDirectory) {
        $ArtifactDirectory = Join-Path ([IO.Path]::GetTempPath()) ("test-all-remote-$($run.id)-" + [guid]::NewGuid().ToString('N'))
    }
    if ((Test-Path -LiteralPath $ArtifactDirectory) -and @(Get-ChildItem -LiteralPath $ArtifactDirectory -Force).Count) {
        throw 'ArtifactDirectory must be new or empty; stale receipts cannot be reused.'
    }
    $raw = Join-Path $ArtifactDirectory 'receipts'
    New-Item -ItemType Directory -Path $raw -Force | Out-Null
    Invoke-RemoteGh @('run', 'download', [string]$run.id, '--repo', $repository,
        '--pattern', "test-all-attempt-$attempt-shard-*", '--dir', $raw) | Out-Host
    if ($LocalReceiptDirectory) {
        $localTarget = Join-Path $raw 'local'
        New-Item -ItemType Directory -Path $localTarget | Out-Null
        Get-ChildItem -LiteralPath $LocalReceiptDirectory -Filter '*.json' -File |
            Copy-Item -Destination $localTarget
    }
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Merge-TestAllReceipts.ps1') -ReceiptDirectory $raw `
        -ExpectedCommit $identity.Commit -ExpectedTree $identity.Tree -RunId ([string]$run.id) -RunAttempt $attempt `
        -OutputPath (Join-Path $ArtifactDirectory 'merged.json')
    if ($LASTEXITCODE) { throw 'Downloaded receipt coverage failed; see the merge diagnostic above.' }
    $finished = ($jobs | Where-Object name -CEQ 'Merge Test-All receipts').completed_at
    $wall = ([datetimeoffset]$finished - [datetimeoffset]$run.created_at).TotalSeconds
    $times = [ordered]@{
        RunUrl = $runUrl; RunId = $run.id; RunAttempt = $attempt; Commit = $identity.Commit; Tree = $identity.Tree
        QueuedAt = $run.created_at; FinishedAt = $finished; WallSeconds = $wall
        Jobs = @($jobs | ForEach-Object {
            [ordered]@{ Name = $_.name; StartedAt = $_.started_at; FinishedAt = $_.completed_at
                Seconds = ([datetimeoffset]$_.completed_at - [datetimeoffset]$_.started_at).TotalSeconds }
        })
    }
    $times | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $ArtifactDirectory 'workflow-times.json') -Encoding utf8
    Write-Host ("CI wall (queue to merge end): {0:N1} s. Exact-source coverage passed: {1}" -f $wall, $runUrl)
    Write-Host "Evidence retained in $ArtifactDirectory"
    exit 0
}
catch { Write-Host "Remote Test-All failed: $($_.Exception.Message)" -ForegroundColor Red; exit 1 }
