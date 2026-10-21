# P121: the staged test environment (ADR-0067). Offline: builds the Bicep and checks the script's guards.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$script:fail = 0
$script:count = 0
$expected = 17
function Assert([string]$Label, [bool]$Condition, [string]$Detail = '') {
    $script:count++
    if ($Condition) { Write-Host "  [OK]   $Label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $Label$(if ($Detail) { " - $Detail" })" -ForegroundColor Red; $script:fail++ }
}
function Read-Text([string]$Relative) {
    $path = Join-Path $root $Relative
    if (Test-Path -LiteralPath $path) { [IO.File]::ReadAllText($path) } else { '' }
}

Write-Host ''
Write-Host 'P121 staged test environment' -ForegroundColor Cyan

$main = Read-Text 'infra\main.bicep'
$resources = Read-Text 'infra\test-environment\resources.bicep'
$configuration = Read-Text 'infra\test-environment\configuration.bicep'
$deploy = Read-Text 'scripts\Deploy-ClaudeTestEnvironment.ps1'
$testAll = Read-Text 'tests\Test-All.ps1'

Assert 'main.bicep takes the Foundry client secret as a secure parameter that defaults to empty' (
    $main -match "@secure\(\)\s*\r?\nparam foundryClientSecret string = ''")
Assert 'main.bicep writes the secret named value only in client-credentials mode with a secret' (
    $main -match "resource foundryClientSecretValue 'Microsoft\.ApiManagement/service/namedValues@2024-05-01' = if \(foundryAuthenticationMode == 'client-credentials' && !empty\(foundryClientSecret\)\)" -and
    $main -match 'name: foundryClientSecretNamedValue' -and $main -match 'secret: true')
$policy = [regex]::Match($main, "resource apiPolicy [^\n]*\n(?<body>.*?)\n\}", [Text.RegularExpressions.RegexOptions]::Singleline).Groups['body'].Value
Assert 'the API policy waits for the secret named value' ($policy -match 'foundryClientSecretValue')

Assert 'resources.bicep composes the gateway, projection, network and registry modules' (
    $resources -match "module gateway '\.\./main\.bicep'" -and $resources -match "module projection '\.\./projection\.bicep'" -and
    $resources -match "module network '\.\./projection-network\.bicep'" -and $resources -match "module registry '\.\./projection-registry\.bicep'")
Assert 'the gateway uses client credentials and a secure secret parameter' (
    $resources -match "foundryAuthenticationMode: 'client-credentials'" -and $resources -match "@secure\(\)\s*\r?\nparam foundryClientSecret string")
Assert 'the network has no runner; configuration deploys a public resolver whose only caller is the gateway identity' (
    $resources -match 'runnerEnabled: false' -and $configuration -match "module resolver '\.\./resolver\.bicep'" -and
    $configuration -match "inboundAccess: 'public'" -and
    $configuration -match 'allowedCallerAppIds: \[\s*gatewayAppId\s*\]' -and $configuration -match 'allowedCallerObjectIds: \[\s*gatewayPrincipalId\s*\]')
Assert 'configuration.bicep deploys the sync job module on the test cron' (
    $configuration -match "module syncJob '\.\./projection-renewal\.bicep'" -and
    $configuration -match "cronExpression: '\*/\$\{syncMinutes\} \* \* \* \*'" -and
    $configuration -match '@minValue\(5\)\s*\r?\n@maxValue\(30\)\s*\r?\nparam syncMinutes int = 5')
Assert 'the no-success alert reads 2 x the interval + 15 minutes' ($configuration -match 'noSuccessMinutes: 2 \* syncMinutes \+ 15')
Assert 'configuration points the gateway at the resolver and names the business units' (
    $configuration -match "'entitlement-source'" -and $configuration -match "'entitlement-resolver-url'" -and
    $configuration -match "'entitlement-resolver-audience'" -and $configuration -match "'bu-registry'" -and $configuration -match "'bu-parents'")

$bicep = Get-Command bicep -ErrorAction SilentlyContinue
$bicepExe = if ($bicep) { $bicep.Source } elseif ($env:AZURE_CONFIG_DIR -and (Test-Path (Join-Path $env:AZURE_CONFIG_DIR 'bin\bicep.exe'))) { Join-Path $env:AZURE_CONFIG_DIR 'bin\bicep.exe' } else { '' }
foreach ($file in 'resources', 'configuration') {
    $path = Join-Path $root "infra\test-environment\$file.bicep"
    if (-not $bicepExe) { Assert "$file.bicep builds" $false 'no bicep executable'; continue }
    if (-not (Test-Path $path)) { Assert "$file.bicep builds" $false 'missing'; continue }
    $errFile = [IO.Path]::GetTempFileName()
    $out = & $bicepExe build $path --stdout 2>$errFile | Out-String
    $err = [IO.File]::ReadAllText($errFile); Remove-Item $errFile
    Assert "$file.bicep builds" ($LASTEXITCODE -eq 0 -and $out.TrimStart().StartsWith('{')) (($err -split "`n" | Where-Object { $_ -match ': Error ' } | Select-Object -First 3) -join ' | ')
}

Assert 'the script names every stage in order' ($deploy -match "'Identity', 'Resources', 'Publish', 'Configure', 'Grant', 'Populate', 'Smoke'")
Assert 'the script refuses a resource group it did not create' ($deploy -match "claude-test-environment" -and $deploy -match 'was not created by Deploy-ClaudeTestEnvironment')
Assert 'the secret stays in memory: never written, printed or put on a command line' (
    $deploy -match '\$foundrySecret' -and $deploy -notmatch 'Write-\w+[^\n]*\$foundrySecret' -and
    $deploy -notmatch 'Set-Content[^\n]*\$foundrySecret' -and $deploy -notmatch '--parameters[^\n]*\$foundrySecret')

if ($deploy) {
    $out = & pwsh -NoProfile -File (Join-Path $root 'scripts\Deploy-ClaudeTestEnvironment.ps1') -SubscriptionId '00000000-0000-0000-0000-000000000000' -ResourceGroup 'rg-x' -SyncMinutes 4 -Phase Resources 2>&1 | Out-String
    Assert 'a sync interval under 5 minutes is refused before any Azure call' ($LASTEXITCODE -ne 0 -and $out -match 'SyncMinutes' -and $out -notmatch 'az ')
    $out = & pwsh -NoProfile -File (Join-Path $root 'scripts\Deploy-ClaudeTestEnvironment.ps1') -SubscriptionId 'not-a-guid' -ResourceGroup 'rg-x' -Phase Resources 2>&1 | Out-String
    Assert 'a subscription that is not a GUID is refused before any Azure call' ($LASTEXITCODE -ne 0 -and $out -match 'SubscriptionId')
}
else {
    Assert 'a sync interval under 5 minutes is refused before any Azure call' $false 'no script'
    Assert 'a subscription that is not a GUID is refused before any Azure call' $false 'no script'
}

Assert 'Test-All registers this suite' ($testAll -match "Invoke-Check\s+'[^']+'\s+'Test-TestEnvironment\.ps1'")

Write-Host ''
if ($script:count -ne $expected) { Write-Host "Expected $expected test-environment assertions, ran $($script:count)." -ForegroundColor Red; exit 1 }
if ($script:fail) { Write-Host "$($script:fail) of $($script:count) test-environment assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "$($script:count) test-environment assertion(s) passed." -ForegroundColor Green
exit 0
