<#
.SYNOPSIS
    Maps the chargeback ledger onto Turnstile's usage events.

.DESCRIPTION
    Dot-source this after ClaudeBusinessUnit.ps1, which owns the price book. It
    owns the mapping so the exporter, the tests and the contract check cannot
    disagree about it. docs/TURNSTILE.md explains the design.

    Turnstile ingests usage from an Event Hub through
    turnstile_core/ingestion/processor.py. The rules below are the ones that
    code enforces, read at commit 4e93935 rather than taken from the published
    contract, which omits fields Turnstile's own policy sends:

      * UsageEvent is a pydantic StrictModel with extra="forbid". One unknown
        field and the whole event is skipped as malformed. The warning goes to
        Turnstile's log, and the sender sees nothing.
      * If input_tokens, cached_tokens or output_tokens is null, every count on
        the row is zeroed and the row is marked estimated. The ledger does not
        know cache per request (ADR-0006), so cached_tokens is sent as 0 and the
        gap is named with ingest_error "stream_cache_usage_unavailable". That is
        the value Turnstile's own reconciliation writes for the same log, and
        the one its dashboard renders as "cache not measured".
      * Rows are keyed on id, and a non-estimated row is never overwritten, so
        an overlapping window can be sent again without double counting.
      * Nothing is sent as estimated. Turnstile's reconciliation starts each
        scan at the oldest row that is estimated and unreconciled; a row it can
        never match, such as an hourly cache total, would hold that window open
        for ever.
      * ingest_source is "backfill", not "eventhub". Turnstile corrects its
        global cache total by subtracting eventhub rows' cache from its own
        API's cache metric, so an eventhub row from this gateway would shrink
        the correction applied to Turnstile's own traffic.
#>

# UsageEvent's fields, turnstile_core/domain/models.py at 4e93935. A field not
# in this list makes Turnstile skip the whole event.
$script:TurnstileUsageEventFields = @(
    'id', 'request_id', 'correlation_id', 'ts', 'team', 'organization', 'organization_id',
    'department', 'department_id', 'project', 'project_id', 'user', 'user_id', 'agent',
    'agent_id', 'workflow', 'run_id', 'turn_index', 'provider', 'model', 'model_id',
    'runtime', 'runtime_authoritative', 'request_source', 'gateway_profile_id',
    'apim_subscription_id', 'application_actor_type', 'application_actor_id',
    'application_admission', 'input_tokens', 'cached_tokens', 'cache_write_tokens',
    'output_tokens', 'tokens_consumed', 'latency_ms', 'status', 'status_code',
    'estimated_cost', 'error_message', 'estimated', 'ingest_source', 'ingest_error',
    'budget_admission', 'model_admission'
)
# Required by contracts/openapi/schemas/events.yaml.
$script:TurnstileRequiredFields = @(
    'id', 'ts', 'team', 'user', 'agent', 'workflow', 'run_id', 'turn_index',
    'provider', 'model', 'latency_ms', 'status', 'ingest_source'
)
$script:TurnstileTokenFields = @('input_tokens', 'cached_tokens', 'cache_write_tokens', 'output_tokens', 'tokens_consumed')
$script:TurnstileProviders = @('aoai', 'anthropic', 'copilot', 'codex')
$script:TurnstileIngestSources = @('eventhub', 'backfill')
$script:TurnstileRequestSource = 'claude-code-foundry-gateway'
$script:TurnstileCacheRequestSource = 'claude-code-foundry-gateway/cache-read'
$script:TurnstileCacheUnmeasured = 'stream_cache_usage_unavailable'
$script:TurnstileCacheFromMetric = 'cache_read_hourly_from_gateway_metric'
# Sets, not arrays: the validator runs on every event, and at 20,000 events a
# linear -notcontains over 44 names was half the exporter's time (measured).
$script:TurnstileFieldSet = New-Object 'System.Collections.Generic.HashSet[string]' (, [string[]]$script:TurnstileUsageEventFields)
$script:TurnstileProviderSet = New-Object 'System.Collections.Generic.HashSet[string]' (, [string[]]$script:TurnstileProviders)
$script:TurnstileIngestSourceSet = New-Object 'System.Collections.Generic.HashSet[string]' (, [string[]]$script:TurnstileIngestSources)

function Get-ClaudeTurnstileText {
    param($Value, [string]$Default)
    $s = [string]$Value
    if ([string]::IsNullOrWhiteSpace($s)) { return $Default }
    return $s
}

