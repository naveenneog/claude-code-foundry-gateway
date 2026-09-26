<#
.SYNOPSIS
    Installs the AUM terminal client (`aum`) in a Python virtual environment, then configures it.

.DESCRIPTION
    One command for the steps in docs/AUM.md "Install and sign in". It reads the Python version
    the package requires from cli/finops/pyproject.toml, lists the interpreters on this machine
    that meet it (the Python launcher's `py -0p`, then PATH) and asks which one when -Python was
    not given. It creates the virtual environment or reuses an existing one, installs cli/finops,
    checks `aum --version` and the Azure CLI sign-in, and runs `aum configure`, which lists the
    real subscriptions, gateways and workspaces to choose from.

    Nothing in Azure is created or changed. -WhatIf prints the plan and writes nothing.

.PARAMETER Python
    Interpreter to create the environment with. Omitted: discovered and asked for.

.PARAMETER VenvPath
    Virtual environment directory. Default: .venv-finops at the repository root, the path the
    guide and tests/Test-All.ps1 use.

.PARAMETER WithTests
    Also installs the test extras, for tests/Test-FinOps.ps1.

.PARAMETER NoConfigure
    Stops after the installation check instead of running `aum configure`.

.PARAMETER ConfigureArguments
    Arguments passed to `aum configure`, for example '--backend','direct','--save'.

.EXAMPLE
    ./scripts/Install-ClaudeAum.ps1

.EXAMPLE
    ./scripts/Install-ClaudeAum.ps1 -Python (py -3.12 -c "import sys; print(sys.executable)") -NoConfigure
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Python,
    [string]$VenvPath,
    [switch]$WithTests,
    [switch]$NoConfigure,
    [string[]]$ConfigureArguments = @()
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'ClaudeChoice.ps1')

function Get-ClaudeAumRequiredPython {
    param([Parameter(Mandatory = $true)][string]$Pyproject)
    $text = Get-Content -LiteralPath $Pyproject -Raw
    $match = [regex]::Match($text, '(?m)^\s*requires-python\s*=\s*"(?<spec>[^"]+)"')
    if (-not $match.Success) { throw "No requires-python in $Pyproject." }
    $spec = $match.Groups['spec'].Value.Trim()
    if ($spec -notmatch '^>=\s*(?<v>\d+\.\d+)$') { throw "Unsupported requires-python '$spec' in $Pyproject; only '>=X.Y' is understood." }
    return [version]$Matches.v
}

function ConvertFrom-ClaudePythonLauncherList {
    # `py -0p` prints one interpreter per line: " -V:3.12 *        C:\...\python.exe"
    param([string[]]$Lines = @())
    foreach ($line in $Lines) {
        $m = [regex]::Match($line, '^\s*-V:(?<v>\d+\.\d+)\S*\s+(?:\*\s+)?(?<path>\S.*?)\s*$')
        if ($m.Success) { [pscustomobject]@{ Version = [version]$m.Groups['v'].Value; Path = $m.Groups['path'].Value; Source = 'Python launcher (py -0p)' } }
    }
}

function Get-ClaudeAumPythonCandidates {
    $found = [System.Collections.Generic.List[object]]::new()
    $launcher = Get-Command py -ErrorAction SilentlyContinue
    if ($launcher) {
        foreach ($c in @(ConvertFrom-ClaudePythonLauncherList -Lines @(& $launcher.Source -0p 2>$null))) { $found.Add($c) }
    }
    foreach ($name in 'python', 'python3') {
        $cmd = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $cmd -or $cmd.Source -match 'WindowsApps') { continue }
        $out = (& $cmd.Source --version 2>&1 | Out-String).Trim()
        if ($out -match 'Python (?<v>\d+\.\d+)') { $found.Add([pscustomobject]@{ Version = [version]$Matches.v; Path = $cmd.Source; Source = "PATH ($name)" }) }
    }
    $seen = @{}
    foreach ($c in $found) {
        $key = $c.Path.ToLowerInvariant()
        if (-not $seen.ContainsKey($key) -and (Test-Path -LiteralPath $c.Path)) { $seen[$key] = $true; $c }
    }
}

function Get-ClaudeAumVenvPythonVersion {
    param([string]$Venv)
    $cfg = Join-Path $Venv 'pyvenv.cfg'
    if (-not (Test-Path -LiteralPath $cfg)) { return $null }
    $line = Get-Content -LiteralPath $cfg | Where-Object { $_ -match '^\s*version(_info)?\s*=\s*(\d+\.\d+)' } | Select-Object -First 1
    if ($line -and $line -match '=\s*(\d+\.\d+)') { return [version]$Matches[1] }
    return $null
}

