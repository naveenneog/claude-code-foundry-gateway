# P121: the staged test environment (ADR-0067). Offline: builds the Bicep and checks the script's guards.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$script:fail = 0
$script:count = 0
$expected = 33
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
# The smoke stage's multiple-group case, through the sync job's own code: a user in standard and premium, and in
# unit a and its team unit b, gets premium and unit b with parent unit a.
$configurationText = Read-Text 'infra\test-environment\configuration.bicep'
Assert 'the configure stage makes unit b a team under unit a' ($deploy -match "buParents = ',unit-b=unit-a,'")
Assert 'the smoke stage adds premium and unit b without leaving standard or unit a, then removes premium' (
    $deploy -match 'Set-Membership \$ids\.premium \$me \$true\n\s*Set-Membership \$ids\.unitB \$me \$true\n' -and
    $deploy -match "premium wins over standard after the scheduled run" -and
    $deploy -match "\`$_\.unit -eq 'unit-b' -and \`$_\.parent -eq 'unit-a'" -and
    $deploy -match "premium model refused again after the scheduled run")
$sync = ([Uri](Join-Path $root 'sync\src')).AbsoluteUri
$probe = @"
import { mergeMembership } from '$sync/plan.mjs';
import { parseBuRegistry, parseBuParents, sortUnitsByDepth } from '$sync/business-units.mjs';
import { unitAssignments, membershipLines } from '$sync/membership-lines.mjs';
const me = '33333333-3333-4333-8333-333333333333';
const registry = parseBuRegistry(',unit-a=11111111-1111-4111-8111-000000000003:100000000,unit-b=11111111-1111-4111-8111-000000000004:100000000,');
const parents = parseBuParents(',unit-b=unit-a,');
const units = sortUnitsByDepth(registry, parents).map((u) => ({ id: u.id, members: [{ oid: me }] }));
const { records } = mergeMembership({ tiers: { standard: [{ oid: me }], premium: [{ oid: me }] }, businessUnits: units });
const [line] = membershipLines({ runId: 'r', at: 'now', records: unitAssignments(units), parents }).map((l) => JSON.parse(l));
console.log(JSON.stringify({ tier: records[0].tier, unit: records[0].businessUnit, row: line.rows[0] }));
"@
$probeOut = & node --input-type=module -e $probe 2>&1 | Out-String
$probeJson = try { $probeOut | ConvertFrom-Json } catch { $null }
Assert 'the sync code gives premium and the deeper unit b, with parent unit a, to a user in all four groups' (
    $probeJson -and $probeJson.tier -eq 'premium' -and $probeJson.unit -eq 'unit-b' -and
    ($probeJson.row -join ',') -eq '33333333-3333-4333-8333-333333333333,unit-b,unit-a') $probeOut.Trim()
# Customer networking: the installer's contract (all five subnets, optional linked DNS zones) and its preflight.
$sub = '00000000-0000-4000-8000-000000000001'
$vnet = "/subscriptions/$sub/resourceGroups/rg-network/providers/Microsoft.Network/virtualNetworks/vnet-customer"
$sn = [ordered]@{ Endpoints = "$vnet/subnets/pe"; Runner = "$vnet/subnets/runner"; Resolver = "$vnet/subnets/resolver"; Renewal = "$vnet/subnets/renewal"; Apim = "$vnet/subnets/apim" }
$nsg = "/subscriptions/$sub/resourceGroups/rg-network/providers/Microsoft.Network/networkSecurityGroups/nsg-apim"
$networkArgs = @('-ProjectionVnetId', $vnet, '-ProjectionEndpointsSubnetId', $sn.Endpoints, '-ProjectionRunnerSubnetId', $sn.Runner,
    '-ProjectionResolverSubnetId', $sn.Resolver, '-ProjectionRenewalSubnetId', $sn.Renewal, '-ProjectionApimSubnetId', $sn.Apim)
function New-Subnet([string]$Id, [string]$Delegation, [string]$Prefix, [string]$Nsg = '') {
    $props = @{ addressPrefix = $Prefix; privateEndpointNetworkPolicies = 'Disabled'; delegations = @(if ($Delegation) { @{ properties = @{ serviceName = $Delegation } } }) }
    if ($Nsg) { $props.networkSecurityGroup = @{ id = $Nsg } }
    @{ id = $Id; properties = $props }
}
$networkResources = @{
    $vnet = @{ id = $vnet; location = 'eastus2' }
    $sn.Endpoints = New-Subnet $sn.Endpoints '' '10.20.1.0/24'
    $sn.Runner = New-Subnet $sn.Runner 'Microsoft.ContainerInstance/containerGroups' '10.20.2.0/24'
    $sn.Resolver = New-Subnet $sn.Resolver 'Microsoft.App/environments' '10.20.3.0/26'
    $sn.Renewal = New-Subnet $sn.Renewal 'Microsoft.App/environments' '10.20.4.0/27'
    $sn.Apim = New-Subnet $sn.Apim 'Microsoft.Web/serverFarms' '10.20.5.0/24' $nsg
    $nsg = @{ id = $nsg; properties = @{ securityRules = @(@{ properties = @{ direction = 'Outbound'; access = 'Allow'; protocol = 'Tcp'; destinationAddressPrefix = 'AzureKeyVault'; destinationPortRange = '443' } }) } }
}
$foundryArgs = @('-PublisherEmail', 'ops@example.invalid', '-FoundryAccountName', 'ai-x', '-FoundryEndpoint', 'https://ai-x.services.ai.azure.com/',
    '-FoundryTenantId', '00000000-0000-4000-8000-0000000000cc', '-FoundryClientId', '00000000-0000-4000-8000-0000000000dd',
    '-FoundrySecretSourceApim', "/subscriptions/$sub/resourceGroups/rg-src/providers/Microsoft.ApiManagement/service/apim-src")

