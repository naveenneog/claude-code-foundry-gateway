<#
.SYNOPSIS
    Migration 0003: report and update lifecycle job definitions that pin repository commits.
#>

function Get-ClaudeFlowMigrationInfo {
    [pscustomobject]@{
        Name = '0003-job-pins'
        Title = 'Update optional job commit pins'
        DecisionKey = 'jobs'
        DependsOn = @('0002-policy-and-named-values')
        Actions = @('Update')
    }
}

function Get-ClaudeFlowMigrationPlan {
    param([Parameter(Mandatory = $true)]$Record, $Discovery)
    $release = Get-ClaudeFlowReleaseInfo
    $required = @()
    if ($Discovery -and $Discovery.PSObject.Properties.Name -contains 'requiredJobs') { $required = @($Discovery.requiredJobs) }
    elseif ($Discovery -and $Discovery.PSObject.Properties.Name -contains 'jobs') { $required = @($Discovery.jobs | Where-Object { $_.commit }) }
    $behind = @($required | Where-Object { $_.commit -and $_.commit -ne $release.commit })
    if (-not $behind.Count) { return New-ClaudeFlowPlan -Step '0003-job-pins' -Summary 'No optional job definitions with older commit pins were discovered.' }
    $actions = @($behind | ForEach-Object { New-ClaudeFlowAction -Verb Update -Target "job $($_.name)" -Detail "commit $($_.commit) -> $($release.commit)" })
    New-ClaudeFlowPlan -Step '0003-job-pins' `
        -Summary 'Repin optional Turnstile/AUM/chargeback jobs that run repository code.' `
        -Actions $actions `
        -Implications @('Only jobs discovered in the estate are changed; absent jobs are not created.', 'A named-value snapshot is still taken first so governance values can be restored with the same rollback file.') `
        -Requires @('Job operator permission on discovered jobs') `
        -Reversible $true `
        -Rollback 'Repin the job to its previous commit or redeploy it from its owning script.' `
        -Data @{ JobsBehind = $behind; TargetCommit = $release.commit; Target = Get-ClaudeFlowRecordTarget -Record $Record -Discovery $Discovery }
}

function Invoke-ClaudeFlowMigration {
    param([Parameter(Mandatory = $true)]$Record, [Parameter(Mandatory = $true)]$Plan)
    if (Test-ClaudeFlowPlanIsNoop $Plan) { return @{} }
    Assert-ClaudeFlowSnapshotBeforeWrite -Plan $Plan
    foreach ($job in @($Plan.Data.JobsBehind)) {
        if ($job.updateCommand) {
            Invoke-Expression ([string]$job.updateCommand)
        }
        else {
            Write-Warning "Job '$($job.name)' is behind but no updateCommand was discovered; leaving it unchanged."
        }
    }
    Add-ClaudeDecisionHistory -Record $Record -Action Update -Decision jobs -From (@($Plan.Data.JobsBehind | ForEach-Object commit) -join ',') -To $Plan.Data.TargetCommit -Commit $Plan.Data.TargetCommit
    @{ jobs = @($Plan.Data.JobsBehind | ForEach-Object name) }
}

function Test-ClaudeFlowMigration {
    param([Parameter(Mandatory = $true)]$Record, $Discovery)
    $release = Get-ClaudeFlowReleaseInfo
    $jobs = if ($Discovery -and $Discovery.jobs) { @($Discovery.jobs) } else { @() }
    $behind = @($jobs | Where-Object { $_.commit -and $_.commit -ne $release.commit })
    [pscustomobject]@{
        Step = '0003-job-pins'
        Passed = ($behind.Count -eq 0)
        Checks = @(@{ Name = 'job commit pins'; Passed = ($behind.Count -eq 0); Evidence = "behind=$($behind.Count)"; Fix = 'Apply job-pin migration or rerun the owning deploy script.' })
    }
}
