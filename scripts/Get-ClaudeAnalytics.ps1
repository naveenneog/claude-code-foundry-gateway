<#
.SYNOPSIS
    Claude Code usage in the shape of the Claude Code Analytics API.

.DESCRIPTION
    Anthropic's Claude Code Analytics API does not cover Foundry. From its
    reference (retrieved 2026-09-02):

        "This API only tracks Claude Code usage on the Claude API. Usage through
         Claude in Amazon Bedrock, Claude in Microsoft Foundry, Claude on Google
         Cloud, or Claude Platform on AWS is not included."

    https://platform.claude.com/docs/en/manage-claude/claude-code-analytics-api

    So the endpoint returns nothing for a Foundry deployment, not partial data.
    This script builds the same records from the gateway's own Application
    Insights telemetry and emits them in the API's response shape, so a report
    or dashboard written against that API keeps working with only the transport
    changed.

    The query is analytics/claude-code-daily.kql - the same file the test
    asserts against. Fields the gateway cannot see are null, never zero. Which
    ones and why: docs/adr/0002-analytics-two-sources.md.

.PARAMETER Date
    UTC day to report, yyyy-MM-dd. Defaults to yesterday, matching the API's
    starting_at parameter.

.PARAMETER Days
    Report a window ending at Date instead of a single day. Useful for a first
    look at a workspace; the API itself is one day per call.

.PARAMETER AsJson
    Emit the API's JSON envelope. Without it, PowerShell objects are returned so
    they can be piped into Where-Object, Export-Csv and the like.

.EXAMPLE
    ./scripts/Get-ClaudeAnalytics.ps1
    Yesterday, as objects.

.EXAMPLE
    ./scripts/Get-ClaudeAnalytics.ps1 -Days 30 -AsJson > usage.json
    A month, in the API's envelope.

.EXAMPLE
    ./scripts/Get-ClaudeAnalytics.ps1 -Days 7 |
        Select-Object date, @{n='who';e={$_.actor.email_address}},
                      @{n='tokens';e={($_.model_breakdown | Measure-Object -Property {$_.tokens.input} -Sum).Sum}}
#>
[CmdletBinding()]
param(
    [string]$Date,
    [int]$Days = 1,
    [switch]$AsJson,
    [string]$ResourceGroup = $(if ($env:CLAUDE_RG) { $env:CLAUDE_RG } else { 'rg-contosohub' }),
    [string]$AppInsightsName = $(if ($env:CLAUDE_APPINSIGHTS) { $env:CLAUDE_APPINSIGHTS } else { 'appi-claude-gateway' })
)

$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot -Parent
$kql = Join-Path $root 'analytics/claude-code-daily.kql'
if (-not (Test-Path $kql)) { throw "Query not found: $kql" }

if ($Date) {
    try { $end = [datetime]::ParseExact($Date, 'yyyy-MM-dd', $null) }
    catch { throw "Date must be yyyy-MM-dd, got '$Date'" }
}
else {
    $end = [datetime]::UtcNow.Date.AddDays(-1)
}
if ($Days -lt 1) { throw "Days must be at least 1, got $Days" }
$start = $end.AddDays(-($Days - 1))

# Substitute the window rather than templating the file, so the query that ships
# is the query that runs and the test asserts the real thing.
$text = (Get-Content $kql -Raw) -replace '(?m)^\s*//.*$', ''
$text = $text -replace 'let _day = startofday\(ago\(1d\)\);', ("let _day = datetime({0});" -f $start.ToString('yyyy-MM-dd'))
$text = $text -replace 'let _next = _day \+ 1d;', ("let _next = _day + {0}d;" -f $Days)

# ARM, not "az monitor app-insights": that command lives in an optional
# extension and prompts to install it on a machine without one.
$sub = az account show --query id -o tsv 2>$null
if (-not $sub) { throw "Not signed in. Run: az login" }
$armToken = az account get-access-token --resource https://management.azure.com --query accessToken -o tsv 2>$null
if (-not $armToken) { throw "Could not get an ARM token. Run: az login" }

$componentUri = "https://management.azure.com/subscriptions/$($sub.Trim())/resourceGroups/$ResourceGroup" +
                "/providers/Microsoft.Insights/components/$AppInsightsName" + '?api-version=2020-02-02'
try {
    $component = Invoke-RestMethod -Uri $componentUri -Headers @{ Authorization = 'Bearer ' + $armToken.Trim() }
}
catch {
    throw "Application Insights '$AppInsightsName' not found in '$ResourceGroup'. Pass -AppInsightsName or set CLAUDE_APPINSIGHTS."
}
$appId = $component.properties.AppId
$tenantId = az account show --query tenantId -o tsv 2>$null

