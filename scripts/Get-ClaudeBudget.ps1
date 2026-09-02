<#
.SYNOPSIS
    Effective Claude budgets and month-to-date spend, per developer.

.DESCRIPTION
    The equivalent of reading effective limits and month-to-date spend from
    Claude Enterprise's Admin API, against a Foundry gateway.

    "Effective" means what the gateway would actually apply to that person right
    now: their tier's limits unless a per-user override in quota-overrides
    replaces the daily quota. Reading the named values alone does not tell you
    that, because the override is resolved in the policy at request time.

    Spend comes from the gateway's own Application Insights telemetry, which is
    authoritative for what was served. The token counts have not been reconciled
    against the Azure invoice (U2 in docs/UNKNOWNS.md), so no currency figure is
    reported here - tokens only.

.PARAMETER User
    Report one person, by UPN or object id. Without it, everyone entitled.

.PARAMETER AsJson
    Emit JSON instead of PowerShell objects.

.EXAMPLE
    ./scripts/Get-ClaudeBudget.ps1

.EXAMPLE
    ./scripts/Get-ClaudeBudget.ps1 -User someone@contoso.com

.EXAMPLE
    ./scripts/Get-ClaudeBudget.ps1 -AsJson > budgets.json
#>
[CmdletBinding()]
param(
    [string]$User,
    [switch]$AsJson,
    [string]$ResourceGroup = $(if ($env:CLAUDE_RG) { $env:CLAUDE_RG } else { 'rg-contosohub' }),
    [string]$ApimName,
    [string]$AppInsightsName = $(if ($env:CLAUDE_APPINSIGHTS) { $env:CLAUDE_APPINSIGHTS } else { $null })
)

$ErrorActionPreference = 'Stop'

$sub = az account show --query id -o tsv 2>$null
if (-not $sub) { throw 'Not signed in. Run: az login' }
if (-not $ApimName) {
    $ApimName = az apim list -g $ResourceGroup --query "[0].name" -o tsv 2>$null
    if (-not $ApimName) { throw "No API Management instance in $ResourceGroup. Pass -ApimName." }
}

$armToken = az account get-access-token --resource https://management.azure.com --query accessToken -o tsv 2>$null
$H = @{ Authorization = 'Bearer ' + $armToken.Trim() }
$base = "https://management.azure.com/subscriptions/$sub/resourceGroups/$ResourceGroup/providers/Microsoft.ApiManagement/service/$ApimName"
$v = '?api-version=2024-05-01'

function Get-Nv($name) {
    try { return (Invoke-RestMethod -Uri "$base/namedValues/$name$v" -Headers $H).properties.value }
    catch { return $null }
}

$limits = @{}
foreach ($n in 'tpm-standard', 'quota-standard', 'tpm-premium', 'quota-premium', 'quota-org', 'quota-overrides', 'allow-standard', 'allow-premium') {
    $limits[$n] = Get-Nv $n
}
if ($null -eq $limits['allow-standard'] -and $null -eq $limits['allow-premium']) {
    throw "No Claude named values on $ApimName. Is this the right gateway?"
}

# Sentinel commas, so an object id cannot partially match another.
function Split-Sentinel($value) {
    if (-not $value) { return @() }
    return @($value.Trim(',') -split ',' | Where-Object { $_ })
}
$standard = Split-Sentinel $limits['allow-standard']
$premium = Split-Sentinel $limits['allow-premium']

# ,oid=tokens,oid=tokens,
$overrides = @{}
foreach ($pair in (Split-Sentinel $limits['quota-overrides'])) {
    $bits = $pair -split '=', 2
    if ($bits.Count -eq 2 -and $bits[1] -match '^\d+$') { $overrides[$bits[0]] = [long]$bits[1] }
}

# Month-to-date tokens per developer, from the gateway's own telemetry. Same
# source and window semantics as analytics/claude-code-daily.kql.
#
# The workspace is resolved from the gateway's diagnostic rather than by name.
# Guessing the name reported zero against a workspace the gateway had stopped
# writing to - see scripts/Get-ClaudeTelemetry.ps1.
$spend = @{}
$upnFor = @{}
$appId = $null
try {
    $telemetry = & (Join-Path $PSScriptRoot 'Get-ClaudeTelemetry.ps1') -ResourceGroup $ResourceGroup -ApimName $ApimName -AppInsightsName $AppInsightsName
    $appId = $telemetry.AppId
    if (-not $telemetry.MetricsEnabled) {
        Write-Warning "Metrics are off on the $($telemetry.DiagnosticScope) diagnostic, so no token counts are being recorded. Spend will read zero."
    }
}
catch { Write-Warning "Could not resolve Application Insights - reporting limits without spend. $($_.Exception.Message)" }

