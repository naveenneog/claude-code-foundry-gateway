# The Turnstile bridge: the chargeback ledger, sent to Turnstile as usage
# events it accepts exactly, without disturbing Turnstile's own accounting.
#
# The rules asserted here are Turnstile's, read from turnstile_core at commit
# 4e93935 and then proven against that code on 2026-09-23: 557 events exported
# from thirty days of the reference ledger were put through its UsageProcessor
# by tests/turnstile/check_contract.py - all accepted, none altered, cost
# identical - and sent through a live Event Hub and received back one event
# per message. docs/TURNSTILE.md has the numbers.
#
# Offline. The live half is the contract check and the round trip in the doc.

$root = Split-Path $PSScriptRoot -Parent
$fail = 0
function Assert($label, $condition, $detail = '') {
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $label$(if ($detail) { " - $detail" })" -ForegroundColor Red; $script:fail++ }
}
function Throws([scriptblock]$Block) { try { & $Block | Out-Null; return $false } catch { return $true } }

. (Join-Path $root 'scripts/ClaudeBusinessUnit.ps1')
. (Join-Path $root 'scripts/ClaudeTurnstile.ps1')
. (Join-Path $root 'scripts/ClaudeTurnstileGovernance.ps1')
# A fixed price book, so a developer's own config/price-book.json cannot move
# the expected figures.
$script:ClaudePriceBook = @{
    'claude-sonnet-5' = @{ InputPerM = [decimal]2.0; OutputPerM = [decimal]10.0 }
    'claude-opus-5'   = @{ InputPerM = [decimal]5.0; OutputPerM = [decimal]25.0 }
}

$lib = (Get-Content (Join-Path $root 'scripts/ClaudeTurnstile.ps1') -Raw) + (Get-Content (Join-Path $root 'scripts/ClaudeTurnstileGovernance.ps1') -Raw)
$exporter = Get-Content (Join-Path $root 'scripts/Export-ClaudeTurnstileUsage.ps1') -Raw
$doc = Get-Content (Join-Path $root 'docs/TURNSTILE.md') -Raw -ErrorAction SilentlyContinue

function New-Row([hashtable]$Overrides = @{}) {
    $r = [ordered]@{
        timestamp = '2026-09-23T10:00:00.123Z'; actor = 'dev-a@contoso.com'; user_id = '11111111-1111-1111-1111-111111111111'
        business_unit = 'platform'; client_surface = 'sdk-cli'; model = 'claude-sonnet-5'
        prompt_tokens = 1200.0; completion_tokens = 300.0
        request_id = 'aaaaaaaa-0000-0000-0000-000000000001'; result_code = '200'; duration_ms = 1532.7
    }
    foreach ($k in $Overrides.Keys) { $r[$k] = $Overrides[$k] }
    return [pscustomobject]$r
}

Write-Host ''
Write-Host 'Turnstile bridge - the event Turnstile accepts' -ForegroundColor Cyan

# 44 fields, not the contract's 30: the published events.yaml omits fields the
# Python model accepts and the policy sends, such as ingest_error.
Assert 'the field list is Turnstile''s UsageEvent at 4e93935' ($script:TurnstileUsageEventFields.Count -eq 44 -and ($script:TurnstileUsageEventFields -contains 'ingest_error') -and ($script:TurnstileUsageEventFields -contains 'cache_write_tokens'))
Assert 'the pinned commit is named where the list is'        ($lib -match 'models\.py at 4e93935')

