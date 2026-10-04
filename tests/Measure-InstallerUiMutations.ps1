param(
    [string]$Mutants = (Join-Path $PSScriptRoot 'installer-ui-mutants.json'),
    [string]$Out = (Join-Path (Split-Path $PSScriptRoot -Parent) 'docs\measurements\p93-mutations.json'),
    [string[]]$Only = @(),
    [switch]$DryRun,
    [string]$AzureConfigDir = $env:AZURE_CONFIG_DIR
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Set-Location $repo
if (-not $DryRun -and -not $AzureConfigDir) {
    throw 'Set AZURE_CONFIG_DIR, or pass -AzureConfigDir, to an isolated signed-out Azure CLI profile: the mutated tests start installer children.'
}
if ($AzureConfigDir) { $env:AZURE_CONFIG_DIR = $AzureConfigDir }
$env:CI = '1'
$env:FORCE_COLOR = '0'

function Get-EolText([string]$Text, [string]$Value) {
    if ($Text.Contains("`r`n")) { return $Value.Replace("`r`n", "`n").Replace("`n", "`r`n") }
    return $Value
}

function Invoke-NodeFile([string]$File) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $psi = [Diagnostics.ProcessStartInfo]::new('node')
    foreach ($arg in @('--test', '--test-reporter=tap', $File)) { $psi.ArgumentList.Add($arg) }
    $psi.WorkingDirectory = $repo
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $proc = [Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEndAsync()
    $stderr = $proc.StandardError.ReadToEndAsync()
    $done = $proc.WaitForExit(300000)
    if (-not $done) { try { $proc.Kill($true) } catch { } }
    $text = $stdout.Result + "`n" + $stderr.Result
    $tests = -1
    $failed = -1
    if ($text -match '(?m)^# tests\s+(\d+)') { $tests = [int]$Matches[1] }
    if ($text -match '(?m)^# fail\s+(\d+)') { $failed = [int]$Matches[1] }
    $failNames = @([regex]::Matches($text, '(?m)^not ok \d+ - (.+)$') | ForEach-Object { $_.Groups[1].Value.Trim().Replace('\#', '#') })
    [pscustomobject]@{
        exitCode = if ($done) { $proc.ExitCode } else { 124 }
        checkCount = $tests
        failedCount = $failed
        failNames = $failNames
        seconds = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
        output = $text
    }
}

function Invoke-PowerShellCheck([object[]]$Command) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $exe = [string]$Command[0]
    $args = @($Command | Select-Object -Skip 1)
    $output = @(& $exe @args 2>&1 | ForEach-Object { [string]$_ })
    $exit = $LASTEXITCODE
    $summary = @($output | Where-Object { $_ -match '^(\d+) checks, (\d+) failed' })[-1]
    $checks = -1
    $failed = -1
    if ($summary -match '^(\d+) checks, (\d+) failed') {
        $checks = [int]$Matches[1]
        $failed = [int]$Matches[2]
    }
    $failNames = @($output | Where-Object { $_ -match '^\s*\[FAIL\]\s+(.+?)(?:\s+-|$)' } | ForEach-Object {
        ($_ -replace '^\s*\[FAIL\]\s+', '') -replace '\s+-.*$', ''
    })
    [pscustomobject]@{
        exitCode = $exit
        checkCount = $checks
        failedCount = $failed
        failNames = $failNames
        seconds = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
        output = ($output -join "`n")
    }
}

function Invoke-MutantTest($Mutant) {
    if ($Mutant.PSObject.Properties['command']) { return Invoke-PowerShellCheck @($Mutant.command) }
    return Invoke-NodeFile ([string]$Mutant.testFile)
}

function Test-Parse([string]$Path) {
    if ($Path -like '*.ps1') {
        $tokens = $null
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
        return ($errors.Count -eq 0)
    }
    if ($Path -like '*.js' -or $Path -like '*.mjs') {
        node --check $Path 2>$null
        return ($LASTEXITCODE -eq 0)
    }
    return $true
}

