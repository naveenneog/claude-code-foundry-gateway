# P15 - compliance retrieval and selective deletion.
#
# RED first: written before the implementation.
#
# U7 fixed the boundaries this asserts. Purge is Azure Monitor's documented GDPR
# erasure mechanism and a real delete, but it is bounded: 50 requests an hour,
# one table per request, a formal 30-day completion SLA with no expedite, and
# Basic and Auxiliary plan tables cannot be purged at all.
#
# So the test checks two things that are easy to get wrong and expensive to get
# wrong quietly:
#
#   1. The tooling states the 30-day SLA rather than implying deletion is
#      prompt. A compliance promise nobody can keep is worse than no promise.
#   2. Deletion is preceded by a query that shows what would be deleted. The
#      REST reference says to "run the query prior to using for a purge request
#      to verify that the results are expected", and purge is non-reversible.

param([switch]$SkipLive)

$root = Split-Path $PSScriptRoot -Parent
$findPath = Join-Path $root 'scripts/Find-ClaudeUserData.ps1'
$purgePath = Join-Path $root 'scripts/Remove-ClaudeUserData.ps1'

$fail = 0
function Assert($label, $condition, $detail = '') {
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $label$(if ($detail) { " - $detail" })" -ForegroundColor Red; $script:fail++ }
}

Write-Host ''
Write-Host 'P15 compliance - find what is held about a person' -ForegroundColor Cyan

Assert 'a finder exists' (Test-Path $findPath) $findPath
if (Test-Path $findPath) {
    $f = Get-Content $findPath -Raw
    Assert 'it takes a subject'          ($f -match '\$User')
    Assert 'it takes a time range'       ($f -match '\$Since|\$From')
    Assert 'it reports per table'        ($f -match 'table|TableName')
    Assert 'it can emit JSON'            ($f -match '\$AsJson')
    # Basic and Auxiliary tables can be searched but not purged, so the finder
    # has to say which of what it found is actually deletable.
    Assert 'it flags what cannot be purged' ($f -match '(?i)Basic|Auxiliary')
}

Write-Host ''
Write-Host 'P15 compliance - delete it' -ForegroundColor Cyan

Assert 'a purger exists' (Test-Path $purgePath) $purgePath
if (Test-Path $purgePath) {
    $p = Get-Content $purgePath -Raw

    # Non-reversible, so it must not be the default behaviour of running the
    # script with a name.
    Assert 'it does not delete by default'   ($p -match '\$Confirm|\$WhatIf|ShouldProcess|\$Execute')
    Assert 'it shows what would go first'    ($p -match 'Find-ClaudeUserData|preview|would be')
    Assert 'it submits one request per table' ($p -match '(?i)per table|one table|foreach')
    Assert 'it tracks the operation'          ($p -match 'x-ms-status-location|purgeId|Get-PurgeStatus|operations/')

    # The numbers from U7. Stating them in the tool is what stops a 30-day
    # process being described to a regulator as immediate.
    Assert 'it states the 30-day SLA'         ($p -match '30[- ]day')
    Assert 'it states the hourly limit'       ($p -match '50')
    Assert 'it names the required role'       ($p -match '(?i)Data Purger')
}

Write-Host ''
Write-Host 'P15 compliance - documentation' -ForegroundColor Cyan

$docs = @(Get-ChildItem (Join-Path $root 'docs') -Filter '*.md' -Recurse -ErrorAction SilentlyContinue) +
        @(Get-ChildItem $root -Filter '*.md' -ErrorAction SilentlyContinue)
$corpus = ($docs | ForEach-Object { Get-Content $_.FullName -Raw }) -join "`n"

Assert 'the SLA is documented'              ($corpus -match '30[- ]day')
Assert 'the plan exclusion is documented'   ($corpus -match '(?i)Basic and Auxiliary|Auxiliary table')
Assert 'capture is documented as opt-in'    ($corpus -match '(?i)CaptureContent')

Write-Host ''
if ($fail) { Write-Host "$fail assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'P15 contract holds.' -ForegroundColor Green
exit 0
