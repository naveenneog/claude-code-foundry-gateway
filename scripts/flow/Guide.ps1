function Get-ClaudeFlowStepInfo {
    [pscustomobject]@{ Name = 'Guide'; Title = 'Deployment guide'; DecisionKey = 'guide'; DependsOn = @('Foundation', 'DeviceProfiles'); Actions = @('Setup', 'Guide') }
}

function Get-ClaudeFlowStepQuestions { param($Record, $Discovery) @() }

function Get-ClaudeFlowStepPlan {
    param($Record, $Discovery)
    New-ClaudeFlowPlan -Step Guide -Summary 'Write onboarding/HOW-TO-USE.md for this deployment' `
        -Actions @(New-ClaudeFlowAction -Verb Write -Target 'onboarding/HOW-TO-USE.md') `
        -Costs @() `
        -Implications @('The guide contains tenant-specific names and is git-ignored.', 'Regenerate after every guided change.') `
        -Requires @('The decision record') `
        -Rollback 'Delete onboarding/HOW-TO-USE.md'
}

function Get-GuideText {
    param($Record)
    $foundation = Get-ClaudeDecision -Record $Record -Key foundation
    $profiles = Get-ClaudeDecision -Record $Record -Key deviceProfiles
    $sku = if ($foundation -and $foundation.sku) { $foundation.sku } else { 'recorded API Management v2 SKU' }
    $finops = Get-ClaudeDecision -Record $Record -Key finops
    $finopsTool = if ($finops -and $finops.tool) { $finops.tool } else { 'workbooks and scripts until AUM or Turnstile is selected' }
    $costLine = if ($Record.decisions -and $Record.decisions.foundation -and $Record.decisions.foundation.estimatedMonthlyUsd) {
        ('$' + $Record.decisions.foundation.estimatedMonthlyUsd + '/month list price plus usage')
    } else { 'Use scripts/Get-ClaudeBom.ps1 -WithPrices for the deployment list price; Foundry and Log Analytics remain usage-based.' }
    $gateway = if ($Record.gatewayUrl) { $Record.gatewayUrl } else { '<gateway URL from the record>' }
    $tenant = if ($Record.tenantId) { $Record.tenantId } else { '<tenant id from the record>' }
    $rg = if ($Record.resourceGroup) { $Record.resourceGroup } else { '<resource group>' }
    $apim = if ($Record.apimName) { $Record.apimName } else { '<apim name>' }
    @"
# How to use this Claude gateway

Generated: $([DateTime]::UtcNow.ToString('o'))

## What was set up

- Gateway: `$gateway`
- Tenant: `$tenant`
- API Management: `$apim` in `$rg`
- SKU decision: `$sku`
- Entitlement store: `$(if ($foundation -and $foundation.entitlementStore) { $foundation.entitlementStore } else { 'recorded or installer-selected' })`
- Developer sign-in: `$(if ($foundation -and $foundation.authMode) { $foundation.authMode } else { $Record.authMode })`
- Desktop sign-in: `$(if ($foundation -and $foundation.desktopSignInKind) { $foundation.desktopSignInKind } elseif ($Record.desktopSignIn) { $Record.desktopSignIn.kind } else { 'helper-script' })`

## Monthly cost

$costLine

Review current cost with:

```powershell
.\scripts\Get-ClaudeBom.ps1 -ResourceGroup '$rg' -ApimName '$apim' -WithPrices
```

## Administrator daily tasks

1. Check health and drift:

```powershell
.\Start-ClaudeGateway.ps1 -Action Status -RecordPath .\onboarding\claude-gateway.json
.\scripts\Test-ClaudeHealth.ps1 -ResourceGroup '$rg' -ApimName '$apim'
```

2. Add or remove developers through the approved path and publish entitlement.
3. Review bypass findings before announcing that the gateway is mandatory.
4. Watch workbook ingestion, budget state freshness and report jobs.

Deep guides: [Setup](../docs/SETUP.md), [Operations](../docs/OPERATIONS.md), [Budgets](../docs/BUDGETS.md), [Troubleshooting](../docs/TROUBLESHOOTING.md).

## Developer setup

Use this order so the most common support surface is verified first:

1. VS Code extension first:

```powershell
code --install-extension anthropic.claude-code
```

2. Claude Code CLI:

```powershell
npm install -g @anthropic-ai/claude-code
claude --version
```

3. Claude Desktop: quit it completely, install the platform bundle, reopen it, and use the recorded Desktop sign-in route.

4. Managed devices: assign the generated MDM payloads from `$($profiles.root)` if profiles were generated. Use [MDM](../docs/MDM.md) for Intune, Jamf and Group Policy.

Then run:

```powershell
.\scripts\Setup-ClaudeWorkstation.ps1 -ConfigPath .\claude-gateway.json
claude -p "Reply with exactly: OK"
```

## FinOps tool

Selected path: `$finopsTool`.

- AUM Direct: `.\.venv-finops\Scripts\aum.exe configure --backend direct --save`, then `aum`, `aum budget list`, `aum usd status`.
- AUM service: use the service URL and roles recorded by that module when it is present.
- Turnstile: open the recorded Turnstile URL with `.\scripts\Open-ClaudeTurnstile.ps1`.
- Workbooks/scripts only: publish queries/workbooks and use `Get-ClaudeBusinessUnit.ps1`, `Get-ClaudeAnalytics.ps1` and `New-ClaudeChargebackReport.ps1`.

## Workbooks and reports

Publish or refresh:

```powershell
.\scripts\Publish-ClaudeQueries.ps1 -ResourceGroup '$rg' -ApimName '$apim'
.\scripts\Publish-ClaudeWorkbook.ps1 -ResourceGroup '$rg' -WorkbookFile infra\workbook-chargeback.json -Name "Claude gateway - chargeback"
.\scripts\New-ClaudeChargebackReport.ps1 -WhatIf
```

Guide: [FinOps](../docs/FINOPS.md), [AUM](../docs/AUM.md), [Chargeback reports](../docs/CHARGEBACK-REPORTS.md).

## Update, change and diagnose

```powershell
.\Start-ClaudeGateway.ps1 -Action Update -RecordPath .\onboarding\claude-gateway.json
.\Start-ClaudeGateway.ps1 -Action Change -Change foundation -RecordPath .\onboarding\claude-gateway.json
.\Start-ClaudeGateway.ps1 -Action Diagnose -RecordPath .\onboarding\claude-gateway.json
.\Start-ClaudeGateway.ps1 -Action Guide -RecordPath .\onboarding\claude-gateway.json
```

Every apply shows one review and fingerprint first. A failed run resumes from the first incomplete step because history is written after each step.
"@
}

function Invoke-ClaudeFlowStep {
    param($Record, $Plan)
    $recordPath = if ($Record.__recordPath) { $Record.__recordPath } else { Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'onboarding\claude-gateway.json' }
    $out = Join-Path (Split-Path $recordPath -Parent) 'HOW-TO-USE.md'
    $dir = Split-Path -Parent $out
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $foundation = Get-ClaudeDecision -Record $Record -Key foundation
    $profiles = Get-ClaudeDecision -Record $Record -Key deviceProfiles
    $finops = Get-ClaudeDecision -Record $Record -Key finops
    $gateway = if ($Record.gatewayUrl) { $Record.gatewayUrl } else { '<gateway URL from the record>' }
    $tenant = if ($Record.tenantId) { $Record.tenantId } else { '<tenant id from the record>' }
    $rg = if ($Record.resourceGroup) { $Record.resourceGroup } else { '<resource group>' }
    $apim = if ($Record.apimName) { $Record.apimName } else { '<apim name>' }
    $sku = if ($foundation -and $foundation.sku) { $foundation.sku } else { 'recorded API Management v2 SKU' }
    $finopsTool = if ($finops -and $finops.tool) { $finops.tool } else { 'workbooks and scripts until AUM or Turnstile is selected' }
    $profileRoot = if ($profiles -and $profiles.root) { $profiles.root } else { 'onboarding/profiles' }
    $desktop = if ($foundation -and $foundation.desktopSignInKind) { $foundation.desktopSignInKind } elseif ($Record.desktopSignIn) { $Record.desktopSignIn.kind } else { 'helper-script' }
    @"
# How to use this Claude gateway

Generated: $([DateTime]::UtcNow.ToString('o'))

## What was set up

- Gateway: `$gateway`
- Tenant: `$tenant`
- API Management: `$apim` in `$rg`
- SKU decision: `$sku`
- Entitlement store: `$(if ($foundation -and $foundation.entitlementStore) { $foundation.entitlementStore } else { 'recorded or installer-selected' })`
- Developer sign-in: `$(if ($foundation -and $foundation.authMode) { $foundation.authMode } else { $Record.authMode })`
- Desktop sign-in: `$desktop`

## Monthly cost

Use `scripts/Get-ClaudeBom.ps1 -WithPrices` for the deployment list price; Foundry and Log Analytics remain usage-based.

## Administrator daily tasks

Run `Start-ClaudeGateway.ps1 -Action Status`, `scripts/Test-ClaudeHealth.ps1`, entitlement sync, bypass review, budget review and workbook/report checks. Deep guides: [Setup](../docs/SETUP.md), [Operations](../docs/OPERATIONS.md), [Budgets](../docs/BUDGETS.md), [Troubleshooting](../docs/TROUBLESHOOTING.md).

## Developer setup

Use this order: VS Code first, then CLI, then Desktop, then the MDM route for managed devices.

```powershell
code --install-extension anthropic.claude-code
npm install -g @anthropic-ai/claude-code
.\scripts\Setup-ClaudeWorkstation.ps1 -ConfigPath .\claude-gateway.json
claude -p "Reply with exactly: OK"
```

Managed-device profiles are in `$profileRoot`; assign them through Intune, Jamf or Group Policy. See [MDM](../docs/MDM.md).

## FinOps tool

Selected path: `$finopsTool`. Use AUM (`aum`, `aum budget list`, `aum usd status`), Turnstile through `Open-ClaudeTurnstile.ps1`, or workbook/script-only operations until a FinOps module records a stronger choice.

## Workbooks and reports

Publish saved queries, workbooks and chargeback reports with `Publish-ClaudeQueries.ps1`, `Publish-ClaudeWorkbook.ps1` and `New-ClaudeChargebackReport.ps1`. See [FinOps](../docs/FINOPS.md), [AUM](../docs/AUM.md), [Chargeback reports](../docs/CHARGEBACK-REPORTS.md).

## Update, change and diagnose

```powershell
.\Start-ClaudeGateway.ps1 -Action Update -RecordPath .\onboarding\claude-gateway.json
.\Start-ClaudeGateway.ps1 -Action Change -Change foundation -RecordPath .\onboarding\claude-gateway.json
.\Start-ClaudeGateway.ps1 -Action Diagnose -RecordPath .\onboarding\claude-gateway.json
.\Start-ClaudeGateway.ps1 -Action Guide -RecordPath .\onboarding\claude-gateway.json
```

Every apply shows one review and fingerprint first. A failed run resumes from the first incomplete step because history is written after each step.
"@ | Set-Content -LiteralPath $out -Encoding UTF8
    @{ guide = @{ path = $out; generatedUtc = [DateTime]::UtcNow.ToString('o') } }
}

function Test-ClaudeFlowStep {
    param($Record)
    $guide = Get-ClaudeDecision -Record $Record -Key guide
    $path = if ($guide -and $guide.path) { [string]$guide.path } elseif ($Record.__recordPath) { Join-Path (Split-Path $Record.__recordPath -Parent) 'HOW-TO-USE.md' } else { '' }
    $text = if ($path -and (Test-Path -LiteralPath $path)) { Get-Content -LiteralPath $path -Raw } else { '' }
    $checks = @(
        @{ Name = 'guide exists'; Passed = [bool]$text; Evidence = $path; Fix = 'Run Start-ClaudeGateway.ps1 -Action Guide.' },
        @{ Name = 'admin section'; Passed = ($text -match 'Administrator daily tasks'); Evidence = 'Administrator daily tasks'; Fix = 'Regenerate the guide.' },
        @{ Name = 'developer order'; Passed = ($text -match 'VS Code extension first' -or $text -match 'VS Code first'); Evidence = 'VS Code, CLI, Desktop'; Fix = 'Regenerate the guide.' },
        @{ Name = 'finops section'; Passed = ($text -match 'FinOps tool'); Evidence = 'FinOps tool'; Fix = 'Regenerate the guide.' },
        @{ Name = 'update/change/diagnose section'; Passed = ($text -match 'Update, change and diagnose'); Evidence = 'Update, change and diagnose'; Fix = 'Regenerate the guide.' }
    )
    [pscustomobject]@{ Step = 'Guide'; Passed = (@($checks | Where-Object { -not $_.Passed }).Count -eq 0); Checks = @($checks) }
}
