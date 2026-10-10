# Tier group names follow the gateway they were recorded for. Offline; no Azure calls.
# Measured 2026-09-27: a gateway installed with custom group names was synced from the
# tenant's default claude-code-* groups, because Sync-ClaudeAccess.ps1 and
# Compare-ClaudeEntitlement.ps1 defaulted to those names instead of the recorded ones.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$fail = 0
function Assert($label, $condition, $detail = '') {
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $label$(if ($detail) { " - $detail" })" -ForegroundColor Red; $script:fail++ }
}

Write-Host ''
Write-Host 'Tier groups - recorded per gateway' -ForegroundColor Cyan

$scratch = Join-Path ([IO.Path]::GetTempPath()) ('tier-groups-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Force -Path (Join-Path $scratch 'scripts'), (Join-Path $scratch 'onboarding') | Out-Null
    Copy-Item -LiteralPath (Join-Path $root 'scripts\Get-ClaudeGatewayTarget.ps1') -Destination (Join-Path $scratch 'scripts')
    @{ apimName = 'apim-p66x'; resourceGroup = 'rg-p66x'; standardGroup = 'grp-p66x-standard'; premiumGroup = 'grp-p66x-premium' } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $scratch 'onboarding\claude-gateway.json') -Encoding UTF8
    $target = Join-Path $scratch 'scripts\Get-ClaudeGatewayTarget.ps1'

    Assert 'the recorded standard group is returned for its own gateway' ((& $target StandardGroup -ForApimName apim-p66x) -eq 'grp-p66x-standard')
    Assert 'the recorded premium group is returned for its own gateway' ((& $target PremiumGroup -ForApimName apim-p66x) -eq 'grp-p66x-premium')
    Assert 'another gateway does not receive the recorded groups' ((& $target StandardGroup -ForApimName apim-other) -eq '' -and (& $target PremiumGroup -ForApimName apim-other) -eq '')
    Assert 'callers that name no gateway keep the recorded groups' ((& $target StandardGroup) -eq 'grp-p66x-standard')

    Copy-Item -LiteralPath (Join-Path $root 'scripts\ClaudeEntitlementGroups.ps1') -Destination (Join-Path $scratch 'scripts')
    . (Join-Path $scratch 'scripts\ClaudeEntitlementGroups.ps1')
    $standardId = '10000000-0000-4000-8000-000000000001'
    $premiumId = '10000000-0000-4000-8000-000000000002'
    $resolved = Resolve-ClaudeEntitlementGroupsForSync -ResourceGroup rg-p66x -ApimName apim-p66x `
        -GetNamedValue { param($Id) '' } `
        -FindGroup { param($Value) [pscustomobject]@{ id = $(if ($Value -eq 'grp-p66x-standard') { $standardId } elseif ($Value -eq 'grp-p66x-premium') { $premiumId } else { '' }) } }
    Assert 'Sync-ClaudeAccess resolver takes StandardGroup from the record for this gateway' ($resolved.Standard.Source -eq 'decision record' -and $resolved.Standard.Id -eq $standardId)
    Assert 'Sync-ClaudeAccess resolver takes PremiumGroup from the record for this gateway' ($resolved.Premium.Source -eq 'decision record' -and $resolved.Premium.Id -eq $premiumId)

    foreach ($script in 'Compare-ClaudeEntitlement.ps1') {
        $text = Get-Content -LiteralPath (Join-Path $root "scripts\$script") -Raw
        Assert "$script uses the shared entitlement-group resolver" ($text -match 'Resolve-ClaudeEntitlementGroupsForSync')
        Assert "$script lets the shared resolver read APIM entitlement-groups" ($text -match 'Get-ApimNamedValue')
        Assert "$script no longer hardcodes the default group as its parameter default" ($text -notmatch "(?m)^\s*\[string\]\`$StandardGroup = 'claude-code-standard'")
    }
}
finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail) { Write-Host "$fail assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'Tier group names follow their gateway.' -ForegroundColor Green
exit 0
