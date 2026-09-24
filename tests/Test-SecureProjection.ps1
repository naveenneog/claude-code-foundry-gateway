# The secure projection: private network, a resolver only the gateway can call,
# a writer only the sync can use, and a migration whose comparison actually
# looks at the projection.
#
# Everything asserted here was deployed and exercised on 2026-09-23 against a
# Premium v2 gateway in Canada Central, a Cosmos account in East US 2 reached
# through a private endpoint in the same VNet, and a Flex Consumption resolver.
# Where a claim came from a measurement, the comment says what was measured.
#
# Offline. The live half is docs/SECURE-PROJECTION.md's walkthrough.

$root = Split-Path $PSScriptRoot -Parent
$fail = 0
function Assert($label, $condition, $detail = '') {
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $label$(if ($detail) { " - $detail" })" -ForegroundColor Red; $script:fail++ }
}

Write-Host ''
Write-Host 'Secure projection - the resolver only the gateway can call' -ForegroundColor Cyan

$rb = Get-Content (Join-Path $root 'infra/resolver.bicep') -Raw
# resolver/src/index.mjs does no authentication and says the template does.
# The template not existing was the gap that kept this path undeployable.
Assert 'the resolver template exists'            ([bool]$rb)
Assert 'the code relies on it by name'           ((Get-Content (Join-Path $root 'resolver/src/index.mjs') -Raw) -match 'infra/resolver\.bicep')
Assert 'every request must be authenticated'     ($rb -match 'requireAuthentication: true')
Assert 'an API answers 401, not a sign-in page'  ($rb -match "unauthenticatedClientAction: 'Return401'")
Assert 'callers are an explicit allow list'      ($rb -match '(?s)@minLength\(1\)\s*param allowedCallerAppIds array')
Assert 'checked on the application id'           ($rb -match 'allowedApplications: allowedCallerAppIds')
Assert 'and on the object id when given'         ($rb -match 'identities: allowedCallerObjectIds')
Assert 'tokens must be for the resolver itself'  ($rb -match "'api://\$\{resolverAppId\}'")
# Measured: with inboundAccess private there is no public endpoint at all.
Assert 'inbound can be private'                  ($rb -match "publicNetworkAccess: isPrivate \? 'Disabled' : 'Enabled'")
Assert 'through its own private endpoint'        ($rb -match "groupIds: \[\s*'sites'\s*\]")
Assert 'outbound goes through the VNet'          ($rb -match 'virtualNetworkSubnetId: integrationSubnetId')

Write-Host ''
Write-Host 'Secure projection - no key anywhere' -ForegroundColor Cyan

Assert 'storage takes no shared key'             ($rb -match 'allowSharedKeyAccess: false')
Assert 'the host reaches storage by identity'    ($rb -match "name: 'AzureWebJobsStorage__accountName'")
Assert 'the package is fetched by identity'      ($rb -match "type: 'SystemAssignedIdentity'")
Assert 'telemetry refuses unauthenticated senders' ($rb -match 'DisableLocalAuth: true')
Assert 'and the app authenticates to send it'    ($rb -match "value: 'Authorization=AAD'")
Assert 'no publishing by user name and password' (($rb -match "name: 'scm'") -and ($rb -match "name: 'ftp'") -and ($rb -match '(?s)basicPublishingCredentialsPolicies.*allow: false'))
Assert 'FTP is off'                              ($rb -match "ftpsState: 'Disabled'")
# Read only, one container. The writer is a different identity, so a
# compromised resolver cannot change who is entitled.
Assert 'the resolver can only read'              ($rb -match "cosmosDataReader = '00000000-0000-0000-0000-000000000001'")
Assert 'and only this container'                 ($rb -match "scope: '\$\{cosmos\.id\}/dbs/\$\{databaseName\}/colls/\$\{containerName\}'")
Assert 'no connection string is set anywhere'    (-not ($rb -match '(?i)AccountKey=|listKeys\('))

Write-Host ''
Write-Host 'Secure projection - the network' -ForegroundColor Cyan

$nb = Get-Content (Join-Path $root 'infra/projection-network.bicep') -Raw
# The enterprise case: the network team owns the VNet and hands over subnets.
Assert 'an existing VNet can be used'            ($nb -match "param vnetId string = ''")
Assert 'with the endpoint subnet it is given'    ($nb -match "param endpointsSubnetId string = ''")
Assert 'and the VNet is only created when absent' ($nb -match "var createVnet = empty\(vnetId\)")
# Learn, flex-consumption-how-to: Microsoft.App/environments, /27 minimum,
# no private endpoints in the same subnet.
Assert 'the resolver subnet has the Flex delegation' ($nb -match "serviceName: 'Microsoft.App/environments'")
Assert 'and is at least a /27'                    ($nb -match 'cidrSubnet\(vnetAddressPrefix, 26, ')
Assert 'the resolver endpoint zone is created'    ($nb -match "privatelink\.azurewebsites\.net")
Assert 'and linked to the VNet'                   ($nb -match '(?s)resource sitesLink.*virtualNetwork: \{\s*id: linkedVnetId')

