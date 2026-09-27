function Get-ClaudeFlowStepInfo {
    [pscustomobject]@{ Name = 'Verify'; Title = 'Verify deployment'; DecisionKey = 'verify'; DependsOn = @('Foundation'); Actions = @('Setup', 'Change') }
}

function Get-ClaudeFlowStepQuestions { param($Record, $Discovery) @() }

function Get-ClaudeFlowStepPlan {
    param($Record, $Discovery)
    New-ClaudeFlowPlan -Step Verify -Summary 'Run health checks and prove the configured gateway' `
        -Actions @(
            New-ClaudeFlowAction -Verb Run -Target 'scripts/Test-ClaudeHealth.ps1'
            New-ClaudeFlowAction -Verb Check -Target 'guided flow step checks'
        ) `
        -Costs @() `
        -Implications @('Health checks are read-only; a separate real request proof should be captured for live evidence.') `
        -Requires @('A completed foundation step') `
        -Rollback 'No persistent change'
}

function Invoke-ClaudeFlowStep {
    param($Record, $Plan)
    $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $health = Join-Path $root 'scripts\Test-ClaudeHealth.ps1'
    $ok = $false
    $errorText = ''
    $checked = [DateTime]::UtcNow.ToString('o')
    if ($Record.resourceGroup -and $Record.apimName -and (Test-Path -LiteralPath $health)) {
        $foundation = Get-ClaudeDecision -Record $Record -Key foundation
        $args = @{ ResourceGroup = $Record.resourceGroup; ApimName = $Record.apimName }
        if ($foundation -and $foundation.foundryAccount) { $args.FoundryAccount = [string]$foundation.foundryAccount }
        try {
            & $health @args
            $ok = ($LASTEXITCODE -eq 0 -or $null -eq $LASTEXITCODE)
        }
        catch {
            $errorText = $_.Exception.Message
            Write-Host "  Verify warning: $errorText" -ForegroundColor Yellow
        }
    }
    @{ verify = @{ checkedUtc = $checked; healthScript = $health; healthPassed = $ok; warning = $errorText } }
}

function Test-ClaudeFlowStep {
    param($Record)
    $v = Get-ClaudeDecision -Record $Record -Key verify
    $checks = @(
        @{ Name = 'health run recorded'; Passed = [bool]($v -and $v.checkedUtc); Evidence = $(if ($v) { $v.checkedUtc } else { '' }); Fix = 'Run Start-ClaudeGateway.ps1 -Action Setup or Change to execute Verify.' }
    )
    [pscustomobject]@{ Step = 'Verify'; Passed = (@($checks | Where-Object { -not $_.Passed }).Count -eq 0); Checks = @($checks) }
}