$e = ConvertTo-ClaudeTurnstileEvent -Row (New-Row) -Parents @{ platform = 'engineering' }
Assert 'a request event passes every check'                  ((Test-ClaudeTurnstileEvent -Event $e).Count -eq 0) ((Test-ClaudeTurnstileEvent -Event $e) -join '; ')
Assert 'the request id is the row''s identity'               ($e['id'] -eq 'aaaaaaaa-0000-0000-0000-000000000001' -and $e['request_id'] -eq $e['id'] -and $e['correlation_id'] -eq $e['id'])
# Turnstile lists a person only when user_id is an address under a known department.
Assert 'a person is identified by their address'             ($e['user_id'] -eq 'dev-a@contoso.com' -and $e['user'] -eq 'dev-a@contoso.com')
Assert 'the address is lower-cased, as Turnstile keys it'    ((ConvertTo-ClaudeTurnstileEvent -Row (New-Row @{ actor = 'Dev-A@Contoso.com' }))['user_id'] -eq 'dev-a@contoso.com')
Assert 'with no address, the object id is kept'              ((ConvertTo-ClaudeTurnstileEvent -Row (New-Row @{ actor = '' }))['user_id'] -eq '11111111-1111-1111-1111-111111111111')
# Turnstile zeroes every count on a row whose cache is null.
Assert 'cache is sent as zero, never null'                   ($e['cached_tokens'] -is [long] -and $e['cached_tokens'] -eq 0 -and $e['cache_write_tokens'] -eq 0)
Assert 'and named as unmeasured'                             ($e['ingest_error'] -eq 'stream_cache_usage_unavailable')
Assert 'nothing is sent as estimated'                        ($e['estimated'] -eq $false)
Assert 'the source is backfill, not eventhub'                ($e['ingest_source'] -eq 'backfill')
Assert 'the provider is anthropic'                           ($e['provider'] -eq 'anthropic')
Assert 'token counts arrive as integers'                     ($e['input_tokens'] -is [long] -and $e['input_tokens'] -eq 1200 -and $e['output_tokens'] -eq 300)
Assert 'a team''s organization is its business unit'         ($e['department'] -eq 'platform' -and $e['team'] -eq 'platform' -and $e['organization'] -eq 'engineering')
$solo = ConvertTo-ClaudeTurnstileEvent -Row (New-Row)
Assert 'a unit with no parent is its own organization'       ($solo['organization'] -eq 'platform')
Assert 'the client is the parsed surface'                    ($e['agent'] -eq 'sdk-cli')
Assert 'status and latency come from the request record'     ($e['status_code'] -eq 200 -and $e['status'] -eq '200' -and $e['latency_ms'] -eq 1533)
$throttled = ConvertTo-ClaudeTurnstileEvent -Row (New-Row @{ result_code = '429'; duration_ms = $null })
Assert 'a status is carried through'                         ($throttled['status_code'] -eq 429)
Assert 'no request record means 200 and zero latency'        ((ConvertTo-ClaudeTurnstileEvent -Row (New-Row @{ result_code = $null }))['status_code'] -eq 200 -and $throttled['latency_ms'] -eq 0)
$blank = ConvertTo-ClaudeTurnstileEvent -Row (New-Row @{ business_unit = ''; actor = ''; user_id = ''; client_surface = ''; model = '' })
Assert 'blanks take the ledger''s own words'                 ($blank['department'] -eq 'unassigned' -and $blank['user'] -eq 'unattributed' -and $blank['user_id'] -eq 'unattributed' -and $blank['agent'] -eq 'unknown' -and $blank['model'] -eq 'unattributed')
Assert 'a row without a request id is refused'               (Throws { ConvertTo-ClaudeTurnstileEvent -Row (New-Row @{ request_id = '' }) })
Assert 'a negative count is refused'                         (Throws { ConvertTo-ClaudeTurnstileEvent -Row (New-Row @{ prompt_tokens = -1 }) })

Write-Host ''
Write-Host 'Turnstile bridge - the money' -ForegroundColor Cyan

