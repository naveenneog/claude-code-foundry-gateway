# Drives the wizard down the reuse branch.
#
# Reuse exists because every earlier run generated a random name prefix and so
# always built a new API Management instance - roughly $250/month each. That is
# how a duplicate gateway appeared in the test tenant.
#
# Two things have to hold, and both have been wrong at some point:
#   - the summary must say it is reusing, not creating
#   - it must adopt the existing instance's resource group, SKU and location,
#     because the API and named values are parented to it
#
# Needs a signed-in az and at least one v2 API Management instance.

$root = Split-Path $PSScriptRoot -Parent
$script = Join-Path $root 'Install-ClaudeGateway.ps1'

$apims = az apim list -o json 2>$null | ConvertFrom-Json
$v2 = @($apims | Where-Object { $_.sku.name -match 'V2$' })

Write-Host ''
Write-Host 'Wizard - reuse an existing v2 API Management instance' -ForegroundColor Cyan
Write-Host ''

if (-not $v2.Count) {
    Write-Host '  skipped - no v2 API Management instance in this subscription' -ForegroundColor Yellow
    Write-Host ''
    exit 0
}

$expected = $v2[0].name
Write-Host ("  expecting it to reuse: {0} ({1}, {2})" -f $expected, $v2[0].sku.name, $v2[0].resourceGroup) -ForegroundColor DarkGray

$answers = Join-Path $env:TEMP 'wiz-reuse-answers.txt'
# y        use this subscription
# (blank)  resource group default
# (blank)  location default
# 1        reuse the first instance offered
# then blanks for the five budgets and two group names. SKU, name prefix and
# publisher email are not asked when reusing - they come from the instance.
@'
y


1








'@ | Set-Content $answers -Encoding ASCII

$out = cmd /c "powershell -NoProfile -File `"$script`" -WhatIf < `"$answers`" 2>&1" | Out-String
Remove-Item $answers -Force -ErrorAction SilentlyContinue

$fail = 0
function Assert($label, $condition) {
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $label" -ForegroundColor Red; $script:fail++ }
}

Write-Host ''
Assert 'offered the reuse menu'          ($out -match 'Existing v2 API Management')
Assert "picked $expected"                ($out -match [regex]::Escape("reusing $expected"))
Assert 'summary says REUSING'            ($out -match 'REUSING - not creating')
Assert 'summary names that instance'     ($out -match [regex]::Escape($expected))
Assert 'did not fall back to a new name' ($out -notmatch 'apim-claudegw\d{6}')
Assert 'no cmd.exe quoting error'        ($out -notmatch 'unexpected at this time')

if ($fail) {
    Write-Host ''
    Write-Host '--- output ---' -ForegroundColor DarkGray
    $out -split "`n" | ForEach-Object { $_.TrimEnd() }
    Write-Host ''
    Write-Host "$fail assertion(s) failed." -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host 'Reuse path works.' -ForegroundColor Green
Write-Host ''
exit 0
