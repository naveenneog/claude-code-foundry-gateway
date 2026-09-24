# Mutate an isolated project-local copy. Never change the developer's worktree
# under a running test, and never use the shared system temporary directory.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$sandbox = Join-Path $root "backups\projection-negative-$PID"
$rules = 'rules'
$node = 'node'
$mutations = @(
    @{ Name='paging stops after one page'; File='scripts\ClaudeProjection.ps1'; From='} while ($token)'; To='} while ($false)'; Suite='paging' }
    @{ Name='empty pages terminate the scan'; File='scripts\ClaudeProjection.ps1'; From='$token = [string]$page.Continuation'; To='if (-not $page.Documents.Count) { break }; $token = [string]$page.Continuation'; Suite='paging' }
    @{ Name='repeated tokens loop'; File='scripts\ClaudeProjection.ps1'; From='if ($seen.ContainsKey($token))'; To='if ($false)'; Suite='paging' }
    @{ Name='response continuation is discarded'; File='scripts\Sync-ClaudeProjection.ps1'; From="Continuation = [string]`$response.Headers['x-ms-continuation']"; To="Continuation = ''"; Suite=$rules }
    @{ Name='query is no longer paged'; File='scripts\Sync-ClaudeProjection.ps1'; From='$existing = Get-ClaudeProjectionExisting -ReadPage'; To='$existing = &'; Suite=$rules }
    @{ Name='continuation header is not forwarded'; File='scripts\Sync-ClaudeProjection.ps1'; From="`$headers['x-ms-continuation'] = `$continuation"; To="`$headers['wrong-header'] = `$continuation"; Suite=$rules }
    @{ Name='PowerShell omits document expiry'; File='scripts\Sync-ClaudeProjection.ps1'; From='expiresAt      = $expiresAt'; To='expiresAt      = 0'; Suite=$rules }
    @{ Name='PowerShell restarts the lease after scanning'; File='scripts\Sync-ClaudeProjection.ps1'; From='$expiresAt = $scanStarted.ToUnixTimeSeconds() + $MaxAgeSeconds'; To='$expiresAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + $MaxAgeSeconds'; Suite=$rules }
    @{ Name='PowerShell accepts a longer maximum lease'; File='scripts\Sync-ClaudeProjection.ps1'; From='[ValidateRange(60,7200)]'; To='[ValidateRange(60,86400)]'; Suite=$rules }
    @{ Name='PowerShell never renews unchanged members'; File='scripts\Sync-ClaudeProjection.ps1'; From='{ $unchanged++ }'; To='{ $unchanged++; continue }'; Suite=$rules }
    @{ Name='PowerShell failed revocation reports success'; File='scripts\Sync-ClaudeProjection.ps1'; From='catch { $failed++; Write-Warning "  could not remove'; To='catch { Write-Warning "  could not remove'; Suite=$rules }
    @{ Name='PowerShell expired apply is not reported'; File='scripts\Sync-ClaudeProjection.ps1'; From='Projection expired during apply'; To='Apply done'; Suite=$rules }
    @{ Name='Node apply omits refresh'; File='sync\src\apply-projection.mjs'; From=', refresh: true'; To=', refresh: false'; Suite=$rules }
    @{ Name='Node apply omits scan lease'; File='sync\src\apply-projection.mjs'; From='toDocument(r, { tenantId, mappingVersion, reconciliation })'; To='toDocument(r, { tenantId, mappingVersion })'; Suite=$rules }
    @{ Name='Node expired apply reports success'; File='sync\src\apply-projection.mjs'; From=' && !expired, expired,'; To=', expired,'; Suite=$rules }
    @{ Name='Node expired apply exits zero'; File='sync\src\apply-projection.mjs'; From=' || expired ? 3 : 0'; To=' ? 3 : 0'; Suite=$rules }
    @{ Name='generation is omitted from documents'; File='sync\src\plan.mjs'; From='    ...reconciliation,'; To=''; Suite=$node }
    @{ Name='renewal skips unchanged members'; File='sync\src\plan.mjs'; From='if (!refresh) continue;'; To='continue;'; Suite=$node }
    @{ Name='lease starts at apply instead of scan'; File='sync\src\plan.mjs'; From='Math.floor(start / 1000) + maxAgeSeconds'; To='Math.floor(now.getTime() / 1000) + maxAgeSeconds'; Suite=$node }
    @{ Name='expired snapshots may be replayed'; File='sync\src\plan.mjs'; From="problems.push('snapshot expired; resolve the directory again')"; To="void 0"; Suite=$node }
    @{ Name='comparison approves expired records'; File='sync\src\plan.mjs'; From=' || freshnessProblems(r, now).length'; To=''; Suite=$node }
    @{ Name='expired record authorizes'; File='resolver\src\entitlement.mjs'; From='if (doc.expiresAt <= Math.floor(now.getTime() / 1000))'; To='if (false)'; Suite=$node }
    @{ Name='missing generation authorizes'; File='resolver\src\entitlement.mjs'; From='!isObjectId(doc.reconciliationGeneration) || '; To=''; Suite=$node }
    @{ Name='future verification authorizes'; File='resolver\src\entitlement.mjs'; From='verified > now.getTime() || '; To=''; Suite=$node }
    @{ Name='unbounded lease authorizes'; File='resolver\src\entitlement.mjs'; From='doc.expiresAt > Math.floor(verified / 1000) + 7200'; To='false'; Suite=$node }
    @{ Name='missing tenant authorizes'; File='resolver\src\entitlement.mjs'; From='if (!tenantId || doc.tenantId !== tenantId)'; To='if (tenantId && doc.tenantId && doc.tenantId !== tenantId)'; Suite=$node }
    @{ Name='resolver drops expiry in response'; File='resolver\src\entitlement.mjs'; From='expiresAt: doc.expiresAt,'; To=''; Suite=$node }
    @{ Name='tenant-free cache key'; File='infra\policy.xml'; From='ent:v2:{{tenant-id}}:'; To='ent:'; Suite=$rules }
    @{ Name='cache outlives record'; File='infra\policy.xml'; From='Math.Min(int.Parse("{{entitlement-cache-seconds}}"), expires - now)'; To='int.Parse("{{entitlement-cache-seconds}}")'; Suite=$rules }
    @{ Name='cache hit skips expiry'; File='infra\policy.xml'; From='return expires > now &amp;&amp; !string.IsNullOrEmpty'; To='return !string.IsNullOrEmpty'; Suite=$rules }
    @{ Name='Razor conditional loses required braces'; File='infra\policy.xml'; From='{ return false; }'; To='return false;'; Suite=$rules }
    @{ Name='stale answer is authorized'; File='infra\policy.xml'; From=' &amp;&amp; (bool)context.Variables["entFresh"]'; To=''; Suite=$rules }
    @{ Name='expired error loses diagnostic'; File='infra\policy.xml'; From='The entitlement projection expired'; To='Unknown failure'; Suite=$rules }
    @{ Name='resolver has no concurrency backpressure'; File='infra\policy.xml'; From='<limit-concurrency key="entitlement-misses" max-count="100">'; To='<limit-concurrency key="entitlement-misses" max-count="10000">'; Suite=$rules }
    @{ Name='resolver has no rate backpressure'; File='infra\policy.xml'; From='<rate-limit-by-key calls="200" renewal-period="1" counter-key="entitlement-misses" />'; To=''; Suite=$rules }
    @{ Name='overload maps to an outage'; File='infra\policy.xml'; From='context.LastError.Source == "limit-concurrency"'; To='context.LastError.Source == "unused"'; Suite=$rules }
    @{ Name='deployed path bypasses coalescing'; File='resolver\src\index.mjs'; From='await lookup(oid)'; To='await getContainer().item(oid, oid).read()'; Suite=$rules }
    @{ Name='transport exceeds APIM deadline'; File='resolver\src\index.mjs'; From='requestTimeout: 2500'; To='requestTimeout: 60000'; Suite=$rules }
    @{ Name='Cosmos retries outlive deadline'; File='resolver\src\index.mjs'; From='maxRetryAttemptCount: 0'; To='maxRetryAttemptCount: 9'; Suite=$rules }
    @{ Name='Cosmos loses the abort signal'; File='resolver\src\index.mjs'; From='.read({ abortSignal })'; To='.read()'; Suite=$rules }
    @{ Name='default lookup deadline exceeds gateway'; File='resolver\src\lookup.mjs'; From='deadlineMs = 3500'; To='deadlineMs = 6000'; Suite=$rules }
    @{ Name='default lookup work exceeds admission'; File='resolver\src\lookup.mjs'; From='maxInFlight = 100'; To='maxInFlight = 1000'; Suite=$rules }
    @{ Name='same identity misses fan out'; File='resolver\src\lookup.mjs'; From='if (pending.has(oid))'; To='if (false)'; Suite=$node }
    @{ Name='distinct identity work is unbounded'; File='resolver\src\lookup.mjs'; From='if (pending.size >= maxInFlight)'; To='if (false)'; Suite=$node }
    @{ Name='timeout does not cancel transport'; File='resolver\src\lookup.mjs'; From='abort.abort();'; To=''; Suite=$node }
    @{ Name='warm capacity regresses'; File='infra\resolver.bicep'; From='param alwaysReadyInstances int = 2'; To='param alwaysReadyInstances int = 1'; Suite=$rules }
    @{ Name='HTTP concurrency regresses'; File='infra\resolver.bicep'; From='perInstanceConcurrency: httpConcurrency'; To='perInstanceConcurrency: 16'; Suite=$rules }
    @{ Name='private default regresses'; File='infra\projection.bicep'; From="param networkAccess string = 'private-only'"; To="param networkAccess string = 'public'"; Suite=$rules }
    @{ Name='explicit public profile is removed'; File='infra\projection.bicep'; From="networkAccess == 'private-only' ? 'Disabled' : 'Enabled'"; To="'Disabled'"; Suite=$rules }
    @{ Name='load can target entitlement'; File='guide\loadtest-projection.mjs'; From="containerName !== 'loadtest' || "; To=''; Suite=$node }
    @{ Name='load count is unbounded'; File='guide\loadtest-projection.mjs'; From='total < 1 || total > 500000 ||'; To=''; Suite=$node }
    @{ Name='load concurrency is unbounded'; File='guide\loadtest-projection.mjs'; From='concurrency < 1 || concurrency > 128'; To='false'; Suite=$node }
)
function Run-Suite($suite) {
    Push-Location $sandbox
    try {
        if ($suite -eq 'node') {
            node --test --test-timeout=1500 --test-reporter=tap resolver/test/*.test.mjs sync/test/*.test.mjs *> $null
        } elseif ($suite -eq 'paging') {
            pwsh -NoProfile -File tests\Test-ProjectionPaging.ps1 *> $null
        } else { pwsh -NoProfile -File tests\Test-ProjectionRules.ps1 *> $null }
        return $LASTEXITCODE
    } finally { Pop-Location }
}
$caught = 0
try {
    foreach ($dir in 'resolver', 'sync', 'scripts', 'infra', 'tests', 'guide') {
        Get-ChildItem (Join-Path $root $dir) -Recurse -File |
            Where-Object { $_.FullName -notmatch '[\\/]node_modules[\\/]' -and $_.Extension -in '.mjs', '.ps1', '.xml', '.bicep', '.json' } |
            ForEach-Object {
                $dest = Join-Path $sandbox $_.FullName.Substring($root.Length + 1)
                New-Item -ItemType Directory -Force (Split-Path $dest) | Out-Null
                Copy-Item $_.FullName $dest
            }
    }
    foreach ($suite in 'rules', 'paging', 'node') {
        if ((Run-Suite $suite) -ne 0) { throw "Unmutated $suite failed; no mutation result is valid." }
    }
    foreach ($m in $mutations) {
        $path = Join-Path $sandbox $m.File
        $before = [IO.File]::ReadAllText($path)
        if (-not $before.Contains($m.From)) { throw "Mutation anchor missing: $($m.Name)" }
        try {
            [IO.File]::WriteAllText($path, $before.Replace($m.From, $m.To))
            if ((Run-Suite $m.Suite) -eq 0) { throw "SURVIVED: $($m.Name)" }
            $caught++
            Write-Host "[CAUGHT] $($m.Name)"
        } finally { [IO.File]::WriteAllText($path, $before) }
    }
    Write-Host "Projection mutations: $caught/$($mutations.Count) caught."
} finally { Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue }
exit 0
