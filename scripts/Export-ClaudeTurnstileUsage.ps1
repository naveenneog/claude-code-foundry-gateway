<#
.SYNOPSIS
    Sends the gateway's per-request Claude usage to Turnstile.

.DESCRIPTION
    Turnstile is a FinOps console for AI spend. This makes the Claude traffic
    that passes through this gateway appear in it, priced the way the
    chargeback report prices it, without Turnstile enforcing anything on that
    traffic: the gateway stays the one enforcer. docs/TURNSTILE.md has the
    design and the measurements behind it.

    It reads the chargeback ledger (analytics/chargeback-ledger.kql) for a
    window, maps each request to Turnstile's usage event, checks every event
    against the rules Turnstile's ingest enforces, and sends them to
    Turnstile's Event Hub. The window is read in slices, and a slice sends
    nothing unless every event in it passes the check: Turnstile would skip a
    bad event silently, and a partial export reads as complete. A failing slice
    stops the export with an error. Slices already sent are harmless to send
    again, so the fix is to re-run the same window.

    Stateless. Each run re-reads a lookback window that ends a lag before now,
    and Turnstile keys rows on the request id, so a run every hour with the
    default two-hour lookback sends each request about twice and records it
    once. There is no watermark to lose.

.PARAMETER EventHubNamespace
    Turnstile's Event Hubs namespace - its deployment output
    eventHubNamespaceName. The identity running this needs Azure Event Hubs
    Data Sender on the hub, and Log Analytics Reader on the gateway's
    workspace.

.PARAMETER EventHubName
    Turnstile's hub - its deployment output eventHubName.

.PARAMETER PriceSource
    Gateway (the default) sends each request's cost from this repository's
    price book, so Turnstile and the chargeback report agree. Turnstile sends
    no cost and lets Turnstile price rows from its own model registry, which
    must then list the Claude models or the rows land at zero.

.PARAMETER From
    Start of an explicit window, for a backfill. With -To, replaces the
    lookback. Sending a period again is harmless.

.PARAMETER SliceMinutes
    The ledger is read in slices of this length. The Log Analytics query API
    returns at most 500,000 rows and 64 MB, so a busy gateway needs shorter
    slices; a partial result stops the export rather than sending part of it.

.PARAMETER ThrottleLimit
    Slices to run at once, on PowerShell 7. Measured on a laptop, one process
    maps, checks and serialises about 1,470 events a second; docs/TURNSTILE.md
    works out how many run side by side a given request volume needs. The Log
    Analytics API allows five concurrent queries per caller, so more than five
    only helps while slices are sending rather than querying.

.PARAMETER NoCacheEvents
    Skip the hourly cache-read rows. The per-request rows carry no cache,
    because the per-request log has none (ADR-0006).

.PARAMETER OutFile
    Write the events as JSON lines instead of sending them. For review, and
    for scripts/Test-ClaudeTurnstileContract.ps1.

.EXAMPLE
    ./scripts/Export-ClaudeTurnstileUsage.ps1 -OutFile ./turnstile-events.jsonl

.EXAMPLE
    ./scripts/Export-ClaudeTurnstileUsage.ps1 -EventHubNamespace evhns-turnstile-prod -EventHubName token-usage

