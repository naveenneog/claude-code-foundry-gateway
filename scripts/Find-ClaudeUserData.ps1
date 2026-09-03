<#
.SYNOPSIS
    What the gateway's telemetry holds about one person.

.DESCRIPTION
    The discovery half of a data subject request. Finds records naming a
    developer across the workspace tables this accelerator writes to, and
    reports which of them can actually be deleted.

    That last part matters. Azure Monitor can only purge Analytics-plan tables:
    "You can't purge data from tables that have the Basic and Auxiliary table
    plans"
    (https://learn.microsoft.com/en-us/azure/azure-monitor/logs/personal-data-mgmt,
    retrieved 2026-09-03). Reporting a row as found without saying it cannot be
    removed would be the more damaging half-truth.

    Run this before Remove-ClaudeUserData.ps1. Microsoft's own instruction for
    purge is to "run the query prior to using for a purge request to verify that
    the results are expected", and purge is not reversible.

    Identifiers. The gateway emits the caller's Entra object id as UserId and
    their UPN as User, so either resolves. Passing a UPN resolves it to an
    object id first, because the object id is what the records are keyed on and
    what the purge predicate will use.

.PARAMETER User
    The developer, by UPN or Entra object id.

.PARAMETER Since
    How far back to look. Defaults to 90 days.

.PARAMETER AsJson
    Emit JSON instead of a table. This is the shape Remove-ClaudeUserData.ps1
    consumes.

.EXAMPLE
    ./scripts/Find-ClaudeUserData.ps1 -User someone@contoso.com

.EXAMPLE
    ./scripts/Find-ClaudeUserData.ps1 -User someone@contoso.com -Since 365 -AsJson
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$User,
    [int]$Since = 90,
    [switch]$AsJson,
    [string]$ResourceGroup = $(if ($env:CLAUDE_RG) { $env:CLAUDE_RG } else { 'rg-contosohub' }),
    [string]$ApimName,
    [string]$AppInsightsName
)

$ErrorActionPreference = 'Stop'

$sub = az account show --query id -o tsv 2>$null
if (-not $sub) { throw 'Not signed in. Run: az login' }

# Resolve to an object id. A UPN is what a request arrives with; the object id
# is what the telemetry is keyed on, and what a purge predicate has to name.
$oid = $User.Trim()
$upn = $null
if ($oid -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
    $upn = $oid
    $resolved = az ad user show --id $oid --query id -o tsv 2>$null
    if (-not $resolved) {
        $escaped = $oid.Replace("'", "''")
        $resolved = az ad user list --filter "mail eq '$escaped'" --query "[0].id" -o tsv 2>$null
    }
    if (-not $resolved) { throw "Could not resolve '$User' to an object id. Pass the object id directly." }
    $oid = $resolved.Trim()
}

