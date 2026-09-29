# The real wizard crosses cmd.exe and a native az.cmd shim on PowerShell 5.1.
# Its Azure and HTTP responses are fixtures; no operator session is consulted.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestAzureFixture.ps1')
$ps51 = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path $ps51)) { throw 'Windows PowerShell 5.1 not found.' }
$root = Split-Path $PSScriptRoot -Parent
$script = Join-Path $root 'Install-ClaudeGateway.ps1'
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('wiz51-' + [guid]::NewGuid().ToString('N'))
$out = ''; $code = 1; $calls = ''; $unexpected = $true; $fail = 0
function Assert($Name, $Condition) {
    if ($Condition) { Write-Host "  [OK]   PS51: $Name" -ForegroundColor Green }
    else { Write-Host "  [FAIL] PS51: $Name" -ForegroundColor Red; $script:fail++ }
}
try {
    $driver = New-TestAzureFixture -Directory $scratch
    $answers = Join-Path $scratch 'answers.txt'
    [IO.File]::WriteAllText($answers, ("y`r`n" + ("`r`n" * 64)), [Text.Encoding]::ASCII)
    $command = "`"$ps51`" -NoProfile -File `"$driver`" -Script `"$script`" -Mode Wizard < `"$answers`" 2>&1"
    $out = & $env:ComSpec /d /c $command | Out-String
    $code = $LASTEXITCODE
    $log = Join-Path $scratch 'az.calls'
    if (Test-Path -LiteralPath $log) { $calls = [IO.File]::ReadAllText($log) }
    $unexpected = Test-Path -LiteralPath (Join-Path $scratch 'unexpected.calls')
}
catch { $out += "`nFixture failed: $($_.Exception.Message)"; $code = 1 }
finally {
    if (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force }
}
$out -split "`n" | ForEach-Object { $_.TrimEnd() }
Assert 'the wizard process exits successfully' ($code -eq 0)
Assert 'native discovery and the missing named value run without unregistered calls' (
    $calls -match '(?m)^cognitiveservices account deployment list .+--query \[\]\.name' -and
    $calls -match '(?m)^apim nv show .+--named-value-id entitlement-cache-seconds' -and -not $unexpected)
Assert 'the real summary and the WhatIf stop are both reached' (
    $out -match '(?m)^\s*Summary\s*$' -and $out -match 'WhatIf - stopping before any change')
Assert 'native quoting and error handling remain intact' ($out -notmatch 'unexpected at this time|NativeCommandError|CategoryInfo')
if ($fail) { Write-Host "$fail PS51 assertion(s) failed."; exit 1 }
Write-Host 'PASS - reached the summary under Windows PowerShell 5.1 with offline native fixtures.' -ForegroundColor Green
exit 0
