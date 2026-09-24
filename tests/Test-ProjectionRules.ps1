$root = Split-Path $PSScriptRoot -Parent
$fail = 0
function Assert($name, $condition) {
    if (-not $condition) { Write-Host "[FAIL] $name"; $script:fail++ }
    else { Write-Host "[OK] $name" }
}
$policy = Get-Content (Join-Path $root 'infra\policy.xml') -Raw
$sync = Get-Content (Join-Path $root 'scripts\Sync-ClaudeProjection.ps1') -Raw
$apply = Get-Content (Join-Path $root 'sync\src\apply-projection.mjs') -Raw
$network = Get-Content (Join-Path $root 'infra\projection.bicep') -Raw
$resolver = Get-Content (Join-Path $root 'infra\resolver.bicep') -Raw
$wiring = Get-Content (Join-Path $root 'resolver\src\index.mjs') -Raw
Assert 'PowerShell consumes the response continuation header' ($sync -match "Continuation = \[string\]\`$response.Headers\['x-ms-continuation'\]")
Assert 'PowerShell queries through the multi-page helper' ($sync -match '\$existing = Get-ClaudeProjectionExisting -ReadPage')
Assert 'PowerShell sends opaque continuation as a header' ($sync -match "\`$headers\['x-ms-continuation'\] = \`$continuation")
Assert 'PowerShell stamps freshness on export and documents' (([regex]::Matches($sync, 'expiresAt\s+= \$expiresAt')).Count -eq 2)
Assert 'PowerShell bounds freshness from scan start' ($sync -match '\$expiresAt = \$scanStarted.ToUnixTimeSeconds\(\) \+ \$MaxAgeSeconds')
Assert 'unchanged PowerShell members are renewed' ($sync -notmatch '\$unchanged\+\+; continue')
Assert 'Node apply refreshes unchanged records' ($apply -match 'keepOrphans: flag\(''--keep-orphans''\), refresh: true')
Assert 'Node writes the scan lease, not a new import lease' ($apply -match 'toDocument\(r, \{ tenantId, mappingVersion, reconciliation \}\)')
Assert 'gateway cache keys include tenant and schema version' (([regex]::Matches($policy, 'ent:v2:\{\{tenant-id\}\}:')).Count -eq 3)
Assert 'gateway cache lifetime is clipped by absolute expiry' ($policy -match 'Math.Min\(int.Parse\("\{\{entitlement-cache-seconds\}\}"\), expires - now\)')
Assert 'gateway checks expiry even on a cache hit' ($policy -match 'return expires > now &amp;&amp; !string.IsNullOrEmpty')
Assert 'APIM Razor conditionals use braced blocks' ($policy -match 'if \(!context.Variables.ContainsKey\("entRecord"\)\) \{ return false; \}' -and $policy -match 'if \(\(string\)rec\["tier"\] == "none"\) \{ return true; \}')
Assert 'gateway only authorizes a fresh answer' ($policy -match 'when condition="@\(context.Variables.ContainsKey\("entRecord"\) &amp;&amp; \(bool\)context.Variables\["entFresh"\]\)"')
Assert 'expired projection is explicitly a service failure' ($policy -match 'The entitlement projection expired')
Assert 'miss backpressure precedes the resolver' ($policy -match '(?s)<limit-concurrency key="entitlement-misses" max-count="100">\s*<send-request')
Assert 'miss rate is bounded before the resolver' ($policy -match '(?s)<rate-limit-by-key calls="200" renewal-period="1" counter-key="entitlement-misses" />\s*<limit-concurrency')
Assert 'miss overload stays a retryable 429, not an entitlement outage' ($policy -match '(?s)context.LastError.Source == "limit-concurrency".{0,200}<set-status code="429"')
Assert 'coalescer is in the deployed path' ($wiring -match 'const lookup = createLookup' -and $wiring -match 'await lookup\(oid\)')
Assert 'Cosmos transport has a bounded timeout and no long retries' ($wiring -match 'requestTimeout: 2500' -and $wiring -match 'maxRetryAttemptCount: 0')
Assert 'two instances are warm by default' ($resolver -match 'param alwaysReadyInstances int = 2')
Assert 'HTTP concurrency is explicitly sized' ($resolver -match 'param httpConcurrency int = 100' -and $resolver -match 'perInstanceConcurrency: httpConcurrency')
Assert 'enterprise Cosmos is private by default' ($network -match "param networkAccess string = 'private-only'")
Assert 'explicit public and selected IP profiles remain' ($network -match "'public'" -and $network -match "'selected-ips'" -and $network -match "networkAccess == 'private-only' \? 'Disabled' : 'Enabled'")
Write-Host "Projection rules: $fail failed."
exit ([int]($fail -gt 0))