Write-Host ''
Write-Host 'Secure projection - a missing record is a refusal, not an outage' -ForegroundColor Cyan

$pol = Get-Content (Join-Path $root 'infra/policy.xml') -Raw
# Measured 2026-09-23 before the fix: an identity with no record got 503,
# Retry-After 5 and "this is not a problem with your access". After it: 403
# permission_error, and the second call answered from cache in 567 ms.
Assert 'the resolver 404 has its own branch'      ($pol -match 'StatusCode == 404\)')
Assert 'it resolves to no tier'                   ($pol -match "\{'tier':'none','businessUnit':''\}")
Assert 'and is cached briefly'                    ($pol -match 'duration="@\(Math\.Min\(60, int\.Parse\("\{\{entitlement-cache-seconds\}\}"\)\)\)"')
Assert 'an unanswered lookup is still a 503'      ($pol -match 'entitlement service did not answer')

Write-Host ''
Write-Host 'Secure projection - the writer runs inside the network' -ForegroundColor Cyan

$sp = Get-Content (Join-Path $root 'scripts/Sync-ClaudeProjection.ps1') -Raw
Assert 'membership can be exported instead of written' ($sp -match '(?m)\[string\]\$ExportPath\s*$')
Assert 'an export needs no Cosmos token'          ($sp -match '(?s)if \(-not \$ExportPath\) \{\s*\$cosmosToken = az account get-access-token')
Assert 'and is written without a byte-order mark' ($sp -match 'UTF8Encoding\(\$false\)')
Assert 'the importer exists'                      (Test-Path (Join-Path $root 'sync/src/apply-projection.mjs'))
$ap = Get-Content (Join-Path $root 'sync/src/apply-projection.mjs') -Raw
Assert 'it validates a snapshot before writing'   ($ap -match 'validateSnapshot\(snap, \{ tenantId \}\)')
Assert 'a failed write is not reported as ok'     ($ap -match 'ok: !\(writes\.failed \|\| deletes\.failed\)')
Assert 'it tolerates a byte-order mark'           ($ap -match '\\uFEFF')
Assert 'it writes in bulk'                        ($ap -match 'executeBulkOperations')
Assert 'and can compare without writing'          ($ap -match "opt\('--compare'\)")

Write-Host ''
Write-Host 'Secure projection - both paths charge the same business unit' -ForegroundColor Cyan

# Measured: Sync-ClaudeAccess.ps1 wrote bu-members deepest-first with the first
# match winning; Sync-ClaudeProjection.ps1 applied units in the order given with
# the last match winning. Anyone in a team and its parent would have changed
# business unit at the flip with no entitlement difference to show for it.
Assert 'the projection reads the gateway registry' ($sp -match "Get-ApimNamedValue -ResourceGroup \`$ResourceGroup -ApimName \`$ApimName -Id 'bu-registry'")
Assert 'orders it as the named-value path does'   ($sp -match 'Sort-ClaudeBuByDepth \$registry -Parents \$parents')
Assert 'and the first match wins'                 ($sp -match 'if \(-not \$assigned\.ContainsKey\(\$m\.Oid\)\)')

# Measured: Sort-Object is not stable - 960 reorderings of equal items in 7.6
# and 1,011 in 5.1 on a 2,000-item sort, and a five-unit registry came back in
# a different order in 5.1. Run the real function on a registry large enough
# that an unstable sort cannot pass by luck.
. (Join-Path $root 'scripts/ClaudeBusinessUnit.ps1')
$units = 1..300 | ForEach-Object { [pscustomobject]@{ Id = "u$_"; Group = "g$_" } }
$parents = @{}; foreach ($i in 1..300) { if ($i % 3 -eq 0) { $parents["u$i"] = 'u1' } }
$sorted = @(Sort-ClaudeBuByDepth $units -Parents $parents | ForEach-Object { $_.Id })
$expected = @(@($units | Where-Object { $parents.ContainsKey($_.Id) }) + @($units | Where-Object { -not $parents.ContainsKey($_.Id) }) | ForEach-Object { $_.Id })
Assert 'units at one depth keep registry order'   (($sorted -join ',') -eq ($expected -join ',')) "first difference at $([Array]::IndexOf(@(for ($k = 0; $k -lt $sorted.Count; $k++) { $sorted[$k] -eq $expected[$k] }), $false))"