# 1,200 x $2/M + 300 x $10/M.
Assert 'a request is priced category by category'            ($e['estimated_cost'] -eq [decimal]0.0054) "got $($e['estimated_cost'])"
Assert 'at six places, not two'                              ((ConvertTo-ClaudeRequestUsd -Model 'claude-sonnet-5' -InputTokens 16 -OutputTokens 4) -eq [decimal]0.000072)
Assert 'money stays decimal'                                 ((ConvertTo-ClaudeRequestUsd -Model 'claude-sonnet-5' -InputTokens 1) -is [decimal])
Assert 'cache read is a tenth of base input'                 ((ConvertTo-ClaudeRequestUsd -Model 'claude-sonnet-5' -CacheReadTokens 1000000) -eq [decimal]0.2)
Assert 'an unknown model is unpriced, not free'              ($null -eq (ConvertTo-ClaudeRequestUsd -Model 'claude-next' -InputTokens 5))
Assert 'and its event carries no cost'                       (-not (ConvertTo-ClaudeTurnstileEvent -Row (New-Row @{ model = 'claude-next' })).Contains('estimated_cost'))
Assert 'Turnstile pricing sends no cost at all'              (-not (ConvertTo-ClaudeTurnstileEvent -Row (New-Row) -PriceSource Turnstile).Contains('estimated_cost'))
Assert 'a negative count cannot be priced'                   (Throws { ConvertTo-ClaudeRequestUsd -Model 'claude-sonnet-5' -InputTokens -5 })

Write-Host ''
Write-Host 'Turnstile bridge - cache reads' -ForegroundColor Cyan

$cacheRow = [pscustomobject]@{ hour = '2026-09-01T14:00:00Z'; user_id = '22222222-2222-2222-2222-222222222222'; actor = 'dev-b@contoso.com'; model = 'claude-sonnet-5'; cached = 844302; business_unit = 'platform' }
$c = ConvertTo-ClaudeTurnstileCacheEvent -Row $cacheRow -Parents @{ platform = 'engineering' }
Assert 'a cache event passes every check'                    ((Test-ClaudeTurnstileEvent -Event $c).Count -eq 0) ((Test-ClaudeTurnstileEvent -Event $c) -join '; ')
Assert 'its id is stable per developer, model and hour'      ($c['id'] -eq 'claude-cache:22222222-2222-2222-2222-222222222222:claude-sonnet-5:20260901T14' -and (ConvertTo-ClaudeTurnstileCacheEvent -Row $cacheRow)['id'] -eq $c['id'])
Assert 'the id keys on the object id, the person on the address' ($c['user_id'] -eq 'dev-b@contoso.com' -and $c['id'] -match '22222222-2222')
Assert 'it carries cache and nothing else'                   ($c['cached_tokens'] -eq 844302 -and $c['input_tokens'] -eq 0 -and $c['output_tokens'] -eq 0)
# An estimated row Turnstile cannot reconcile holds its window open for ever.
Assert 'it is not estimated either'                          ($c['estimated'] -eq $false)
Assert 'it names the capped metric it came from'             ($c['ingest_error'] -eq 'cache_read_hourly_from_gateway_metric')
Assert 'no client is claimed for it'                         ($c['agent'] -eq 'unattributed')
Assert 'it is priced at the cache-read rate'                 ($c['estimated_cost'] -eq [decimal]0.168860) "got $($c['estimated_cost'])"
Assert 'it is marked apart from requests'                    ($c['request_source'] -eq 'claude-code-foundry-gateway/cache-read' -and $e['request_source'] -eq 'claude-code-foundry-gateway')

Write-Host ''
Write-Host 'Turnstile bridge - the check before sending' -ForegroundColor Cyan

function Copy-Event($ev) { $n = [ordered]@{}; foreach ($k in $ev.Keys) { $n[$k] = $ev[$k] }; return $n }
$x = Copy-Event $e; $x['tier'] = 'standard'
Assert 'an unknown field is caught'                          (@(Test-ClaudeTurnstileEvent -Event $x) -match "unknown field 'tier'")
$x = Copy-Event $e; $x['cached_tokens'] = $null
Assert 'a null cache is caught'                              (@(Test-ClaudeTurnstileEvent -Event $x) -match 'would zero every count')
$x = Copy-Event $e; $x['input_tokens'] = 12.0
Assert 'a fractional count is caught'                        (@(Test-ClaudeTurnstileEvent -Event $x) -match 'not an integer')
$x = Copy-Event $e; $x['estimated'] = $true
Assert 'an estimated row is caught'                          (@(Test-ClaudeTurnstileEvent -Event $x) -match 'reconciliation window')
$x = Copy-Event $e; $x['ingest_source'] = 'eventhub'
Assert 'an eventhub source is caught'                        (@(Test-ClaudeTurnstileEvent -Event $x) -match 'own cache correction')
$x = Copy-Event $e; $x['ts'] = '2026-09-23 10:00:00'
Assert 'a time without a zone is caught'                     (@(Test-ClaudeTurnstileEvent -Event $x) -match 'not an ISO 8601')
$x = Copy-Event $e; $x.Remove('team')
Assert 'a missing required field is caught'                  (@(Test-ClaudeTurnstileEvent -Event $x) -match "required field 'team'")

