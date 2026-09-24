# P18 - the chargeback ledger.
#
# RED first: written before the implementation.
#
# Why this packet exists, measured 2026-09-15 on the live gateway:
#
#   The quota scalar excludes cache tokens. Two identical calls with a cacheable
#   10,000-token prompt wrote and then read 10,003 cache tokens; both metered 16.
#   Against thirty days of real usage here, 38.7% of the cost weight is invisible
#   to the quota, because a cache read is priced at 0.1x base input and output at
#   5x, and cache reads are 6.8M tokens against 320k prompt.
#
#   The quota scalar is also wrong for streaming: a streamed request reported 11
#   where the completion was 41.
#
#   Custom metrics cap at 100 unique dimension values and then, in Microsoft's
#   words, data "is silently discarded".
#
# ADR-0006 records the decision: the ledger is the built-in
# ApiManagementGatewayLlmLog, which is a log rather than a metric, is correct for
# streaming, and carries a per-request id - joined to identity by a trace the
# gateway emits, because the log has no caller in it.

param([switch]$SkipLive)

$root = Split-Path $PSScriptRoot -Parent
$policyPath = Join-Path $root 'infra/policy.xml'
$bicepPath = Join-Path $root 'infra/main.bicep'
$ledgerPath = Join-Path $root 'analytics/chargeback-ledger.kql'

$fail = 0
function Assert($label, $condition, $detail = '') {
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $label$(if ($detail) { " - $detail" })" -ForegroundColor Red; $script:fail++ }
}

$policy = if (Test-Path $policyPath) { Get-Content $policyPath -Raw } else { '' }
$bicep = if (Test-Path $bicepPath) { Get-Content $bicepPath -Raw } else { '' }

Write-Host ''
Write-Host 'P18 ledger - the identity trace' -ForegroundColor Cyan

$trace = [regex]::Match($policy, '<trace\b.*?</trace>', 'Singleline')
Assert 'the policy emits a trace'            $trace.Success
Assert 'at information severity'             ($trace.Success -and $trace.Value -match 'severity="information"') 'must be >= the diagnostic verbosity or it is dropped'

# The join key has to be carried deliberately. Application Insights operation_Id
# is a W3C trace id; the log's CorrelationId is a GUID. They do not match.
Assert 'it carries the join key'             ($trace.Success -and $trace.Value -match 'RequestId')
Assert 'the join key is context.RequestId'   ($trace.Success -and $trace.Value -match 'context\.RequestId')

