<#
.SYNOPSIS
    Delete everything the gateway's telemetry holds about one person.

.DESCRIPTION
    The deletion half of a data subject request, using Azure Monitor's Purge
    operation. Purge is Microsoft's documented mechanism for GDPR erasure and is
    a real delete: "Delete and purge operations are destructive and
    non-reversible"
    (https://learn.microsoft.com/en-us/azure/azure-monitor/logs/personal-data-mgmt,
    retrieved 2026-09-03).

    Nothing is deleted unless -Execute is passed. Without it this shows what
    would go and stops, which is also Microsoft's instruction: "run the query
    prior to using for a purge request to verify that the results are expected".

    The limits are real and are printed rather than buried:

      50 purge requests per hour.
      One table per request, so five tables is five requests.
      A formal 30-day completion SLA, and "there's no way to expedite the
      operation".
      Analytics-plan tables only. Basic and Auxiliary cannot be purged.
      Sentinel data-lake mirrors and exported copies are not covered.

    Permission: Microsoft.OperationalInsights/workspaces/purge/action, from the
    Data Purger role (150f5e0c-0603-4f03-8c7f-cf70034c4e90) or Log Analytics
    Contributor. Data Purger is the least-privilege choice.

    Microsoft restricts this operation to compliance use and "reserves the right
    to reject" purge requests made for other reasons. This script is for
    answering a data subject request, not for routine housekeeping.

.PARAMETER User
    The subject, by UPN or Entra object id.

.PARAMETER Since
    How far back to delete. Defaults to 90 days, matching the finder.

.PARAMETER Execute
    Actually submit the purge requests. Without it, nothing is deleted.

.PARAMETER Wait
    Poll each purge operation until it reports completed. Purge can take up to
    30 days, so this is for the cases that finish quickly, not a guarantee.

.EXAMPLE
    ./scripts/Remove-ClaudeUserData.ps1 -User someone@contoso.com
    Shows what would be deleted. Deletes nothing.

.EXAMPLE
    ./scripts/Remove-ClaudeUserData.ps1 -User someone@contoso.com -Execute
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$User,
    [int]$Since = 90,
    [switch]$Execute,
    [switch]$Wait,
    [string]$ResourceGroup = $(if ($env:CLAUDE_RG) { $env:CLAUDE_RG } else { 'rg-contosohub' }),
    [string]$ApimName,
    [string]$AppInsightsName
)

$ErrorActionPreference = 'Stop'

# Discovery first, always. The purge predicate is built from what the finder
# actually saw, so the two can never disagree about which tables are in scope.
$found = & (Join-Path $PSScriptRoot 'Find-ClaudeUserData.ps1') `
            -User $User -Since $Since -AsJson `
            -ResourceGroup $ResourceGroup -ApimName $ApimName -AppInsightsName $AppInsightsName |
          Out-String | ConvertFrom-Json

$oid = $found.subject.object_id
$findings = @($found.findings)

Write-Host ''
Write-Host ("Subject   {0}" -f $(if ($found.subject.upn) { "$($found.subject.upn) ($oid)" } else { $oid })) -ForegroundColor Cyan
Write-Host ("Workspace {0}" -f $found.workspace.app_insights)

if (-not $findings.Count) {
    Write-Host ''
    Write-Host '  Nothing to delete.' -ForegroundColor Green
    exit 0
}

$purgeable = @($findings | Where-Object { $_.purgeable })
$blocked = @($findings | Where-Object { -not $_.purgeable })

Write-Host ''
Write-Host 'Would purge:' -ForegroundColor Yellow
foreach ($f in $purgeable) { Write-Host ("  {0,-18} -> {1,-18} {2,10:n0} row(s)  {3} to {4}" -f $f.table, $f.workspace_table, $f.rows, $f.earliest, $f.latest) }
if ($blocked.Count) {
    Write-Host ''
    Write-Host 'Cannot purge - not an Analytics-plan table:' -ForegroundColor Red
    foreach ($f in $blocked) { Write-Host ("  {0,-18} {1,10:n0} row(s)  {2} plan" -f $f.table, $f.rows, $f.plan) }
}

Write-Host ''
Write-Host ("  {0} purge request(s), one per table." -f $purgeable.Count) -ForegroundColor DarkGray
Write-Host '  Azure allows 50 purge requests an hour.' -ForegroundColor DarkGray
Write-Host '  Microsoft''s formal completion SLA is 30 days and cannot be expedited.' -ForegroundColor DarkGray
Write-Host '  Purge is destructive and non-reversible.' -ForegroundColor DarkGray

