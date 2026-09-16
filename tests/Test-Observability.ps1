# P24/P27 - the Observe half: client attribution, saved functions, the workbook.
#
# RED first for the parts that did not exist; the policy change was made ahead
# of the suite and is asserted here alongside them.
#
# The thing this packet exists to fix: the gateway could not tell the Claude
# Code CLI, the VS Code extension and Claude Desktop apart. Measured 2026-09-16,
# AppRequests.Properties carried only API and service metadata, ClientType read
# "PC" and ClientBrowser was empty - no agent string anywhere.
#
# Offline only. The live half ran against the reference gateway and is recorded
# in docs/STATUS.md.

$root = Split-Path $PSScriptRoot -Parent
$policyPath = Join-Path $root 'infra/policy.xml'
$ledgerPath = Join-Path $root 'analytics/chargeback-ledger.kql'
$wbPath = Join-Path $root 'infra/workbook.json'
$pubQ = Join-Path $root 'scripts/Publish-ClaudeQueries.ps1'
$pubW = Join-Path $root 'scripts/Publish-ClaudeWorkbook.ps1'

$fail = 0
function Assert($label, $condition, $detail = '') {
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $label$(if ($detail) { " - $detail" })" -ForegroundColor Red; $script:fail++ }
}

Write-Host ''
Write-Host 'Observe - which client made the call' -ForegroundColor Cyan

$policy = Get-Content $policyPath -Raw

# Scoped to the chargeback trace: matching "User-Agent" anywhere in a 27KB
# policy would pass on a comment.
$i = $policy.IndexOf('<trace source="claude-chargeback"')
$trace = if ($i -ge 0) { $policy.Substring($i, [Math]::Min(2200, $policy.Length - $i)) } else { '' }
Assert 'the chargeback trace exists'      ($i -ge 0)
Assert 'it carries a Client field'        ($trace -match '<metadata name="Client"')
Assert 'read from the request User-Agent' ($trace -match 'User-Agent')
# An agent string has no length limit and this is one field on every request.
Assert 'bounded in length'                ($trace -match 'Substring\(0,\s*\d+\)')
# Empty must be a value, not a blank: "unknown" is countable, "" disappears
# into every other empty string in the table.
Assert 'a missing agent reads as unknown' ($trace -match '"unknown"')

# The classifier belongs in KQL. In policy it needs a redeploy every time a
# client changes its agent string.
Assert 'the policy does not classify'     ($policy -notmatch '(?i)vscode|electron|desktop')

Write-Host ''
Write-Host 'Observe - the ledger carries it' -ForegroundColor Cyan

$ledger = Get-Content $ledgerPath -Raw
Assert 'the ledger projects a client'      ($ledger -match 'client_surface')
Assert 'and keeps the raw agent beside it' ($ledger -match 'client_raw')
Assert 'and projects the business unit'    ($ledger -match 'business_unit')
# Parsed, not enumerated. A list of expected surfaces was wrong the first time
# it was written: Claude Code 2.1.241 sends "(external, sdk-cli)", not "cli".
Assert 'the surface is extracted, not listed' ($ledger -match 'extract\(@?"\\\(external')
Assert 'the measured agent string is recorded' ($ledger -match 'sdk-cli')
# Unattributed rows have to be countable, or the gaps hide.
Assert 'an unknown client is named'        ($ledger -match '"unknown"')
Assert 'an unassigned unit is named'       ($ledger -match '"unassigned"')

Write-Host ''
Write-Host 'Observe - saved KQL functions' -ForegroundColor Cyan