foreach ($field in 'UserId', 'User', 'Tier', 'Model') {
    Assert "it carries $field"               ($trace.Success -and $trace.Value -match "name=`"$field`"")
}

# In outbound, because the tier and model variables are set inbound and the
# record should describe a request that actually completed.
$outboundAt = $policy.IndexOf('<outbound>')
Assert 'the trace is emitted in outbound' (($outboundAt -ge 0) -and ($trace.Index -gt $outboundAt)) "trace at $($trace.Index), outbound at $outboundAt"

# Reading the response body here would buffer it and end streaming for Claude
# Code. ADR-0006 takes the gap instead.
Assert 'the trace does not read the response body' ($trace.Success -and $trace.Value -notmatch 'context\.Response\.Body')

Write-Host ''
Write-Host 'P18 ledger - the log is switched on by the template' -ForegroundColor Cyan

Assert 'the resource log category is deployed' ($bicep -match 'GatewayLlmLogs')
Assert 'the API diagnostic enables LLM logs'   ($bicep -match 'largeLanguageModel')
Assert 'it points at the workspace'            ($bicep -match 'workspaceId')

# The table has RequestMessages and ResponseMessages columns. Filling them is
# content capture, which P15 keeps opt-in and off by default.
Assert 'message capture is not turned on'      ($bicep -notmatch "messages:\s*'all'" -and $bicep -notmatch "messages:\s*'auto'")

Write-Host ''
Write-Host 'P18 ledger - the query' -ForegroundColor Cyan

Assert 'the ledger query exists' (Test-Path $ledgerPath) $ledgerPath
if (Test-Path $ledgerPath) {
    $kql = Get-Content $ledgerPath -Raw
    Assert 'it reads the built-in log'      ($kql -match 'ApiManagementGatewayLlmLog')
    Assert 'it joins identity from traces'  ($kql -match 'AppTraces')
    Assert 'it joins on the correlation id' ($kql -match 'CorrelationId')
    Assert 'it reports who spent it'        ($kql -match 'actor|user_id')
    Assert 'it keeps prompt and completion apart' ($kql -match 'PromptTokens' -and $kql -match 'CompletionTokens')
    Assert 'it flags streamed requests'     ($kql -match 'IsStreamCompletion')

    # Cache is absent from the log and unreadable for a streamed request. A
    # report that shows zero there is stating something false.
    Assert 'it records where usage came from' ($kql -match 'usage_source')
    Assert 'it does not invent a cache zero'  ($kql -match '(?i)unknown|null')
}

Write-Host ''
Write-Host 'P18 ledger - live' -ForegroundColor Cyan

if ($SkipLive) {
    Write-Host '  skipped - offline run (-SkipLive)' -ForegroundColor Yellow
}
else {
    $rg = & (Join-Path $root 'scripts/Get-ClaudeGatewayTarget.ps1') ResourceGroup
    $apim = az apim list -g $rg --query "[0].name" -o tsv 2>$null
    $sub = az account show --query id -o tsv 2>$null
    if (-not $apim -or -not $sub) {
        Write-Host '  skipped - not signed in, or no API Management' -ForegroundColor Yellow
    }
    else {
        $armTok = (az account get-access-token --resource https://management.azure.com --query accessToken -o tsv 2>$null).Trim()
        $AH = @{ Authorization = 'Bearer ' + $armTok }
        $base = "https://management.azure.com/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.ApiManagement/service/$apim"

        $ds = Invoke-RestMethod -Uri "$base/providers/Microsoft.Insights/diagnosticSettings?api-version=2021-05-01-preview" -Headers $AH
        $llm = @($ds.value | Where-Object { $_.properties.logs | Where-Object { $_.category -eq 'GatewayLlmLogs' -and $_.enabled } })
        Assert 'GatewayLlmLogs is enabled on the gateway' ($llm.Count -gt 0)

        $diag = Invoke-RestMethod -Uri "$base/apis/claude-foundry/diagnostics/applicationinsights?api-version=2024-05-01" -Headers $AH
        Assert 'the API diagnostic has LLM logs on' ($diag.properties.largeLanguageModel.logs -eq 'enabled') ("got: " + ($diag.properties.largeLanguageModel | ConvertTo-Json -Compress))
        Assert 'request message capture is off'     ($null -eq $diag.properties.largeLanguageModel.requests)
        Assert 'response message capture is off'    ($null -eq $diag.properties.largeLanguageModel.responses)

        # Drive one plain and one streamed request, then prove both land in the
        # ledger with an actor attached. Streaming is the case the quota scalar
        # gets wrong, so it is the one that matters.
        $marker = [guid]::NewGuid().ToString('N').Substring(0, 8)
        $callTok = (az account get-access-token --resource https://cognitiveservices.azure.com --query accessToken -o tsv 2>$null).Trim()
        foreach ($stream in $false, $true) {
            $b = @{ model = 'claude-sonnet-5'; max_tokens = 30; messages = @(@{ role = 'user'; content = "ledger $marker" }) }
            if ($stream) { $b['stream'] = $true }
            Invoke-WebRequest -Uri "https://$apim.azure-api.net/claude/v1/messages" -Method Post -Body ($b | ConvertTo-Json -Depth 6) `
                -ContentType 'application/json' -SkipHttpErrorCheck `
                -Headers @{ Authorization = 'Bearer ' + $callTok; 'anthropic-version' = '2023-06-01' } | Out-Null
        }

        $qTok = (az account get-access-token --resource https://api.applicationinsights.io --query accessToken -o tsv 2>$null).Trim()
        # The workspace is found through the Application Insights resource the gateway logs to,
        # not named here (tests/Test-NoDeploymentValues.ps1).
        $telemetry = & (Join-Path $root 'scripts/Get-ClaudeTelemetry.ps1') -ResourceGroup $rg -ApimName $apim
        $ws = az resource show -g $rg -n $telemetry.AppInsights --resource-type Microsoft.Insights/components --query properties.WorkspaceResourceId -o tsv
        $kqlLive = (Get-Content $ledgerPath -Raw) -replace '(?m)^\s*//.*$', ''

        $rows = @()
        foreach ($wait in 120, 120, 120, 120) {
            Start-Sleep -Seconds $wait
            try {
                $res = Invoke-RestMethod -Uri "https://api.loganalytics.io/v1$ws/query" -Method Post -ContentType 'application/json' `
                       -Headers @{ Authorization = 'Bearer ' + $qTok } -Body (@{ query = $kqlLive } | ConvertTo-Json)
                $cols = @($res.tables[0].columns.name)
                $rows = @($res.tables[0].rows)
            }
            catch {
                Assert 'the ledger query runs' $false $_.ErrorDetails.Message
                break
            }
            Write-Host ("         {0} ledger row(s) so far" -f $rows.Count) -ForegroundColor DarkGray
            if (($rows.Count -ge 2) -and @($rows | Where-Object { $_[$cols.IndexOf("actor")] -ne "unattributed" }).Count) { break }
        }

        if ($rows.Count) {
            Assert 'the ledger query runs' $true

            # "unattributed" is what the query substitutes when the join finds
            # nothing, and it is a non-empty string. Asserting the column is
            # merely populated would pass whether or not identity ever arrived,
            # which is a test that measures nothing.
            $iActor = $cols.IndexOf('actor')
            $named = @($rows | Where-Object { $_[$iActor] -and $_[$iActor] -ne 'unattributed' })
            Assert 'rows are attributed to a real caller' ($named.Count -gt 0) 'every row came back unattributed, so the trace join produced nothing'

            $iUser = $cols.IndexOf('user_id')
            Assert 'the caller has an object id' (($named.Count -gt 0) -and $named[0][$iUser]) 'actor present but no oid'

            $streamed = @($rows | Where-Object { "$($_[$cols.IndexOf('streamed')])" -match '^(True|true|1)$' })
            Assert 'a streamed request is in the ledger' ($streamed.Count -gt 0) 'streaming is most of Claude Code'
            if ($streamed.Count) {
                $iOut = $cols.IndexOf('completion_tokens')
                Assert 'the streamed row has completion tokens' ([double]$streamed[0][$iOut] -gt 0) 'the quota scalar misses these'
            }

            # Zero would be a claim. The categories are not collected per
            # request, so the column has to stay null.
            $iKnown = $cols.IndexOf('cache_tokens_known')
            $iCache = $cols.IndexOf('cache_read_tokens')
            Assert 'cache is reported as unknown, not zero' (("$($rows[0][$iCache])" -eq '') -and ("$($rows[0][$iKnown])" -match '^(False|false|0)$')) "cache='$($rows[0][$iCache])' known='$($rows[0][$iKnown])'"

            Write-Host ("         {0} row(s), {1} attributed, {2} streamed" -f $rows.Count, $named.Count, $streamed.Count) -ForegroundColor DarkGray
        }
        else {
            Assert 'the ledger returns rows' $false 'nothing arrived within the ingestion window'
        }
    }
}

Write-Host ''
if ($fail) { Write-Host "$fail assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'P18 contract holds.' -ForegroundColor Green
exit 0
