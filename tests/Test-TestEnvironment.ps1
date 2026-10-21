# P121: the staged test environment (ADR-0067). Offline: builds the Bicep and checks the script's guards.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$script:fail = 0
$script:count = 0
$expected = 24
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
Assert 'the resolver storage is reached through private endpoints, whatever a policy sets its public access to' (
    $configuration -match 'privateEndpointSubnetId: endpointsSubnetId' -and $configuration -match 'blobDnsZoneId: blobDnsZoneId')
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

# Behaviour, against a stand-in az that records each call (tests/test-environment-stub/az.ps1).
$stubDir = Join-Path $PSScriptRoot 'test-environment-stub'
$work = Join-Path ([IO.Path]::GetTempPath()) ('claude-testenv-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $work | Out-Null
$rg = 'rg-claude-test-x'
$prefix = 'tstub0001'
$g = @('11111111-1111-4111-8111-000000000001', '11111111-1111-4111-8111-000000000002', '11111111-1111-4111-8111-000000000003', '11111111-1111-4111-8111-000000000004')
$app = '22222222-2222-4222-8222-000000000001'
function Invoke-Stubbed([hashtable]$Fixture, [string[]]$Arguments) {
    $fixturePath = Join-Path $work ([guid]::NewGuid().ToString('N') + '.json')
    $logPath = Join-Path $work ([guid]::NewGuid().ToString('N') + '.log')
    [IO.File]::WriteAllText($fixturePath, ($Fixture | ConvertTo-Json -Depth 6))
    [IO.File]::WriteAllText($logPath, '')
    $saved = @{ PATH = $env:PATH; F = $env:STUB_AZ_FIXTURE; L = $env:STUB_AZ_LOG }
    $env:PATH = $stubDir + [IO.Path]::PathSeparator + $env:PATH; $env:STUB_AZ_FIXTURE = $fixturePath; $env:STUB_AZ_LOG = $logPath
    try { $out = & pwsh -NoProfile -File (Join-Path $root 'scripts\Deploy-ClaudeTestEnvironment.ps1') -SubscriptionId '00000000-0000-4000-8000-000000000001' -ResourceGroup $rg -NamePrefix $prefix -UseCurrentAzLogin @Arguments 2>&1 | Out-String; $code = $LASTEXITCODE }
    finally { $env:PATH = $saved.PATH; $env:STUB_AZ_FIXTURE = $saved.F; $env:STUB_AZ_LOG = $saved.L }
    [pscustomobject]@{ Code = $code; Out = $out; Calls = @(Get-Content $logPath) }
}
$mutating = '^(group create|group delete|tag update|ad group (create|delete|member)|ad app (create|delete|update)|ad sp create)'
$names = @{ $g[0] = "claude-test-$prefix-standard"; $g[1] = "claude-test-$prefix-premium"; $g[2] = "claude-test-$prefix-unit-a"; $g[3] = "claude-test-$prefix-unit-b" }
$owned = @{ 'claude-test-environment' = $prefix; 'claude-test-groups' = ($g -join ','); 'claude-test-resolver-app' = $app }

$r = Invoke-Stubbed @{ tags = @{ purpose = 'someone-else' } } @('-Phase', 'Identity')
Assert 'a resource group without the environment tag is refused with no Azure or Entra write' (
    $r.Code -ne 0 -and $r.Out -match 'was not created by Deploy-ClaudeTestEnvironment' -and -not @($r.Calls | Where-Object { $_ -match $mutating }).Count) ($r.Calls -join ' ; ')

$injected = $owned.Clone(); $injected['claude-test-groups'] = "x&calc,$($g[1]),$($g[2]),$($g[3])"
$r = Invoke-Stubbed @{ tags = $injected; groupNames = $names; appNames = @{ $app = "claude-test-resolver-$prefix" } } @('-Phase', 'Teardown')
Assert 'a tag value that is not an object id is refused before it reaches az' (
    $r.Code -ne 0 -and $r.Out -match 'not four object ids' -and -not @($r.Calls | Where-Object { $_ -match '&|delete' }).Count) ($r.Calls -join ' ; ')

$foreign = $names.Clone(); $foreign[$g[1]] = 'production-entitlement-group'
$r = Invoke-Stubbed @{ tags = $owned; groupNames = $foreign; appNames = @{ $app = "claude-test-resolver-$prefix" } } @('-Phase', 'Teardown')
$deleted = @($r.Calls | Where-Object { $_ -match '^ad group delete --group (\S+)' } | ForEach-Object { ($_ -split ' ')[4] })
Assert 'Teardown deletes only groups whose names it gave them, and keeps the resource group while one is left' (
    $r.Code -ne 0 -and $deleted.Count -eq 3 -and $deleted -notcontains $g[1] -and
    -not @($r.Calls | Where-Object { $_ -match '^group delete' }).Count -and $r.Out -match 'production-entitlement-group') ($r.Calls -join ' ; ')

$r = Invoke-Stubbed @{ tags = $owned; groupNames = $names; appNames = @{ $app = "claude-test-resolver-$prefix" } } @('-Phase', 'Teardown')
Assert 'Teardown of an intact environment deletes its four groups, its app, then its resource group' (
    $r.Code -eq 0 -and @($r.Calls | Where-Object { $_ -match '^ad group delete' }).Count -eq 4 -and
    @($r.Calls | Where-Object { $_ -match "^ad app delete --id $app" }).Count -eq 1 -and $r.Calls[-1] -match "^group delete -n $rg ") ($r.Calls -join ' ; ')
Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue

# The compiled templates, not the source text: each named value and module input is wired to what it must carry.
if ($bicepExe -and (Test-Path (Join-Path $root 'infra\test-environment\configuration.bicep'))) {
    $arm = & $bicepExe build (Join-Path $root 'infra\test-environment\configuration.bicep') --stdout 2>$null | ConvertFrom-Json -AsHashtable
    $nv = @($arm.resources | Where-Object { $_.type -eq 'Microsoft.ApiManagement/service/namedValues' })[0]
    $value = [string]$nv.properties.value
    $resolverOut = "reference\(resourceId\('Microsoft\.Resources/deployments', 'test-resolver'\), '[0-9-]+'\)\.outputs"
    Assert 'the compiled named values loop over every key and take the resolver outputs' (
        $nv.copy.count -eq "[length(variables('gatewayValueKeys'))]" -and @($arm.variables.gatewayValueKeys).Count -eq 6 -and
        $value -match "'entitlement-source', 'projection'" -and
        $value -match "'entitlement-resolver-url', $resolverOut\.resolverUrl\.value" -and
        $value -match "'entitlement-resolver-audience', $resolverOut\.resolverAudience\.value" -and
        $value -match "'bu-registry', parameters\('buRegistry'\)" -and $value.EndsWith("[variables('gatewayValueKeys')[copyIndex()]]]")) $value
    $rp = @($arm.resources | Where-Object { $_.name -eq 'test-resolver' })[0].properties.parameters
    Assert 'the compiled resolver gets all four storage endpoint inputs' (
        $rp.privateEndpointSubnetId.value -eq "[parameters('endpointsSubnetId')]" -and $rp.blobDnsZoneId.value -eq "[parameters('blobDnsZoneId')]" -and
        $rp.queueDnsZoneId.value -eq "[parameters('queueDnsZoneId')]" -and $rp.tableDnsZoneId.value -eq "[parameters('tableDnsZoneId')]")}
else {
    Assert 'the compiled named values loop over every key and take the resolver outputs' $false 'no bicep executable'
    Assert 'the compiled resolver gets all four storage endpoint inputs' $false 'no bicep executable'
}
Assert 'Test-All registers this suite' ($testAll -match "Invoke-Check\s+'[^']+'\s+'Test-TestEnvironment\.ps1'")

Write-Host ''
if ($script:count -ne $expected) { Write-Host "Expected $expected test-environment assertions, ran $($script:count)." -ForegroundColor Red; exit 1 }
if ($script:fail) { Write-Host "$($script:fail) of $($script:count) test-environment assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "$($script:count) test-environment assertion(s) passed." -ForegroundColor Green
exit 0
