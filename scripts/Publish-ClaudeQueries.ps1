<#
.SYNOPSIS
    Publishes the analytics queries into the workspace as callable KQL functions.

.DESCRIPTION
    The queries in analytics/ are files you paste into the Logs blade. Published
    as saved functions they become callable by name - ClaudeChargeback() - which
    is what a workbook, a Grafana panel or a colleague at a query prompt can
    reach without knowing this repository exists.

    A saved search is workspace metadata. It stores nothing, ingests nothing and
    costs nothing; the only bill is the query when someone runs it.

    The .kql file stays the single source. This rewrites only the window lines,
    turning the fixed defaults at the top of each file into function parameters,
    and refuses to publish if it cannot find them - a function silently pinned
    to "yesterday" would answer every question wrongly and look right doing it.

.PARAMETER Query
    Publish one query by alias rather than all of them.

.PARAMETER List
    Show what is published in the workspace now, and exit.

.PARAMETER Remove
    Remove the published functions instead of publishing them.

.EXAMPLE
    ./scripts/Publish-ClaudeQueries.ps1 -List
    ./scripts/Publish-ClaudeQueries.ps1
    ./scripts/Publish-ClaudeQueries.ps1 -Query ClaudeChargeback
#>
[CmdletBinding()]
param(
    [string]$Query,
    [switch]$List,
    [switch]$Remove,
    [string]$ResourceGroup = $(if ($env:CLAUDE_RG) { $env:CLAUDE_RG } else { 'rg-contosohub' }),
    [string]$WorkspaceName,
    [string]$SubscriptionId
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

# Each query declares how its window becomes a parameter. The rewrite is
# per-query rather than a generic rule because the two files do not agree:
# the ledger takes a range, the daily report takes one date.
$QUERIES = @(
    @{
        Alias   = 'ClaudeChargeback'
        File    = 'analytics/chargeback-ledger.kql'
        Display = 'Claude chargeback ledger'
        Params  = 'p_from:datetime=datetime(null),p_to:datetime=datetime(null)'
        Rewrite = [ordered]@{
            'let _from = ago(1d);' = 'let _from = iff(isnull(p_from), ago(1d), p_from);'
            'let _to = now();'     = 'let _to = iff(isnull(p_to), now(), p_to);'
        }
        Help    = 'ClaudeChargeback() for the last day, ClaudeChargeback(ago(30d), now()) for a month.'
    }
    @{
        Alias   = 'ClaudeCodeDaily'
        File    = 'analytics/claude-code-daily.kql'
        Display = 'Claude Code daily usage'
        Params  = 'p_day:datetime=datetime(null)'
        Rewrite = [ordered]@{
            'let _day = startofday(ago(1d));' = 'let _day = iff(isnull(p_day), startofday(ago(1d)), startofday(p_day));'
        }
        Help    = 'ClaudeCodeDaily() for yesterday, ClaudeCodeDaily(datetime(2026-09-15)) for a date.'
    }
)

function Get-Token {
    $t = az account get-access-token --resource https://management.azure.com --query accessToken -o tsv 2>$null
    if (-not $t) { throw "Could not acquire an Azure Resource Manager token. Run: az login" }
    return $t.Trim()
}

if (-not $SubscriptionId) { $SubscriptionId = az account show --query id -o tsv }

if (-not $WorkspaceName) {
    # One workspace in the group is unambiguous. More than one is not, and
    # guessing which holds the gateway's telemetry is how a report ends up
    # querying an empty workspace and reporting zero usage.
    $found = az monitor log-analytics workspace list -g $ResourceGroup --query "[].name" -o tsv 2>$null
    $names = @($found -split "`n" | Where-Object { $_ })
    if ($names.Count -eq 1) { $WorkspaceName = $names[0].Trim() }
    elseif ($names.Count -eq 0) { throw "No Log Analytics workspace in '$ResourceGroup'. Pass -WorkspaceName." }
    else {
        throw ("$($names.Count) workspaces in '$ResourceGroup': " + ($names -join ', ') +
               ". Pass -WorkspaceName to say which holds the gateway's telemetry.")
    }
}

$base = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup" +
        "/providers/Microsoft.OperationalInsights/workspaces/$WorkspaceName/savedSearches"
$headers = @{ Authorization = "Bearer $(Get-Token)"; 'Content-Type' = 'application/json' }

Write-Host ''
Write-Host ("Workspace {0} ({1})" -f $WorkspaceName, $ResourceGroup) -ForegroundColor Cyan

if ($List) {
    $existing = Invoke-RestMethod -Uri "$base`?api-version=2020-08-01" -Headers $headers -Method Get
    $ours = @($existing.value | Where-Object { $_.properties.category -eq 'Claude' })
    Write-Host ''
    if (-not $ours.Count) {
        Write-Host '  Nothing published. Run this without -List to publish.' -ForegroundColor DarkGray
        exit 0
    }
    Write-Host ("  {0,-22} {1,-46} {2}" -f 'Function', 'Parameters', 'Query lines')
    Write-Host ('  ' + ('-' * 88)) -ForegroundColor DarkGray
    foreach ($s in $ours) {
        $lines = @($s.properties.query -split "`n").Count
        Write-Host ("  {0,-22} {1,-46} {2}" -f $s.properties.functionAlias, $s.properties.functionParameters, $lines)
    }
    Write-Host ''
    exit 0
}

$selected = if ($Query) {
    $match = @($QUERIES | Where-Object { $_.Alias -eq $Query })
    if (-not $match.Count) {
        throw ("No query '$Query'. Known: " + (($QUERIES.Alias) -join ', ') + ".")
    }
    $match
} else { $QUERIES }

foreach ($q in $selected) {
    $id = $q.Alias.ToLower()
    $uri = "$base/$id`?api-version=2020-08-01"

    if ($Remove) {
        try { Invoke-RestMethod -Uri $uri -Headers $headers -Method Delete | Out-Null; Write-Host "  removed $($q.Alias)" -ForegroundColor Yellow }
        catch { Write-Host "  $($q.Alias) was not published" -ForegroundColor DarkGray }
        continue
    }

    $path = Join-Path $root $q.File
    if (-not (Test-Path $path)) { throw "Missing query file: $($q.File)" }
    $kql = [IO.File]::ReadAllText($path)

    # Refuse rather than publish a function pinned to a fixed window. If the
    # file's window line has been reworded, the rewrite silently does nothing
    # and every caller gets yesterday no matter what they ask for.
    foreach ($from in $q.Rewrite.Keys) {
        if ($kql -notmatch [regex]::Escape($from)) {
            throw ("$($q.File) no longer contains '$from', so its window cannot become a parameter. " +
                   "Publishing anyway would pin $($q.Alias) to a fixed window that ignores its arguments. " +
                   "Update the Rewrite table in this script to match the file.")
        }
        $kql = $kql.Replace($from, $q.Rewrite[$from])
    }

    $body = @{
        properties = @{
            category           = 'Claude'
            displayName        = $q.Display
            query              = $kql
            functionAlias      = $q.Alias
            functionParameters = $q.Params
            version            = 2
        }
    } | ConvertTo-Json -Depth 5

    Invoke-RestMethod -Uri $uri -Headers $headers -Method Put -Body $body | Out-Null
    Write-Host ("  published {0}({1})" -f $q.Alias, $q.Params) -ForegroundColor Green
    Write-Host ("            {0}" -f $q.Help) -ForegroundColor DarkGray
}

Write-Host ''
Write-Host '  A saved function is workspace metadata - it stores nothing and costs nothing.' -ForegroundColor DarkGray
Write-Host '  The .kql files in analytics/ stay the source; re-run this after editing one.' -ForegroundColor DarkGray
Write-Host ''