$r = Invoke-Stubbed @{ tags = $owned } (@('-Phase', 'Resources', '-ProjectionVnetId', $vnet, '-ProjectionEndpointsSubnetId', $sn.Endpoints) + $foundryArgs)
Assert 'a customer VNet without all five subnet ids is refused before any Azure call' (
    $r.Code -eq 2 -and $r.Out -match 'requires explicit IDs for: RunnerSubnetId, ResolverSubnetId, RenewalSubnetId, ApimSubnetId' -and -not $r.Calls.Count) ($r.Out.Trim())
$r = Invoke-Stubbed @{ tags = $owned } (@('-Phase', 'Resources') + $networkArgs + @('-ProjectionCosmosDnsZoneId', "/subscriptions/$sub/resourceGroups/rg-dns/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net") + $foundryArgs)
Assert 'a DNS zone id for the wrong namespace is refused before any Azure call' ($r.Code -eq 2 -and $r.Out -match 'CosmosDnsZoneId must be the complete resource ID of privatelink.documents.azure.com' -and -not $r.Calls.Count) ($r.Out.Trim())
$other = $networkArgs | ForEach-Object { $_ -replace '00000000-0000-4000-8000-000000000001', '00000000-0000-4000-8000-000000000009' }
$r = Invoke-Stubbed @{ tags = $owned } (@('-Phase', 'Resources') + $other + $foundryArgs)
Assert 'a customer VNet in another subscription is refused before any Azure call' ($r.Code -eq 2 -and $r.Out -match 'must be in -SubscriptionId' -and -not $r.Calls.Count) ($r.Out.Trim())

$broken = $networkResources.Clone(); $broken[$sn.Renewal] = New-Subnet $sn.Renewal '' '10.20.4.0/27'
$r = Invoke-Stubbed @{ tags = $owned; resources = $broken } (@('-Phase', 'Resources') + $networkArgs + $foundryArgs)
Assert 'an undelegated renewal subnet stops Resources before the Foundry secret is read or anything is deployed' (
    $r.Code -ne 0 -and $r.Out -match 'Renewal subnet must be delegated only to Microsoft.App/environments' -and
    -not @($r.Calls | Where-Object { $_ -match '^(rest|bicep)' }).Count) (($r.Calls -join ' ; ') + ' | ' + $r.Out.Trim())
$r = Invoke-Stubbed @{ tags = $owned; resources = $networkResources } (@('-Phase', 'Resources') + $networkArgs + $foundryArgs)
$firstRest = [array]::FindIndex([string[]]$r.Calls, [Predicate[string]]{ param($c) $c -match '^rest ' })
$lastShow = [array]::FindLastIndex([string[]]$r.Calls, [Predicate[string]]{ param($c) $c -match '^resource show' })
Assert 'a valid customer network passes the installer preflight, and only then is the secret read' (
    $r.Out -match 'customer network passed the installer preflight' -and $lastShow -ge 0 -and $firstRest -gt $lastShow) (($r.Calls -join ' ; ') + ' | ' + $r.Out.Trim())

if ($bicepExe) {
    $armResources = & $bicepExe build (Join-Path $root 'infra\test-environment\resources.bicep') --stdout 2>$null | ConvertFrom-Json -AsHashtable
    $np = @($armResources.resources | Where-Object { $_.name -eq 'test-projection-network' })[0].properties.parameters
    $wired = @('vnetId', 'endpointsSubnetId', 'runnerSubnetId', 'resolverSubnetId', 'renewalSubnetId', 'apimSubnetId',
        'cosmosDnsZoneId', 'sitesDnsZoneId', 'blobDnsZoneId', 'queueDnsZoneId', 'tableDnsZoneId') | Where-Object { $np[$_].value -ne "[parameters('$_')]" }
    Assert 'the compiled resources stage passes every customer network id to the network module' (-not $wired.Count) ($wired -join ', ')
}
else { Assert 'the compiled resources stage passes every customer network id to the network module' $false 'no bicep executable' }
Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
Assert 'Test-All registers this suite' ($testAll -match "Invoke-Check\s+'[^']+'\s+'Test-TestEnvironment\.ps1'")

Write-Host ''
if ($script:count -ne $expected) { Write-Host "Expected $expected test-environment assertions, ran $($script:count)." -ForegroundColor Red; exit 1 }
if ($script:fail) { Write-Host "$($script:fail) of $($script:count) test-environment assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "$($script:count) test-environment assertion(s) passed." -ForegroundColor Green
exit 0
