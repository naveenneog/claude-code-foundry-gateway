<#
.SYNOPSIS
    Publishes the Claude dashboards to Azure Managed Grafana.

.DESCRIPTION
    Optional, and the only observability option here with a standing bill. The
    workbook covers the same ground for nothing - it is an ARM definition that
    runs when somebody opens it - so this exists for organisations that already
    run Grafana and want Claude spend on the same wall as everything else, not
    as the default.

    Azure Managed Grafana is priced per instance per hour, and the Essential
    tier has no SLA. Before running this, check that the answer to "why Grafana
    rather than the workbook" is something other than "it looks better", because
    the difference is a monthly charge that the workbook does not have.
    - https://azure.microsoft.com/pricing/details/managed-grafana/

    It does not create the Grafana instance. Standing one up is a decision with
    a cost attached and belongs in whatever provisions your other shared
    infrastructure, not in a script that was run to publish a dashboard.

    The dashboard reads the same saved KQL functions as the workbook, so publish
    those first with ./scripts/Publish-ClaudeQueries.ps1. Two consumers, one
    query definition - a Grafana panel with its own copy of the KQL is a second
    thing to keep current.

.PARAMETER GrafanaName
    An existing Azure Managed Grafana instance.

.PARAMETER List
    Show the Grafana instances in the subscription, and exit.

.EXAMPLE
    ./scripts/Publish-ClaudeGrafana.ps1 -List
    ./scripts/Publish-ClaudeGrafana.ps1 -GrafanaName graf-platform
#>
[CmdletBinding()]
param(
    [string]$GrafanaName,
    [switch]$List,
    [string]$ResourceGroup = $(& (Join-Path $PSScriptRoot 'Get-ClaudeGatewayTarget.ps1') ResourceGroup),
    [string]$WorkspaceName,
    [string]$SubscriptionId
)

$ErrorActionPreference = 'Stop'

function Get-Token {
    $t = az account get-access-token --resource https://management.azure.com --query accessToken -o tsv 2>$null
    if (-not $t) { throw "Could not acquire an Azure Resource Manager token. Run: az login" }
    return $t.Trim()
}

if (-not $SubscriptionId) { $SubscriptionId = az account show --query id -o tsv }
$headers = @{ Authorization = "Bearer $(Get-Token)"; 'Content-Type' = 'application/json' }

function Invoke-Grafana {
    # az grafana lives in the amg extension, which is not installed by default.
    # Without this the extension's own message is handed to ConvertFrom-Json,
    # which fails on the first letter and reports a parse error - sending the
    # reader to look at JSON rather than at a missing extension.
    #
    # Azure's own output here is a Python traceback several hundred lines long
    # ending in the prompt it could not show. Repeating that buries the one
    # sentence that matters, so only the extension name is kept.
    param([string[]]$Arguments, [switch]$Soft)
    $out = & az @Arguments 2>&1
    $text = ($out | Out-String)
    $missing = $text -match '(?i)requires the extension|is not in the ''az'' command group|not recognized'
    if ($LASTEXITCODE -ne 0 -or $missing) {
        if ($missing) {
            if ($Soft) { return $null }
            throw ("The Azure CLI needs the Managed Grafana extension for this. Install it with:" +
                   [Environment]::NewLine + "    az extension add --name amg")
        }
        if ($Soft) { return $null }
        # A real failure keeps Azure's words, trimmed to the last few lines -
        # the useful part of an az error is the end, not the traceback.
        $tail = (($text -split "`n") | Where-Object { $_.Trim() } | Select-Object -Last 4) -join ' '
        throw ("az " + ($Arguments -join ' ') + " failed. Azure reported: " + $tail.Trim())
    }
    return $text
}

if ($List) {
    Write-Host ''
    $text = Invoke-Grafana -Soft -Arguments @('grafana', 'list', '--query', "[].{name:name, rg:resourceGroup, sku:sku.name, endpoint:properties.endpoint}", '-o', 'json')
    if ($null -eq $text) {
        # Discovery should not fail because an optional thing is optional.
        Write-Host '  The Azure CLI does not have the Managed Grafana extension, so this cannot look.' -ForegroundColor Yellow
        Write-Host '    az extension add --name amg' -ForegroundColor Cyan
        Write-Host ''
        Write-Host '  You may not need it. The workbook shows the same figures and bills nothing to' -ForegroundColor DarkGray
        Write-Host '  keep, where Grafana is charged per instance per hour whether it is open or not:' -ForegroundColor DarkGray
        Write-Host '    ./scripts/Publish-ClaudeWorkbook.ps1' -ForegroundColor Cyan
        Write-Host ''
        exit 0
    }
    $all = @()
    if ($text.Trim()) { try { $all = @($text | ConvertFrom-Json) } catch { $all = @() } }
    if (-not $all.Count) {
        Write-Host '  No Azure Managed Grafana instance in this subscription.' -ForegroundColor DarkGray
        Write-Host '  The workbook covers the same ground for nothing:' -ForegroundColor DarkGray
        Write-Host '    ./scripts/Publish-ClaudeWorkbook.ps1' -ForegroundColor Cyan
        Write-Host ''
        exit 0
    }
    Write-Host ("  {0,-26} {1,-20} {2,-12} {3}" -f 'Name', 'Resource group', 'SKU', 'Endpoint')
    Write-Host ('  ' + ('-' * 100)) -ForegroundColor DarkGray
    foreach ($g in $all) { Write-Host ("  {0,-26} {1,-20} {2,-12} {3}" -f $g.name, $g.rg, $g.sku, $g.endpoint) }
    Write-Host ''
    exit 0
}

