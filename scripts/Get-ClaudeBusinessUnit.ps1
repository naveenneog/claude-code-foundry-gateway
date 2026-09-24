<#
.SYNOPSIS
    Business units, their budgets, their members and what they have spent.

.DESCRIPTION
    The reporting half of business unit chargeback. It shows what the gateway
    would actually apply, so it reads the live named values rather than a
    configuration file that may have drifted from them.

    Spend comes from the P18 ledger, which is the built-in API Management LLM log
    joined to identity. Two things about that figure, both stated in the output
    rather than left for a reader to discover:

      It is list price. Azure bills Claude as a single aggregated Claude
      Consumption Unit meter and private-offer discounts are applied before that
      conversion, so this cannot be reconciled to an invoice. U2 covers what
      would close the gap.

      It excludes cached tokens. No API Management source carries the cache
      categories per request, and the quota counter does not count them at all -
      on thirty days of live usage that was 38.7% of the real cost weight. Real
      spend is therefore higher than shown, not lower.

.PARAMETER BusinessUnit
    Report one business unit rather than all of them.

.PARAMETER Days
    How far back to total spend. Defaults to the current month to date.

.PARAMETER AsJson
    Emit JSON instead of a table.

.EXAMPLE
    ./scripts/Get-ClaudeBusinessUnit.ps1

.EXAMPLE
    ./scripts/Get-ClaudeBusinessUnit.ps1 -BusinessUnit finance -AsJson
#>
[CmdletBinding()]
param(
    [string]$BusinessUnit,
    [int]$Days,
    [switch]$AsJson,
    [string]$ResourceGroup = $(& (Join-Path $PSScriptRoot 'Get-ClaudeGatewayTarget.ps1') ResourceGroup),
    [string]$ApimName,
    [string]$Model = 'claude-sonnet-5',
    [decimal]$OutputShare = 0.2
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'ApimNamedValue.ps1')
. (Join-Path $PSScriptRoot 'ClaudeBusinessUnit.ps1')

$sub = az account show --query id -o tsv 2>$null
if (-not $sub) { throw 'Not signed in. Run: az login' }
if (-not $ApimName) {
    $ApimName = az apim list -g $ResourceGroup --query "[0].name" -o tsv 2>$null
    if (-not $ApimName) { throw "No API Management instance in $ResourceGroup. Pass -ApimName." }
}

$registry = @(ConvertFrom-ClaudeBuRegistry (Get-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id 'bu-registry'))
$members = ConvertFrom-ClaudeBuMembers (Get-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id 'bu-members')
$parents = ConvertFrom-ClaudeBuParents (Get-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id 'bu-parents')
$unassignedMode = Get-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id 'bu-unassigned'
if (-not $unassignedMode) { $unassignedMode = 'allow' }

# Everyone entitled, so the unassigned can be counted rather than guessed.
function Split-Sentinel($v) { if (-not $v) { return @() }; return @($v.Trim(',') -split ',' | Where-Object { $_ }) }
$entitled = @(Split-Sentinel (Get-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id 'allow-standard')) +
            @(Split-Sentinel (Get-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id 'allow-premium'))
$entitled = @($entitled | Select-Object -Unique)

