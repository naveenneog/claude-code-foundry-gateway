<#
.SYNOPSIS
    Measures how far spend can run past a budget before a kill switch stops it.

.DESCRIPTION
    A budget enforced outside the request path cannot be a hard cap. Between
    the moment spend crosses a threshold and the moment the gateway refuses,
    four things elapse:

      1. Telemetry lag        the request has to reach the ledger before
                              anything can notice it
      2. Job interval         whatever watches the ledger runs on a timer
      3. Propagation delay    a named value written by that job has to reach
                              the gateway before the policy reads it
      4. In-flight requests   requests already admitted are already spending

    Terms 1 and 3 are properties of Azure and are measured here, against the
    live gateway, because neither is documented. Term 2 is your choice and is
    supplied with -JobIntervalSeconds. Term 4 is a property of your traffic and
    is named rather than measured - this script has no traffic model, and
    docs/SCALE.md says why.

    The point is not the number. It is that a figure exists and is stated, so
    "delayed kill switch" can be described honestly rather than called a hard
    cap. A genuine hard cap needs admission-time budget reservation, which
    API Management's quota policies do not offer.

    Nothing is left changed. The override map is saved before the measurement
    and restored in a finally block.

.PARAMETER JobIntervalSeconds
    How often the process that watches the ledger would run. Defaults to 300.

.PARAMETER TimeoutSeconds
    How long to wait for each measurement before giving up. Defaults to 600.

.EXAMPLE
    ./scripts/Measure-ClaudeOvershoot.ps1 -ResourceGroup rg-claude -ApimName apim-claude
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ResourceGroup,
    [Parameter(Mandatory = $true)][string]$ApimName,
    [int]$JobIntervalSeconds = 300,
    [int]$TimeoutSeconds = 600,
    [int]$PollSeconds = 5,
    [int]$LookbackHours = 24,
    [string]$WorkspaceName,
    [switch]$AsJson
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

