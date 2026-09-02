# P10 — the analytics equivalent.
#
# RED first: this test is written before the implementation and fails for the
# right reason - the artefacts do not exist yet.
#
# Two halves. The offline half asserts the contract of the KQL itself and runs
# anywhere. The live half submits the query to Application Insights and is
# skipped, not failed, when there is no token - a missing signin is not a
# regression.
#
# The contract comes from the Claude Code Analytics API field set
# (https://platform.claude.com/docs/en/manage-claude/claude-code-analytics-api,
# retrieved 2026-09-02), so a report written against that API keeps working
# with only the transport swapped. See ADR-0002 for why two sources are needed
# and which fields the gateway alone cannot supply.

# -SkipLive keeps the run offline. Test-All.ps1 uses it for the default suite and
# omits it under -IncludeAzure, so the same file serves both.
param([switch]$SkipLive)

$root = Split-Path $PSScriptRoot -Parent
$kql = Join-Path $root 'analytics/claude-code-daily.kql'

$fail = 0
function Assert($label, $condition, $detail = '') {
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $label$(if ($detail) { " - $detail" })" -ForegroundColor Red; $script:fail++ }
}

Write-Host ''
Write-Host 'P10 analytics - contract' -ForegroundColor Cyan

Assert 'the query exists' (Test-Path $kql) $kql
if (-not (Test-Path $kql)) {
    Write-Host ''
    Write-Host "$fail assertion(s) failed." -ForegroundColor Red
    exit 1
}

$text = Get-Content $kql -Raw

# The field set a caller migrating off the Claude Code Analytics API expects.
# Names use underscores rather than the API's nesting, because KQL columns are
# flat; the mapping is documented in ADR-0002.
$contract = @(
    'date', 'actor', 'terminal_type', 'num_sessions',
    'tokens_input', 'tokens_output', 'tokens_cache_read',
    'model', 'estimated_cost_usd', 'cost_is_estimate',
    'lines_added', 'lines_removed', 'commits', 'pull_requests',
    'tool_accepted', 'tool_rejected'
)
foreach ($c in $contract) {
    Assert "projects $c" ($text -match "(?m)^\s*$([regex]::Escape($c))\s*=" -or $text -match "\b$([regex]::Escape($c))\b")
}

# Measured 2026-09-02: 38 of 371 records for one user carry SessionId "none",
# because not every surface sends x-claude-code-session-id. Counting those as
# sessions would inflate num_sessions for anyone using the VS Code panel.
Assert 'excludes the "none" session id' ($text -match '"none"')

# U2 is open: token counts have not been reconciled against the Azure invoice,
# so any money figure has to be labelled an estimate at the source rather than
# in a footnote someone drops.
Assert 'marks cost as an estimate' ($text -match 'cost_is_estimate')

# ---------------------------------------------------------------- live half

Write-Host ''
Write-Host 'P10 analytics - live' -ForegroundColor Cyan

# The app id is resolved through ARM rather than "az monitor app-insights",
# which belongs to an optional extension and prompts to install it on a machine
# that does not have one. Same names and defaults as scripts/Show-Governance.ps1.
$rg = if ($env:CLAUDE_RG) { $env:CLAUDE_RG } else { 'rg-contosohub' }
$ai = if ($env:CLAUDE_APPINSIGHTS) { $env:CLAUDE_APPINSIGHTS } else { 'appi-claude-gateway' }

