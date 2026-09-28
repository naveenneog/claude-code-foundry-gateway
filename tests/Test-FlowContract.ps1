# The guided flow's shared contract (ADR-0030): plans, costs, fingerprints, the decision record and
# step ordering. Offline; no Azure calls.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$fail = 0
function Assert($label, $condition, $detail = '') {
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $label$(if ($detail) { " - $detail" })" -ForegroundColor Red; $script:fail++ }
}
function Get-Thrown([scriptblock]$Block) { try { & $Block; return '' } catch { return $_.Exception.Message } }

Write-Host ''
Write-Host 'Guided flow - shared contract' -ForegroundColor Cyan
. (Join-Path $root 'scripts\flow\FlowContract.ps1')

$scratch = Join-Path ([IO.Path]::GetTempPath()) ('flow-contract-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch -Force | Out-Null
try {
    # Plans
    $a = New-ClaudeFlowAction -Verb Create -Target 'apim/contoso' -Detail 'Basic v2, 1 unit'
    Assert 'an action carries verb, target and detail' ($a.Verb -eq 'Create' -and $a.Target -eq 'apim/contoso' -and $a.Detail -eq 'Basic v2, 1 unit')
    Assert 'an unknown verb is refused' ((Get-Thrown { New-ClaudeFlowAction -Verb Explode -Target x }) -match 'verb')
    $c = New-ClaudeFlowCost -Item 'API Management Basic v2' -MonthlyUsd 150.00 -Source 'Azure Retail Prices API' -RetrievedUtc '2026-09-26T00:00:00Z'
    Assert 'a cost is a decimal amount with its source' ($c.MonthlyUsd -is [decimal] -and $c.MonthlyUsd -eq 150.00 -and $c.Source)
    Assert 'a negative cost is refused' ((Get-Thrown { New-ClaudeFlowCost -Item x -MonthlyUsd -1 -Source s }) -match 'negative')
    Assert 'an unknown cost needs a reason' ((Get-Thrown { New-ClaudeFlowCost -Item x -Source s }) -match 'reason')
    $u = New-ClaudeFlowCost -Item 'Model tokens' -Source 'usage based' -UnknownReason 'depends on usage'
    Assert 'an unknown cost is null, not zero' ($null -eq $u.MonthlyUsd -and $u.UnknownReason -eq 'depends on usage')
    Assert 'a plan without a step name is refused' ((Get-Thrown { New-ClaudeFlowPlan -Step '' -Summary s }) -match 'step')
    $p1 = New-ClaudeFlowPlan -Step Foundation -Summary 'Gateway' -Actions @($a) -Costs @($c, $u) -Implications @('Developers need az login') -Requires @('Owner') -Reversible $true -Rollback 'Delete the resource group'
    Assert 'a plan carries actions, costs, implications, roles and rollback' ($p1.Actions.Count -eq 1 -and $p1.Costs.Count -eq 2 -and $p1.Implications.Count -eq 1 -and $p1.Requires[0] -eq 'Owner' -and $p1.Reversible -and $p1.Rollback)
    $noop = New-ClaudeFlowPlan -Step Monitoring -Summary 'Nothing to change'
    Assert 'a plan with no actions is a no-op' ($noop.Actions.Count -eq 0 -and (Test-ClaudeFlowPlanIsNoop $noop))

    # Totals
    $total = Get-ClaudeFlowTotalMonthlyUsd -Plans @($p1, $noop)
    Assert 'the total sums known costs and lists the unknown ones' ($total.KnownMonthlyUsd -eq 150.00 -and $total.Unknown.Count -eq 1 -and $total.Unknown[0] -match 'Model tokens')

    # Fingerprints
    $f1 = Get-ClaudeFlowFingerprint -Plans @($p1, $noop)
    $p1b = New-ClaudeFlowPlan -Step Foundation -Summary 'Gateway' -Actions @($a) -Costs @((New-ClaudeFlowCost -Item 'API Management Basic v2' -MonthlyUsd 150.00 -Source 'Azure Retail Prices API' -RetrievedUtc '2026-09-27T09:00:00Z'), $u) -Implications @('Developers need az login') -Requires @('Owner') -Reversible $true -Rollback 'Delete the resource group'
    Assert 'a fingerprint is 64 hex characters' ($f1 -match '^[a-f0-9]{64}$')
    Assert 'the same plans give the same fingerprint, whenever the prices were read' ($f1 -eq (Get-ClaudeFlowFingerprint -Plans @($p1b, $noop)))
    $changed = New-ClaudeFlowPlan -Step Foundation -Summary 'Gateway' -Actions @((New-ClaudeFlowAction -Verb Create -Target 'apim/contoso' -Detail 'Standard v2, 1 unit')) -Costs @($c, $u) -Implications @('Developers need az login') -Requires @('Owner') -Reversible $true -Rollback 'Delete the resource group'
    Assert 'a changed action changes the fingerprint' ($f1 -ne (Get-ClaudeFlowFingerprint -Plans @($changed, $noop)))
    $pricier = New-ClaudeFlowPlan -Step Foundation -Summary 'Gateway' -Actions @($a) -Costs @((New-ClaudeFlowCost -Item 'API Management Basic v2' -MonthlyUsd 151.00 -Source 'Azure Retail Prices API'), $u) -Implications @('Developers need az login') -Requires @('Owner') -Reversible $true -Rollback 'Delete the resource group'
    Assert 'a changed price changes the fingerprint' ($f1 -ne (Get-ClaudeFlowFingerprint -Plans @($pricier, $noop)))
    # One plan, one fingerprint on every shell (P72): ConvertTo-Json escapes ' < > & on Windows
    # PowerShell 5.1 only, so strings are written by the flow's own encoder, non-ASCII as \u.
    $keyed = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    $keyed['b'] = "the gateway's <a&b> " + [string][char]0x2014 + ' "q"'; $keyed['B'] = 1; $keyed['a-b'] = $true; $keyed['a_b'] = $null
    $canon = ConvertTo-ClaudeFlowCanonical $keyed
    Assert 'the canonical form escapes only quotes, backslashes, control and non-ASCII characters, with keys in ordinal order' ($canon -eq ('{"B":1,"a-b":true,"a_b":null,"b":"the gateway''s <a&b> \u2014 \"q\""}')) $canon

    # Decision record
    $path = Join-Path $scratch 'claude-gateway.json'
    Assert 'a missing record reads as null' ($null -eq (Read-ClaudeDecisionRecord -Path $path))
    $legacy = [ordered]@{ mode = 'gateway'; gatewayUrl = 'https://apim-contoso.azure-api.net/claude'; apimName = 'apim-contoso'; resourceGroup = 'rg-contoso'; standardGroup = 'claude-code-standard'; futureField = @{ keep = 'me' } }
    [IO.File]::WriteAllText($path, ($legacy | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
    $record = Read-ClaudeDecisionRecord -Path $path
    Assert 'a version 1 record is read as version 1' ((Get-ClaudeDecisionRecordVersion $record) -eq 1)
    Set-ClaudeDecision -Record $record -Key entitlementStore -Value 'named-value'
    Add-ClaudeDecisionHistory -Record $record -Action Setup -Decision entitlementStore -From $null -To 'named-value' -Principal 'admin@contoso.com' -Commit ('a' * 40)
    Set-ClaudeDecisionRelease -Record $record -Version 'v1.2.3' -Commit ('b' * 40)
    Write-ClaudeDecisionRecord -Record $record -Path $path
    $back = Read-ClaudeDecisionRecord -Path $path
    Assert 'a written record is version 2' ((Get-ClaudeDecisionRecordVersion $back) -eq 2)
    Assert 'existing fields keep their values' ($back.gatewayUrl -eq $legacy.gatewayUrl -and $back.standardGroup -eq 'claude-code-standard')
    Assert 'fields the writer does not know are preserved' ($back.futureField.keep -eq 'me')
    Assert 'a decision is recorded under decisions' ((Get-ClaudeDecision -Record $back -Key entitlementStore) -eq 'named-value')
    Assert 'history records who changed what' ($back.history.Count -eq 1 -and $back.history[0].decision -eq 'entitlementStore' -and $back.history[0].to -eq 'named-value' -and $back.history[0].by -eq 'admin@contoso.com' -and $back.history[0].utc)
    Assert 'history is stored as a list even with one entry' ([IO.File]::ReadAllText($path) -match '"history":\s*\[')
    Assert 'the release that applied the record is kept' ($back.release.version -eq 'v1.2.3' -and $back.release.commit -eq ('b' * 40))
    Set-ClaudeDecision -Record $back -Key finops -Value ([ordered]@{ tool = 'Direct' })
    Write-ClaudeDecisionRecord -Record $back -Path $path
    $again = Read-ClaudeDecisionRecord -Path $path
    Assert 'a nested decision round-trips' ((Get-ClaudeDecision -Record $again -Key finops).tool -eq 'Direct' -and (Get-ClaudeDecision -Record $again -Key entitlementStore) -eq 'named-value')
    Assert 'no temporary file is left beside the record' (@(Get-ChildItem $scratch -Filter '*.tmp*').Count -eq 0)
    [IO.File]::WriteAllText($path, '{ not json', (New-Object Text.UTF8Encoding($false)))
    Assert 'a corrupt record is refused, not treated as empty' ((Get-Thrown { Read-ClaudeDecisionRecord -Path $path }) -match 'not valid JSON')

    # Step ordering
    $steps = @(
        [pscustomobject]@{ Name = 'Guide'; DependsOn = @('Verify') },
        [pscustomobject]@{ Name = 'Foundation'; DependsOn = @() },
        [pscustomobject]@{ Name = 'Verify'; DependsOn = @('Foundation', 'FinOps') },
        [pscustomobject]@{ Name = 'FinOps'; DependsOn = @('Foundation') }
    )
    $order = @(Get-ClaudeFlowStepOrder -Steps $steps | ForEach-Object Name)
    Assert 'steps are ordered by their dependencies' (($order -join ',') -eq 'Foundation,FinOps,Verify,Guide') ($order -join ',')
    $cycle = @([pscustomobject]@{ Name = 'A'; DependsOn = @('B') }, [pscustomobject]@{ Name = 'B'; DependsOn = @('A') })
    Assert 'a dependency cycle is refused' ((Get-Thrown { Get-ClaudeFlowStepOrder -Steps $cycle }) -match 'cycle')
    $missing = @([pscustomobject]@{ Name = 'A'; DependsOn = @('Nope') })
    Assert 'an unknown dependency is refused' ((Get-Thrown { Get-ClaudeFlowStepOrder -Steps $missing }) -match 'Nope')
}
finally { Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host ''
if ($fail) { Write-Host "$fail assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'Guided flow contract holds.' -ForegroundColor Green
exit 0
