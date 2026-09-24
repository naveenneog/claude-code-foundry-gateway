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
    [string]$ResourceGroup = $(& (Join-Path $PSScriptRoot 'Get-ClaudeGatewayTarget.ps1') ResourceGroup),
    [string]$WorkspaceName,
    [string]$ApimName,
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
    @{
        Alias   = 'ClaudeCost'
        File    = 'analytics/chargeback-cost.kql'
        Display = 'Claude chargeback in money'
        Params  = 'p_from:datetime=datetime(null),p_to:datetime=datetime(null)'
        Rewrite = [ordered]@{
            'let _from = ago(1d);' = 'let _from = iff(isnull(p_from), ago(1d), p_from);'
            'let _to = now();'     = 'let _to = iff(isnull(p_to), now(), p_to);'
        }
        # Two tables are generated into this one rather than typed into the file.
        # See New-GeneratedBlock for why each refuses to publish empty.
        Generate = @('PRICE-BOOK', 'MEMBERSHIP')
        Help    = 'ClaudeCost() for the last day, ClaudeCost(startofmonth(now()), now()) for the month to date.'
    }
)

function New-GeneratedBlock {
    <#
        Replaces a marked block in a .kql file with a table built from live
        configuration, and refuses if the markers are gone.

        The refusal matters more than the substitution. Both tables have a
        placeholder that parses and runs: an empty price table prices every
        model at null, and an empty membership table attributes every request to
        whatever the gateway stamped at the time. Neither errors. A publish that
        quietly skipped the substitution would produce a function that returns a
        confident, wrong number - which is the failure this whole file is
        written to avoid.
    #>
    param([string]$Kql, [string]$Marker, [string]$Block, [string]$File)

    $begin = "// $Marker-BEGIN"
    $end = "// $Marker-END"
    $s = $Kql.IndexOf($begin)
    $e = $Kql.IndexOf($end)
    if ($s -lt 0 -or $e -lt 0 -or $e -lt $s) {
        throw ("$File no longer contains the $begin / $end markers, so its $Marker table cannot be generated. " +
               "Publishing anyway would leave the placeholder in place, and the placeholder returns a wrong " +
               "answer rather than an error.")
    }
    return $Kql.Substring(0, $s) + $Block + "`n" + $Kql.Substring($e)
}

function New-PriceBlock {
    $path = Join-Path $root 'config/price-book.json'
    if (-not (Test-Path $path)) { $path = Join-Path $root 'config/price-book.example.json' }
    $pb = Get-Content $path -Raw | ConvertFrom-Json
    $models = @($pb.models.PSObject.Properties)
    if (-not $models.Count) { throw "The price book at $path has no models, so nothing could be priced." }

    $rows = @($models | ForEach-Object {
        '    "{0}", {1}, {2}' -f $_.Name, $_.Value.inputPerM, $_.Value.outputPerM
    }) -join ",`n"

    return ("let price_book_date = `"{0}`";`n" -f $pb.date) +
           "let price = datatable(model: string, input_per_m: real, output_per_m: real) [`n$rows`n];"
}

function New-MembershipBlock {
    param([string]$Apim)

    if (-not $Apim) {
        $Apim = az apim list -g $ResourceGroup --query "[0].name" -o tsv 2>$null
        if ($Apim) { $Apim = $Apim.Trim() }
    }
    if (-not $Apim) {
        throw ("No API Management instance found in $ResourceGroup, so business unit membership could not be read. " +
               "ClaudeCost attributes spend to the unit a developer belongs to today; without the mapping it would " +
               "fall back to whatever was stamped at request time and disagree with Get-ClaudeBusinessUnit.ps1. " +
               "Pass -ApimName.")
    }

    $members = az apim nv show -g $ResourceGroup --service-name $Apim --named-value-id 'bu-members' --query value -o tsv 2>$null
    $parents = az apim nv show -g $ResourceGroup --service-name $Apim --named-value-id 'bu-parents' --query value -o tsv 2>$null

    $parentOf = @{}
    foreach ($e in @(($parents -as [string]).Trim(',') -split ',' | Where-Object { $_ })) {
        if ($e -match '^(.+?)=(.+)$') { $parentOf[$Matches[1]] = $Matches[2] }
    }

    $rows = @(foreach ($e in @(($members -as [string]).Trim(',') -split ',' | Where-Object { $_ })) {
        if ($e -match '^(.+?)=(.+)$') {
            $oid = $Matches[1]; $unit = $Matches[2]
            '    "{0}", "{1}", "{2}"' -f $oid, $unit, $(if ($parentOf[$unit]) { $parentOf[$unit] } else { '' })
        }
    })

    # An empty mapping is published deliberately as an empty table rather than
    # refused: a gateway with no business units yet is a legitimate state, and
    # every row then reports attribution "stamped", which is accurate. What is
    # refused above is being unable to *ask* - that is not the same as the
    # answer being none.
    $body = if ($rows.Count) { ($rows -join ",`n") } else { '    "", "", ""' }

    return ("let membership_date = `"{0}`";`n" -f (Get-Date -Format 'yyyy-MM-dd')) +
           "let membership = datatable(oid: string, unit: string, parent: string) [`n$body`n];"
}

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

    foreach ($marker in @($q.Generate)) {
        if (-not $marker) { continue }
        $block = switch ($marker) {
            'PRICE-BOOK' { New-PriceBlock }
            'MEMBERSHIP' { New-MembershipBlock -Apim $ApimName }
            default      { throw "Unknown generated block '$marker' in $($q.Alias)." }
        }
        $kql = New-GeneratedBlock -Kql $kql -Marker $marker -Block $block -File $q.File
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