if (-not $GrafanaName) {
    throw ("Pass -GrafanaName, or -List to see what exists. This does not create a Grafana instance: " +
           "that is a standing charge and belongs wherever your other shared infrastructure is provisioned. " +
           "If you do not already run Grafana, ./scripts/Publish-ClaudeWorkbook.ps1 covers the same ground " +
           "for nothing.")
}

$grafText = Invoke-Grafana -Arguments @('grafana', 'show', '-n', $GrafanaName, '--query', '{id:id, endpoint:properties.endpoint, rg:resourceGroup}', '-o', 'json')
if (-not $grafText.Trim()) { throw "No Azure Managed Grafana instance '$GrafanaName' visible in this subscription." }
$g = $grafText | ConvertFrom-Json

if (-not $WorkspaceName) {
    $ws = @((az monitor log-analytics workspace list -g $ResourceGroup --query "[].name" -o tsv 2>$null) -split "`n" | Where-Object { $_ })
    if ($ws.Count -eq 1) { $WorkspaceName = $ws[0].Trim() }
    elseif ($ws.Count -eq 0) { throw "No Log Analytics workspace in '$ResourceGroup'. Pass -WorkspaceName." }
    else { throw ("$($ws.Count) workspaces in '$ResourceGroup': " + ($ws -join ', ') + ". Pass -WorkspaceName - a dashboard bound to the wrong one renders empty and reads as no usage.") }
}
$workspaceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.OperationalInsights/workspaces/$WorkspaceName"

# Same refusal as the workbook: a dashboard whose every panel opens on a
# resolver error reads as broken rather than as a missing step.
$saved = Invoke-RestMethod -Method Get -Headers $headers -Uri "https://management.azure.com$workspaceId/savedSearches?api-version=2020-08-01"
$aliases = @($saved.value | Where-Object { $_.properties.category -eq 'Claude' } | ForEach-Object { $_.properties.functionAlias })
if ($aliases -notcontains 'ClaudeChargeback') {
    throw ("$WorkspaceName has no ClaudeChargeback function, which every panel calls. Run " +
           "./scripts/Publish-ClaudeQueries.ps1 first.")
}

# One query definition, two consumers. A panel carrying its own copy of the KQL
# is a second thing to keep current, and the first to go stale.
function Panel($title, $kql, $x, $y, $w, $h, $viz) {
    return [ordered]@{
        title      = $title
        type       = $viz
        datasource = @{ type = 'grafana-azure-monitor-datasource' }
        gridPos    = @{ x = $x; y = $y; w = $w; h = $h }
        targets    = @(@{
            queryType    = 'Azure Log Analytics'
            azureLogAnalytics = @{
                resource = $workspaceId
                query    = $kql
            }
        })
    }
}

$range = 'ClaudeChargeback($__timeFrom, $__timeTo)'
$dashboard = [ordered]@{
    title         = 'Claude gateway'
    uid           = 'claude-gateway'
    timezone      = 'browser'
    time          = @{ from = 'now-7d'; to = 'now' }
    schemaVersion = 39
    panels        = @(
        Panel 'Read this first' "" 0 0 24 3 'text'
        Panel 'Tokens by business unit' "$range | summarize Tokens = sum(total_tokens) by business_unit | order by Tokens desc" 0 3 8 9 'barchart'
        Panel 'Tokens by client'        "$range | summarize Tokens = sum(total_tokens) by client_surface | order by Tokens desc" 8 3 8 9 'piechart'
        Panel 'Consumption over time'   "$range | summarize Tokens = sum(total_tokens) by bin(timestamp, 1h), business_unit | render timechart" 16 3 8 9 'timeseries'
        Panel 'Developers'              "$range | summarize Requests = count(), Tokens = sum(total_tokens) by actor, business_unit, tier | order by Tokens desc | take 25" 0 12 12 10 'table'
        Panel 'Attribution gaps'        "$range | summarize Requests = count(), NoCaller = countif(actor == 'unattributed'), NoBusinessUnit = countif(business_unit == 'unassigned'), NoClient = countif(client_surface == 'unknown')" 12 12 12 10 'table'
    )
}
# The caveat travels with the numbers, same as the workbook.
$dashboard.panels[0].options = @{ mode = 'markdown'; content = @'
Figures are **list price** and are not reconciled to an Azure invoice. The budget counter
counts prompt and completion tokens only - measured over thirty days, cache reads were
**38.7% of real cost weight**, so real spend is higher than shown, never lower.
Panels read `ClaudeChargeback()`, published by `./scripts/Publish-ClaudeQueries.ps1`.
'@ }

$body = @{ dashboard = $dashboard; overwrite = $true } | ConvertTo-Json -Depth 20

Write-Host ''
Write-Host ("Grafana {0}" -f $GrafanaName) -ForegroundColor Cyan

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("claude-grafana-{0}.json" -f [guid]::NewGuid().ToString('N').Substring(0, 8))
[IO.File]::WriteAllText($tmp, $body)
try {
    Invoke-Grafana -Arguments @('grafana', 'dashboard', 'create', '-n', $GrafanaName, '--definition', "@$tmp", '--overwrite', '-o', 'none') | Out-Null
}
finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }

Write-Host ("  published, reading {0}" -f $WorkspaceName) -ForegroundColor Green
Write-Host ("  {0}/d/claude-gateway" -f $g.endpoint) -ForegroundColor Cyan
Write-Host ''
Write-Host '  Grafana is billed per instance per hour whether or not anyone opens it.' -ForegroundColor Yellow
Write-Host '  The workbook shows the same figures and bills only for the queries it runs.' -ForegroundColor DarkGray
Write-Host ''
