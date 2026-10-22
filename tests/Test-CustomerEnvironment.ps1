# P124: one command runs a production setup from the customer sheet (ADR-0070). Offline: the answers it writes pass
# the installer's validator, and -Phase All runs every phase in order against stand-in tools.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$script:fail = 0
$script:count = 0
$expected = 9
function Assert([string]$Label, [bool]$Condition, [string]$Detail = '') {
    $script:count++
    if ($Condition) { Write-Host "  [OK]   $Label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $Label$(if ($Detail) { " - $Detail" })" -ForegroundColor Red; $script:fail++ }
}
Write-Host ''
Write-Host 'P124 customer setup from one sheet' -ForegroundColor Cyan

$work = Join-Path ([IO.Path]::GetTempPath()) ('claude-customer-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $work | Out-Null
try {
    # The example sheet with real-looking values in place of its <placeholders>.
    $sheet = Get-Content -Raw (Join-Path $root 'config\customer-sheet.example.json') | ConvertFrom-Json
    $sub = '11111111-1111-4111-8111-111111111111'
    $vnet = "/subscriptions/$sub/resourceGroups/rg-network/providers/Microsoft.Network/virtualNetworks/vnet-claude"
    $dns = "/subscriptions/$sub/resourceGroups/rg-dns/providers/Microsoft.Network/privateDnsZones"
    $g = $sheet.gateway
    $g.tenantId = '22222222-2222-4222-8222-222222222222'; $g.subscriptionId = $sub; $g.resourceGroup = 'rg-claude-gateway'; $g.apimName = 'apim-claude-prod'
    $g.location = 'eastus2'; $g.publisherEmail = 'ops@contoso.example'; $g.foundryAccount = 'ai-claude'; $g.foundryResourceGroup = 'rg-foundry'
    $g.foundrySubscriptionId = '33333333-3333-4333-8333-333333333333'; $g.foundryEndpoint = 'https://ai-claude.services.ai.azure.com/'
    $g.foundryTenantId = '22222222-2222-4222-8222-222222222222'; $g.foundryClientId = '44444444-4444-4444-8444-444444444444'
    $g.compatibilityGroups.standard = 'LTM-Claude-Compat-Standard'; $g.compatibilityGroups.premium = 'LTM-Claude-Compat-Premium'
    $sheet.network.vnetId = $vnet
    foreach ($n in 'endpoints', 'runner', 'resolver', 'renewal', 'apim') { $sheet.network.subnets.$n = "$vnet/subnets/snet-$n" }
    $sheet.network.privateDnsZones.cosmos = "$dns/privatelink.documents.azure.com"; $sheet.network.privateDnsZones.sites = "$dns/privatelink.azurewebsites.net"
    $sheet.network.privateDnsZones.blob = "$dns/privatelink.blob.core.windows.net"; $sheet.network.privateDnsZones.queue = "$dns/privatelink.queue.core.windows.net"
    $sheet.network.privateDnsZones.table = "$dns/privatelink.table.core.windows.net"
    foreach ($grp in $sheet.groups) { $grp.objectId = '00000000-0000-4000-8000-{0:d12}' -f [int]$grp.row }
$sheet.projection.namePrefix = 'claudeprod'; $sheet.projection.alertEmail = @('ops@contoso.example')
    $sheetPath = Join-Path $work 'sheet.json'
    $sheet | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $sheetPath -Encoding utf8

    $onboarding = Join-Path $work 'onboarding'
    $out = & pwsh -NoProfile -File (Join-Path $root 'scripts\Deploy-ClaudeCustomerEnvironment.ps1') -SheetPath $sheetPath -Phase Plan -OnboardingDirectory $onboarding -OfflineGroups 2>&1 | Out-String
    $answersPath = Join-Path $onboarding 'answers.claudeprod.json'
    $answers = if (Test-Path $answersPath) { Get-Content -Raw $answersPath | ConvertFrom-Json } else { $null }
    Assert 'Plan writes answers that the installer validator accepts, and the catalog' ($LASTEXITCODE -eq 0 -and $answers -and
        $out -match "checked by the installer's validator" -and $out -match '11 tiers, 47 groups') $out.Trim()
    Assert 'the answers reuse the existing APIM, the client-credentials Foundry and the customer network' ($answers -and
        $answers.ExistingApimName -eq 'apim-claude-prod' -and $answers.FoundryAuthenticationMode -eq 'client-credentials' -and
        $answers.FoundrySubscriptionId -eq '33333333-3333-4333-8333-333333333333' -and $answers.ProjectionNetworkMode -eq 'existing' -and
        $answers.ProjectionRenewalSubnetId -eq "$vnet/subnets/snet-renewal" -and $answers.ProjectionTableDnsZoneId -eq "$dns/privatelink.table.core.windows.net")
    Assert 'the model allow-lists come from the profiles and the deployments: standard Haiku, Sonnet and Opus (Standard-L3 Ha-So-Op), premium adds Fable' ($answers -and
        (@($answers.StandardModels) -join ',') -eq 'claude-haiku-5-5,claude-sonnet-5-5,claude-opus-5-5' -and
        (@($answers.PremiumModels) -join ',') -eq 'claude-haiku-5-5,claude-sonnet-5-5,claude-opus-5-5,claude-fable-5-1')
    Assert 'the job deploys without a schedule; the Schedule phase sets the sheet interval' ($answers -and $answers.ProjectionSyncInterval -eq 'manual')

    $partial = $sheet | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $partial.network.subnets.renewal = '<vnetId>/subnets/<sync-job-subnet>'; $partial.gateway.apimName = ''
    $partialPath = Join-Path $work 'partial.json'; $partial | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $partialPath
    $out = & pwsh -NoProfile -File (Join-Path $root 'scripts\Deploy-ClaudeCustomerEnvironment.ps1') -SheetPath $partialPath -OnboardingDirectory (Join-Path $work 'o2') -OfflineGroups 2>&1 | Out-String
    Assert 'an incomplete sheet (a placeholder left, an empty APIM name) stops before anything runs' (
        $LASTEXITCODE -eq 2 -and $out -match 'gateway\.apimName is required' -and $out -match 'network\.subnets\.renewal is required' -and -not (Test-Path (Join-Path $work 'o2'))) $out.Trim()

    $mi = $sheet | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $mi.gateway.foundryAuthentication = 'managed-identity'
    $miPath = Join-Path $work 'mi.json'; $mi | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $miPath
    $out = & pwsh -NoProfile -File (Join-Path $root 'scripts\Deploy-ClaudeCustomerEnvironment.ps1') -SheetPath $miPath -Phase Plan -OnboardingDirectory (Join-Path $work 'o3') -OfflineGroups 2>&1 | Out-String
    Assert 'managed identity with Foundry in another subscription is refused, naming client-credentials' ($LASTEXITCODE -eq 2 -and $out -match 'client-credentials') $out.Trim()

    # -Phase All against stand-in tools that record their calls.
    $tools = Join-Path $work 'tools'; $log = Join-Path $work 'calls.log'
    New-Item -ItemType Directory -Force -Path (Join-Path $tools 'scripts') | Out-Null
    $stub = "param([Parameter(ValueFromRemainingArguments)]`$rest) Add-Content -Path '$log' -Value ('{0} {1}' -f (Split-Path `$PSCommandPath -Leaf), (`$rest -join ' ')); exit 0"
    foreach ($s in 'Install-ClaudeGateway.ps1', 'scripts\Set-ClaudeAccessCatalog.ps1', 'scripts\Set-ClaudePlanTokenQuotas.ps1', 'scripts\Sync-ClaudeAccess.ps1',
        'scripts\Grant-ClaudeProjectionRenewalGraphAccess.ps1', 'scripts\Set-ClaudeProjectionSyncSchedule.ps1') { Set-Content -LiteralPath (Join-Path $tools $s) -Value $stub }
    Copy-Item (Join-Path $root 'scripts\ConvertTo-ClaudeAccessCatalog.ps1') (Join-Path $tools 'scripts')
    $azDir = Join-Path $work 'az'; New-Item -ItemType Directory -Force -Path $azDir | Out-Null
    Set-Content -LiteralPath (Join-Path $azDir 'az.ps1') -Value @"
`$line = `$args -join ' '
Add-Content -Path '$log' -Value ('az ' + `$line)
if (`$line -match 'outputs\.identityPrincipalId') { '55555555-5555-4555-8555-555555555555'; exit 0 }
if (`$line -match 'outputs\.jobName') { 'caj-renew-test'; exit 0 }
if (`$line -match '^containerapp job start') { 'caj-renew-test-1'; exit 0 }
if (`$line -match '^containerapp job execution show') { 'Succeeded'; exit 0 }
exit 9
"@
    $savedPath = $env:PATH; $env:PATH = $azDir + [IO.Path]::PathSeparator + $env:PATH
    try { $out = & pwsh -NoProfile -File (Join-Path $root 'scripts\Deploy-ClaudeCustomerEnvironment.ps1') -SheetPath $sheetPath -OnboardingDirectory (Join-Path $work 'o4') -OfflineGroups -ToolRoot $tools 2>&1 | Out-String; $code = $LASTEXITCODE }
    finally { $env:PATH = $savedPath }
    $calls = @(Get-Content -LiteralPath $log -ErrorAction SilentlyContinue)
    $order = @($calls | Where-Object { $_ -notmatch '^az ' } | ForEach-Object { ($_ -split ' ')[0] })
    Assert 'one command, no phase named, runs every phase in order' ($code -eq 0 -and ($order -join ',') -eq
        'Install-ClaudeGateway.ps1,Install-ClaudeGateway.ps1,Set-ClaudeAccessCatalog.ps1,Set-ClaudePlanTokenQuotas.ps1,Sync-ClaudeAccess.ps1,Grant-ClaudeProjectionRenewalGraphAccess.ps1,Set-ClaudeProjectionSyncSchedule.ps1') (
        "$code | $($order -join ',') | $($out.Trim())")
    Assert 'preflight runs before the deployment, and the grant goes to the sync job identity' (
        $calls[0] -match '-Preflight' -and $calls[1] -match '-Yes' -and @($calls | Where-Object { $_ -match '^Grant-.*55555555-5555-4555-8555-555555555555' }).Count -eq 1) ($calls -join ' ; ')
    Assert 'the schedule is set to the sheet interval only after a proven job run' (
        @($calls | Where-Object { $_ -match '^Set-ClaudeProjectionSyncSchedule\.ps1 .*-Interval: 15m' }).Count -eq 1 -and
        [array]::IndexOf([string[]]$calls, @($calls | Where-Object { $_ -match '^az containerapp job execution show' })[0]) -lt
        [array]::IndexOf([string[]]$calls, @($calls | Where-Object { $_ -match '^Set-ClaudeProjectionSyncSchedule' })[0])) ($calls -join ' ; ')
}
finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host ''
if ($script:count -ne $expected) { Write-Host "Expected $expected customer-setup assertions, ran $($script:count)." -ForegroundColor Red; exit 1 }
if ($script:fail) { Write-Host "$($script:fail) of $($script:count) customer-setup assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "$($script:count) customer-setup assertion(s) passed." -ForegroundColor Green
exit 0
