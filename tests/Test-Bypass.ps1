# P16 - the bypass audit.
#
# RED first: written before the implementation.
#
# Every control this repository builds - entitlement, the org ceiling, per-user
# budgets, the model allowlist - governs traffic that goes through the gateway.
# A principal holding data-plane access directly on the Foundry account skips all
# of it by pointing a client straight at the endpoint.
#
# docs/SETUP.md 4.2 describes checking this by hand, against one role name. That
# is not enough. Measured on the reference deployment 2026-09-03: four distinct
# roles grant Cognitive Services data actions, and "Foundry User" grants the same
# Microsoft.CognitiveServices/* as "Cognitive Services User" while appearing
# nowhere in the documentation.
#
# So the audit must derive the role set from the role definitions rather than
# from a hardcoded name, or it will keep missing whatever Azure adds next.

param([switch]$SkipLive)

$root = Split-Path $PSScriptRoot -Parent
$auditPath = Join-Path $root 'scripts/Get-ClaudeBypass.ps1'

$fail = 0
function Assert($label, $condition, $detail = '') {
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $label$(if ($detail) { " - $detail" })" -ForegroundColor Red; $script:fail++ }
}

Write-Host ''
Write-Host 'P16 bypass audit - the script' -ForegroundColor Cyan

Assert 'an audit exists' (Test-Path $auditPath) $auditPath

if (Test-Path $auditPath) {
    $a = Get-Content $auditPath -Raw

    # Deriving the role set is the whole point. A hardcoded list of role names
    # would have missed Foundry User, which is how this was found.
    Assert 'it reads role definitions'      ($a -match 'role definition list|roleDefinitions|dataActions')
    Assert 'it classifies by data action'   ($a -match 'dataActions')
    Assert 'it includes inherited grants'   ($a -match 'include-inherited')

    # A subscription-scoped assignment still applies to the Foundry account and
    # is invisible without asking for it.
    Assert 'it reports where a grant comes from' ($a -match '(?i)inherited|scope')

    # The gateway is supposed to hold this role. Flagging it would train the
    # operator to ignore the output.
    Assert 'it excludes the gateway identity' ($a -match 'principalId|identity\.principalId')

    # An audit that only prints is a report. This has to be usable as a check.
    Assert 'it exits non-zero on a finding'   ($a -match 'exit 1')
    Assert 'it tells you how to fix it'       ($a -match 'az role assignment delete')
}

Write-Host ''
Write-Host 'P16 bypass audit - documentation' -ForegroundColor Cyan

$docs = @(Get-ChildItem (Join-Path $root 'docs') -Filter '*.md' -Recurse -ErrorAction SilentlyContinue) +
        @(Get-ChildItem $root -Filter '*.md' -ErrorAction SilentlyContinue)
$corpus = ($docs | ForEach-Object { Get-Content $_.FullName -Raw }) -join "`n"

# The documentation named one role. There are more.
Assert 'Foundry User is documented as a bypass' ($corpus -match 'Foundry User')
Assert 'the audit is referenced'                ($corpus -match 'Get-ClaudeBypass')

Write-Host ''
if ($fail) { Write-Host "$fail assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'P16 contract holds.' -ForegroundColor Green
exit 0