# Spend per business unit, from the ledger.
$spend = @{}
$ledgerRead = $false
try {
    $telemetry = & (Join-Path $PSScriptRoot 'Get-ClaudeTelemetry.ps1') -ResourceGroup $ResourceGroup -ApimName $ApimName
    $comp = Invoke-RestMethod -Headers @{ Authorization = 'Bearer ' + (az account get-access-token --resource https://management.azure.com --query accessToken -o tsv).Trim() } `
            -Uri ("https://management.azure.com/subscriptions/$sub/resourceGroups/$ResourceGroup/providers/Microsoft.Insights/components/$($telemetry.AppInsights)" + '?api-version=2020-02-02')
    $ws = $comp.properties.WorkspaceResourceId
    if ($ws) {
        $window = if ($Days) { "ago($($Days)d)" } else { 'startofmonth(now())' }
        # Cache read is not in the per-request log: measured, its token columns
        # are PromptTokens, CompletionTokens and TotalTokens only, and a request
        # that read 10,003 cached tokens recorded none of them.
        #
        # The gateway's own llm-emit-token-metric does emit it, carrying a
        # UserId dimension - the same object id the business-unit map keys on.
        # Measured 2026-09-17 on the reference workspace: AppMetrics holds
        # 6,833,717 cached tokens against UserId 43cc5304. So cache is attributed
        # here at per-user granularity rather than per request, which is the
        # granularity chargeback bills at anyway.
        #
        # union rather than join, in both directions: a caller can have metered
        # requests whose trace never landed, and a metric row whose request did
        # not. Either side alone would silently drop one of them.
        $kql = @"
let metered = ApiManagementGatewayLlmLog
| where TimeGenerated >= $window
| project rid = tostring(CorrelationId), prompt = toreal(PromptTokens), completion = toreal(CompletionTokens);
let attributed = AppTraces
| where TimeGenerated >= $window
| where Properties.RequestId != ""
| project rid = tostring(Properties.RequestId), user_id = tostring(Properties.UserId)
| join kind=inner metered on rid
| summarize tokens = sum(prompt + completion), requests = count() by user_id;
let cached = AppMetrics
| where TimeGenerated >= $window
| where Name == "Prompt Cached Tokens"
| summarize cache_read = sum(Sum) by user_id = tostring(Properties.UserId);
union
    (attributed | extend cache_read = 0.0),
    (cached | extend tokens = 0.0, requests = 0)
| summarize tokens = sum(tokens), requests = sum(requests), cache_read = sum(cache_read) by user_id
"@
        $qt = (az account get-access-token --resource https://api.applicationinsights.io --query accessToken -o tsv).Trim()
        $res = Invoke-RestMethod -Uri "https://api.loganalytics.io/v1$ws/query" -Method Post -ContentType 'application/json' `
               -Headers @{ Authorization = 'Bearer ' + $qt } -Body (@{ query = $kql } | ConvertTo-Json)
        $cols = @($res.tables[0].columns.name)
        foreach ($row in $res.tables[0].rows) {
            $uid = [string]$row[$cols.IndexOf('user_id')]
            $bu = if ($members.Contains($uid)) { $members[$uid] } else { 'unassigned' }
            if (-not $spend.ContainsKey($bu)) { $spend[$bu] = @{ Tokens = [long]0; Requests = 0; CacheRead = [long]0 } }
            $spend[$bu].Tokens += [long]$row[$cols.IndexOf('tokens')]
            $spend[$bu].Requests += [int]$row[$cols.IndexOf('requests')]
            $spend[$bu].CacheRead += [long]$row[$cols.IndexOf('cache_read')]
        }
        $ledgerRead = $true
    }
}
catch { Write-Warning "Could not read the ledger, so spend is not shown: $($_.Exception.Message)" }

$records = @()
foreach ($u in $registry) {
    if ($BusinessUnit -and $u.Id -ne $BusinessUnit) { continue }
    $memberCount = @($members.Keys | Where-Object { $members[$_] -eq $u.Id }).Count
    $own = if ($spend.ContainsKey($u.Id)) { [long]$spend[$u.Id].Tokens } else { 0 }

    # A team's members are mapped to the team, not to the business unit above
    # it, so a parent read straight from the ledger would show zero while its
    # counter was filling up. The gateway charges a request to its unit and to
    # that unit's parent, so the parent's figure has to be the roll-up or the
    # percentage would not match what enforcement is doing. See ADR-0008.
    $childIds = @($parents.Keys | Where-Object { $parents[$_] -eq $u.Id })
    $childTokens = 0
    $childRequests = 0
    foreach ($c in $childIds) {
        if ($spend.ContainsKey($c)) {
            $childTokens += [long]$spend[$c].Tokens
            $childRequests += [int]$spend[$c].Requests
        }
    }
    $used = $own + $childTokens
    $memberCount += @($members.Keys | Where-Object { $members[$_] -in $childIds }).Count

    $ownCache = if ($spend.ContainsKey($u.Id)) { [long]$spend[$u.Id].CacheRead } else { 0 }
    $childCache = 0
    foreach ($c in $childIds) { if ($spend.ContainsKey($c)) { $childCache += [long]$spend[$c].CacheRead } }
    $cacheRead = $ownCache + $childCache

    $records += [ordered]@{
        id              = $u.Id
        parent          = $(if ($parents[$u.Id]) { $parents[$u.Id] } else { $null })
        teams           = $childIds
        group           = $u.Group
        members         = $memberCount
        tokens_per_month = $u.TokensPerMonth
        budget_usd_estimate = ConvertTo-ClaudeBuUsd -Tokens $u.TokensPerMonth -Model $Model -OutputShare $OutputShare
        tokens_used     = $used
        tokens_used_own = $own
        used_usd_estimate = ConvertTo-ClaudeBuUsd -Tokens $used -Model $Model -OutputShare $OutputShare
        # Cache read, attributed from the gateway's own emitted metric. Kept as
        # its own line rather than folded into tokens_used, because the quota
        # that enforces the budget still cannot see it - reporting it inside the
        # same number would imply the budget counts it.
        tokens_cache_read = $cacheRead
        cache_read_usd_estimate = ConvertTo-ClaudeCacheUsd -Tokens $cacheRead -Model $Model
        percent_used    = $(if ($u.TokensPerMonth -gt 0) { [math]::Round(($used / $u.TokensPerMonth) * 100, 1) } else { $null })
        requests        = $(if ($spend.ContainsKey($u.Id)) { $spend[$u.Id].Requests } else { 0 }) + $childRequests
    }
}

$assigned = @($members.Keys)
$unassigned = @($entitled | Where-Object { $_ -notin $assigned })

$envelope = [ordered]@{
    gateway = $ApimName
    business_units = $records
    unassigned = [ordered]@{
        developers = $unassigned.Count
        behaviour  = $unassignedMode
        tokens_used = $(if ($spend.ContainsKey('unassigned')) { [long]$spend['unassigned'].Tokens } else { 0 })
    }
    cost_basis = [ordered]@{
        source          = 'list price'
        price_book_date = $ClaudePriceBookDate
        model_assumed   = $Model
        output_share    = $OutputShare
        # Cache read is now attributed, from the gateway's emitted metric, at
        # per-user granularity. Cache *write* is not: the 5-minute and 1-hour
        # categories exist only in the Anthropic response body, and reading that
        # in an outbound policy buffers the response and ends streaming.
        cache_read_known       = $true
        excludes_cache_write   = $true
        # The budget still cannot see any cache category. Reporting it and
        # enforcing it are different mechanisms - U13.
        budget_counts_cache    = $false
        reconciled_to_invoice  = $false
    }
    ledger_read = $ledgerRead
}

if ($AsJson) { $envelope | ConvertTo-Json -Depth 10; exit 0 }

Write-Host ''
Write-Host ("Business units on {0}" -f $ApimName) -ForegroundColor Cyan
if (-not $records.Count) {
    Write-Host '  None defined. Add one with ./scripts/Set-ClaudeBusinessUnit.ps1.' -ForegroundColor DarkGray
}
else {
    Write-Host ''
    Write-Host ("  {0,-16} {1,-24} {2,6} {3,13} {4,13} {5,6} {6,13}" -f 'Id', 'Entra group', 'Members', 'Budget', 'Used', 'Used %', 'Cache read')
    Write-Host ('  ' + ('-' * 96)) -ForegroundColor DarkGray

    # Business units first, each followed by its teams.
    $tops = @($records | Where-Object { -not $_.parent })
    $ordered = @()
    foreach ($t in $tops) {
        $ordered += $t
        $ordered += @($records | Where-Object { $_.parent -eq $t.id })
    }
    $ordered += @($records | Where-Object { $ordered -notcontains $_ })

    foreach ($r in $ordered) {
        $name = if ($r.parent) { '  ' + $r.id } else { $r.id }
        Write-Host ("  {0,-16} {1,-24} {2,6} {3,13:n0} {4,13:n0} {5,6} {6,13:n0}" -f `
            $name, $r.group, $r.members, $r.tokens_per_month, $r.tokens_used,
            $(if ($null -ne $r.percent_used) { "$($r.percent_used)%" } else { '-' }),
            $r.tokens_cache_read)
    }
    if (@($records | Where-Object { $_.parent }).Count) {
        Write-Host ''
        Write-Host '  An indented row is a team. A parent row totals its own members and its teams,' -ForegroundColor DarkGray
        Write-Host '  because the gateway charges a request to the team and to the unit above it.' -ForegroundColor DarkGray
    }
}

Write-Host ''
Write-Host ("  Unassigned developers: {0}  (behaviour: {1})" -f $unassigned.Count, $unassignedMode) -ForegroundColor $(if ($unassigned.Count) { 'Yellow' } else { 'Green' })
if ($unassigned.Count -and $unassignedMode -eq 'allow') {
    Write-Host '  Their usage is served and recorded, but counts against no budget.' -ForegroundColor DarkGray
    Write-Host '  Set bu-unassigned to "deny" once every developer has a business unit.' -ForegroundColor DarkGray
}

Write-Host ''
Write-Host '  Figures are at list price and are not reconciled to an Azure invoice.' -ForegroundColor DarkGray
Write-Host '  Cache reads are attributed from the gateway metric and shown above; the two' -ForegroundColor DarkGray
Write-Host '  cache write categories are not, so real spend is still somewhat higher than' -ForegroundColor DarkGray
Write-Host '  shown. The budget itself counts neither. See docs/BUSINESS-UNITS.md.' -ForegroundColor DarkGray
if (-not $ledgerRead) { Write-Host '  Spend could not be read from the ledger.' -ForegroundColor Yellow }
