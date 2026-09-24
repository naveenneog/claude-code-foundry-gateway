# The resolver's decisions, run as part of the suite.
#
# The logic lives in JavaScript because it runs in an Azure Function, and it is
# tested with node --test rather than being restated in PowerShell. Restating it
# would make two sources for the same decision, and the copy that is not
# deployed is the one that stays right.
#
# This wrapper exists so a single `./tests/Test-All.ps1` still covers it. A test
# that has to be remembered separately is a test that stops being run.

$root = Split-Path $PSScriptRoot -Parent

$fail = 0
function Assert($label, $condition, $detail = '') {
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $label$(if ($detail) { " - $detail" })" -ForegroundColor Red; $script:fail++ }
}

Write-Host ''
Write-Host 'Resolver - the entitlement read path' -ForegroundColor Cyan

$resolverDir = Join-Path $root 'resolver'
Assert 'the resolver ships' (Test-Path (Join-Path $resolverDir 'src/entitlement.mjs'))
Assert 'with a function host manifest' (Test-Path (Join-Path $resolverDir 'host.json'))

# The decisions are separated from the Azure wiring on purpose: a test that
# needed a Cosmos account would not be run.
$logic = Get-Content (Join-Path $resolverDir 'src/entitlement.mjs') -Raw
$wiring = Get-Content (Join-Path $resolverDir 'src/index.mjs') -Raw
Assert 'the decisions import nothing from Azure' ($logic -notmatch "from '@azure/")
Assert 'and the wiring is what talks to Cosmos'  ($wiring -match "from '@azure/cosmos'")

# Key authentication is disabled on the account, so this is the only way in.
Assert 'it authenticates with a managed identity' ($wiring -match 'DefaultAzureCredential')
Assert 'and does not accept a connection string'  ($wiring -notmatch 'AccountKey|connectionString')
# A point read by id and partition key is the operation measured flat at 1 RU.
Assert 'the lookup is a point read with cancellation' ($wiring -match '\.item\(oid, oid\)\.read\(\{ abortSignal \}\)')
# Authentication is configured on the Function App, not re-implemented here.
Assert 'auth is not decided in two places'        ($wiring -match '(?s)Authentication is not done here')

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Assert 'node is available to run them' $false 'install Node to run the resolver tests'
} else {
    Push-Location $resolverDir
    $out = node --test test/*.test.mjs 2>&1 | Out-String
    $code = $LASTEXITCODE
    Pop-Location

    $passed = if ($out -match '(?m)^.\s*pass\s+(\d+)') { [int]$Matches[1] } else { 0 }
    $failed = if ($out -match '(?m)^.\s*fail\s+(\d+)') { [int]$Matches[1] } else { -1 }

    Assert "node --test ran them ($passed passed)" ($code -eq 0 -and $failed -eq 0) `
        (($out -split "`n" | Where-Object { $_ -match 'not ok |failing tests' } | Select-Object -First 3) -join ' | ')
    # A wrapper that reports success when nothing ran is worse than no wrapper.
    Assert 'and there were tests to run' ($passed -gt 0) 'no tests executed'
}

Write-Host ''
if ($fail) { Write-Host "$fail assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'Resolver contract holds.' -ForegroundColor Green
exit 0