function ConvertTo-ClaudeTurnstileTimestamp {
    <#
    .SYNOPSIS
        UTC, ISO 8601, millisecond precision, whatever the input's type.

    .DESCRIPTION
        Windows PowerShell hands back the Log Analytics timestamp as a string,
        PowerShell 7 as a DateTime, so both are accepted. A DateTime with no
        kind is taken as UTC, because that is what Log Analytics returns.
    #>
    param([Parameter(Mandatory = $true)]$Value)
    $invariant = [Globalization.CultureInfo]::InvariantCulture
    if ($Value -is [datetime]) {
        $dt = $Value
        if ($dt.Kind -eq [DateTimeKind]::Unspecified) { $dt = [datetime]::SpecifyKind($dt, [DateTimeKind]::Utc) }
        return $dt.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ', $invariant)
    }
    $dto = [DateTimeOffset]::Parse([string]$Value, $invariant, [Globalization.DateTimeStyles]::AssumeUniversal)
    return $dto.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ss.fffZ', $invariant)
}

function Get-ClaudeTurnstileOrganization {
    param([string]$Unit, [hashtable]$Parents)
    # A team rolls up to its business unit (ADR-0008), which is what Turnstile
    # calls an organization. A unit with no parent is its own organization.
    if ($Parents -and $Parents.ContainsKey($Unit) -and -not [string]::IsNullOrWhiteSpace([string]$Parents[$Unit])) {
        return [string]$Parents[$Unit]
    }
    return $Unit
}

function ConvertTo-ClaudeTurnstileEvent {
    <#
    .SYNOPSIS
        One ledger row, as the usage event Turnstile ingests.

    .PARAMETER Row
        A row of analytics/chargeback-ledger.kql, with result_code and
        duration_ms joined from AppRequests.

    .PARAMETER Parents
        The bu-parents map, so a team's organization is its business unit.

    .PARAMETER PriceSource
        Gateway sends the cost from this repository's price book, so Turnstile
        and the chargeback report show the same figure. Turnstile sends none,
        and Turnstile prices the row from its own model registry - which must
        then list the Claude models, or the rows land at zero.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Row,
        [hashtable]$Parents = @{},
        [ValidateSet('Gateway', 'Turnstile')][string]$PriceSource = 'Gateway'
    )
    $rid = [string]$Row.request_id
    if ([string]::IsNullOrWhiteSpace($rid)) {
        throw 'A ledger row has no request id, so it cannot be exported: without a stable id, sending it again would count it twice.'
    }
    $inputTokens = [long]$Row.prompt_tokens
    $outputTokens = [long]$Row.completion_tokens
    if ($inputTokens -lt 0 -or $outputTokens -lt 0) { throw "Request $rid has a negative token count." }

    # Inlined rather than calling Get-ClaudeTurnstileText: a PowerShell
    # function call costs tens of microseconds, and this runs per request.
    $unit = [string]$Row.business_unit
    if ([string]::IsNullOrWhiteSpace($unit)) { $unit = 'unassigned' }
    $organization = $unit
    if ($Parents.Count -gt 0 -and $Parents.ContainsKey($unit)) {
        $parent = [string]$Parents[$unit]
        if (-not [string]::IsNullOrWhiteSpace($parent)) { $organization = $parent }
    }
    $surface = [string]$Row.client_surface
    if ([string]::IsNullOrWhiteSpace($surface)) { $surface = 'unknown' }
    # The tier travels as Turnstile's project: it is the one free grouping dimension on a
    # usage row, so Turnstile can break spend down by tier. Enforcement of the tier stays
    # in the gateway (docs/TURNSTILE.md).
    $tier = ([string]$Row.tier).Trim().ToLowerInvariant()
    $projectId = if ($tier) { "tier-$tier" } else { 'unattributed' }
    $projectName = if ($tier) { (Get-Culture).TextInfo.ToTitleCase($tier) + ' tier' } else { 'unattributed' }
    $model = [string]$Row.model
    if ([string]::IsNullOrWhiteSpace($model)) { $model = 'unattributed' }
    $actor = [string]$Row.actor
    if ([string]::IsNullOrWhiteSpace($actor)) { $actor = 'unattributed' }
    # Turnstile lists a person, and so lets them be given a budget, only when user_id is
    # an email address under a known department (merge_observed_users, 4e93935): its own
    # gateway keys people on preferred_username. So the address is sent as the id, and
    # the object id only where there is no address. A renamed UPN therefore starts a new
    # person in Turnstile, though not in the ledger, which keys on the object id.
    $userId = [string]$Row.user_id
    if ($actor.Contains('@')) { $userId = $actor.ToLowerInvariant() }
    elseif ([string]::IsNullOrWhiteSpace($userId)) { $userId = 'unattributed' }

    # AppRequests joined every request in thirty days of the reference ledger
    # (741 of 741, measured 2026-09-23), so these fallbacks are for a gateway
    # whose request telemetry is sampled or switched off.
    $statusCode = 200
    if ("$($Row.result_code)" -match '^\d{3}$') { $statusCode = [int]"$($Row.result_code)" }
    $latency = [long]0
    if ("$($Row.duration_ms)" -ne '') { $latency = [long][math]::Round([double]$Row.duration_ms) }

    $event = [ordered]@{
        id                 = $rid
        request_id         = $rid
        correlation_id     = $rid
        ts                 = ConvertTo-ClaudeTurnstileTimestamp $Row.timestamp
        team               = $unit
        organization       = $organization
        organization_id    = $organization
        department         = $unit
        department_id      = $unit
        project            = $projectName
        project_id         = $projectId
        user               = $actor
        user_id            = $userId
        agent              = $surface
        agent_id           = $surface
        workflow           = 'claude-code'
        run_id             = $rid
        turn_index         = 1
        provider           = 'anthropic'
        model              = $model
        model_id           = $model
        runtime            = 'microsoft-foundry'
        request_source     = $script:TurnstileRequestSource
        input_tokens       = $inputTokens
        cached_tokens      = [long]0
        cache_write_tokens = [long]0
        output_tokens      = $outputTokens
        latency_ms         = $latency
        status             = [string]$statusCode
        status_code        = $statusCode
        estimated          = $false
        ingest_source      = 'backfill'
        ingest_error       = $script:TurnstileCacheUnmeasured
    }
    if ($PriceSource -eq 'Gateway') {
        $usd = ConvertTo-ClaudeRequestUsd -Model $model -InputTokens $inputTokens -OutputTokens $outputTokens
        if ($null -ne $usd) { $event['estimated_cost'] = $usd }
    }
    return $event
}