$sub = az account show --query id -o tsv
$base = "https://management.azure.com/subscriptions/$sub/resourceGroups/$ResourceGroup/providers/Microsoft.ApiManagement/service/$ApimName"
$v = '?api-version=2022-08-01'
$armTok = (az account get-access-token --resource https://management.azure.com --query accessToken -o tsv).Trim()
$H = @{ Authorization = "Bearer $armTok"; 'Content-Type' = 'application/json' }

function Get-Nv($name) {
    try { return (Invoke-RestMethod -Uri "$base/namedValues/$name$v" -Headers $H).properties.value } catch { return $null }
}
function Set-Nv($name, $value) {
    $b = @{ properties = @{ displayName = $name; value = $value } } | ConvertTo-Json -Depth 5
    Invoke-RestMethod -Method Put -Uri "$base/namedValues/$name$v" -Headers $H -Body $b | Out-Null
}

$myOid = az ad signed-in-user show --query id -o tsv
if (-not $myOid) { throw 'Could not resolve the signed-in user. Run: az login' }
$myOid = $myOid.Trim()

function Invoke-Gateway {
    $t = (az account get-access-token --resource https://cognitiveservices.azure.com --query accessToken -o tsv).Trim()
    $payload = @{ model = 'claude-sonnet-5'; max_tokens = 16; messages = @(@{ role = 'user'; content = 'Say OK.' }) } | ConvertTo-Json -Depth 5
    return Invoke-WebRequest -Uri "https://$ApimName.azure-api.net/claude/v1/messages" -Method Post -Body $payload `
        -ContentType 'application/json' -SkipHttpErrorCheck `
        -Headers @{ Authorization = 'Bearer ' + $t; 'anthropic-version' = '2023-06-01' }
}

Write-Host ''
Write-Host 'Overshoot: how far spend runs past a budget' -ForegroundColor Cyan
Write-Host "  APIM : $ApimName ($ResourceGroup)"
Write-Host ''

$saved = Get-Nv 'quota-overrides'
$result = [ordered]@{}

try {
    # --- Term 3: propagation. Write an override, then poll the gateway until
    # the policy serves the new number. This is the delay between a control
    # decision and the gateway acting on it.
    #
    # Measured through a response header rather than by reading the named value
    # back: the ARM API returns the new value immediately, which says nothing
    # about when the gateway's policy sees it. That distinction is the whole
    # measurement.
    $probe = 31337
    Write-Host "  Propagation: writing a $probe-token override and polling the gateway" -ForegroundColor White

    & (Join-Path $root 'scripts/Set-ClaudeBudget.ps1') -User $myOid -Tokens $probe -ResourceGroup $ResourceGroup -ApimName $ApimName | Out-Null
    $writtenAt = Get-Date

    $propagated = $null
    $calls = 0
    while (((Get-Date) - $writtenAt).TotalSeconds -lt $TimeoutSeconds) {
        Start-Sleep -Seconds $PollSeconds
        $r = Invoke-Gateway
        $calls++
        $rem = ($r.Headers['x-quota-remaining-today'] -join '')
        if ($rem -and [long]$rem -le $probe) {
            $propagated = ((Get-Date) - $writtenAt).TotalSeconds
            break
        }
    }

    if ($null -eq $propagated) {
        Write-Host ("    not observed within {0}s over {1} call(s)" -f $TimeoutSeconds, $calls) -ForegroundColor Red
    } else {
        Write-Host ("    observed after {0:n0}s ({1} call(s))" -f $propagated, $calls) -ForegroundColor Green
    }
    $result.propagation_seconds = $propagated
    $result.propagation_calls = $calls

    # --- Term 1: telemetry lag. Read it from the data rather than by polling
    # for a request to appear.
    #
    # The first version of this polled: make a call, then query every few
    # seconds until it showed up. It reported "not visible within 420s" while
    # the real lag was around 80 seconds, because the poll loop caught and
    # discarded its own errors - a failing query and an empty result looked the
    # same, and the answer came out four times too large.
    #
    # ingestion_time() is the direct measurement. It also gives a distribution
    # over many requests instead of one sample, which matters because the bound
    # should use the worst case, not the median.
    Write-Host ''
    Write-Host '  Telemetry: reading ingestion lag off the ledger' -ForegroundColor White

    # Resolving the workspace by taking [0] from the group is how a report ends
    # up querying an empty workspace and stating zero. It happened here: this
    # resource group holds three workspaces, [0] was not the gateway's, and the
    # first run reported "no requests in the last 24h" against a ledger holding
    # 29. Same shape as the bypass audit picking the wrong Foundry account.
    #
    # One workspace is unambiguous. More than one has to be named.
    $wsId = $null
    if ($WorkspaceName) {
        $wsId = az monitor log-analytics workspace show -g $ResourceGroup -n $WorkspaceName --query customerId -o tsv 2>$null
    } else {
        $found = az monitor log-analytics workspace list -g $ResourceGroup --query "[].name" -o tsv 2>$null
        $names = @($found -split "`n" | Where-Object { $_ })
        if ($names.Count -eq 1) {
            $WorkspaceName = $names[0].Trim()
            $wsId = az monitor log-analytics workspace show -g $ResourceGroup -n $WorkspaceName --query customerId -o tsv 2>$null
        } elseif ($names.Count -gt 1) {
            throw ("$($names.Count) workspaces in '$ResourceGroup': " + ($names -join ', ') +
                   ". Pass -WorkspaceName to say which holds the gateway's telemetry.")
        }
    }

    if (-not $wsId) {
        Write-Host '    no Log Analytics workspace found in this resource group - skipped' -ForegroundColor Yellow
        $result.telemetry_seconds = $null
    } else {
        $wsId = $wsId.Trim()
        Write-Host ("    workspace {0}" -f $WorkspaceName) -ForegroundColor DarkGray
        $laTok = (az account get-access-token --resource https://api.loganalytics.io --query accessToken -o tsv).Trim()
        $q = "ApiManagementGatewayLlmLog " +
             "| where TimeGenerated > ago(${LookbackHours}h) " +
             "| extend lag = datetime_diff('second', ingestion_time(), TimeGenerated) " +
             "| summarize n = count(), p50 = percentile(lag, 50), worst = max(lag)"

        # Not wrapped in a silent catch. A query that fails has to say so, or it
        # reads as "no lag" and the bound comes out too small.
        $resp = Invoke-RestMethod -Uri "https://api.loganalytics.io/v1/workspaces/$wsId/query" -Method Post `
            -ContentType 'application/json' -Headers @{ Authorization = "Bearer $laTok" } `
            -Body (@{ query = $q } | ConvertTo-Json)

        $row = $resp.tables[0].rows[0]
        $n = [long]$row[0]
        if ($n -eq 0) {
            Write-Host ("    no requests in the last {0}h - send one through the gateway first" -f $LookbackHours) -ForegroundColor Yellow
            $result.telemetry_seconds = $null
        } else {
            $result.telemetry_samples = $n
            $result.telemetry_p50_seconds = [int]$row[1]
            $result.telemetry_seconds = [int]$row[2]
            Write-Host ("    {0} request(s): median {1}s, worst {2}s" -f $n, [int]$row[1], [int]$row[2]) -ForegroundColor Green
        }
    }
}
finally {
    if ($null -ne $saved) {
        try { Set-Nv 'quota-overrides' $saved; Write-Host "`n  quota-overrides restored" -ForegroundColor DarkGray }
        catch { Write-Host "  RESTORE FAILED - set quota-overrides back to '$saved' by hand" -ForegroundColor Red }
    }
}

$result.job_interval_seconds = $JobIntervalSeconds

# The bound. Stated as a window of time rather than a number of tokens, because
# tokens depend on a traffic model this deployment cannot supply.
$known = 0
foreach ($k in 'telemetry_seconds', 'job_interval_seconds', 'propagation_seconds') {
    if ($null -ne $result[$k]) { $known += [double]$result[$k] }
}
$result.window_seconds = [int][math]::Ceiling($known)
$result.complete = ($null -ne $result.propagation_seconds -and $null -ne $result.telemetry_seconds)

if ($AsJson) {
    $result | ConvertTo-Json -Depth 5
} else {
    Write-Host ''
    Write-Host '  The bound' -ForegroundColor Cyan
    Write-Host ("    telemetry lag      {0}  (worst of {1} request(s); median {2})" -f `
        $(if ($null -ne $result.telemetry_seconds) { '{0:n0}s' -f $result.telemetry_seconds } else { 'not measured' }), `
        $(if ($result.telemetry_samples) { $result.telemetry_samples } else { 0 }), `
        $(if ($null -ne $result.telemetry_p50_seconds) { '{0:n0}s' -f $result.telemetry_p50_seconds } else { '-' }))
    Write-Host ("    job interval       {0}s  (your choice)" -f $JobIntervalSeconds)
    Write-Host ("    propagation        {0}" -f $(if ($null -ne $result.propagation_seconds) { '{0:n0}s' -f $result.propagation_seconds } else { 'not measured' }))
    Write-Host ("    ---------------------------")
    Write-Host ("    window             {0}s" -f $result.window_seconds) -ForegroundColor Yellow
    Write-Host ''
    Write-Host '    Spending continues for that window after the threshold is crossed,'
    Write-Host '    plus whatever was already admitted and is still streaming. Multiply'
    Write-Host '    by your peak token rate to get the overshoot in tokens - this'
    Write-Host '    deployment has no traffic model, see docs/SCALE.md.'
    Write-Host ''
    Write-Host '    This is a delayed kill switch, not a hard cap. A hard cap needs'
    Write-Host '    admission-time reservation, which the quota policies do not offer.' -ForegroundColor DarkGray
}

if (-not $result.complete) { exit 1 }
exit 0