# The fast path checks structure once per shape, so the value checks must
# still see a bad row that comes after many good ones.
$many = New-Object System.Collections.Generic.List[object]
for ($i = 0; $i -lt 300; $i++) { $many.Add((ConvertTo-ClaudeTurnstileEvent -Row (New-Row @{ request_id = ('r-{0:d4}' -f $i) }))) }
Assert 'a clean set has no problems'                         ((Test-ClaudeTurnstileEventSet -Events $many.ToArray()).Count -eq 0)
$many[250]['cached_tokens'] = $null
$many[251]['ts'] = 'yesterday'
$many[252]['ingest_source'] = 'eventhub'
$odd = Copy-Event $many[253]; $odd['tier'] = 'premium'; $many[253] = $odd
$many[254]['estimated'] = $true
$found = Test-ClaudeTurnstileEventSet -Events $many.ToArray()
Assert 'a late null cache is still caught'                   (@($found) -match "^r-0250: 'cached_tokens' is null")
Assert 'a late bad time is still caught'                     (@($found) -match '^r-0251: ts')
Assert 'a late wrong source is still caught'                 (@($found) -match "^r-0252: ingest_source")
Assert 'a late new shape gets the full check'                (@($found) -match "^r-0253: unknown field 'tier'")
Assert 'a late estimated row is still caught'                (@($found) -match '^r-0254: estimated must be false')

Write-Host ''
Write-Host 'Turnstile bridge - batches' -ForegroundColor Cyan

$bodies = @($many | Select-Object -First 200 | ForEach-Object { ConvertTo-ClaudeTurnstileJson -Event $_ })
$batches = Split-ClaudeEventBatch -Bodies $bodies -MaxBytes 20000
$unpacked = @($batches | ForEach-Object { ($_ | ConvertFrom-Json) } | ForEach-Object { $_.Body })
Assert 'every batch is under the limit'                      (@($batches | Where-Object { [Text.Encoding]::UTF8.GetByteCount($_) -gt 20000 }).Count -eq 0)
Assert 'no event is lost or changed in batching'             ($unpacked.Count -eq 200 -and $unpacked[0] -eq $bodies[0] -and $unpacked[199] -eq $bodies[199])
Assert 'the batch list comes back as one object'             ($batches -is [string[]] -and $batches.Count -gt 1)
Assert 'an empty list gives no batches'                      ((Split-ClaudeEventBatch -Bodies @()).Count -eq 0)
Assert 'an event over the limit is refused'                  (Throws { Split-ClaudeEventBatch -Bodies @($bodies[0]) -MaxBytes 100 })
# Measured: wrapping it in @() made one element of the whole list, and the
# live send failed on the type.
Assert 'no caller wraps the batch list in @()'               (-not ($exporter -match '@\(Split-ClaudeEventBatch') -and -not ($lib -match '@\(Split-ClaudeEventBatch'))
Assert 'batches go as Event Hubs JSON, Entra-signed'         ($lib -match "application/vnd\.microsoft\.servicebus\.json" -and $lib -match 'Authorization = "Bearer \$Token"' -and $lib -match '-ne 201')
Assert 'the token is for Event Hubs'                         ($lib -match 'get-access-token --resource https://eventhubs\.azure\.net')

Write-Host ''
Write-Host 'Turnstile bridge - the window' -ForegroundColor Cyan