function ConvertTo-ClaudeTurnstileCacheEvent {
    <#
    .SYNOPSIS
        One hour of one developer's cache reads on one model, as a usage event.

    .DESCRIPTION
        Cache reads are not in the per-request log. The gateway's own
        llm-emit-token-metric carries them per user and model, so they travel
        as their own hourly rows rather than being split across requests by
        guesswork.

        That metric is a lower bound. Custom metrics cap a dimension at 100
        values and silently discard the rest (ADR-0006), and this one carries
        UserId and SessionId, so past about a hundred developers some cache
        reads are never recorded. The ingest_error says where the figure came
        from, so a reader can discount it.

        Only a complete, settled hour may be sent. The row is not estimated, so
        Turnstile keeps the first copy it receives, and a partial hour would
        stay partial.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Row,
        [hashtable]$Parents = @{},
        [ValidateSet('Gateway', 'Turnstile')][string]$PriceSource = 'Gateway'
    )
    $cached = [long]$Row.cached
    if ($cached -lt 0) { throw 'A cache-read total cannot be negative.' }
    $objectId = Get-ClaudeTurnstileText $Row.user_id 'unattributed'
    $actor = Get-ClaudeTurnstileText $Row.actor 'unattributed'
    # The row id keys on the object id so it survives a UPN rename; the person Turnstile
    # sees is the address, for the same reason as a request row.
    $userId = if ($actor.Contains('@')) { $actor.ToLowerInvariant() } else { $objectId }
    $model = Get-ClaudeTurnstileText $Row.model 'unattributed'
    $ts = ConvertTo-ClaudeTurnstileTimestamp $Row.hour
    $hourKey = [DateTimeOffset]::Parse($ts, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime.ToString('yyyyMMddTHH', [Globalization.CultureInfo]::InvariantCulture)
    # Stable, so sending the same hour again is a no-op in Turnstile.
    $id = 'claude-cache:{0}:{1}:{2}' -f $objectId, $model, $hourKey
    $unit = Get-ClaudeTurnstileText $Row.business_unit 'unassigned'
    $organization = Get-ClaudeTurnstileOrganization -Unit $unit -Parents $Parents

    $event = [ordered]@{
        id                 = $id
        request_id         = $id
        correlation_id     = $id
        ts                 = $ts
        team               = $unit
        organization       = $organization
        organization_id    = $organization
        department         = $unit
        department_id      = $unit
        user               = $actor
        user_id            = $userId
        # The metric carries no user agent, so no client can be named.
        agent              = 'unattributed'
        agent_id           = 'unattributed'
        workflow           = 'claude-code'
        run_id             = $id
        turn_index         = 1
        provider           = 'anthropic'
        model              = $model
        model_id           = $model
        runtime            = 'microsoft-foundry'
        request_source     = $script:TurnstileCacheRequestSource
        input_tokens       = [long]0
        cached_tokens      = $cached
        cache_write_tokens = [long]0
        output_tokens      = [long]0
        latency_ms         = [long]0
        status             = '200'
        status_code        = 200
        estimated          = $false
        ingest_source      = 'backfill'
        ingest_error       = $script:TurnstileCacheFromMetric
    }
    if ($PriceSource -eq 'Gateway') {
        $usd = ConvertTo-ClaudeRequestUsd -Model $model -CacheReadTokens $cached
        if ($null -ne $usd) { $event['estimated_cost'] = $usd }
    }
    return $event
}

