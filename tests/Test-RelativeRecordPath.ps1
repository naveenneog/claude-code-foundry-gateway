# P79: a decision record path given relative to PowerShell's current folder is read and written
# there, whatever the process's start directory. Found by the owner on 2026-09-28: from the
# repository root, `.\Update-ClaudeGateway.ps1` read C:\Users\<name>\onboarding\claude-gateway.json.
# The root shim's -RecordPath default was relative, and Read-ClaudeDecisionRecord read it with
# [IO.File]::ReadAllText, which resolves a relative path against the process's start directory;
# `cd` in PowerShell does not change it. Each case runs in a child process started in one folder
# (start) and moved to another (repo), on PowerShell 7 and Windows PowerShell 5.1.
param([switch]$Child, [string]$Case, [string]$Repo, [string]$Start)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$fail = 0
function Assert($Label, $Condition, $Detail = '') {
    if ($Condition) { Write-Host "  [OK]   $Label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $Label$(if ($Detail) { " - $Detail" })" -ForegroundColor Red; $script:fail++ }
}

if ($Child) {
    $out = [ordered]@{ case = $Case; ok = $false; detail = '' }
    try {
        switch ($Case) {
            'read' {
                Set-Location -LiteralPath $Repo
                . (Join-Path $Repo 'scripts\flow\FlowContract.ps1')
                $r = Read-ClaudeDecisionRecord -Path 'onboarding\claude-gateway.json'
                $out.ok = [string]$r.apimName -ceq 'apim-relative'
                $out.detail = "apimName=$([string]$r.apimName)"
            }
            'write' {
                Set-Location -LiteralPath $Repo
                . (Join-Path $Repo 'scripts\flow\FlowContract.ps1')
                Write-ClaudeDecisionRecord -Record ([pscustomobject]@{ schemaVersion = 2; apimName = 'written' }) -Path 'onboarding\written.json'
                $inRepo = Test-Path -LiteralPath (Join-Path $Repo 'onboarding\written.json')
                $inStart = Test-Path -LiteralPath (Join-Path $Start 'onboarding\written.json')
                $out.ok = $inRepo -and -not $inStart
                $out.detail = "in repo: $inRepo; in the start directory: $inStart"
            }
            'shim-here' {
                Set-Location -LiteralPath $Repo
                $result = & (Join-Path $Repo 'Update-ClaudeGateway.ps1') -DiscoveryPath 'onboarding\discovery.json' -WarningAction SilentlyContinue 6>$null | Select-Object -Last 1
                $out.ok = -not $result.MissingRecord -and [string]$result.Fingerprint -match '^[0-9a-f]{64}$'
                $out.detail = "missing=$($result.MissingRecord) fingerprint=$($result.Fingerprint)"
            }
            'shim-elsewhere' {
                Set-Location -LiteralPath $Start
                $result = & (Join-Path $Repo 'Update-ClaudeGateway.ps1') -DiscoveryPath (Join-Path $Repo 'onboarding\discovery.json') -WarningAction SilentlyContinue 6>$null | Select-Object -Last 1
                $out.ok = -not $result.MissingRecord -and [string]$result.Fingerprint -match '^[0-9a-f]{64}$'
                $out.detail = "missing=$($result.MissingRecord) fingerprint=$($result.Fingerprint)"
            }
        }
    }
    catch { $out.detail = 'error: ' + $_.Exception.Message }
    'P79JSON ' + ([pscustomobject]$out | ConvertTo-Json -Compress)
    exit 0
}

Write-Host ''
Write-Host 'Decision records - a relative path is PowerShell''s, not the process''s' -ForegroundColor Cyan
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('record-path-' + [guid]::NewGuid().ToString('N'))
$repo = Join-Path $scratch 'repo'
$start = Join-Path $scratch 'start'
try {
    New-Item -ItemType Directory -Path (Join-Path $repo 'onboarding'), $start -Force | Out-Null
    foreach ($d in 'scripts', 'infra', 'config') { Copy-Item -LiteralPath (Join-Path $root $d) -Destination $repo -Recurse }
    Copy-Item -LiteralPath (Join-Path $root 'Update-ClaudeGateway.ps1') -Destination $repo
    [ordered]@{ schemaVersion = 2; mode = 'gateway'; resourceGroup = 'rg-relative'; apimName = 'apim-relative'; gatewayUrl = 'https://apim-relative.azure-api.net/claude'; decisions = [ordered]@{}; history = @() } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $repo 'onboarding\claude-gateway.json') -Encoding UTF8
    @{ policyHash = ''; namedValues = @() } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $repo 'onboarding\discovery.json') -Encoding UTF8

    $shells = [ordered]@{ '7' = (Get-Process -Id $PID).Path }
    $ps51 = if ($env:SystemRoot) { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' } else { '' }
    if ($ps51 -and (Test-Path -LiteralPath $ps51)) { $shells['5.1'] = $ps51 }
    $labels = [ordered]@{
        'read'           = 'a relative record path is read from PowerShell''s folder'
        'write'          = 'a relative record path is written in PowerShell''s folder'
        'shim-here'      = 'the root Update-ClaudeGateway.ps1 run from the repository reads its record'
        'shim-elsewhere' = 'the root Update-ClaudeGateway.ps1 run from another folder reads the repository''s record'
    }
    foreach ($shell in $shells.Keys) {
        foreach ($case in $labels.Keys) {
            Remove-Item -LiteralPath (Join-Path $repo 'onboarding\written.json'), (Join-Path $start 'onboarding') -Recurse -Force -ErrorAction SilentlyContinue
            # The child starts in $start, so its process directory is $start whatever it does next.
            $psi = [Diagnostics.ProcessStartInfo]::new($shells[$shell])
            foreach ($a in @('-NoProfile', '-NonInteractive', '-File', $PSCommandPath, '-Child', '-Case', $case, '-Repo', $repo, '-Start', $start)) { $psi.ArgumentList.Add($a) }
            $psi.WorkingDirectory = $start
            $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
            $p = [Diagnostics.Process]::Start($psi)
            $stdout = $p.StandardOutput.ReadToEnd(); $stderr = $p.StandardError.ReadToEnd(); $p.WaitForExit()
            $line = @($stdout -split "`r?`n" | Where-Object { $_ -like 'P79JSON *' } | Select-Object -Last 1)
            $r = if ($line.Count) { $line[0].Substring(8) | ConvertFrom-Json } else { $null }
            $detail = if ($r) { $r.detail } else { ((@(($stdout + $stderr) -split "`r?`n" | Where-Object { $_.Trim() }) | Select-Object -Last 3) -join ' | ') }
            Assert "PowerShell ${shell}: $($labels[$case])" ($r -and $r.ok) $detail
        }
    }
}
finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail) { Write-Host "$fail check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'A relative record path means PowerShell''s current folder on both shells.' -ForegroundColor Green
exit 0
