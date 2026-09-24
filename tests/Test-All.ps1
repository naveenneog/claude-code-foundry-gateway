# Runs the checks that guard the setup scripts.
#
# Split into two groups because they have different requirements: the offline
# checks need only bash and both PowerShell hosts, so they can run anywhere.
# The Azure ones need a signed-in az and are skipped when there isn't one,
# rather than reported as failures.
#
#   ./tests/Test-All.ps1                offline checks
#   ./tests/Test-All.ps1 -IncludeAzure  plus the ones that call Azure

param([switch]$IncludeAzure)

$root = Split-Path $PSScriptRoot -Parent
$scriptsDir = Join-Path $root 'scripts'
$results = @()

function Invoke-Check {
    param([string]$Name, [string]$Script, [hashtable]$Params = @{})

    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor DarkGray
    Write-Host " $Name" -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor DarkGray

    # Tests live in tests/, but a few checks are tools that also ship to users
    # and stay in scripts/ - Repair-ScriptEncoding is both a repair tool and a
    # check. Look in both rather than duplicating the file.
    $path = Join-Path $PSScriptRoot $Script
    if (-not (Test-Path $path)) { $path = Join-Path $scriptsDir $Script }
    if (-not (Test-Path $path)) {
        # A registered check that is missing proves nothing, so it fails the run.
        Write-Host "  FAIL - $Script not found" -ForegroundColor Red
        $script:results += [pscustomobject]@{ Name = $Name; Result = 'FAIL' }
        return
    }

    $global:LASTEXITCODE = 0
    # Splat a hashtable, not an array: an array is bound positionally, so
    # '-Check' would land in $Root and the check would silently scan nothing
    # and still report success.
    # A terminating error inside a check travels up to the nearest try block.
    # Without this catch that was the one around every check below: the rest
    # never ran and the summary still said all passed (Test-RunnerIntegrity).
    $ok = $false
    try {
        & $path @Params | Out-Host
        $ok = ($LASTEXITCODE -eq 0)
    }
    catch { Write-Host "  FAIL - the check stopped with an error: $($_.Exception.Message)" -ForegroundColor Red }
    $script:results += [pscustomobject]@{ Name = $Name; Result = $(if ($ok) { 'PASS' } else { 'FAIL' }) }
}