function Test-ClaudeTurnstileEvent {
    <#
    .SYNOPSIS
        The reasons Turnstile would skip or distort this event. Empty means none.

    .DESCRIPTION
        Turnstile gives the sender no signal: a malformed event is skipped with
        a warning in its own log. So every event is checked here, against the
        rules turnstile_core enforces, before anything is sent.
    #>
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Event)
    $problems = New-Object System.Collections.Generic.List[string]
    foreach ($k in @($Event.Keys)) {
        if (-not $script:TurnstileFieldSet.Contains([string]$k)) { $problems.Add("unknown field '$k': Turnstile forbids extra fields and would skip the event") }
    }
    foreach ($k in $script:TurnstileRequiredFields) {
        if (-not $Event.Contains($k) -or [string]::IsNullOrWhiteSpace([string]$Event[$k])) { $problems.Add("required field '$k' is missing or empty") }
    }
    foreach ($k in $script:TurnstileTokenFields) {
        if ($Event.Contains($k) -and $null -ne $Event[$k]) {
            $v = $Event[$k]
            if (-not ($v -is [int] -or $v -is [long])) { $problems.Add("'$k' is $($v.GetType().Name), not an integer: Turnstile marks the row invalid") }
            elseif ($v -lt 0) { $problems.Add("'$k' is negative") }
        }
    }
    foreach ($k in 'input_tokens', 'cached_tokens', 'output_tokens') {
        if (-not $Event.Contains($k) -or $null -eq $Event[$k]) { $problems.Add("'$k' is null: Turnstile would zero every count on the row") }
    }
    if ($Event.Contains('cache_write_tokens') -and $Event.Contains('cached_tokens') -and $null -ne $Event['cache_write_tokens'] -and $null -ne $Event['cached_tokens'] -and $Event['cache_write_tokens'] -gt $Event['cached_tokens']) {
        $problems.Add('cache_write_tokens exceeds cached_tokens: Turnstile marks the row invalid')
    }
    if ($Event.Contains('provider') -and -not $script:TurnstileProviderSet.Contains([string]$Event['provider'])) { $problems.Add("provider '$($Event['provider'])' is not one Turnstile accepts") }
    if ($Event.Contains('ingest_source') -and -not $script:TurnstileIngestSourceSet.Contains([string]$Event['ingest_source'])) { $problems.Add("ingest_source '$($Event['ingest_source'])' is not one Turnstile accepts") }
    if ($Event.Contains('ingest_source') -and [string]$Event['ingest_source'] -ne 'backfill') { $problems.Add("ingest_source must be 'backfill': an eventhub row would distort Turnstile's own cache correction") }
    if ($Event.Contains('estimated') -and $Event['estimated'] -ne $false) { $problems.Add('estimated must be false: an estimated row Turnstile cannot reconcile holds its reconciliation window open') }
    if ($Event.Contains('turn_index') -and -not ([long]$Event['turn_index'] -ge 1)) { $problems.Add('turn_index must be at least 1') }
    if ($Event.Contains('latency_ms') -and -not ([long]$Event['latency_ms'] -ge 0)) { $problems.Add('latency_ms cannot be negative') }
    if ($Event.Contains('status_code') -and $null -ne $Event['status_code'] -and ([int]$Event['status_code'] -lt 0 -or [int]$Event['status_code'] -gt 599)) { $problems.Add('status_code must be between 0 and 599') }
    if ($Event.Contains('estimated_cost') -and $null -ne $Event['estimated_cost'] -and [decimal]$Event['estimated_cost'] -lt 0) { $problems.Add('estimated_cost cannot be negative') }
    if ($Event.Contains('ts')) {
        $parsed = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParse([string]$Event['ts'], [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsed) -or [string]$Event['ts'] -notmatch '(Z|[+-]\d{2}:\d{2})$') {
            $problems.Add("ts '$($Event['ts'])' is not an ISO 8601 time with a zone")
        }
    }
    return , $problems.ToArray()
}