$telemetry = & (Join-Path $PSScriptRoot 'Get-ClaudeTelemetry.ps1') `
                -ResourceGroup $ResourceGroup -ApimName $ApimName -AppInsightsName $AppInsightsName
$appId = $telemetry.AppId

$armToken = az account get-access-token --resource https://management.azure.com --query accessToken -o tsv 2>$null
$H = @{ Authorization = 'Bearer ' + $armToken.Trim() }

# The workspace behind the Application Insights component. Purge is a workspace
# operation, and classic component resources have been retired.
$component = Invoke-RestMethod -Headers $H -Uri ("https://management.azure.com/subscriptions/$sub/resourceGroups/$ResourceGroup" +
             "/providers/Microsoft.Insights/components/$($telemetry.AppInsights)" + '?api-version=2020-02-02')
$workspaceId = $component.properties.WorkspaceResourceId

# Tables this accelerator can put a developer's identity into.
#
# Two names each, because the two APIs disagree. Queries go through the
# Application Insights API, which uses the classic schema names; purge goes to
# the workspace, which uses the Log Analytics names. Sending "customMetrics" to
# the purge endpoint returns "'customMetrics' is not a valid table" - measured
# 2026-09-03, which is how this was found.
#
# AppGenAIContent is the one that matters for a subject request: when content
# capture is turned on, prompts and responses land there in InputMessages,
# OutputMessages, SystemInstructions, ToolCallArguments and ToolCallResult.
$tables = @(
    @{ Query = 'customMetrics'; Workspace = 'AppMetrics';        Column = 'customDimensions'; PurgeColumn = 'Properties'; Key = 'UserId' },
    @{ Query = 'customEvents';  Workspace = 'AppEvents';         Column = 'customDimensions'; PurgeColumn = 'Properties'; Key = 'UserId' },
    @{ Query = 'requests';      Workspace = 'AppRequests';       Column = 'customDimensions'; PurgeColumn = 'Properties'; Key = 'UserId' },
    @{ Query = 'traces';        Workspace = 'AppTraces';         Column = 'customDimensions'; PurgeColumn = 'Properties'; Key = 'UserId' },
    @{ Query = 'AppGenAIContent'; Workspace = 'AppGenAIContent'; Column = 'Attributes';       PurgeColumn = 'Attributes'; Key = 'UserId' }
)

# Whether a table can be purged is a property of the workspace, not an
# assumption: "You can't purge data from tables that have the Basic and
# Auxiliary table plans". Read it rather than guess it.
$plans = @{}
if ($workspaceId) {
    try {
        $all = Invoke-RestMethod -Headers $H -Uri ("https://management.azure.com$workspaceId/tables" + '?api-version=2022-10-01')
        foreach ($t in $all.value) { $plans[$t.name] = $t.properties.plan }
    }
    catch { Write-Verbose "Could not read table plans: $($_.Exception.Message)" }
}

$queryToken = az account get-access-token --resource https://api.applicationinsights.io --query accessToken -o tsv 2>$null
$QH = @{ Authorization = 'Bearer ' + $queryToken.Trim() }

$findings = @()
foreach ($t in $tables) {
    $kql = @"
$($t.Query)
| where timestamp > ago($($Since)d)
| where tostring($($t.Column).$($t.Key)) == "$oid"
| summarize rows = count(), earliest = min(timestamp), latest = max(timestamp)
"@
    # AppGenAIContent is a workspace table with no timestamp alias, so it is
    # queried on TimeGenerated.
    if ($t.Query -eq 'AppGenAIContent') {
        $kql = @"
AppGenAIContent
| where TimeGenerated > ago($($Since)d)
| where tostring($($t.Column).$($t.Key)) == "$oid"
| summarize rows = count(), earliest = min(TimeGenerated), latest = max(TimeGenerated)
"@
    }
    try {
        $r = Invoke-RestMethod -Uri "https://api.applicationinsights.io/v1/apps/$appId/query" -Method Post `
             -ContentType 'application/json' -Headers $QH -Body (@{ query = $kql } | ConvertTo-Json)
        $cols = @($r.tables[0].columns.name)
        $row = @($r.tables[0].rows)[0]
        $count = if ($row) { [long]$row[$cols.IndexOf('rows')] } else { 0 }
        if ($count -gt 0) {
            $plan = if ($plans.ContainsKey($t.Workspace)) { $plans[$t.Workspace] } else { 'unknown' }
            $findings += [ordered]@{
                table           = $t.Query
                workspace_table = $t.Workspace
                column          = $t.PurgeColumn
                key             = $t.Key
                rows            = $count
                earliest        = $row[$cols.IndexOf('earliest')]
                latest          = $row[$cols.IndexOf('latest')]
                plan            = $plan
                # Analytics only. Basic and Auxiliary cannot be purged, and
                # "unknown" is treated as not purgeable rather than assumed
                # deletable - the safer direction for a compliance answer.
                purgeable       = ($plan -eq 'Analytics')
            }
        }
    }
    catch {
        # A table that does not exist in this workspace is not an error; it is
        # a table the deployment does not use.
        Write-Verbose "Skipped $($t.Query): $($_.Exception.Message)"
    }
}

$result = [ordered]@{
    subject = [ordered]@{
        object_id = $oid
        upn       = $upn
    }
    workspace = [ordered]@{
        app_insights          = $telemetry.AppInsights
        app_id                = $appId
        workspace_resource_id = $workspaceId
    }
    window_days = $Since
    findings    = $findings
    total_rows  = (($findings | ForEach-Object { $_.rows } | Measure-Object -Sum).Sum)
}

if ($AsJson) { $result | ConvertTo-Json -Depth 10; exit 0 }

Write-Host ''
Write-Host ("Subject   {0}" -f $(if ($upn) { "$upn ($oid)" } else { $oid })) -ForegroundColor Cyan
Write-Host ("Workspace {0}" -f $telemetry.AppInsights)
Write-Host ("Window    last {0} day(s)" -f $Since)
Write-Host ''

if (-not $findings.Count) {
    Write-Host '  No records found for this subject in the tables this gateway writes to.' -ForegroundColor Green
    Write-Host '  Other tables in this workspace may hold data written by other instrumentation.' -ForegroundColor DarkGray
    exit 0
}

Write-Host ("{0,-18} {1,10} {2,-22} {3,-22} {4}" -f 'Table', 'Rows', 'Earliest', 'Latest', 'Deletable')
Write-Host ('-' * 96) -ForegroundColor DarkGray
foreach ($f in $findings) {
    Write-Host ("{0,-18} {1,10:n0} {2,-22} {3,-22} {4}" -f $f.table, $f.rows, $f.earliest, $f.latest,
        $(if ($f.purgeable) { "yes ($($f.workspace_table))" } else { "NO - $($f.plan) plan" }))
}
Write-Host ''
Write-Host ("  {0:n0} row(s) across {1} table(s)." -f $result.total_rows, $findings.Count)
Write-Host '  Delete them with ./scripts/Remove-ClaudeUserData.ps1 -User <subject> -Execute.' -ForegroundColor DarkGray
Write-Host '  Purge takes one request per table and completes within Microsoft''s 30-day SLA.' -ForegroundColor DarkGray