Assert 'a publisher exists' (Test-Path $pubQ) $pubQ
$q = Get-Content $pubQ -Raw
Assert 'it publishes the ledger'      ($q -match 'ClaudeChargeback')
Assert 'and the daily report'         ($q -match 'ClaudeCodeDaily')
# The .kql file stays the source. A copy of the query inside the publisher is
# a second thing to keep current.
Assert 'it reads the .kql files'      ($q -match "analytics/chargeback-ledger\.kql")
Assert 'it does not restate the query' ($q -notmatch 'ApiManagementGatewayLlmLog')
# A function whose window is fixed answers every question with yesterday and
# looks right doing it.
Assert 'the window becomes a parameter' ($q -match 'functionParameters')
Assert 'it refuses when the window line is gone' ($q -match 'cannot become a parameter')
Assert 'it can list what is published' ($q -match '\$List')
Assert 'and remove them'               ($q -match '\$Remove')
Assert 'it refuses an ambiguous workspace' ($q -match 'Pass -WorkspaceName')

Write-Host ''
Write-Host 'Observe - the workbook' -ForegroundColor Cyan

Assert 'a workbook definition exists' (Test-Path $wbPath) $wbPath
$wbRaw = Get-Content $wbPath -Raw
$parsed = $null
try { $parsed = $wbRaw | ConvertFrom-Json } catch { }
Assert 'it is valid JSON'            ($null -ne $parsed) 'would publish a workbook that cannot open'
Assert 'it has tiles'                ($null -ne $parsed -and @($parsed.items).Count -ge 6) "got $(@($parsed.items).Count)"
Assert 'it calls the saved function' ($wbRaw -match 'ClaudeChargeback\(')
# The whole point of the packet.
Assert 'it breaks usage down by client' ($wbRaw -match 'client_surface')
Assert 'and by business unit'           ($wbRaw -match 'business_unit')
# A dollar figure with no caveat is the failure mode, same as the reports.
Assert 'it states the figures are list price' ($wbRaw -match '(?i)list price')
Assert 'and that cache is excluded'           ($wbRaw -match '38\.7' -and $wbRaw -match '(?i)cach')
# The gaps have to be visible or they are not managed.
Assert 'it counts what it could not attribute' ($wbRaw -match 'unattributed' -and $wbRaw -match 'Attribution gaps')

Assert 'a publisher exists' (Test-Path $pubW) $pubW
$w = Get-Content $pubW -Raw
Assert 'it validates the JSON first'   ($w -match 'not valid JSON')
# Publishing against a workspace without the functions gives every tile a
# resolver error, which reads as a broken dashboard rather than a missed step.
Assert 'it checks the functions exist' ($w -match 'does not have')
Assert 'it names the fix'              ($w -match 'Publish-ClaudeQueries')
# Re-running must update rather than leave a second copy beside the first.
Assert 'the workbook id is deterministic' ($w -match 'ComputeHash')
Assert 'it refuses an ambiguous workspace' ($w -match 'renders empty')
Assert 'it can list and remove'         ($w -match '\$List' -and $w -match '\$Remove')
# A portal link built from the management endpoint opens nothing.
Assert 'the portal link uses the ARM path' ($w -match '\$armPath/providers/Microsoft\.Insights/workbooks')

Write-Host ''
Write-Host 'Observe - documentation' -ForegroundColor Cyan

$mon = Get-Content (Join-Path $root 'docs/MONITORING.md') -Raw
Assert 'monitoring documents the functions' ($mon -match 'Publish-ClaudeQueries')
Assert 'and the workbook'                   ($mon -match 'Publish-ClaudeWorkbook')
Assert 'and what each costs'                ($mon -match '(?i)costs nothing|no standing cost|adds no')
Assert 'and the client breakdown'           ($mon -match '(?i)client')
foreach ($shot in 'obs-1-publish-queries.png', 'obs-2-publish-workbook.png',
                  'obs-3-workbook-guard.png', 'obs-4-by-client.png') {
    Assert "it ships $shot" (Test-Path (Join-Path $root "docs/guide/$shot"))
    Assert "and shows it"   ($mon -match [regex]::Escape($shot))
}

Write-Host ''
if ($fail) { Write-Host "$fail assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'Observe contract holds.' -ForegroundColor Green
exit 0