function Test-ClaudeTurnstileEventSet {
    <#
    .SYNOPSIS
        Test-ClaudeTurnstileEvent over many events, fast enough to run on all.

    .DESCRIPTION
        Every event is still checked. What is not repeated is the structural
        half - which fields exist, which are required - because every event of
        one kind has the same fields: those checks run once per distinct set of
        field names, and the values that vary from row to row are checked on
        every event.

        Measured on PowerShell 7.6: the full check costs about 1.3 ms an event,
        almost all of it PowerShell's per-iteration loop cost over 44 names,
        and it was half the exporter's time at 20,000 events.

        Returns the problems as "id: reason" strings. Empty means none.
    #>
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Events)
    $problems = New-Object System.Collections.Generic.List[string]
    $shapes = @{}
    foreach ($e in $Events) {
        $signature = @($e.Keys) -join ','
        if (-not $shapes.ContainsKey($signature)) {
            # A new shape gets the full check, values and all.
            $shapes[$signature] = $true
            foreach ($p in (Test-ClaudeTurnstileEvent -Event $e)) { $problems.Add(('{0}: {1}' -f $e['id'], $p)) }
            continue
        }
        # The shape has passed once; these are the values that vary per row.
        $id = [string]$e['id']
        if ([string]::IsNullOrWhiteSpace($id)) { $problems.Add(': required field ''id'' is missing or empty'); continue }
        foreach ($k in 'input_tokens', 'cached_tokens', 'cache_write_tokens', 'output_tokens') {
            $v = $e[$k]
            if ($null -eq $v) { $problems.Add("${id}: '$k' is null: Turnstile would zero every count on the row") }
            elseif (-not ($v -is [long] -or $v -is [int])) { $problems.Add("${id}: '$k' is not an integer") }
            elseif ($v -lt 0) { $problems.Add("${id}: '$k' is negative") }
        }
        if ($null -ne $e['cache_write_tokens'] -and $null -ne $e['cached_tokens'] -and $e['cache_write_tokens'] -gt $e['cached_tokens']) { $problems.Add("${id}: cache_write_tokens exceeds cached_tokens") }
        if ([string]$e['ts'] -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$') { $problems.Add("${id}: ts '$($e['ts'])' is not an ISO 8601 time with a zone") }
        $sc = $e['status_code']
        if ($null -ne $sc -and ($sc -lt 0 -or $sc -gt 599)) { $problems.Add("${id}: status_code must be between 0 and 599") }
        if ($e['latency_ms'] -lt 0) { $problems.Add("${id}: latency_ms cannot be negative") }
        if ($e.Contains('estimated_cost') -and $e['estimated_cost'] -lt 0) { $problems.Add("${id}: estimated_cost cannot be negative") }
        foreach ($k in 'team', 'user', 'agent', 'model', 'run_id') {
            if ([string]::IsNullOrWhiteSpace([string]$e[$k])) { $problems.Add("${id}: required field '$k' is missing or empty") }
        }
        if (-not $script:TurnstileProviderSet.Contains([string]$e['provider'])) { $problems.Add("${id}: provider '$($e['provider'])' is not one Turnstile accepts") }
        if ([string]$e['ingest_source'] -ne 'backfill') { $problems.Add("${id}: ingest_source must be 'backfill'") }
        if ($e['estimated'] -ne $false) { $problems.Add("${id}: estimated must be false") }
    }
    return , $problems.ToArray()
}

function ConvertTo-ClaudeTurnstileJson {
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Event)
    return ($Event | ConvertTo-Json -Compress -Depth 3)
}

function Split-ClaudeEventBatch {
    <#
    .SYNOPSIS
        Groups event bodies into Event Hubs batch requests under a byte limit.

    .DESCRIPTION
        The batch body is a JSON array of {"Body": "<event json>"}, so each
        event is measured as it will be sent - escaped, with its wrapper - not
        as its raw length. 240 KB stays under the Basic tier's 256 KB limit;
        Standard allows 1 MB.
    #>
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Bodies,
        [int]$MaxBytes = 240000
    )
    $batches = New-Object System.Collections.Generic.List[string]
    $current = New-Object System.Collections.Generic.List[string]
    $size = 2
    foreach ($b in $Bodies) {
        $item = '{"Body":' + (ConvertTo-Json -InputObject $b -Compress) + '}'
        $itemBytes = [Text.Encoding]::UTF8.GetByteCount($item) + 1
        if ($itemBytes + 2 -gt $MaxBytes) { throw "One event is $itemBytes bytes, over the $MaxBytes byte batch limit." }
        if ($current.Count -gt 0 -and ($size + $itemBytes) -gt $MaxBytes) {
            $batches.Add(('[' + ($current -join ',') + ']'))
            $current = New-Object System.Collections.Generic.List[string]
            $size = 2
        }
        $current.Add($item)
        $size += $itemBytes
    }
    if ($current.Count -gt 0) { $batches.Add(('[' + ($current -join ',') + ']')) }
    return , $batches.ToArray()
}

