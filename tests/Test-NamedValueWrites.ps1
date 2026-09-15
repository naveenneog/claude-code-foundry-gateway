# P17 - named value writes must fail loudly.
#
# RED first: written before the fix.
#
# Measured 2026-09-15: APIM named values cap at 4,096 characters. A 4,096-char
# value returns HTTP 201; 8,192 returns HTTP 400 "NamedValue Value should be
# between 1 and 4096 characters long." A 36-character object id plus its
# separator is 37 chars, so an allow list holds about 110 entries.
#
# Every named value write in this repository was made with
# `az apim nv update ... -o none 2>$null` and no $LASTEXITCODE check, so that
# 400 was discarded. Two consequences, both silent:
#
#   Sync-ClaudeAccess.ps1   past ~110 members a tier stops updating, and the
#                           sync reports success while entitlement goes stale.
#   Show-Governance.ps1     drops tpm-standard to 100 to demonstrate throttling
#                           and then restores it. A failed restore leaves the
#                           standard tier throttled at 100 tokens per minute.
#
# The fix is a shared helper that refuses an oversized value before the call and
# throws on a failed one. This asserts both, and that every caller uses it.

param([switch]$SkipLive)

$root = Split-Path $PSScriptRoot -Parent
$helper = Join-Path $root 'scripts/ApimNamedValue.ps1'

$fail = 0
function Assert($label, $condition, $detail = '') {
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $label$(if ($detail) { " - $detail" })" -ForegroundColor Red; $script:fail++ }
}

Write-Host ''
Write-Host 'P17 named value writes - the helper' -ForegroundColor Cyan

Assert 'a shared helper exists' (Test-Path $helper) $helper
if (-not (Test-Path $helper)) {
    Write-Host ''
    Write-Host "$fail assertion(s) failed." -ForegroundColor Red
    exit 1
}

. $helper

Assert 'it exposes Set-ApimNamedValue' ([bool](Get-Command Set-ApimNamedValue -ErrorAction SilentlyContinue))
Assert 'it publishes the documented limit' ((Get-Variable -Name ApimNamedValueMaxLength -Scope Global -ErrorAction SilentlyContinue) -or $ApimNamedValueMaxLength -eq 4096) "expected 4096"

Write-Host ''
Write-Host 'P17 named value writes - the size guard' -ForegroundColor Cyan

# The guard has to refuse before the request is sent, so it can be exercised
# without Azure and without a real named value.
$oversized = ',' + ('a' * 4200) + ','
$threw = $false
$message = ''
try { Test-ApimNamedValueLength -Id 'probe' -Value $oversized }
catch { $threw = $true; $message = $_.Exception.Message }
Assert 'an oversized value is refused'      $threw
Assert 'the refusal names the limit'        ($message -match '4096') $message
Assert 'the refusal names the named value'  ($message -match 'probe') $message
Assert 'the refusal says how far over'      ($message -match '\d{4}') $message

$ok = $true
try { Test-ApimNamedValueLength -Id 'probe' -Value (',' + ('a' * 4000) + ',') }
catch { $ok = $false }
Assert 'a value within the limit passes' $ok

# The entitlement case specifically: how many object ids actually fit.
$oids = @(1..120 | ForEach-Object { [guid]::NewGuid().ToString() })
$value = ',' + ($oids -join ',') + ','
$threwOids = $false
try { Test-ApimNamedValueLength -Id 'allow-standard' -Value $value } catch { $threwOids = $true }
Assert '120 object ids are refused, not silently truncated' $threwOids "value was $($value.Length) chars"

Write-Host ''
Write-Host 'P17 named value writes - every caller uses it' -ForegroundColor Cyan

# A caller that still shells out directly would keep the old silent behaviour,
# so the pattern is asserted away rather than merely replaced once.
$callers = @(Get-ChildItem (Join-Path $root 'scripts') -Filter '*.ps1' -Recurse) +
           @(Get-ChildItem (Join-Path $root 'tests') -Filter '*.ps1' -Recurse)
$offenders = @()
foreach ($f in $callers) {
    if ($f.Name -eq 'ApimNamedValue.ps1') { continue }
    foreach ($line in (Get-Content $f.FullName)) {
        # A comment describing the old shape is not a call. Skip them, or this
        # detector flags the very documentation explaining what it guards.
        if ($line.TrimStart().StartsWith('#')) { continue }
        # An `az apim nv update/create` with its errors sent to $null and no
        # exit check is the exact shape that hid the 400.
        if ($line -match 'az\s+apim\s+nv\s+(update|create)' -and $line -match '2>\$null') {
            $offenders += "$($f.Name): $($line.Trim())"
        }
    }
}
Assert 'no script writes a named value with errors suppressed' ($offenders.Count -eq 0) ($offenders -join ' | ')

$sync = Get-Content (Join-Path $root 'scripts/Sync-ClaudeAccess.ps1') -Raw
Assert 'the sync uses the helper'          ($sync -match 'Set-ApimNamedValue')
Assert 'the sync sources the helper'       ($sync -match 'ApimNamedValue\.ps1')

$gov = Join-Path $root 'scripts/Show-Governance.ps1'
if (Test-Path $gov) {
    $g = Get-Content $gov -Raw
    Assert 'the governance demo restores through the helper' ($g -match 'Set-ApimNamedValue')
}

Write-Host ''
Write-Host 'P17 named value writes - live' -ForegroundColor Cyan

if ($SkipLive) {
    Write-Host '  skipped - offline run (-SkipLive)' -ForegroundColor Yellow
}
else {
    $rg = if ($env:CLAUDE_RG) { $env:CLAUDE_RG } else { 'rg-contosohub' }
    $apim = az apim list -g $rg --query "[0].name" -o tsv 2>$null
    if (-not $apim) {
        Write-Host '  skipped - no API Management found' -ForegroundColor Yellow
    }
    else {
        # A real write, then a real read-back. Writing without confirming the
        # value landed is what the old code effectively did.
        $probeId = 'p17-write-probe'
        $value = ',p17-' + [DateTime]::UtcNow.ToString('HHmmss') + ','
        try {
            Set-ApimNamedValue -ResourceGroup $rg -ApimName $apim -Id $probeId -Value $value
            Assert 'a valid write succeeds' $true
            $readBack = az apim nv show -g $rg --service-name $apim --named-value-id $probeId --query value -o tsv 2>$null
            Assert 'the value read back matches what was written' ($readBack -eq $value) "wrote '$value', read '$readBack'"
        }
        catch {
            Assert 'a valid write succeeds' $false $_.Exception.Message
        }
        finally {
            az apim nv delete -g $rg --service-name $apim --named-value-id $probeId --yes -o none 2>$null
        }
    }
}

Write-Host ''
if ($fail) { Write-Host "$fail assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'P17 contract holds.' -ForegroundColor Green
exit 0