$queryToken = az account get-access-token --resource https://api.applicationinsights.io --query accessToken -o tsv 2>$null
if (-not $queryToken) { throw "Could not get an Application Insights token. Run: az login" }

$result = Invoke-RestMethod -Uri "https://api.applicationinsights.io/v1/apps/$appId/query" `
          -Method Post -ContentType 'application/json' `
          -Headers @{ Authorization = 'Bearer ' + $queryToken.Trim() } `
          -Body (@{ query = $text } | ConvertTo-Json)

$table = $result.tables[0]
$col = @{}
for ($i = 0; $i -lt $table.columns.Count; $i++) { $col[$table.columns[$i].name] = $i }

# Null, not zero. A metric that was never exported and a metric that measured
# zero are different facts, and a dashboard cannot tell them apart after the
# fact. Empty string is what the query API returns for a null numeric.
#
# Counts come back as [long]: the API reports whole things, and a double
# serialises as 3.0, which does not diff cleanly against it.
function Get-NullableCount($row, $name) {
    $v = $row[$col[$name]]
    if ($null -eq $v -or $v -eq '') { return $null }
    return [long][math]::Round([double]$v)
}

# Money keeps its fractional part.
function Get-NullableAmount($row, $name) {
    $v = $row[$col[$name]]
    if ($null -eq $v -or $v -eq '') { return $null }
    return [double]$v
}

# The API documents date as RFC 3339. Casting the value to [string] would format
# it in the current culture instead - "08/13/2026 00:00:00" here, something else
# on a machine set to another locale - and break any caller parsing RFC 3339.
function Format-Rfc3339($value) {
    if ($null -eq $value -or $value -eq '') { return $null }
    return ([datetime]$value).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
}

# The query returns one row per date/actor/model. The API nests models under one
# record per date/actor, so regroup.
$records = @()
$rows = @($table.rows)
$groups = $rows | Group-Object -Property { "$($_[$col['date']])|$($_[$col['actor']])" }

foreach ($g in $groups) {
    $first = $g.Group[0]

    $models = @()
    foreach ($row in $g.Group) {
        $models += [ordered]@{
            model  = [string]$row[$col['model']]
            tokens = [ordered]@{
                input          = Get-NullableCount $row 'tokens_input'
                output         = Get-NullableCount $row 'tokens_output'
                cache_read     = Get-NullableCount $row 'tokens_cache_read'
                # Foundry emits no cache-creation metric. See ADR-0002.
                cache_creation = $null
            }
            estimated_cost = [ordered]@{
                currency = 'USD'
                amount   = Get-NullableAmount $row 'estimated_cost_usd'
                # U2 is open: token counts have not been reconciled against the
                # Azure invoice. The flag travels with the number so it cannot be
                # separated from it downstream.
                is_estimate = $true
            }
        }
    }

    $records += [ordered]@{
        date  = Format-Rfc3339 $first[$col['date']]
        actor = [ordered]@{
            type          = 'user_actor'
            email_address = [string]$first[$col['actor']]
        }
        # The Entra tenant stands in for the Anthropic organization id.
        organization_id = $tenantId
        customer_type   = 'foundry'
        terminal_type   = $(if ($first[$col['terminal_type']]) { [string]$first[$col['terminal_type']] } else { $null })
        core_metrics    = [ordered]@{
            num_sessions  = Get-NullableCount $first 'num_sessions'
            lines_of_code = [ordered]@{
                added   = Get-NullableCount $first 'lines_added'
                removed = Get-NullableCount $first 'lines_removed'
            }
            commits_by_claude_code       = Get-NullableCount $first 'commits'
            pull_requests_by_claude_code = Get-NullableCount $first 'pull_requests'
        }
        # Claude Code emits one code_edit_tool.decision counter, not one per
        # tool, so the four tools the API reports separately cannot be split.
        tool_actions = [ordered]@{
            edit_tool = [ordered]@{
                accepted = Get-NullableCount $first 'tool_accepted'
                rejected = Get-NullableCount $first 'tool_rejected'
            }
        }
        model_breakdown = $models
    }
}

$envelope = [ordered]@{
    data      = $records
    has_more  = $false
    next_page = $null
}

if ($AsJson) { $envelope | ConvertTo-Json -Depth 10 }
else { $records | ForEach-Object { [pscustomobject]$_ } }
