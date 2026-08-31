# Runs the wizard under Windows PowerShell 5.1 specifically.
#
# The reported failure only reproduces on 5.1, because PowerShell 7 quotes
# arguments to .cmd shims differently. Development happened on 7, which is
# exactly why it shipped broken - so this check exists to stop that recurring.

$ps51 = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path $ps51)) { throw 'Windows PowerShell 5.1 not found.' }

$root = Split-Path $PSScriptRoot -Parent
$script = Join-Path $root 'Install-ClaudeGateway.ps1'

Write-Host ''
Write-Host 'Running the wizard under Windows PowerShell 5.1' -ForegroundColor Cyan
Write-Host "  $ps51" -ForegroundColor DarkGray
Write-Host ''

$answers = Join-Path $env:TEMP 'wiz51-answers.txt'
# y            use this subscription
# (blank)      resource group default
# (blank)      location default
# 3            create a new gateway rather than reusing one
# then blanks: SKU, name prefix, publisher email, five budgets, two groups
@'
y


3










'@ | Set-Content $answers -Encoding ASCII

$out = cmd /c "`"$ps51`" -NoProfile -File `"$script`" -WhatIf < `"$answers`" 2>&1" | Out-String
Remove-Item $answers -Force -ErrorAction SilentlyContinue

$out -split "`n" | ForEach-Object { $_.TrimEnd() }

Write-Host ''
Write-Host ('-' * 66) -ForegroundColor DarkGray
if ($out -match 'unexpected at this time') {
    Write-Host 'FAIL - the cmd.exe quoting bug is still present.' -ForegroundColor Red
    exit 1
}
elseif ($out -match 'NativeCommandError|CategoryInfo') {
    Write-Host 'FAIL - a native command error occurred under 5.1.' -ForegroundColor Red
    exit 1
}
elseif ($out -match 'Summary') {
    Write-Host 'PASS - reached the summary under Windows PowerShell 5.1.' -ForegroundColor Green
}
else {
    Write-Host 'INCONCLUSIVE - did not reach the summary; read the output above.' -ForegroundColor Yellow
    exit 1
}
Write-Host ''
