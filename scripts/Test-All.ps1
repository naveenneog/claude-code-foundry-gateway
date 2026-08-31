# Runs the checks that guard the setup scripts.
#
# Split into two groups because they have different requirements: the offline
# checks need only bash and both PowerShell hosts, so they can run anywhere.
# The Azure ones need a signed-in az and are skipped when there isn't one,
# rather than reported as failures.
#
#   ./scripts/Test-All.ps1              offline checks
#   ./scripts/Test-All.ps1 -IncludeAzure   plus the ones that call Azure

param([switch]$IncludeAzure)

$root = Split-Path $PSScriptRoot -Parent
$results = @()

function Invoke-Check {
    param([string]$Name, [string]$Script, [hashtable]$Params = @{})

    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor DarkGray
    Write-Host " $Name" -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor DarkGray

    $path = Join-Path $PSScriptRoot $Script
    if (-not (Test-Path $path)) {
        Write-Host "  skipped - $Script not found" -ForegroundColor Yellow
        $script:results += [pscustomobject]@{ Name = $Name; Result = 'SKIP' }
        return
    }

    $global:LASTEXITCODE = 0
    # Splat a hashtable, not an array: an array is bound positionally, so
    # '-Check' would land in $Root and the check would silently scan nothing
    # and still report success.
    & $path @Params | Out-Host
    $ok = ($LASTEXITCODE -eq 0)
    $script:results += [pscustomobject]@{ Name = $Name; Result = $(if ($ok) { 'PASS' } else { 'FAIL' }) }
}

Push-Location $root
try {
    # Must come first: a missing BOM mangles every other PowerShell check on 5.1.
    Invoke-Check 'Script encoding (PowerShell 5.1 safety)' 'Repair-ScriptEncoding.ps1' @{ Check = $true }
    Invoke-Check 'Azure CLI arguments vs cmd.exe'          'Test-AzArguments.ps1'
    Invoke-Check 'Shell scripts - syntax and banner'       'Test-ShellScripts.ps1'
    Invoke-Check 'Preflight on both PowerShell hosts'      'Test-PreflightBothHosts.ps1'
    Invoke-Check 'Wizard reaches summary on PS 5.1'        'Test-On-PS51.ps1'

    if ($IncludeAzure) {
        Invoke-Check 'Foundry discovery is selective'      'Test-Discovery.ps1'
        Invoke-Check 'Wizard reuses an existing gateway'   'Test-ApimReuse.ps1'
    }
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
$failed = @($results | Where-Object Result -eq 'FAIL').Count
if ($failed) { Write-Host "$failed check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'All checks passed.' -ForegroundColor Green