Write-Host ''
Write-Host 'Secure projection - the flip is checked against the projection' -ForegroundColor Cyan

$ce = Get-Content (Join-Path $root 'scripts/Compare-ClaudeEntitlement.ps1') -Raw
# The directory comparison says whether the lists are current. Only comparing
# the gateway with the records the resolver serves says who would gain or lose
# access at the flip.
Assert 'the gateway decisions can be exported'    ($ce -match '(?m)\[string\]\$ExportGatewayPath\s*$')
Assert 'with the business-unit map'               ($ce -match "named-value-id bu-members")
Assert 'the comparison names the outcomes'        ((Get-Content (Join-Path $root 'sync/src/plan.mjs') -Raw) -match "'would-lose-access'")

Write-Host ''
Write-Host 'Secure projection - getting work into the network' -ForegroundColor Cyan

$cr = Get-Content (Join-Path $root 'scripts/ClaudeRunner.ps1') -Raw
# Measured: exec URL-decodes its command ('+' became a space and split the
# argument) and refuses 5,000 characters or more with InvalidCommandLength.
Assert 'files travel as base64url'                ($cr -match "\.Replace\('\+', '-'\)\.Replace\('/', '_'\)")
Assert 'and are decoded as base64url'             ($cr -match "'base64url'\)")
Assert 'chunks fit under the exec limit'          ($cr -match '4990 - \$overhead')
Assert 'a failed chunk stops the copy'            ($cr -match 'InvalidCommandLength\|terminated with non-zero')
Assert 'and the result is checked by hash'        ($cr -match 'did not arrive intact')

Write-Host ''
Write-Host 'Secure projection - a redeploy keeps the network' -ForegroundColor Cyan

# Measured with ARM what-if, 2026-09-23: re-running the installer's create path
# against a gateway with outbound VNet integration predicted virtualNetworkType
# External -> None, the subnet deleted, publicNetworkAccess and customProperties
# removed and both portals Disabled -> Enabled. With the live values handed
# back, the same what-if predicted none of those changes.
$mb = Get-Content (Join-Path $root 'infra/main.bicep') -Raw
Assert 'the template states the VNet mode'        ($mb -match 'virtualNetworkType: apimVirtualNetworkType')
Assert 'and the subnet when there is one'         ($mb -match '(?s)empty\(apimSubnetId\) \? \{\} : \{\s*virtualNetworkConfiguration: \{\s*subnetResourceId: apimSubnetId')
Assert 'and public access'                        ($mb -match 'publicNetworkAccess: apimPublicNetworkAccess')
Assert 'and both portals'                         (($mb -match 'developerPortalStatus: apimDeveloperPortalStatus') -and ($mb -match 'legacyPortalStatus: apimLegacyPortalStatus'))
Assert 'and the protocol settings'                ($mb -match 'customProperties: apimCustomProperties')
$ins = Get-Content (Join-Path $root 'Install-ClaudeGateway.ps1') -Raw
Assert 'the installer reads them from the live gateway' ($ins -match 'api-version=2024-05-01" -Headers @\{ Authorization = "Bearer \$armToken" \}')
Assert 'and hands them back as a parameter file'  ($ins -match "\`$preserveArgs = @\('--parameters', ""@\`$preserveFile""\)")
Assert 'on the deployment itself'                 ($ins -match '(?s)az deployment group create.*@preserveArgs')
Assert 'and will not redeploy blind'              ($ins -match 'Refusing to redeploy a gateway whose network state could not be read')
# The revocation window is a security control: how long a removed developer
# keeps working. Measured: three consecutive re-runs each deployed
# entitlementCacheSeconds=3600, the prompt's default, whatever the gateway had.
Assert 'a re-run reads the revocation window back' ($ins -match '\$liveWindow = Invoke-AzOptional \{ az apim nv show -g \$ResourceGroup --service-name \$windowTarget --named-value-id entitlement-cache-seconds')
Assert 'and keeps it instead of the default'      ($ins -match '\$entitlementCacheSeconds = \$liveWindowSeconds')
Assert 'and says so'                              ($ins -match "Keeping this gateway's revocation window")
# Measured on Windows PowerShell 5.1: an az call for a gateway that does not
# exist yet raised NativeCommandError under 2>$null, and with
# ErrorActionPreference Stop the wizard ended before its summary.
Assert 'optional az calls cannot end the script on 5.1' ($ins -match "(?s)function Invoke-AzOptional.*\`$ErrorActionPreference = 'Continue'")
Assert 'the window lookup uses it'                ($ins -match '\$liveWindow = Invoke-AzOptional \{')
Assert 'and so does the network-state lookup'     ($ins -match '\$liveId = Invoke-AzOptional \{')