$now = [datetime]::new(2026, 9, 23, 16, 40, 0, [DateTimeKind]::Utc)
$w = Get-ClaudeTurnstileWindow -NowUtc $now
Assert 'the window ends a lag before now'                    ($w.To -eq $now.AddMinutes(-15))
Assert 'and looks back two hours'                            ($w.From -eq $now.AddMinutes(-135))
Assert 'cache hours end once settled'                        ($w.CacheTo -eq [datetime]::new(2026, 9, 23, 16, 0, 0, [DateTimeKind]::Utc))
# Rounded down: rounding up would lose 14:00-15:00 for good if the previous
# run was skipped.
Assert 'the first cache hour is rounded down'                ($w.CacheFrom -eq [datetime]::new(2026, 9, 23, 14, 0, 0, [DateTimeKind]::Utc) -and $w.CacheHours -eq 2)
$unsettled = Get-ClaudeTurnstileWindow -NowUtc ([datetime]::new(2026, 9, 23, 16, 20, 0, [DateTimeKind]::Utc))
Assert 'an hour not yet settled is left for later'           ($unsettled.CacheTo -eq [datetime]::new(2026, 9, 23, 15, 0, 0, [DateTimeKind]::Utc))
$explicit = Get-ClaudeTurnstileWindow -NowUtc $now -From ([datetime]'2026-09-01') -To ([datetime]'2026-09-02')
Assert 'a date without a zone is UTC, not local time'        ($explicit.From -eq [datetime]::new(2026, 9, 1, 0, 0, 0, [DateTimeKind]::Utc) -and $explicit.To.Kind -eq [DateTimeKind]::Utc)
Assert 'an empty window is refused'                          (Throws { Get-ClaudeTurnstileWindow -NowUtc $now -From ([datetime]'2026-09-02') -To ([datetime]'2026-09-01') })
Assert 'a timestamp from either host reads the same'         ((ConvertTo-ClaudeTurnstileTimestamp '2026-09-23T10:00:00.123Z') -eq '2026-09-23T10:00:00.123Z' -and (ConvertTo-ClaudeTurnstileTimestamp ([datetime]::new(2026, 9, 23, 10, 0, 0, 123, [DateTimeKind]::Utc))) -eq '2026-09-23T10:00:00.123Z' -and (ConvertTo-ClaudeTurnstileTimestamp ([datetime]::new(2026, 9, 23, 10, 0, 0, 123))) -eq '2026-09-23T10:00:00.123Z')

Write-Host ''
Write-Host 'Turnstile bridge - the queries' -ForegroundColor Cyan

$ledger = Get-Content (Join-Path $root 'analytics/chargeback-ledger.kql') -Raw
$q = Get-ClaudeTurnstileLedgerQuery -LedgerKql $ledger -From ([datetime]::new(2026, 9, 23, 10, 0, 0, [DateTimeKind]::Utc)) -To ([datetime]::new(2026, 9, 23, 11, 0, 0, [DateTimeKind]::Utc))
Assert 'the ledger is run as written'                        ($q.Contains('ApiManagementGatewayLlmLog') -and $q.Contains('client_surface = case('))
# The caller trace and the log row of one streamed request are written up to
# the forward timeout apart.
Assert 'it is read fifteen minutes wider'                    ($q.Contains('let _from = datetime(2026-09-23T09:45:00.000Z);') -and $q.Contains('let _to = datetime(2026-09-23T11:15:00.000Z);'))
Assert 'then cut back to the window, half-open'              ($q.Contains('| where timestamp >= datetime(2026-09-23T10:00:00.000Z) and timestamp < datetime(2026-09-23T11:00:00.000Z)'))
Assert 'only requests that carried tokens'                   ($q.Contains('| where total_tokens > 0'))
Assert 'status and latency joined on the request id'         ($q -match 'Properties\["Request Id"\]' -and $q.Contains('result_code = take_any(ResultCode)'))
Assert 'a reworded ledger stops the export'                  (Throws { Get-ClaudeTurnstileLedgerQuery -LedgerKql ($ledger.Replace('let _to = now();', 'let _to = now() ;')) -From ([datetime]::UtcNow.AddHours(-1)) -To ([datetime]::UtcNow) } )
$cq = Get-ClaudeTurnstileCacheQuery -From ([datetime]::new(2026, 9, 23, 10, 0, 0, [DateTimeKind]::Utc)) -To ([datetime]::new(2026, 9, 23, 12, 0, 0, [DateTimeKind]::Utc))
Assert 'cache is summed per developer, model and hour'       ($cq.Contains('Name == "Prompt Cached Tokens"') -and $cq.Contains('by hour = bin(TimeGenerated, 1h), user_id, actor, model'))
Assert 'with the developer''s latest unit'                   ($cq.Contains('summarize arg_max(TimeGenerated, business_unit) by user_id'))

