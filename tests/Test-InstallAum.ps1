# Install-ClaudeAum.ps1: interpreter discovery and choice, -WhatIf writing nothing, refusal of a
# missing interpreter, and (with AUM_INSTALL_E2E=1) a real install into a temporary environment.
# No Azure calls: `aum configure` is never run here.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$script = Join-Path $root 'scripts\Install-ClaudeAum.ps1'
$fail = 0
function Assert($label, $condition, $detail = '') {
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $label$(if ($detail) { " - $detail" })" -ForegroundColor Red; $script:fail++ }
}
function Get-Thrown([scriptblock]$Block) { try { & $Block; return '' } catch { return $_.Exception.Message } }

Write-Host ''
Write-Host 'AUM install script' -ForegroundColor Cyan
. $script

$scratch = Join-Path ([IO.Path]::GetTempPath()) ('install-aum-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch -Force | Out-Null
try {
    $required = Get-ClaudeAumRequiredPython -Pyproject (Join-Path $root 'cli\finops\pyproject.toml')
    Assert 'the required Python version is read from the package, not fixed in the script' ($required -is [version] -and $required -ge [version]'3.0')
    $py = Join-Path $scratch 'pyproject.toml'
    Set-Content -LiteralPath $py -Value 'requires-python = ">=3.13"'
    Assert 'another requires-python is honoured' ((Get-ClaudeAumRequiredPython -Pyproject $py) -eq [version]'3.13')
    Set-Content -LiteralPath $py -Value 'requires-python = "~=3.12"'
    Assert 'an unsupported specifier is refused, not guessed' ((Get-Thrown { Get-ClaudeAumRequiredPython -Pyproject $py }) -match 'Unsupported')

    $listed = @(ConvertFrom-ClaudePythonLauncherList -Lines @(
        ' -V:3.14 *        C:\py314\python.exe', ' -V:3.12          C:\py312\python.exe',
        ' -V:3.11-32       C:\py311\python.exe', 'no interpreter line'))
    Assert 'py -0p lines are parsed, the default marker and architecture suffix included' (
        $listed.Count -eq 3 -and $listed[0].Version -eq [version]'3.14' -and $listed[0].Path -eq 'C:\py314\python.exe' -and $listed[2].Version -eq [version]'3.11')

    $noConsole = $false
    $picked = Get-Thrown { Select-ClaudeAumPython -Candidates $listed -Required ([version]'3.12') -Interactive $noConsole }
    Assert 'two usable interpreters without a console stop and name -Python' ($picked -match 'Python')
    $one = @($listed | Where-Object { $_.Version -le [version]'3.12' })
    Assert 'a single usable interpreter is taken without a console' ((Select-ClaudeAumPython -Candidates $one -Required ([version]'3.12') -Interactive $noConsole) -eq 'C:\py312\python.exe')
    $defaultPick = & {
        function Read-Host { param($Prompt) '' }
        Select-ClaudeAumPython -Candidates $listed -Required ([version]'3.12') -Interactive $true
    }
    Assert 'Enter takes the lowest version that meets the requirement' ($defaultPick -eq 'C:\py312\python.exe') "got $defaultPick"
    $keepPick = & {
        function Read-Host { param($Prompt) '' }
        Select-ClaudeAumPython -Candidates $listed -Required ([version]'3.12') -ExistingVersion ([version]'3.14') -Interactive $true
    }
    Assert "an existing environment's version is recommended" ($keepPick -eq 'C:\py314\python.exe') "got $keepPick"
    Assert 'an interpreter below the requirement is never offered' ((Get-Thrown { Select-ClaudeAumPython -Candidates @($listed[2]) -Required ([version]'3.12') -Interactive $noConsole }) -match 'needs Python')

    $real = @(Get-ClaudeAumPythonCandidates | Where-Object { $_.Version -ge $required } | Sort-Object Version | Select-Object -First 1)
    if (-not $real.Count) {
        Write-Host "  [SKIP] no Python $required or later on this machine; the script runs were not exercised" -ForegroundColor DarkGray
    }
    else {
        $venv = Join-Path $scratch 'venv'
        $whatIf = & pwsh -NoProfile -NonInteractive -File $script -Python $real[0].Path -VenvPath $venv -NoConfigure -WhatIf 2>&1 | Out-String
        Assert '-WhatIf prints the plan and creates nothing' ($LASTEXITCODE -eq 0 -and $whatIf -match 'What if' -and -not (Test-Path -LiteralPath $venv)) $whatIf
        $wrong = & pwsh -NoProfile -NonInteractive -File $script -Python (Join-Path $scratch 'missing.exe') -VenvPath $venv -NoConfigure 2>&1 | Out-String
        Assert 'a missing interpreter path is refused before anything runs' ($LASTEXITCODE -ne 0 -and $wrong -match 'No interpreter' -and -not (Test-Path -LiteralPath $venv)) $wrong
        # A real install downloads the package's dependencies, so the suite runs it only on request
        # rather than depend on the package index on every run.
        if ($env:AUM_INSTALL_E2E -eq '1') {
            $install = & pwsh -NoProfile -NonInteractive -File $script -Python $real[0].Path -VenvPath $venv -NoConfigure 2>&1 | Out-String
            $aum = Join-Path $venv 'Scripts\aum.exe'
            Assert 'a real run installs aum into the chosen environment' ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $aum) -and $install -match 'Installed') $install
            $again = & pwsh -NoProfile -NonInteractive -File $script -Python $real[0].Path -VenvPath $venv -NoConfigure 2>&1 | Out-String
            Assert 'a second run reuses the environment' ($LASTEXITCODE -eq 0 -and $again -match 'exists, reused') $again
        }
        else { Write-Host '  [SKIP] real install (set AUM_INSTALL_E2E=1 to run it)' -ForegroundColor DarkGray }
    }
}
finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail) { Write-Host "$fail assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'AUM install script holds.' -ForegroundColor Green
exit 0