if ($appId) {
    $qToken = az account get-access-token --resource https://api.applicationinsights.io --query accessToken -o tsv 2>$null
    $kql = @'
customMetrics
| where timestamp >= startofmonth(now())
| where name in ("Prompt Tokens", "Completion Tokens")
| extend uid = tostring(customDimensions.UserId), upn = tostring(customDimensions.User)
| summarize tokens = sum(valueSum), upn = take_any(upn) by uid
'@
    try {
        $r = Invoke-RestMethod -Uri "https://api.applicationinsights.io/v1/apps/$appId/query" -Method Post `
             -ContentType 'application/json' -Headers @{ Authorization = 'Bearer ' + $qToken.Trim() } `
             -Body (@{ query = $kql } | ConvertTo-Json)
        $cols = @($r.tables[0].columns.name)
        foreach ($row in $r.tables[0].rows) {
            $uid = [string]$row[$cols.IndexOf('uid')]
            $spend[$uid] = [long]$row[$cols.IndexOf('tokens')]
            $upnFor[$uid] = [string]$row[$cols.IndexOf('upn')]
        }
    }
    catch { Write-Warning "Could not read spend: $($_.Exception.Message)" }
}

$records = @()
foreach ($entry in @(@{ oids = $premium; tier = 'premium' }, @{ oids = $standard; tier = 'standard' })) {
    foreach ($oid in $entry.oids) {
        # Premium wins when someone is in both groups, matching the policy's own
        # order of checks.
        if ($entry.tier -eq 'standard' -and $premium -contains $oid) { continue }

        $tierQuota = if ($entry.tier -eq 'premium') { [long]$limits['quota-premium'] } else { [long]$limits['quota-standard'] }
        $override = if ($overrides.ContainsKey($oid)) { $overrides[$oid] } else { $null }

        $records += [ordered]@{
            object_id = $oid
            upn       = $(if ($upnFor.ContainsKey($oid)) { $upnFor[$oid] } else { $null })
            tier      = $entry.tier
            effective = [ordered]@{
                tokens_per_minute   = $(if ($entry.tier -eq 'premium') { [long]$limits['tpm-premium'] } else { [long]$limits['tpm-standard'] })
                tokens_per_day      = $(if ($null -ne $override) { $override } else { $tierQuota })
                tokens_per_day_from = $(if ($null -ne $override) { 'override' } else { 'tier' })
                tier_default_per_day = $tierQuota
            }
            month_to_date = [ordered]@{
                tokens = $(if ($spend.ContainsKey($oid)) { $spend[$oid] } else { 0 })
                # U2 is open: emitted token counts have not been reconciled
                # against the Azure invoice, so no money figure is reported.
                cost_reported = $false
            }
        }
    }
}

if ($User) {
    $needle = $User.Trim()
    $records = @($records | Where-Object { $_.object_id -eq $needle -or ($_.upn -and $_.upn -eq $needle) })
    if (-not $records.Count) { throw "No entitled developer matches '$User'. Check the object id or UPN." }
}

$orgSpent = ($spend.Values | Measure-Object -Sum).Sum
$envelope = [ordered]@{
    gateway = $ApimName
    organisation = [ordered]@{
        tokens_per_month  = [long]$limits['quota-org']
        month_to_date     = [long]$orgSpent
        # The policy reference states high-concurrency requests can temporarily
        # exceed the limit, and that it is tracked per gateway rather than
        # aggregated across an instance.
        soft_cap          = $true
        per_gateway       = $true
    }
    developers = $records
}

if ($AsJson) { $envelope | ConvertTo-Json -Depth 10 }
else {
    Write-Host ''
    Write-Host ("Gateway {0}" -f $ApimName) -ForegroundColor Cyan
    Write-Host ("Organisation  {0,15:n0} tokens/month   {1,15:n0} used this month   (soft cap, per gateway)" -f `
        $envelope.organisation.tokens_per_month, $envelope.organisation.month_to_date)
    Write-Host ''
    Write-Host ("{0,-38} {1,-9} {2,12} {3,14} {4,-9} {5,14}" -f 'Developer', 'Tier', 'Tokens/min', 'Tokens/day', 'From', 'Used (MTD)')
    Write-Host ('-' * 100) -ForegroundColor DarkGray
    foreach ($rec in $records) {
        Write-Host ("{0,-38} {1,-9} {2,12:n0} {3,14:n0} {4,-9} {5,14:n0}" -f `
            $(if ($rec.upn) { $rec.upn } else { $rec.object_id }),
            $rec.tier, $rec.effective.tokens_per_minute, $rec.effective.tokens_per_day,
            $rec.effective.tokens_per_day_from, $rec.month_to_date.tokens)
    }
    Write-Host ''
    Write-Host 'Token counts are not reconciled against the Azure invoice, so no cost is shown. See docs/UNKNOWNS.md U2.' -ForegroundColor DarkGray
    Write-Host 'Change a daily budget with ./scripts/Set-ClaudeBudget.ps1.' -ForegroundColor DarkGray
}
