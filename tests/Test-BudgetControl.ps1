# P12 - programmatic cost control.
#
# RED first: written before the implementation.
#
# Claude Enterprise exposes an Admin API that reads effective limits and
# month-to-date spend and sets or clears per-user overrides. P10 supplies the
# spend and P11 supplies the ceiling, so this is a surface over both plus one new
# thing: a per-user quota that is not just "move them to the other tier".
#
# The mechanism was measured on a throwaway API on 2026-09-02, because two parts
# of it are not obvious from the reference:
#
#   token-quota accepts a policy expression, but the expression must return
#   long. Int32 is rejected with "Expression return type 'System.Int32' is not
#   allowed" and string with "Cannot implicitly convert type 'string' to
#   'long'", both at deploy time.
#
#   A named value substitutes its raw text into the expression, so a JSON map
#   would terminate the surrounding C# string literal on its first quote. The
#   map is comma-delimited with sentinel commas, matching allow-standard.
#
# Measured: no override -> tier default (999999), override present -> 50, and the
# counter drained to zero against the override rather than the default.

param([switch]$SkipLive)

$root = Split-Path $PSScriptRoot -Parent
$policyPath = Join-Path $root 'infra/policy.xml'
$bicepPath = Join-Path $root 'infra/main.bicep'
$readPath = Join-Path $root 'scripts/Get-ClaudeBudget.ps1'
$writePath = Join-Path $root 'scripts/Set-ClaudeBudget.ps1'

$fail = 0
function Assert($label, $condition, $detail = '') {
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $label$(if ($detail) { " - $detail" })" -ForegroundColor Red; $script:fail++ }
}

Write-Host ''
Write-Host 'P12 cost control - per-user override' -ForegroundColor Cyan

$policy = if (Test-Path $policyPath) { Get-Content $policyPath -Raw } else { '' }
$bicep = if (Test-Path $bicepPath) { Get-Content $bicepPath -Raw } else { '' }

Assert 'the template takes overrides'   ($bicep -match 'param\s+quotaOverridesExisting\s+string')
Assert 'they become a named value'      ($bicep -match "key:\s*'quota-overrides'")

# A redeploy must not wipe them. allow-standard needed exactly this guard after
# a what-if showed a redeploy resetting it to ',,' and revoking everyone. The
# check is the preservation expression, not just the parameter's presence.
Assert 'a redeploy preserves them'      ($bicep -match 'empty\(quotaOverridesExisting\)\s*\?[^:]*:\s*quotaOverridesExisting')

Assert 'the policy resolves an effective quota' ($policy -match '<set-variable name="effectiveQuota"')
Assert 'it reads the override map'              ($policy -match '\{\{quota-overrides\}\}')
Assert 'it falls back to the tier quota'        ($policy -match '\{\{quota-premium\}\}' -and $policy -match '\{\{quota-standard\}\}')

# Measured: Int32 and string are both rejected at deploy time.
Assert 'the quota expression returns long' ($policy -match 'token-quota="@\(long\.Parse')

# Sentinel commas make the lookup exact, so one object id cannot partially match
# another - the same reason allow-standard uses them.
Assert 'the lookup is anchored on commas' ($policy -match '","\s*\+\s*oid|"," \+ oid')

Write-Host ''
Write-Host 'P12 cost control - admin surface' -ForegroundColor Cyan

Assert 'a reader exists' (Test-Path $readPath) $readPath
Assert 'a writer exists' (Test-Path $writePath) $writePath

if (Test-Path $readPath) {
    $r = Get-Content $readPath -Raw
    Assert 'the reader reports effective limits' ($r -match 'effective|EffectiveQuota|quota-overrides')
    Assert 'the reader reports spend to date'    ($r -match 'customMetrics|monthToDate|mtd')
    Assert 'the reader can emit JSON'            ($r -match '\$AsJson')
}
if (Test-Path $writePath) {
    $w = Get-Content $writePath -Raw
    Assert 'the writer sets an override'   ($w -match '\$Tokens')
    Assert 'the writer clears an override' ($w -match '\$Clear')

    # The allow-list wipe was caused by a write that replaced the whole value
    # from an incomplete read. This checks the structure that prevents it, not a
    # comment claiming to: the current map must be read before it is written,
    # and the write must refuse if another person's entry would disappear.
    $readAt = $w.IndexOf("Get-Nv 'quota-overrides'")
    $writeAt = $w.IndexOf("Set-Nv 'quota-overrides'")
    Assert 'the writer reads before it writes' (($readAt -ge 0) -and ($writeAt -ge 0) -and ($readAt -lt $writeAt)) "read at $readAt, write at $writeAt"
    Assert 'the writer refuses to drop another entry' ($w -match 'Refusing to write')
}

Write-Host ''
if ($fail) { Write-Host "$fail assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'P12 contract holds.' -ForegroundColor Green
exit 0