.EXAMPLE
    # Backfill a month, a day per slice.
    ./scripts/Export-ClaudeTurnstileUsage.ps1 -EventHubNamespace evhns-turnstile-prod -EventHubName token-usage `
        -From 2026-09-01 -To 2026-10-01 -SliceMinutes 1440
#>
[CmdletBinding()]
param(
    [string]$ResourceGroup = $(if ($env:CLAUDE_RG) { $env:CLAUDE_RG } else { 'rg-contosohub' }),
    [string]$ApimName,
    [string]$WorkspaceResourceId,
    [string]$EventHubNamespace,
    [string]$EventHubName,
    [ValidateSet('Gateway', 'Turnstile')][string]$PriceSource,
    [int]$LookbackMinutes = 120,
    [int]$LagMinutes = 15,
    [int]$CacheSettleMinutes = 30,
    [Nullable[datetime]]$From = $null,
    [Nullable[datetime]]$To = $null,
    [int]$SliceMinutes = 60,
    [ValidateRange(1, 16)][int]$ThrottleLimit = 1,
    [switch]$NoCacheEvents,
    [string]$OutFile,
    [int]$MaxBatchBytes = 240000,
    [switch]$AsJson
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'ApimNamedValue.ps1')
. (Join-Path $PSScriptRoot 'ClaudeBusinessUnit.ps1')
. (Join-Path $PSScriptRoot 'ClaudeTurnstile.ps1')
. (Join-Path $PSScriptRoot 'ClaudeTurnstileGovernance.ps1')

if ($SliceMinutes -lt 1) { throw 'SliceMinutes must be at least 1.' }
if (($From -and -not $To) -or ($To -and -not $From)) { throw 'Pass -From and -To together, or neither.' }

$sub = az account show --query id -o tsv 2>$null
if (-not $sub) { throw 'Not signed in. Run: az login' }
if (-not $ApimName) {
    $ApimName = az apim list -g $ResourceGroup --query "[0].name" -o tsv 2>$null
    if (-not $ApimName) { throw "No API Management instance in $ResourceGroup. Pass -ApimName." }
}

# Where to send and how to price come from the gateway's Turnstile connection
# (Connect-ClaudeTurnstile.ps1) unless given here. Nothing about a Turnstile deployment
# is assumed by this script.
$integration = ConvertFrom-ClaudeTurnstileIntegrationValue (Get-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id $script:TurnstileIntegrationNamedValue)
$PriceSource = Resolve-ClaudeTurnstileSetting $PriceSource $integration 'priceSource' 'PriceSource' 'Gateway'
if (-not $OutFile) {
    $EventHubNamespace = Resolve-ClaudeTurnstileSetting $EventHubNamespace $integration 'eventHubNamespace' 'EventHubNamespace'
    $EventHubName = Resolve-ClaudeTurnstileSetting $EventHubName $integration 'eventHubName' 'EventHubName'
}

if (-not $WorkspaceResourceId) {
    $telemetry = & (Join-Path $PSScriptRoot 'Get-ClaudeTelemetry.ps1') -ResourceGroup $ResourceGroup -ApimName $ApimName
    $arm = (az account get-access-token --resource https://management.azure.com --query accessToken -o tsv).Trim()
    $comp = Invoke-RestMethod -Headers @{ Authorization = "Bearer $arm" } `
        -Uri ("https://management.azure.com/subscriptions/$sub/resourceGroups/$ResourceGroup/providers/Microsoft.Insights/components/$($telemetry.AppInsights)" + '?api-version=2020-02-02')
    $WorkspaceResourceId = $comp.properties.WorkspaceResourceId
    if (-not $WorkspaceResourceId) { throw "The gateway's Application Insights is not workspace-based, so there is no ledger to read." }
}

# A team's organization in Turnstile is its business unit (ADR-0008).
$parents = ConvertFrom-ClaudeBuParents (Get-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id 'bu-parents')
if (-not $parents) { $parents = @{} }