$completed = $false
Push-Location $root
try {
    # Must come first: a missing BOM mangles every other PowerShell check on 5.1.
    Invoke-Check 'Script encoding (PowerShell 5.1 safety)' 'Repair-ScriptEncoding.ps1' @{ Check = $true }
    Invoke-Check 'Test-All counts every check'             'Test-RunnerIntegrity.ps1'
    Invoke-Check 'Format strings parse and run'            'Test-FormatStrings.ps1'
Invoke-Check 'Screenshots and the docs that show them' 'Test-Screenshots.ps1'
Invoke-Check 'Resolver - the entitlement read path'   'Test-Resolver.ps1'
    Invoke-Check 'Named value writes fail loudly'          'Test-NamedValueWrites.ps1' @{ SkipLive = $true }
    Invoke-Check 'Release log hygiene'                     'Test-ReleaseLog.ps1'
    Invoke-Check 'Azure CLI arguments vs cmd.exe'          'Test-AzArguments.ps1'
    Invoke-Check 'Shell scripts - syntax and banner'       'Test-ShellScripts.ps1'
    Invoke-Check 'Preflight on both PowerShell hosts'      'Test-PreflightBothHosts.ps1'
    Invoke-Check 'Wizard reaches summary on PS 5.1'        'Test-On-PS51.ps1'
    Invoke-Check 'Analytics query contract'                'Test-Analytics.ps1' @{ SkipLive = $true }
    Invoke-Check 'Org spend ceiling'                       'Test-OrgCeiling.ps1' @{ SkipLive = $true }
    Invoke-Check 'Per-user budget control'                 'Test-BudgetControl.ps1' @{ SkipLive = $true }
    Invoke-Check 'Capability scoping per tier'             'Test-CapabilityScoping.ps1' @{ SkipLive = $true }
    Invoke-Check 'Compliance retrieval and deletion'       'Test-Compliance.ps1' @{ SkipLive = $true }
    Invoke-Check 'Chargeback ledger'                       'Test-Ledger.ps1' @{ SkipLive = $true }
    Invoke-Check 'Business unit chargeback'                'Test-BusinessUnits.ps1'
    Invoke-Check 'Teams and the budget cascade'            'Test-Teams.ps1'
    Invoke-Check 'Model discovery and deployment'          'Test-ModelDeployment.ps1'
    Invoke-Check 'Client attribution and the workbook'     'Test-Observability.ps1'
    Invoke-Check 'Business unit checks detect breakage'    'Test-BusinessUnitsNegative.ps1'
    Invoke-Check 'Admin surface - SKU, groups, tiers'      'Test-AdminSurface.ps1'
    Invoke-Check 'Scale ceilings and the load envelope'    'Test-Scale.ps1'
    Invoke-Check 'Secure projection and the migration'     'Test-SecureProjection.ps1'
    Invoke-Check 'Projection checks detect breakage'        'Test-ProjectionNegative.ps1'
    Invoke-Check 'Adding models, and plugin governance'    'Test-ModelsAndPlugins.ps1'
    Invoke-Check 'Backup and restore'                      'Test-Backup.ps1'
    Invoke-Check 'Turnstile - usage mapping and its rules' 'Test-Turnstile.ps1'
    Invoke-Check 'Turnstile - governance and connection'   'Test-TurnstileGovernance.ps1'
    Invoke-Check 'Turnstile checks detect breakage'        'Test-TurnstileNegative.ps1'
    Invoke-Check 'No deployment written into the code'     'Test-NoDeploymentValues.ps1'
    Invoke-Check 'Foundry bypass audit'                    'Test-Bypass.ps1' @{ SkipLive = $true }

    $finopsPython = Join-Path $root '.venv-finops\Scripts\python.exe'
    $finopsUnixPython = Join-Path $root '.venv-finops\bin\python'
    if ((Test-Path $finopsPython) -or (Test-Path $finopsUnixPython)) {
        Invoke-Check 'AUM - commands, dashboard and pilot' 'Test-FinOps.ps1'
    }
    else {
        Write-Host 'SKIP - AUM: Python or the worktree .venv-finops is missing. See docs/AUM.md to install.' -ForegroundColor Yellow
        $results += [pscustomobject]@{ Name = 'AUM - commands, dashboard and pilot'; Result = 'SKIP' }
    }

    if ($IncludeAzure) {
        Invoke-Check 'Foundry discovery is selective'      'Test-Discovery.ps1'
        Invoke-Check 'Wizard reuses an existing gateway'   'Test-ApimReuse.ps1'
        Invoke-Check 'Analytics query against live data'   'Test-Analytics.ps1'
        Invoke-Check 'Org ceiling on the live gateway'     'Test-OrgCeilingLive.ps1'
        Invoke-Check 'Budget control on the live gateway'  'Test-BudgetControlLive.ps1'
        Invoke-Check 'Model allowlist on the live gateway' 'Test-CapabilityScopingLive.ps1'
        Invoke-Check 'Named value writes against Azure'    'Test-NamedValueWrites.ps1'
    }
    $completed = $true
}
finally { Pop-Location }

Write-Host ''
Write-Host ('=' * 72) -ForegroundColor DarkGray
Write-Host ' Summary' -ForegroundColor Cyan
Write-Host ('=' * 72) -ForegroundColor DarkGray
foreach ($r in $results) {
    $colour = switch ($r.Result) { 'PASS' { 'Green' } 'FAIL' { 'Red' } default { 'Yellow' } }
    Write-Host ("  {0,-4}  {1}" -f $r.Result, $r.Name) -ForegroundColor $colour
}

if (-not $IncludeAzure) {
    Write-Host ''
    Write-Host '  Azure checks not run. Add -IncludeAzure once you are signed in.' -ForegroundColor DarkGray
}

Write-Host ''
if (-not $completed) { Write-Host 'The run stopped before every check ran, so it proves nothing.' -ForegroundColor Red; exit 1 }
$failed = @($results | Where-Object Result -eq 'FAIL').Count
if ($failed) { Write-Host "$failed check(s) failed." -ForegroundColor Red; exit 1 }
$skippedCount = @($results | Where-Object Result -eq 'SKIP').Count
if ($skippedCount) { Write-Host "$skippedCount check(s) skipped - the summary names them, and each said why." -ForegroundColor Yellow }
Write-Host 'All checks passed.' -ForegroundColor Green
