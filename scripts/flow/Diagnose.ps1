<#
.SYNOPSIS
    Guided-flow Diagnose step. Plans are read-only; apply runs diagnostics.
#>

if (-not (Get-Command New-ClaudeFlowPlan -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'FlowContract.ps1')
}

function Get-ClaudeFlowStepInfo {
    [pscustomobject]@{
        Name = 'Diagnose'
        Title = 'Diagnose gateway and workstation setup'
        DecisionKey = 'diagnostics'
        DependsOn = @()
        Actions = @('Diagnose','Status','Guide')
    }
}

function Get-ClaudeFlowStepQuestions {
    param($Record, $Discovery)
    @()
}

function Get-ClaudeFlowStepPlan {
    param($Record, $Discovery)
    New-ClaudeFlowPlan -Step 'Diagnose' -Summary 'Run read-only administrator and developer workstation diagnostics' -Actions @(
        (New-ClaudeFlowAction -Verb Check -Target 'Gateway setup' -Detail 'Decision record, APIM, policy, entitlement, budgets, FinOps, workbooks, reports and bypass principals'),
        (New-ClaudeFlowAction -Verb Check -Target 'Developer workstation' -Detail 'Azure CLI, Claude Code, managed settings, VS Code, Desktop and network path')
    ) -Costs @() -Implications @('No Azure resource writes are made. One request is sent unless -NoRequest is supplied by the caller.') -Requires @('Reader on APIM/Foundry for setup checks; local user access for workstation checks') -Reversible $true -Rollback 'No rollback needed; checks are read-only.'
}

function Invoke-ClaudeFlowStep {
    param(
        $Record,
        $Plan,
        [switch]$NoRequest
    )
    $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $results = @()
    $setup = Join-Path $root 'scripts\Debug-ClaudeSetup.ps1'
    $workstation = Join-Path $root 'scripts\Debug-ClaudeWorkstation.ps1'
    if (Test-Path $setup) {
        $scriptParams = @{}
        if ($Record.resourceGroup) { $scriptParams.ResourceGroup = [string]$Record.resourceGroup }
        if ($Record.apimName) { $scriptParams.ApimName = [string]$Record.apimName }
        if ($Record.gatewayUrl) { $scriptParams.GatewayUrl = [string]$Record.gatewayUrl }
        if ($NoRequest) { $scriptParams.NoRequest = $true }
        $text = & $setup @scriptParams *>&1 | Out-String
        $results += [pscustomobject]@{ Scope='setup'; ExitCode=$LASTEXITCODE; Output=$text }
    }
    if (Test-Path $workstation) {
        $scriptParams = @{}
        if ($Record.gatewayUrl) { $scriptParams.GatewayUrl = [string]$Record.gatewayUrl }
        if ($Record.tenantId) { $scriptParams.TenantId = [string]$Record.tenantId }
        if ($NoRequest) { $scriptParams.NoRequest = $true }
        $text = & $workstation @scriptParams *>&1 | Out-String
        $results += [pscustomobject]@{ Scope='workstation'; ExitCode=$LASTEXITCODE; Output=$text }
    }
    @{ DecisionChanges = @{}; Results = @($results) }
}

function Test-ClaudeFlowStep {
    param($Record)
    [pscustomobject]@{
        Step = 'Diagnose'
        Passed = $true
        Checks = @(
            @{ Name='Diagnostics scripts exist'; Passed=((Test-Path (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'scripts\Debug-ClaudeSetup.ps1')) -and (Test-Path (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'scripts\Debug-ClaudeWorkstation.ps1'))); Evidence='Admin and workstation scripts are present.'; Fix='Restore scripts/Debug-ClaudeSetup.ps1 and scripts/Debug-ClaudeWorkstation.ps1.' }
        )
    }
}