function Send-ClaudeEventHubBatch {
    <#
    .SYNOPSIS
        Sends one batch to an Event Hub over REST with an Entra token.

    .DESCRIPTION
        https://learn.microsoft.com/rest/api/eventhub/send-batch-events - the
        content type is what makes the service unpack the array into separate
        events. 201 is the only success.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Namespace,
        [Parameter(Mandatory = $true)][string]$EventHub,
        [Parameter(Mandatory = $true)][string]$Batch,
        [Parameter(Mandatory = $true)][string]$Token
    )
    $uri = 'https://{0}.servicebus.windows.net/{1}/messages?timeout=60&api-version=2014-01' -f $Namespace, $EventHub
    $response = Invoke-WebRequest -Method Post -Uri $uri -UseBasicParsing `
        -Headers @{ Authorization = "Bearer $Token" } `
        -ContentType 'application/vnd.microsoft.servicebus.json' `
        -Body ([Text.Encoding]::UTF8.GetBytes($Batch))
    if ([int]$response.StatusCode -ne 201) { throw "Event Hubs answered $($response.StatusCode), not 201." }
}

function Get-ClaudeTurnstileWindow {
    <#
    .SYNOPSIS
        The period to export, and the cache hours that are complete within it.

    .DESCRIPTION
        Stateless on purpose: each run re-reads a lookback window ending a lag
        before now, and Turnstile's keying on id makes the overlap harmless.
        There is no watermark to lose, so a scheduled job needs no storage.

        The lag covers Log Analytics ingestion. A cache hour is complete only
        once it ended a settle time ago, because its row is kept as first sent.
    #>
    param(
        [Parameter(Mandatory = $true)][datetime]$NowUtc,
        [int]$LookbackMinutes = 120,
        [int]$LagMinutes = 15,
        [int]$CacheSettleMinutes = 30,
        [Nullable[datetime]]$From = $null,
        [Nullable[datetime]]$To = $null
    )
    if ($LookbackMinutes -lt 1) { throw 'LookbackMinutes must be at least 1.' }
    if ($LagMinutes -lt 0) { throw 'LagMinutes cannot be negative.' }
    if ($NowUtc.Kind -eq [DateTimeKind]::Local) { $NowUtc = $NowUtc.ToUniversalTime() }
    # PowerShell unwraps a Nullable parameter into the plain value, so there is
    # no .Value to call here. A time given without a zone, such as
    # -From 2026-09-01, is taken as UTC like everything in Log Analytics;
    # ToUniversalTime alone would read it as local time and shift the window.
    $asUtc = {
        param([datetime]$d)
        if ($d.Kind -eq [DateTimeKind]::Unspecified) { return [datetime]::SpecifyKind($d, [DateTimeKind]::Utc) }
        return $d.ToUniversalTime()
    }
    $end = if ($null -ne $To) { & $asUtc $To } else { $NowUtc.AddMinutes(-$LagMinutes) }
    $start = if ($null -ne $From) { & $asUtc $From } else { $end.AddMinutes(-$LookbackMinutes) }
    if ($start -ge $end) { throw "The window is empty: $($start.ToString('o')) is not before $($end.ToString('o'))." }

    # Whole hours ended at least the settle time ago. The first hour is rounded
    # down, not up: hour bins are absolute, and rounding up would lose an hour
    # for good whenever a scheduled run is skipped. Sending an hour twice is a
    # no-op in Turnstile; not sending it is a permanent gap.
    $settledBy = $NowUtc.AddMinutes(-$CacheSettleMinutes)
    $cacheEnd = [datetime]::new($end.Year, $end.Month, $end.Day, $end.Hour, 0, 0, [DateTimeKind]::Utc)
    while ($cacheEnd -gt $settledBy) { $cacheEnd = $cacheEnd.AddHours(-1) }
    $cacheStart = [datetime]::new($start.Year, $start.Month, $start.Day, $start.Hour, 0, 0, [DateTimeKind]::Utc)
    if ($cacheStart -gt $cacheEnd) { $cacheStart = $cacheEnd }

    [pscustomobject]@{
        From       = $start
        To         = $end
        CacheFrom  = $cacheStart
        CacheTo    = $cacheEnd
        CacheHours = [math]::Max(0, [int](($cacheEnd - $cacheStart).TotalHours))
    }
}

function Get-ClaudeTurnstileLedgerQuery {
    <#
    .SYNOPSIS
        analytics/chargeback-ledger.kql for one period, with status and latency.

    .DESCRIPTION
        The ledger file is run as written rather than copied, so Turnstile and
        the chargeback report cannot drift apart. Only its two period lines are
        replaced, and a replacement that does not happen is an error: a ledger
        whose period lines were reworded would otherwise silently export the
        last day, whatever window was asked for.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$LedgerKql,
        [Parameter(Mandatory = $true)][datetime]$From,
        [Parameter(Mandatory = $true)][datetime]$To
    )
    $invariant = [Globalization.CultureInfo]::InvariantCulture
    $f = $From.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ', $invariant)
    $t = $To.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ', $invariant)
    # The ledger is read wider than the window, because the two halves of one
    # request are not written at the same moment. The caller trace is emitted
    # in outbound, when response headers arrive; the log row is written when a
    # stream ends, up to the 600-second forward timeout later. Read only the
    # window, a request near its edge would lose its caller - and since the
    # first copy Turnstile receives is kept, it would stay unattributed.
    $margin = [TimeSpan]::FromMinutes(15)
    $wf = $From.ToUniversalTime().Subtract($margin).ToString('yyyy-MM-ddTHH:mm:ss.fffZ', $invariant)
    $wt = $To.ToUniversalTime().Add($margin).ToString('yyyy-MM-ddTHH:mm:ss.fffZ', $invariant)
    $fromLine = 'let _from = ago(1d);'
    $toLine = 'let _to = now();'
    if (-not $LedgerKql.Contains($fromLine) -or -not $LedgerKql.Contains($toLine)) {
        throw "The ledger query no longer contains '$fromLine' and '$toLine', so its period cannot be set. Update Get-ClaudeTurnstileLedgerQuery with it."
    }
    $q = $LedgerKql.Replace($fromLine, "let _from = datetime($wf);").Replace($toLine, "let _to = datetime($wt);")
    # Then the rows are cut back to the window itself, half-open, so a request
    # on the boundary between two consecutive windows is exported by one.
    return $q.TrimEnd() + @"

| where timestamp >= datetime($f) and timestamp < datetime($t)
| where total_tokens > 0
| project timestamp, actor, user_id, tier, business_unit, client_surface, model, prompt_tokens, completion_tokens, request_id
| join kind=leftouter (
    AppRequests
    | where TimeGenerated between (_from .. _to)
    | extend request_id = tostring(Properties["Request Id"])
    | where isnotempty(request_id)
    | summarize result_code = take_any(ResultCode), duration_ms = take_any(DurationMs) by request_id
  ) on request_id
| project-away request_id1
"@
}

function Get-ClaudeTurnstileCacheQuery {
    <#
    .SYNOPSIS
        Cache reads per developer, model and complete hour, with their unit.
    #>
    param(
        [Parameter(Mandatory = $true)][datetime]$From,
        [Parameter(Mandatory = $true)][datetime]$To
    )
    $f = $From.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ', [Globalization.CultureInfo]::InvariantCulture)
    $t = $To.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ', [Globalization.CultureInfo]::InvariantCulture)
    return @"
let _from = datetime($f);
let _to = datetime($t);
let units = AppTraces
| where TimeGenerated between ((_from - 1d) .. _to)
| where Properties.RequestId != ""
| extend user_id = tostring(Properties.UserId), business_unit = tostring(Properties.BusinessUnit)
| summarize arg_max(TimeGenerated, business_unit) by user_id
| project user_id, business_unit;
AppMetrics
| where TimeGenerated >= _from and TimeGenerated < _to
| where Name == "Prompt Cached Tokens"
| extend user_id = tostring(Properties.UserId), actor = tostring(Properties.User), model = tostring(Properties.Model)
| summarize cached = tolong(sum(Sum)) by hour = bin(TimeGenerated, 1h), user_id, actor, model
| where cached > 0
| join kind=leftouter units on user_id
| project hour, user_id, actor, model, cached, business_unit
"@
}

function Invoke-ClaudeLedgerQuery {
    <#
    .SYNOPSIS
        Runs KQL against a Log Analytics workspace and returns rows as objects.

    .DESCRIPTION
        A result over the API's limits comes back as a partial table plus an
        error. That is treated as a failure: sending the partial table would
        under-report and look complete.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$WorkspaceResourceId,
        [Parameter(Mandatory = $true)][string]$Kql
    )
    $token = (az account get-access-token --resource https://api.loganalytics.io --query accessToken -o tsv).Trim()
    $res = Invoke-RestMethod -Uri "https://api.loganalytics.io/v1$WorkspaceResourceId/query" -Method Post `
        -ContentType 'application/json' -Headers @{ Authorization = "Bearer $token" } `
        -Body (@{ query = $Kql } | ConvertTo-Json -Compress)
    if ($res.PSObject.Properties['error'] -and $res.error) {
        throw "Log Analytics returned a partial result ($($res.error.code): $($res.error.message)). Lower -SliceMinutes."
    }
    $table = $res.tables[0]
    if (@($table.rows).Count -ge 500000) { throw 'A slice reached the 500,000-row query limit. Lower -SliceMinutes.' }
    $cols = @($table.columns.name)
    foreach ($row in $table.rows) {
        $o = [ordered]@{}
        for ($i = 0; $i -lt $cols.Count; $i++) { $o[$cols[$i]] = $row[$i] }
        [pscustomobject]$o
    }
}

function Invoke-ClaudeTurnstileSlice {
    <#
    .SYNOPSIS
        One slice of the ledger: read, map, check, and send or return.

    .DESCRIPTION
        Self-contained so slices can run in parallel runspaces. A slice sends
        nothing unless every one of its events passes the check. A slice that
        fails stops the export with an error; the slices already sent are
        harmless to send again, because Turnstile keeps the first copy of each
        id, so the whole window can simply be re-run.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$WorkspaceResourceId,
        [Parameter(Mandatory = $true)][string]$LedgerKql,
        [Parameter(Mandatory = $true)][datetime]$From,
        [Parameter(Mandatory = $true)][datetime]$To,
        [hashtable]$Parents = @{},
        [ValidateSet('Gateway', 'Turnstile')][string]$PriceSource = 'Gateway',
        [string]$Namespace,
        [string]$EventHub,
        [int]$MaxBatchBytes = 240000,
        [switch]$ReturnBodies
    )
    $events = New-Object System.Collections.Generic.List[object]
    foreach ($row in @(Invoke-ClaudeLedgerQuery -WorkspaceResourceId $WorkspaceResourceId -Kql (Get-ClaudeTurnstileLedgerQuery -LedgerKql $LedgerKql -From $From -To $To))) {
        $events.Add((ConvertTo-ClaudeTurnstileEvent -Row $row -Parents $Parents -PriceSource $PriceSource))
    }
    $problems = Test-ClaudeTurnstileEventSet -Events $events.ToArray()
    if ($problems.Count) {
        throw ("Slice $($From.ToString('o')) to $($To.ToString('o')) was not sent: $($problems.Count) problem(s) would make Turnstile skip or distort events.`n" + (($problems | Select-Object -First 10) -join "`n"))
    }
    $bodies = @($events | ForEach-Object { ConvertTo-ClaudeTurnstileJson -Event $_ })
    $batchCount = 0
    if (-not $ReturnBodies -and $bodies.Count) {
        $batches = Split-ClaudeEventBatch -Bodies $bodies -MaxBytes $MaxBatchBytes
        $ehToken = (az account get-access-token --resource https://eventhubs.azure.net --query accessToken -o tsv).Trim()
        foreach ($b in $batches) { Send-ClaudeEventHubBatch -Namespace $Namespace -EventHub $EventHub -Batch $b -Token $ehToken }
        $batchCount = $batches.Count
    }
    $cost = [decimal]0
    $inTok = [long]0
    $outTok = [long]0
    $unattributed = 0
    $unpriced = New-Object System.Collections.Generic.List[string]
    foreach ($e in $events) {
        $inTok += $e['input_tokens']
        $outTok += $e['output_tokens']
        if ($e['user_id'] -eq 'unattributed') { $unattributed++ }
        if ($e.Contains('estimated_cost')) { $cost += [decimal]$e['estimated_cost'] } else { $unpriced.Add([string]$e['model']) }
    }
    [pscustomobject]@{
        From         = $From
        Requests     = $events.Count
        InputTokens  = $inTok
        OutputTokens = $outTok
        CostUsd      = $cost
        Unattributed = $unattributed
        Unpriced     = $unpriced.ToArray()
        Batches      = $batchCount
        Bodies       = $(if ($ReturnBodies) { $bodies } else { @() })
    }
}
