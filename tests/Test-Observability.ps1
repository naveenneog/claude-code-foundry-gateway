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
Write-Host 'Observe - chargeback in money' -ForegroundColor Cyan

$cost = Get-Content (Join-Path $root 'analytics/chargeback-cost.kql') -Raw

# ADR-0010: categories are priced separately and never summed before pricing,
# because a blended rate applied to a cache read overstates it tenfold.
Assert 'prompt and completion are priced apart' (
    $cost -match 'prompt_usd\s*=' -and $cost -match 'completion_usd\s*=')
Assert 'cache read is priced at a tenth of input' ($cost -match 'cache_read_multiplier\s*=\s*0\.1')
Assert 'and multiplied by the input rate'          ($cost -match 'input_per_m \* cache_read_multiplier')

# Rates and membership are generated, never typed. Asserted by the markers the
# publisher requires, so a hand-pasted table cannot satisfy this.
Assert 'the price table is generated'  ($cost -match '(?m)^// PRICE-BOOK-BEGIN' -and $cost -match '(?m)^// PRICE-BOOK-END')
Assert 'the membership table too'      ($cost -match '(?m)^// MEMBERSHIP-BEGIN' -and $cost -match '(?m)^// MEMBERSHIP-END')
Assert 'both carry the date they were read' (
    $cost -match 'price_book_date' -and $cost -match 'membership_date')

# The measured disagreement this function exists to reconcile.
Assert 'it attributes to today s unit'  ($cost -match '(?m)^\s*business_unit = coalesce\(iff\(unit_now')
Assert 'and keeps the stamp for audit'  ($cost -match 'business_unit_at_time')
Assert 'and marks spend that moved'     ($cost -match '"moved"')

# An unpriced model must cost null, not zero - zero is a claim.
Assert 'an unpriced model is not priced at zero' ($cost -match 'iff\(isnull\(input_per_m\), real\(null\)')
Assert 'and the row says so'                     ($cost -match 'priced_ok = isnotnull\(input_per_m\)')

# Cache has no surface on the metric, so it must not be spread across surfaces.
Assert 'cache is not allocated to a surface' ($cost -match 'cache \(no surface\)')
Assert 'and cache write is still declared missing' ($cost -match 'cache_write_known = false')

$pq = Get-Content (Join-Path $root 'scripts/Publish-ClaudeQueries.ps1') -Raw
Assert 'the publisher generates both tables' ($pq -match "Generate\s*=\s*@\('PRICE-BOOK', 'MEMBERSHIP'\)")
# The placeholder parses and runs, so a skipped substitution returns a wrong
# number rather than an error. Refusing is the whole point.
Assert 'and refuses when a marker is gone'   ($pq -match 'cannot be generated')
Assert 'membership is read from the gateway' ($pq -match "named-value-id 'bu-members'")
Assert 'and it refuses when it cannot ask'   ($pq -match 'business unit membership could not be read')

$wbc = Get-Content (Join-Path $root 'infra/workbook-chargeback.json') -Raw
Assert 'a chargeback workbook ships'     ($wbc -match 'ClaudeCost\(')
Assert 'it totals money'                 ($wbc -match 'Estimated spend \(USD\)')
Assert 'it breaks down by business unit' ($wbc -match 'by \[.Business unit.\] = business_unit')
Assert 'and by developer'                ($wbc -match 'by Developer = actor')
Assert 'and by model'                    ($wbc -match 'by Model = model')
Assert 'and by client surface'           ($wbc -match 'by \[.Client surface.\] = client_surface')
Assert 'it separates cache from metered' ($wbc -match 'Cache read \(USD\)')
Assert 'it states the figure is list price' ($wbc -match 'not.{0,4} reconciled to an Azure invoice')
Assert 'and that real spend is higher'      ($wbc -match 'higher than shown, never lower')
Assert 'it surfaces unpriced spend'         ($wbc -match 'Spend on unpriced models')
Assert 'and spend that moved unit'          ($wbc -match 'Spend that moved unit')
Assert 'and the dates behind the numbers'   ($wbc -match 'Price book' -and $wbc -match 'Membership read')
try { $null = $wbc | ConvertFrom-Json; $wbcOk = $true } catch { $wbcOk = $false }
Assert 'the workbook is valid JSON' $wbcOk 'it would publish and fail to open'

# A relative -WorkbookFile passed Test-Path and then failed the read, because
# [IO.File] uses the .NET current directory rather than the PowerShell location.
Assert 'the workbook path is resolved before reading' ($w -match 'Resolve-Path \$WorkbookFile')

# The portal reads resource ids, not REST URLs. Given the management endpoint in
# front of the id it resolves nothing and every tile reports that no workspace
# is selected, which reads as a broken dashboard rather than a malformed id.
Assert 'a bare ARM workspace id is derived'  ($w -match '(?m)^\$workspaceArmId = "\$armPath/providers/Microsoft\.OperationalInsights')
Assert 'and the workbook is sourced from it' ($w -match 'sourceId\s+= \$workspaceArmId')
Assert 'the REST id keeps the endpoint'      ($w -match '(?m)^\$workspaceId = "\$rgScope/providers')

# sourceId scopes the workbook; it does not tell a tile what to query.
Assert 'every workspace tile is bound'  ($w -match "crossComponentResources' -NotePropertyValue @\(\`$workspaceArmId\)")
Assert 'binding uses the ARM id too'    ($w -notmatch 'crossComponentResources = @\(\$workspaceId\)')
Assert 'and a workbook that binds nothing is refused' ($w -match 'no tile targeting a Log Analytics workspace')
# Two workbooks differ in how they treat cache, so the closing note is derived
# from the file rather than stated as a blanket fact.
Assert 'the cache note follows the file' ($w -match "if \(\`$json -match 'cache_read_usd'\)")

# A tiles visualisation renders one tile per ROW, not one per column. Given a
# single row of many columns the portal cannot infer a layout and the section
# renders "Could not create tiles. Use tile settings to configure this section."
# Both workbooks shipped that way. Checked structurally rather than by wording,
# because the query text that produces the right shape has no fixed form.
foreach ($f in 'infra/workbook.json', 'infra/workbook-chargeback.json') {
    $doc = Get-Content (Join-Path $root $f) -Raw | ConvertFrom-Json
    $tiles = @($doc.items | Where-Object { $_.content.visualization -eq 'tiles' })
    Assert "$f has a tiles section" ($tiles.Count -gt 0)
    foreach ($t in $tiles) {
        $ts = $t.content.tileSettings
        Assert "$f/$($t.name) maps a tile title" (
            $ts -and $ts.titleContent -and $ts.titleContent.columnMatch) 'tiles need titleContent.columnMatch'
        Assert "$f/$($t.name) maps a tile value" (
            $ts -and $ts.leftContent -and $ts.leftContent.columnMatch) 'tiles need leftContent.columnMatch'
        # One row per tile means the query projects a label column, so the
        # column named by titleContent has to be produced by it.
        Assert "$f/$($t.name) projects that column" (
            $t.content.query -match [regex]::Escape($ts.titleContent.columnMatch))
    }
}

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
