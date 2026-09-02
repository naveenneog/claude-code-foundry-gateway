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

# A reused gateway usually already holds Cognitive Services User on Foundry,
# granted by whatever created it. Azure refuses a second assignment for the same
# principal, role and scope even under a different name, so redeploying without
# checking fails the whole deployment with RoleAssignmentExists.
#
# `what-if` does not catch it: the grant is a nested deployment at another
# scope, which comes back as Unsupported, so the plan looks clean.
Write-Host ''
Write-Host 'Role assignment collision check' -ForegroundColor Cyan

$expectedRg = $v2[0].resourceGroup
$apimOid = az apim show -g $expectedRg -n $expected --query identity.principalId -o tsv 2>$null

if (-not $apimOid) {
    Write-Host '  skipped - that instance has no managed identity' -ForegroundColor Yellow
}
else {
    # Queried by assignee across the subscription rather than by picking a
    # Foundry account and looking at its scope.
    #
    # The first version of this check took the first AIServices account it
    # found, which in a subscription with thirteen of them was not the one the
    # gateway is wired to. It reported "no existing assignment" for a gateway
    # that demonstrably had one - a green check that verified nothing.
    $held = @(az role assignment list --assignee $apimOid --all -o json 2>$null | ConvertFrom-Json |
              Where-Object { $_.roleDefinitionName -eq 'Cognitive Services User' })

    if ($held.Count) {
        Write-Host ("  [OK]   {0} already holds the role ({1} assignment(s)) - the installer must pass grantFoundryRole=false" -f $expected, $held.Count) -ForegroundColor Green
        # -WhatIf stops before the deployment step, so the detection does not
        # run in this pass. Assert the code path exists instead.
        $src = Get-Content $script -Raw
        if ($src -match 'grantFoundryRole' -and $src -match 'Cognitive Services User') {
            Write-Host '  [OK]   the installer checks before granting' -ForegroundColor Green
        } else {
            Write-Host '  [FAIL] the installer has no role-assignment check - a reuse deploy will fail' -ForegroundColor Red
            exit 1
        }
    }
    else {
        Write-Host '  [OK]   no existing assignment for this principal - the grant will run normally' -ForegroundColor Green
    }
}

Write-Host ''
Write-Host 'Reuse path works.' -ForegroundColor Green
Write-Host ''
exit 0