function Select-ClaudeAumPython {
    param(
        [object[]]$Candidates = @(),
        [Parameter(Mandatory = $true)][version]$Required,
        [version]$ExistingVersion,
        [object]$Interactive = $null
    )
    $usable = @($Candidates | Where-Object { $_.Version -ge $Required } | Sort-Object Version)
    if (-not $usable.Count) {
        $seen = ($Candidates | ForEach-Object { "$($_.Version) at $($_.Path)" }) -join '; '
        throw "AUM needs Python $Required or later; none was found$(if ($seen) { " (found: $seen)" }). Install it from https://www.python.org/downloads/ and pass -Python <path>."
    }
    # An existing environment's version is kept; otherwise the lowest version that meets the
    # requirement, the one the package's dependency ranges were tested against.
    $recommended = if ($ExistingVersion) { $usable | Where-Object { $_.Version.Major -eq $ExistingVersion.Major -and $_.Version.Minor -eq $ExistingVersion.Minor } | Select-Object -First 1 } else { $null }
    $reason = if ($recommended) { "matches the existing environment ($ExistingVersion)" } else { 'lowest version that meets the requirement' }
    if (-not $recommended) { $recommended = $usable[0] }
    $options = foreach ($c in $usable) {
        New-ClaudeChoiceOption -Value $c.Path -Label "Python $($c.Version)" -Detail "$($c.Path) - $($c.Source)" -Recommended:($c.Path -eq $recommended.Path) -Reason $reason
    }
    $selectArgs = @{
        Parameter   = 'Python'
        Question    = "Python interpreter for AUM (needs $Required or later)"
        Options     = @($options)
        WhereToFind = @('py -0p', 'Get-Command python')
        AcceptRecommendedWithoutConsole = ($usable.Count -eq 1)
    }
    if ($null -ne $Interactive) { $selectArgs.Interactive = $Interactive }
    return Select-ClaudeChoice @selectArgs
}

function Invoke-ClaudeAumStep {
    param([string]$Label, [scriptblock]$Action)
    Write-Host "  $Label" -ForegroundColor Cyan
    & $Action
    if ($LASTEXITCODE) { throw "$Label failed with exit code $LASTEXITCODE." }
}

if ($MyInvocation.InvocationName -eq '.') { return }

$package = Join-Path $repoRoot 'cli\finops'
$required = Get-ClaudeAumRequiredPython -Pyproject (Join-Path $package 'pyproject.toml')
if (-not $VenvPath) { $VenvPath = Join-Path $repoRoot '.venv-finops' }
$VenvPath = [IO.Path]::GetFullPath($VenvPath)
$existingVersion = Get-ClaudeAumVenvPythonVersion -Venv $VenvPath

if ($Python) {
    if (-not (Test-Path -LiteralPath $Python)) { throw "No interpreter at '$Python'." }
    $out = (& $Python --version 2>&1 | Out-String).Trim()
    if ($out -notmatch 'Python (?<v>\d+\.\d+)' -or [version]$Matches.v -lt $required) { throw "'$Python' reports '$out'; AUM needs Python $required or later." }
}
else {
    $Python = Select-ClaudeAumPython -Candidates @(Get-ClaudeAumPythonCandidates) -Required $required -ExistingVersion $existingVersion
}

$venvPython = if ($IsLinux -or $IsMacOS) { Join-Path $VenvPath 'bin/python' } else { Join-Path $VenvPath 'Scripts\python.exe' }
$aum = if ($IsLinux -or $IsMacOS) { Join-Path $VenvPath 'bin/aum' } else { Join-Path $VenvPath 'Scripts\aum.exe' }
$target = if ($WithTests) { "$package[test]" } else { $package }

Write-Host ''
Write-Host 'AUM - Azure Usage Management, terminal client' -ForegroundColor Cyan
Write-Host "  Python      : $Python"
Write-Host "  Environment : $VenvPath $(if (Test-Path -LiteralPath $venvPython) { '(exists, reused)' } else { '(new)' })"
Write-Host "  Package     : $target"
Write-Host "  Then        : $(if ($NoConfigure) { 'aum --version' } else { "aum configure $($ConfigureArguments -join ' ')" })"
Write-Host ''

if (-not $PSCmdlet.ShouldProcess($VenvPath, 'Create or reuse the virtual environment and install AUM')) { return }

if (-not (Test-Path -LiteralPath $venvPython)) {
    Invoke-ClaudeAumStep "Create $VenvPath" { & $Python -m venv $VenvPath }
}
Invoke-ClaudeAumStep 'Install cli/finops' { & $venvPython -m pip install --disable-pip-version-check -q -e $target }
Invoke-ClaudeAumStep 'Check aum --version' { & $aum --version }

$az = Get-Command az -ErrorAction SilentlyContinue
if (-not $az) {
    Write-Warning 'Azure CLI is not installed. AUM signs in through it: https://learn.microsoft.com/cli/azure/install-azure-cli'
}
else {
    $account = az account show -o json 2>$null | ConvertFrom-Json
    if ($account) { Write-Host "  Azure CLI signed in as $($account.user.name), tenant $($account.tenantId)" -ForegroundColor DarkGray }
    else { Write-Warning 'Azure CLI is not signed in. Run: az login --tenant <tenant-id>' }
}

if ($NoConfigure) {
    Write-Host ''
    Write-Host "Installed. Next: $aum configure" -ForegroundColor Green
    return
}
Write-Host ''
& $aum configure @ConfigureArguments
exit $LASTEXITCODE