$appId = $env:CLAUDE_ANALYTICS_APPID
if (-not $appId) {
    $sub = az account show --query id -o tsv 2>$null
    $arm = az account get-access-token --resource https://management.azure.com --query accessToken -o tsv 2>$null
    if ($sub -and $arm) {
        $armUri = "https://management.azure.com/subscriptions/$($sub.Trim())/resourceGroups/$rg" +
                  "/providers/Microsoft.Insights/components/$ai" + '?api-version=2020-02-02'
        try {
            $h = @{ Authorization = 'Bearer ' + $arm.Trim() }
            $appId = (Invoke-RestMethod -Uri $armUri -Headers $h).properties.AppId
        }
        catch { $appId = $null }
    }
}
$token = if ($SkipLive) { $null } else { az account get-access-token --resource https://api.applicationinsights.io --query accessToken -o tsv 2>$null }

if ($SkipLive) {
    Write-Host '  skipped - offline run (-SkipLive)' -ForegroundColor Yellow
}
elseif (-not $appId -or -not $token) {
    Write-Host "  skipped - no Application Insights app id or no token ($rg/$ai)" -ForegroundColor Yellow
}
else {
    # Whole-line comments only, matching the comment style the KQL file uses.
    # Sent as a POST body: a URL-encoded query this long is near the limit and
    # hard to read back when it trips it.
    $q = $text -replace '(?m)^\s*//.*$', ''
    $uri = "https://api.applicationinsights.io/v1/apps/$($appId.Trim())/query"
    try {
        $h = @{ Authorization = 'Bearer ' + $token.Trim() }
        $r = Invoke-RestMethod -Uri $uri -Method Post -ContentType 'application/json' `
             -Headers $h -Body (@{ query = $q } | ConvertTo-Json)
        $cols = @($r.tables[0].columns.name)
        Assert 'the query runs against Application Insights' $true
        $missing = @($contract | Where-Object { $_ -notin $cols })
        Assert 'returns every contracted column' ($missing.Count -eq 0) ("missing: " + ($missing -join ', '))
        Write-Host ("         {0} column(s), {1} row(s) from {2}" -f $cols.Count, $r.tables[0].rows.Count, $ai) -ForegroundColor DarkGray

        # Non-vacuity. A query that returns the right column names over an empty
        # window proves nothing - the gateway half could be filtering everything
        # out and this would still be green. So: ask whether the workspace holds
        # any gateway metrics at all, and if it does, require the query to
        # produce rows and non-zero tokens over that same window.
        $probe = 'customMetrics | where timestamp > ago(30d) | where name == "Prompt Tokens" | count'
        $pr = Invoke-RestMethod -Uri $uri -Method Post -ContentType 'application/json' `
              -Headers $h -Body (@{ query = $probe } | ConvertTo-Json)
        $have = [int]$pr.tables[0].rows[0][0]

        if ($have -eq 0) {
            Write-Host '         skipped non-vacuity check - no gateway metrics in the last 30 days' -ForegroundColor Yellow
        }
        else {
            $wide = $q -replace 'let _day = startofday\(ago\(1d\)\);', 'let _day = startofday(ago(30d));' `
                       -replace 'let _next = _day \+ 1d;', 'let _next = _day + 31d;'
            $wr = Invoke-RestMethod -Uri $uri -Method Post -ContentType 'application/json' `
                  -Headers $h -Body (@{ query = $wide } | ConvertTo-Json)
            $wrows = @($wr.tables[0].rows)
            $wcols = @($wr.tables[0].columns.name)
            Assert 'returns rows when the workspace holds gateway metrics' ($wrows.Count -gt 0) "$have metric record(s) present but the query returned nothing"

            $iIn = $wcols.IndexOf('tokens_input')
            $iOut = $wcols.IndexOf('tokens_output')
            $iCache = $wcols.IndexOf('tokens_cache_read')
            $iSess = $wcols.IndexOf('num_sessions')
            $iActor = $wcols.IndexOf('actor')

            # Each column is checked on its own. Summing them first would let one
            # working metric mask two broken ones, which is how a green test ends
            # up measuring nothing.
            $sum = { param($ix) ($wrows | ForEach-Object { [double]$_[$ix] } | Measure-Object -Sum).Sum }
            $tin = & $sum $iIn
            $tout = & $sum $iOut
            $tcache = & $sum $iCache
            $tsess = & $sum $iSess
            $actors = @($wrows | ForEach-Object { [string]$_[$iActor] } | Where-Object { $_ } | Select-Object -Unique)

            Assert 'reports prompt tokens'     ($tin -gt 0)    "tokens_input=$tin"
            Assert 'reports completion tokens' ($tout -gt 0)   "tokens_output=$tout"
            Assert 'reports cached tokens'     ($tcache -gt 0) "tokens_cache_read=$tcache"
            Assert 'reports sessions'          ($tsess -gt 0)  "num_sessions=$tsess"
            Assert 'attributes usage to a named caller' ($actors.Count -gt 0) 'every actor was empty'
            Write-Host ("         {0} row(s) over 30d, in {1:n0} / out {2:n0} / cached {3:n0} token(s), {4} session(s), {5} caller(s)" -f `
                $wrows.Count, $tin, $tout, $tcache, $tsess, $actors.Count) -ForegroundColor DarkGray
        }
    }
    catch {
        $detail = $_.ErrorDetails.Message
        if (-not $detail) { $detail = $_.Exception.Message }
        Assert 'the query runs against Application Insights' $false $detail
    }
}

# --------------------------------------------------------------- report shape
#
# The KQL returns a flat table, one row per date/actor/model. The Analytics API
# returns one record per date/actor with the models nested underneath. A caller
# swapping transports needs the nested shape, so scripts/Get-ClaudeAnalytics.ps1
# does the reshaping and this asserts it matches.
#
# Response shape from the API reference, retrieved 2026-09-02.

Write-Host ''
Write-Host 'P10 analytics - report shape' -ForegroundColor Cyan

$reporter = Join-Path $root 'scripts/Get-ClaudeAnalytics.ps1'
Assert 'the reporter exists' (Test-Path $reporter) $reporter

if (Test-Path $reporter) {
    $rtext = Get-Content $reporter -Raw
    Assert 'takes a date'          ($rtext -match '\$Date')
    Assert 'can emit JSON'         ($rtext -match '\$AsJson')
    Assert 'reads the shared KQL'  ($rtext -match 'claude-code-daily\.kql')

    if ($SkipLive) {
        Write-Host '  skipped live shape check - offline run (-SkipLive)' -ForegroundColor Yellow
    }
    else {
        # Run it over a window known to hold data, so the shape is asserted
        # against real records rather than an empty array.
        $json = & $reporter -Days 30 -AsJson 2>&1 | Out-String
        $ok = $false
        try { $envelope = $json | ConvertFrom-Json; $ok = $true } catch { }
        Assert 'emits parsable JSON' $ok $json

        if ($ok) {
            Assert 'wraps records in the API envelope' (($envelope.PSObject.Properties.Name -contains 'data') -and ($envelope.PSObject.Properties.Name -contains 'has_more') -and ($envelope.PSObject.Properties.Name -contains 'next_page'))
            $recs = @($envelope.data)
            Assert 'returns records' ($recs.Count -gt 0) 'data was empty over 30 days'

            if ($recs.Count -gt 0) {
                $rec = $recs[0]
                Assert 'names the actor'            ($rec.actor.email_address -and $rec.actor.type -eq 'user_actor') ($rec.actor | ConvertTo-Json -Compress)
                Assert 'carries core_metrics'       ($null -ne $rec.core_metrics.num_sessions)
                Assert 'carries tool_actions'       ($rec.PSObject.Properties.Name -contains 'tool_actions')
                Assert 'breaks down by model'       (@($rec.model_breakdown).Count -gt 0)
                Assert 'reports input tokens'       (@($rec.model_breakdown)[0].tokens.input -ge 0)
                Assert 'reports cost in USD'        (@($rec.model_breakdown)[0].estimated_cost.currency -eq 'USD')
                Assert 'labels cost an estimate'    (@($rec.model_breakdown)[0].estimated_cost.is_estimate -eq $true)
                Assert 'nulls what it cannot measure' ($null -eq $rec.core_metrics.lines_of_code.added) 'lines_of_code.added should be null until U8 closes'

                # The API documents date as RFC 3339. A [string] cast of a
                # DateTime uses the current culture instead, so this would ship
                # "08/13/2026 00:00:00" on an en-US box and something else
                # elsewhere - a caller parsing RFC 3339 breaks on both.
                #
                # Read from the raw JSON text: ConvertFrom-Json parses an ISO
                # string straight back into a DateTime, so a parsed check sees a
                # DateTime whether the file was correct or not.
                $dates = [regex]::Matches($json, '"date"\s*:\s*"([^"]*)"')
                $badDates = @($dates | Where-Object { $_.Groups[1].Value -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$' })
                Assert 'formats date as RFC 3339' (($dates.Count -gt 0) -and ($badDates.Count -eq 0)) ("saw: " + (($dates | ForEach-Object { $_.Groups[1].Value } | Select-Object -First 3) -join ', '))

                # Counts are whole things. Serialising them as 3.0 and 916.0 is
                # not what the API returns and makes a diff against it noisy.
                #
                # Checked against the raw JSON text, not the parsed object:
                # ConvertFrom-Json turns 3.0 into a double that renders as "3",
                # so a parsed check passes whatever the file actually says.
                $decimals = [regex]::Matches($json, '"(num_sessions|input|output|cache_read|added|removed|commits_by_claude_code|pull_requests_by_claude_code|accepted|rejected)"\s*:\s*-?\d+\.\d')
                Assert 'emits counts as integers' ($decimals.Count -eq 0) ("saw: " + (($decimals | ForEach-Object { $_.Value }) -join ', '))

                $tot = ($recs | ForEach-Object { [double]($_.model_breakdown | Measure-Object -Property { $_.tokens.input } -Sum).Sum } | Measure-Object -Sum).Sum
                Assert 'reshaping preserves tokens' ($tot -gt 0) "input tokens across all records = $tot"
                Write-Host ("         {0} record(s), {1:n0} input token(s)" -f $recs.Count, $tot) -ForegroundColor DarkGray
            }
        }
    }
}

Write-Host ''
if ($fail) { Write-Host "$fail assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'P10 contract holds.' -ForegroundColor Green
exit 0