$list = @(Get-Content -LiteralPath $Mutants -Raw | ConvertFrom-Json)
$Only = @($Only | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($Only.Count) { $list = @($list | Where-Object { $Only -contains $_.id }) }

if ($DryRun) {
    foreach ($mutant in $list) {
        $text = [IO.File]::ReadAllText((Join-Path $repo $mutant.file))
        $find = Get-EolText $text ([string]$mutant.find)
        $count = ([regex]::Matches($text, [regex]::Escape($find))).Count
        '{0,-36} {1,-42} matches={2}' -f $mutant.id, $mutant.file, $count
    }
    return
}

$baseline = @{}
foreach ($mutant in $list) {
    $key = if ($mutant.PSObject.Properties['command']) { ($mutant.command -join ' ') } else { [string]$mutant.testFile }
    if ($baseline.ContainsKey($key)) { continue }
    $run = Invoke-MutantTest $mutant
    if ($run.exitCode -ne 0 -or $run.failedCount -ne 0 -or $run.checkCount -lt 1) {
        throw "baseline for $key is not green: exit=$($run.exitCode) checks=$($run.checkCount) failed=$($run.failedCount)"
    }
    $baseline[$key] = $run.checkCount
    Write-Host ("baseline {0}: {1} checks, {2} s" -f $key, $run.checkCount, $run.seconds)
}

$results = foreach ($mutant in $list) {
    $path = Join-Path $repo $mutant.file
    $bytes = [IO.File]::ReadAllBytes($path)
    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    $text = [IO.File]::ReadAllText($path)
    $find = Get-EolText $text ([string]$mutant.find)
    $replace = Get-EolText $text ([string]$mutant.replace)
    $count = ([regex]::Matches($text, [regex]::Escape($find))).Count
    $runnerKey = if ($mutant.PSObject.Properties['command']) { ($mutant.command -join ' ') } else { [string]$mutant.testFile }
    $record = [ordered]@{
        id = [string]$mutant.id
        why = [string]$mutant.why
        measuredCommit = (git rev-parse --short HEAD)
        file = [string]$mutant.file
        find = [string]$mutant.find
        replace = [string]$mutant.replace
        parse = $null
        suiteExitCode = $null
        checkCount = $null
        failedCount = $null
        baselineCount = $baseline[$runnerKey]
        namedTest = [string]$mutant.test
        targetFailed = $false
        verdict = ''
        seconds = 0
        restored = $false
    }
    if ($count -ne 1) {
        $record.verdict = "NOT-APPLIED (find matched $count times)"
        [pscustomobject]$record
        continue
    }
    try {
        $bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        [IO.File]::WriteAllText($path, $text.Replace($find, $replace), [Text.UTF8Encoding]::new($bom))
        $record.parse = Test-Parse $path
        if (-not $record.parse) {
            $record.verdict = 'INVALID (does not parse)'
        } else {
            $run = Invoke-MutantTest $mutant
            $record.suiteExitCode = $run.exitCode
            $record.checkCount = $run.checkCount
            $record.failedCount = $run.failedCount
            $record.seconds = $run.seconds
            $record.targetFailed = [bool](@($run.failNames) | Where-Object { $_ -eq $mutant.test })
            if ($run.checkCount -ne $baseline[$runnerKey]) { $record.verdict = "LOAD-CHANGED ($($run.checkCount) of $($baseline[$runnerKey]))" }
            elseif ($record.targetFailed) { $record.verdict = 'CAUGHT' }
            elseif ($run.failedCount -gt 0) { $record.verdict = 'OTHER-TEST-FAILED' }
            else { $record.verdict = 'MISSED' }
        }
    } finally {
        [IO.File]::WriteAllBytes($path, $bytes)
        $record.restored = ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -eq $hash)
    }
    Write-Host ("{0,-36} {1,-18} {2,5} s" -f $record.id, $record.verdict, $record.seconds)
    [pscustomobject]$record
}

$ignoredDirty = @(
    'docs/measurements/p93-mutations.json',
    'tests/Measure-InstallerUiMutations.ps1',
    'tests/installer-ui-mutants.json'
)
$porcelain = @(git status --porcelain | Where-Object {
    $path = ($_ -replace '^.. ', '') -replace '\\', '/'
    $ignoredDirty -notcontains $path
})
[pscustomobject]@{
    schemaVersion = 2
    packet = 'P93'
    dateUtc = [DateTime]::UtcNow.ToString('o')
    measuredCommit = (git rev-parse --short HEAD)
    selector = 'pwsh -NoProfile -File .\tests\Measure-InstallerUiMutations.ps1'
    rule = 'caught = parses, baseline check count, and the named test fails'
    supersededEvidence = @(
        [pscustomobject]@{
            name = 'legacy P93 mutation entries with caught/checks only'
            reason = 'The older file recorded historical 17-check and 19-check summaries without exact find/replace text, exit code, failed count or target test. This run replaces them with auditable file-scoped measurements.'
        }
    )
    results = @($results)
    cleanTree = (-not $porcelain.Count)
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Out -Encoding utf8

Write-Host ("caught {0} of {1}; tree clean: {2}" -f @($results | Where-Object verdict -eq 'CAUGHT').Count, @($results).Count, (-not $porcelain.Count))
if (@($results | Where-Object verdict -ne 'CAUGHT').Count) { exit 1 }
