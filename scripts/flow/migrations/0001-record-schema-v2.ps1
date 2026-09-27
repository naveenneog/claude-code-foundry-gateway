<#
.SYNOPSIS
    Migration 0001: bring schema-version 1 decision records to ADR-0030 schema version 2.
#>

function Get-ClaudeFlowMigrationInfo {
    [pscustomobject]@{
        Name = '0001-record-schema-v2'
        Title = 'Upgrade decision record schema'
        DecisionKey = 'record'
        DependsOn = @()
        Actions = @('Update')
    }
}

function Get-ClaudeFlowMigrationPlan {
    param([Parameter(Mandatory = $true)]$Record, $Discovery)
    $version = Get-ClaudeDecisionRecordVersion -Record $Record
    if ($version -ge 2 -and $Record.release) {
        return New-ClaudeFlowPlan -Step '0001-record-schema-v2' -Summary 'Decision record already uses schema version 2.'
    }
    New-ClaudeFlowPlan -Step '0001-record-schema-v2' `
        -Summary 'Rewrite the decision record to schemaVersion 2, preserving unknown legacy fields.' `
        -Actions @((New-ClaudeFlowAction -Verb Migrate -Target 'onboarding/claude-gateway.json' -Detail "schemaVersion $version -> 2")) `
        -Implications @('No Azure resource changes. Unknown legacy fields are preserved beside the new decisions/release/history fields.') `
        -Requires @('Writable decision record') `
        -Reversible $true `
        -Rollback 'Restore the previous claude-gateway.json from source control or the operator backup.' `
        -Data @{ FromVersion = $version; ToVersion = 2 }
}

function Invoke-ClaudeFlowMigration {
    param([Parameter(Mandatory = $true)]$Record, [Parameter(Mandatory = $true)]$Plan)
    if (Test-ClaudeFlowPlanIsNoop $Plan) { return @{} }
    Set-ClaudeRecordProperty $Record 'schemaVersion' 2
    if (-not ($Record.PSObject.Properties.Name -contains 'decisions') -or $null -eq $Record.decisions) {
        Set-ClaudeRecordProperty $Record 'decisions' ([pscustomobject]@{})
    }
    $release = Get-ClaudeFlowReleaseInfo
    Set-ClaudeDecisionRelease -Record $Record -Version $release.version -Commit $release.commit
    Add-ClaudeDecisionHistory -Record $Record -Action Update -Decision record -From $Plan.Data.FromVersion -To 2 -Commit $release.commit
    @{ record = 'schema-v2' }
}

function Test-ClaudeFlowMigration {
    param([Parameter(Mandatory = $true)]$Record, $Discovery)
    $passed = (Get-ClaudeDecisionRecordVersion -Record $Record) -eq 2
    [pscustomobject]@{
        Step = '0001-record-schema-v2'
        Passed = $passed
        Checks = @(@{ Name = 'schemaVersion'; Passed = $passed; Evidence = "schemaVersion=$($Record.schemaVersion)"; Fix = 'Re-run Update-ClaudeGateway.ps1.' })
    }
}