Write-Host ''
Write-Host 'Turnstile bridge - the exporter' -ForegroundColor Cyan

Assert 'a slice checks before it sends'                      ($lib -match '(?s)function Invoke-ClaudeTurnstileSlice.*Test-ClaudeTurnstileEventSet.*Send-ClaudeEventHubBatch')
Assert 'cache rows are checked before they are sent'         ($exporter -match '(?s)Test-ClaudeTurnstileEventSet -Events \$cacheEvents.*Send-ClaudeEventHubBatch')
Assert 'a partial query result stops the export'             ($lib -match 'returned a partial result' -and $lib -match '500,000-row query limit')
Assert 'slices run side by side only on PowerShell 7'        ($exporter -match 'ThrottleLimit -gt 1 -and \$PSVersionTable\.PSVersion\.Major -ge 7' -and $exporter -match 'ForEach-Object -ThrottleLimit \$ThrottleLimit -Parallel')
Assert 'each runspace loads the libraries itself'            ($exporter -match 'foreach \(\$lib in \$using:libs\) \{ \. \$lib \}')
Assert 'the destination comes from the connection, or is refused' ($exporter -match "Resolve-ClaudeTurnstileSetting \`$EventHubNamespace \`$integration 'eventHubNamespace'" -and (Throws { Resolve-ClaudeTurnstileSetting $null $null 'eventHubNamespace' 'EventHubNamespace' }))
Assert 'unpriced models are named, not hidden'               ($exporter -match 'models the price book does not list')
$checker = Get-Content (Join-Path $root 'tests/turnstile/check_contract.py') -Raw
Assert 'the contract check runs Turnstile''s own processor'  ($checker -match 'from turnstile_core\.ingestion\.processor import CoefficientResolver, UsageProcessor' -and $checker -match 'processor\.process\(e\)')
Assert 'and its controls cover each rule relied on'          ($checker -match 'unknown field is skipped' -and $checker -match 'null cache zeroes the row' -and $checker -match 'no cost and no registry price stores zero' -and $checker -match 'cache-unmeasured flag survives ingest')

Write-Host ''
Write-Host 'Turnstile bridge - the guide' -ForegroundColor Cyan

Assert 'the guide exists'                                    ([bool]$doc)
Assert 'it keeps one enforcer'                               ($doc -match '(?i)one enforcer')
Assert 'it says why the source is backfill'                  ($doc -match '(?s)backfill.{0,400}cache correction')
Assert 'it says why nothing is estimated'                    ($doc -match '(?s)estimated.{0,400}reconciliation window')
Assert 'it gives the cache metric''s limit'                  ($doc -match '100 unique values' -and $doc -match '(?i)lower bound')
Assert 'it records the measured round trip'                  ($doc -match '557' -and $doc -match '1,114' -and $doc -match '4e93935')
Assert 'it records the measured throughput'                  ($doc -match '1,47\d events a second')
Assert 'it gives the Microsoft Learn source for the transport' ($doc -match 'learn\.microsoft\.com/rest/api/eventhub/send-batch-events')

Write-Host ''
if ($fail) { Write-Host "$fail check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'Every Turnstile bridge check passed.' -ForegroundColor Green
exit 0
