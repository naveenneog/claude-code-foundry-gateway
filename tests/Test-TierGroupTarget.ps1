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

    foreach ($script in 'Sync-ClaudeAccess.ps1', 'Compare-ClaudeEntitlement.ps1') {
        $text = Get-Content -LiteralPath (Join-Path $root "scripts\$script") -Raw
        foreach ($field in 'StandardGroup', 'PremiumGroup') {
            $call = "(?m)^\s*if \(-not \`$$field\) \{ \`$$field = \[string\]\(& \(Join-Path \`$PSScriptRoot 'Get-ClaudeGatewayTarget\.ps1'\) $field -ForApimName \`$ApimName 3>\`$null\) \}"
            Assert "$script takes $field from the record for this gateway" ($text -match $call)
        }
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