$window = Get-ClaudeTurnstileWindow -NowUtc ([datetime]::UtcNow) -LookbackMinutes $LookbackMinutes -LagMinutes $LagMinutes `
    -CacheSettleMinutes $CacheSettleMinutes -From $From -To $To
$ledgerKql = Get-Content (Join-Path (Split-Path $PSScriptRoot -Parent) 'analytics/chargeback-ledger.kql') -Raw

$slices = @()
$cursor = $window.From
while ($cursor -lt $window.To) {
    $next = $cursor.AddMinutes($SliceMinutes)
    if ($next -gt $window.To) { $next = $window.To }
    $slices += [pscustomobject]@{ From = $cursor; To = $next }
    $cursor = $next
}

$sliceArgs = @{
    WorkspaceResourceId = $WorkspaceResourceId
    LedgerKql           = $ledgerKql
    Parents             = $parents
    PriceSource         = $PriceSource
    Namespace           = $EventHubNamespace
    EventHub            = $EventHubName
    MaxBatchBytes       = $MaxBatchBytes
    ReturnBodies        = [bool]$OutFile
}
if ($ThrottleLimit -gt 1 -and $PSVersionTable.PSVersion.Major -ge 7) {
    # Slices are independent, so they run side by side. The Log Analytics API
    # allows five concurrent queries per caller, which is why the default
    # ceiling is five. Each runspace loads the libraries itself.
    $libs = @((Join-Path $PSScriptRoot 'ClaudeBusinessUnit.ps1'), (Join-Path $PSScriptRoot 'ClaudeTurnstile.ps1'))
    $results = @($slices | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
        $ErrorActionPreference = 'Stop'
        foreach ($lib in $using:libs) { . $lib }
        $a = $using:sliceArgs
        Invoke-ClaudeTurnstileSlice @a -From $_.From -To $_.To
    })
}
else {
    if ($ThrottleLimit -gt 1) { Write-Warning 'Parallel slices need PowerShell 7; running them one at a time.' }
    $results = @(foreach ($s in $slices) { Invoke-ClaudeTurnstileSlice @sliceArgs -From $s.From -To $s.To })
}

# Cache reads, per developer, model and complete hour. Read and sent on their
# own, after the requests, with the same check before anything leaves.
$cacheEvents = New-Object System.Collections.Generic.List[object]
if (-not $NoCacheEvents -and $window.CacheHours -gt 0) {
    foreach ($row in @(Invoke-ClaudeLedgerQuery -WorkspaceResourceId $WorkspaceResourceId -Kql (Get-ClaudeTurnstileCacheQuery -From $window.CacheFrom -To $window.CacheTo))) {
        $cacheEvents.Add((ConvertTo-ClaudeTurnstileCacheEvent -Row $row -Parents $parents -PriceSource $PriceSource))
    }
}
$rejected = Test-ClaudeTurnstileEventSet -Events $cacheEvents.ToArray()
if ($rejected.Count) {
    throw ("The cache-read rows were not sent: $($rejected.Count) problem(s) would make Turnstile skip or distort them.`n" + (($rejected | Select-Object -First 10) -join "`n"))
}
$cacheBodies = @($cacheEvents | ForEach-Object { ConvertTo-ClaudeTurnstileJson -Event $_ })
$cacheBatches = 0
if ($OutFile) {
    $all = New-Object System.Collections.Generic.List[string]
    foreach ($r in $results) { foreach ($b in $r.Bodies) { $all.Add($b) } }
    foreach ($b in $cacheBodies) { $all.Add($b) }
    [IO.File]::WriteAllLines([IO.Path]::GetFullPath($OutFile), $all.ToArray(), (New-Object System.Text.UTF8Encoding($false)))
    $destination = $OutFile
}
else {
    if ($cacheBodies.Count) {
        # Not wrapped in @(): the function returns its array as one object so
        # an empty result survives, and @() would make that a one-element array
        # whose element is the whole batch list.
        $batches = Split-ClaudeEventBatch -Bodies $cacheBodies -MaxBytes $MaxBatchBytes
        $ehToken = (az account get-access-token --resource https://eventhubs.azure.net --query accessToken -o tsv).Trim()
        foreach ($b in $batches) { Send-ClaudeEventHubBatch -Namespace $EventHubNamespace -EventHub $EventHubName -Batch $b -Token $ehToken }
        $cacheBatches = $batches.Count
    }
    $destination = "$EventHubNamespace/$EventHubName"
}

$cacheCost = [decimal]0
$cacheUnpriced = @()
foreach ($e in $cacheEvents) { if ($e.Contains('estimated_cost')) { $cacheCost += [decimal]$e['estimated_cost'] } else { $cacheUnpriced += [string]$e['model'] } }
$requestCost = [decimal]0
foreach ($r in $results) { $requestCost += [decimal]$r.CostUsd }
$unpricedModels = @(@($results | ForEach-Object { $_.Unpriced }) + $cacheUnpriced | Where-Object { $_ } | Sort-Object -Unique)
$unpricedCount = @($results | ForEach-Object { $_.Unpriced } | Where-Object { $_ }).Count + $cacheUnpriced.Count
if ($PriceSource -eq 'Gateway' -and $unpricedCount) {
    Write-Warning ("$unpricedCount event(s) on models the price book does not list ($($unpricedModels -join ', ')) were sent without a cost. " +
        'Turnstile prices them from its registry, or records zero. Add the model with ./scripts/Add-ClaudeModel.ps1.')
}

$summary = [pscustomobject][ordered]@{
    From            = $window.From.ToString('o')
    To              = $window.To.ToString('o')
    Slices          = $slices.Count
    ThrottleLimit   = $ThrottleLimit
    CacheHours      = $(if ($NoCacheEvents) { 0 } else { $window.CacheHours })
    Requests        = [long]($results | Measure-Object -Property Requests -Sum).Sum
    CacheEvents     = $cacheEvents.Count
    InputTokens     = [long]($results | Measure-Object -Property InputTokens -Sum).Sum
    OutputTokens    = [long]($results | Measure-Object -Property OutputTokens -Sum).Sum
    CacheReadTokens = [long]($cacheEvents | ForEach-Object { $_['cached_tokens'] } | Measure-Object -Sum).Sum
    RequestCostUsd  = [math]::Round($requestCost, 4)
    CacheCostUsd    = [math]::Round($cacheCost, 4)
    CostUsd         = [math]::Round($requestCost + $cacheCost, 4)
    PriceSource     = $PriceSource
    PriceBookDate   = $script:ClaudePriceBookDate
    Unpriced        = $unpricedCount
    UnpricedModels  = $unpricedModels
    # Requests that carried tokens but no caller. Measured as the three
    # requests logged before the caller trace shipped on the reference
    # gateway; a new one is a gap to investigate.
    Unattributed    = [long]($results | Measure-Object -Property Unattributed -Sum).Sum
    Batches         = [long]($results | Measure-Object -Property Batches -Sum).Sum + $cacheBatches
    Sent            = (-not $OutFile)
    Destination     = $destination
}
if ($AsJson) { $summary | ConvertTo-Json -Depth 4 } else { $summary }