Write-Host ''
Write-Host 'Secure projection - the Deploy to Azure button deploys this' -ForegroundColor Cyan

# infra/azuredeploy.json was compiled once, in the first commit, and never
# again: the button deployed a gateway without the entitlement switch, business
# units or anything since. It must be what main.bicep compiles to now.
$shippedPath = Join-Path $root 'infra/azuredeploy.json'
$freshPath = Join-Path ([IO.Path]::GetTempPath()) "azuredeploy-check-$PID.json"
$null = az bicep build --file (Join-Path $root 'infra/main.bicep') --outfile $freshPath 2>&1
if (Test-Path $freshPath) {
    $strip = { param($p) $j = Get-Content $p -Raw | ConvertFrom-Json; $j.PSObject.Properties.Remove('metadata'); $j | ConvertTo-Json -Depth 64 -Compress }
    $same = (& $strip $shippedPath) -eq (& $strip $freshPath)
    Remove-Item $freshPath -ErrorAction SilentlyContinue
    Assert 'the button template is main.bicep, compiled now' $same 'run: az bicep build --file infra/main.bicep --outfile infra/azuredeploy.json'
}
else { Assert 'the button template can be checked' $false 'az bicep build produced nothing' }

Write-Host ''
Write-Host 'Secure projection - documented as deployed' -ForegroundColor Cyan

$doc = Get-Content (Join-Path $root 'docs/SECURE-PROJECTION.md') -Raw
Assert 'the deployment is documented'             ([bool]$doc)
Assert 'and linked from the README'               ((Get-Content (Join-Path $root 'README.md') -Raw) -match 'docs/SECURE-PROJECTION\.md')
Assert 'it names the Flex delegation'             ($doc -match '`Microsoft\.App/environments`')
Assert 'and the region capacity refusal'          ($doc -match 'high demand')
Assert 'and why storage needs three endpoints'    ($doc -match 'All three are needed')
Assert 'and what a capacity unit is'              ($doc -match '\*\*1 request and 1,000 tokens per minute\*\*')
Assert 'and the redeploy check'                   ($doc -match "--query virtualNetworkType")
Assert 'the cost matches the model'               ($doc -match '\*\*\$69\.09\*\*' -and $doc -match '\$65\.28')

$auth = Get-Content (Join-Path $root 'docs/AUTHENTICATION.md') -Raw
Assert 'the authentication types are documented'  ([bool]$auth)
Assert 'and linked from the README'               ((Get-Content (Join-Path $root 'README.md') -Raw) -match 'docs/AUTHENTICATION\.md')
Assert 'it says what a service principal token lasts' ($auth -match '\*\*1,445 minutes, about 24 hours\*\*')
Assert 'and that entitlement, not expiry, revokes' ($auth -match "\*\*The gateway's entitlement check, not token expiry\.\*\*")
Assert 'it marks what was not measured'           (([regex]::Matches($auth, '\| not measured \|')).Count -ge 2)
Assert 'and quotes the device code guidance'      ($auth -match 'unilateral block on device code flow')

Write-Host ''
Write-Host 'Secure projection - the sync rules, run' -ForegroundColor Cyan
& (Join-Path $PSScriptRoot 'Test-ProjectionPaging.ps1')
Assert 'multi-page Cosmos behavior holds' ($LASTEXITCODE -eq 0)
& (Join-Path $PSScriptRoot 'Test-ProjectionRules.ps1')
Assert 'projection freshness and miss-path rules hold' ($LASTEXITCODE -eq 0)

$syncDir = Join-Path $root 'sync'
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Assert 'node is available to run them' $false 'install Node to run the sync tests'
} elseif (-not (Test-Path (Join-Path $syncDir 'test'))) {
    Assert 'the sync tests are present' $false $syncDir
} else {
    Push-Location $syncDir
    $out = node --test --test-reporter=tap test/*.test.mjs 2>&1 | Out-String
    $code = $LASTEXITCODE
    Pop-Location
    $passed = if ($out -match '(?m)^# pass (\d+)') { [int]$Matches[1] } else { 0 }
    $failed = if ($out -match '(?m)^# fail (\d+)') { [int]$Matches[1] } else { -1 }
    Assert "node --test ran them ($passed passed)" ($code -eq 0 -and $failed -eq 0) (($out -split "`n" | Where-Object { $_ -match '^not ok' } | Select-Object -First 3) -join ' | ')
    Assert 'and there were tests to run' ($passed -gt 0)
}

Write-Host ''
if ($fail) { Write-Host "$fail assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'Secure projection contract holds.' -ForegroundColor Green
exit 0
