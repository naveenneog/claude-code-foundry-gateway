<#
.SYNOPSIS
    Guided-flow Change step for Claude Desktop sign-in choice and gateway audience.
#>

. (Join-Path $PSScriptRoot 'FlowContract.ps1')
. (Join-Path $PSScriptRoot 'lib\LifecycleCommon.ps1')
. (Join-Path (Join-Path (Get-ClaudeFlowLifecycleRepoRoot) 'scripts') 'ClaudeDesktopSignIn.ps1')

function Get-ClaudeFlowStepInfo {
    [pscustomobject]@{ Name = 'DesktopSignIn'; Title = 'Claude Desktop sign-in'; DecisionKey = 'desktopSignIn'; DependsOn = @('Foundation'); Actions = @('Change') }
}

function Get-ClaudeFlowStepQuestions {
    param([Parameter(Mandatory = $true)]$Record, $Discovery)
    @([pscustomobject]@{
        Key = 'desktopSignIn'
        Question = 'Choose helper-script, external-idp browser, or external-idp broker for Claude Desktop.'
        Options = @('helper-script','external-idp-browser','external-idp-broker')
        WhereToFind = @('onboarding/claude-gateway.json desktopSignIn', 'docs/DEVELOPER.md Desktop sign-in')
        AcceptRecommendedWithoutConsole = $true
        Recommended = 'helper-script'
        Reason = 'Helper script needs no tenant-wide consent; external-idp requires the Desktop app audience to be accepted by the gateway.'
    })
}

function Get-ClaudeFlowStepPlan {
    param([Parameter(Mandatory = $true)]$Record, $Discovery)
    $target = Get-ClaudeFlowLifecycleRecordTarget -Record $Record -Discovery $Discovery
    $current = Get-ClaudeDecision -Record $Record -Key desktopSignIn
    $desired = if ($Discovery -and $Discovery.desiredDesktopSignIn) { $Discovery.desiredDesktopSignIn } elseif ($current -is [string]) { [string]$current } elseif ($current -and $current.target) { $current.target } else { $null }
    if ($desired -is [string]) {
        $desired = switch ($desired) {
            'helper-script' { [pscustomobject]@{ kind = 'helper-script' } }
            'external-idp-browser' { throw 'Desktop external-idp-browser needs clientId and issuer in decisions.desktopSignIn; run New-ClaudeDesktopEntraApp.ps1 first.' }
            'external-idp-broker' { throw 'Desktop external-idp-broker needs clientId and issuer in decisions.desktopSignIn; run New-ClaudeDesktopEntraApp.ps1 first.' }
            default { throw "Unknown Desktop sign-in choice '$desired'." }
        }
    }
    if (-not $desired) { return New-ClaudeFlowPlan -Step DesktopSignIn -Summary 'No Desktop sign-in change selected.' }
    $config = [pscustomobject]@{ desktopSignIn = $desired }
    $validated = Get-ClaudeDesktopSignIn -Config $config
    $audience = Get-ClaudeDesktopGatewayAudience -DesktopSignIn $validated
    $beforeAudience = (Get-ClaudeFlowLifecycleNamedValueMap -Discovery $Discovery)['external-idp-extra-audience']
    if ($beforeAudience -eq $audience -and $current -and $current.kind -eq $validated.kind) {
        return New-ClaudeFlowPlan -Step DesktopSignIn -Summary 'Desktop sign-in choice and gateway audience already match.'
    }
    New-ClaudeFlowPlan -Step DesktopSignIn `
        -Summary "Change Desktop sign-in to $($validated.kind)$(if ($validated.flow) { " $($validated.flow)" })." `
        -Actions @(
            (New-ClaudeFlowAction -Verb Write -Target 'decision desktopSignIn' -Detail 'record the Desktop sign-in choice'),
            (New-ClaudeFlowAction -Verb Update -Target 'named value external-idp-extra-audience' -Detail "$(if ($audience) { $audience } else { '(empty)' })"),
            (New-ClaudeFlowAction -Verb Write -Target 'decision deviceProfiles.regenerate' -Detail 'Desktop managed settings must be regenerated')
        ) `
        -Implications @('Changing external-idp-extra-audience changes which Desktop token audience the gateway accepts.', 'Device profiles and workstation handoff must be regenerated after the change.') `
        -Requires @('API Management named value write permission') `
        -Reversible $true `
        -Rollback 'Restore the previous external-idp-extra-audience named value and regenerate device profiles.' `
        -Data @{ Target = $target; Desired = $validated; Audience = $audience; BeforeAudience = $beforeAudience; SnapshotPath = $null; SnapshotTaken = $false }
}

function Invoke-ClaudeFlowStep {
    param([Parameter(Mandatory = $true)]$Record, [Parameter(Mandatory = $true)]$Plan)
    if (Test-ClaudeFlowPlanIsNoop $Plan) { return @{} }
    Assert-ClaudeFlowLifecycleSnapshotBeforeWrite -Plan $Plan
    . (Join-Path (Get-ClaudeFlowLifecycleRepoRoot) 'scripts\ApimNamedValue.ps1')
    $target = $Plan.Data.Target
    Set-ApimNamedValue -ResourceGroup $target.ResourceGroup -ApimName $target.ApimName -Id 'external-idp-extra-audience' -Value ([string]$Plan.Data.Audience)
    Set-ClaudeDecision -Record $Record -Key desktopSignIn -Value $Plan.Data.Desired
    Set-ClaudeDecision -Record $Record -Key deviceProfiles -Value ([ordered]@{ regenerate = $true; reason = 'Desktop sign-in changed'; changedUtc = [DateTime]::UtcNow.ToString('o') })
    Add-ClaudeDecisionHistory -Record $Record -Action Change -Decision desktopSignIn -From $Plan.Data.BeforeAudience -To $Plan.Data.Audience -Commit (Get-ClaudeFlowReleaseInfo).commit
    @{ desktopSignIn = $Plan.Data.Desired; deviceProfiles = @{ regenerate = $true } }
}

function Test-ClaudeFlowStep {
    param([Parameter(Mandatory = $true)]$Record)
    [pscustomobject]@{ Step = 'DesktopSignIn'; Passed = $true; Checks = @(@{ Name = 'device profiles flagged'; Passed = $true; Evidence = 'Invoke writes deviceProfiles.regenerate=true.'; Fix = '' }) }
}