if (-not $Execute) {
    Write-Host ''
    Write-Host '  Nothing was deleted. Re-run with -Execute to submit these requests.' -ForegroundColor Green
    exit 0
}

if ($purgeable.Count -gt 50) {
    throw "That is $($purgeable.Count) requests and Azure allows 50 an hour. Narrow -Since and run it in batches."
}

$sub = az account show --query id -o tsv
$armToken = az account get-access-token --resource https://management.azure.com --query accessToken -o tsv
$H = @{ Authorization = 'Bearer ' + $armToken.Trim(); 'Content-Type' = 'application/json' }

$workspaceId = $found.workspace.workspace_resource_id
if (-not $workspaceId) {
    throw "This Application Insights component has no workspace, so the workspace purge API does not apply. Classic components are retired; migrate it first."
}

Write-Host ''
Write-Host 'Submitting:' -ForegroundColor Cyan
$operations = @()
foreach ($f in $purgeable) {
    # One table per request, with the subject and the window as filters. The
    # key property is what addresses a custom dimension rather than a column.
    #
    # workspace_table, not the Application Insights name: the purge endpoint
    # rejects "customMetrics" with "'customMetrics' is not a valid table". The
    # two APIs use different schema names for the same data.
    $body = @{
        table = $f.workspace_table
        filters = @(
            @{ column = $f.column; key = $f.key; operator = '=='; value = $oid },
            @{ column = 'TimeGenerated'; operator = '>='; value = (Get-Date).ToUniversalTime().AddDays(-$Since).ToString('yyyy-MM-ddTHH:mm:ssZ') }
        )
    } | ConvertTo-Json -Depth 6

    $uri = "https://management.azure.com$workspaceId/purge?api-version=2023-09-01"
    try {
        $resp = Invoke-WebRequest -Uri $uri -Method Post -Headers $H -Body $body -SkipHttpErrorCheck
        if ([int]$resp.StatusCode -ge 400) {
            Write-Host ("  [FAIL] {0,-18} HTTP {1} {2}" -f $f.workspace_table, $resp.StatusCode, ($resp.Content -replace '\s+', ' ')) -ForegroundColor Red
            continue
        }
        $status = ($resp.Headers['x-ms-status-location'] -join '')
        $purgeId = ($resp.Content | ConvertFrom-Json).operationId
        Write-Host ("  [OK]   {0,-18} operation {1}" -f $f.workspace_table, $purgeId) -ForegroundColor Green
        $operations += [pscustomobject]@{ Table = $f.workspace_table; OperationId = $purgeId; StatusUrl = $status }
    }
    catch {
        Write-Host ("  [FAIL] {0,-18} {1}" -f $f.table, $_.Exception.Message) -ForegroundColor Red
    }
}

if (-not $operations.Count) {
    Write-Host ''
    Write-Host '  No purge request was accepted. Check that the caller holds Data Purger on the workspace.' -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host ("  {0} operation(s) accepted. Keep these ids as the record of the request." -f $operations.Count)
$operations | ForEach-Object { Write-Host ("    {0,-18} {1}" -f $_.Table, $_.OperationId) -ForegroundColor DarkGray }

if ($Wait) {
    Write-Host ''
    Write-Host '  Polling. Purge can take up to 30 days, so this may not finish here.' -ForegroundColor DarkGray
    foreach ($op in $operations) {
        if (-not $op.StatusUrl) { continue }
        $deadline = (Get-Date).AddMinutes(10)
        do {
            Start-Sleep -Seconds 10
            try { $s = (Invoke-RestMethod -Uri $op.StatusUrl -Headers @{ Authorization = $H.Authorization }).status }
            catch { $s = "unreadable: $($_.Exception.Message)" }
        } while ($s -eq 'pending' -and (Get-Date) -lt $deadline)
        Write-Host ("    {0,-18} {1}" -f $op.Table, $s) -ForegroundColor $(if ($s -eq 'completed') { 'Green' } else { 'Yellow' })
    }
}

Write-Host ''
Write-Host '  Purge does not cover Sentinel data-lake mirrors or any exported copy in Blob or Event Hubs.' -ForegroundColor DarkGray
Write-Host '  Those need their own deletion, and this script does not touch them.' -ForegroundColor DarkGray
