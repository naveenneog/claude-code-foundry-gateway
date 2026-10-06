<#
.SYNOPSIS
    Deploys, populates and compare-gates the entitlement projection.

.DESCRIPTION
    One idempotent command for P61. It deploys a private Cosmos projection,
    creates the private network endpoints that the resolver needs to reach it,
    deploys the resolver with SKU-valid inbound access, exports the gateway's
    current named-value decisions, populates the projection from Entra, compares
    the resolver records against those decisions, and leaves named values
    authoritative. With -FlipAfterCleanCompare it deploys, publishes and applies
    nothing: it runs Invoke-ClaudeProjectionSwitch (ADR-0050) with the projection
    prefix and switch evidence. PreflightOnly
    runs the checks alone.

    BasicV2 must use a public resolver endpoint because Basic v2 has no
    outbound VNet integration. The public endpoint is not anonymous: App Service
    Authentication requires a token for the resolver audience, from the tenant,
    issued to the gateway managed identity. Cosmos stays private in every shape.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)][string]$ResourceGroup,
    [Parameter(Mandatory = $true)][string]$ApimName,
    [Parameter(Mandatory = $true)][string]$NamePrefix,
    [string]$SubscriptionId,
    [string]$Location,
    [ValidateSet('BasicV2','StandardV2','PremiumV2')]
    [string]$Sku = 'BasicV2',
    [ValidateSet('private','public')]
    [string]$ResolverInboundAccess,
    [string]$ResolverAppId,
    [string]$StandardGroup = 'claude-code-standard',
    [string]$PremiumGroup = 'claude-code-premium',
    [switch]$FlipAfterCleanCompare,
    [switch]$PreflightOnly,
    [ValidateSet('Auto','Snapshot')][string]$CompareBaseline = 'Auto',
    [switch]$ResolverPublicByDefault,
    [ValidateRange(1,10)][int]$RetryCount = 3,
    [ValidateRange(5,120)][int]$RetryDelaySeconds = 15
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'ApimNamedValue.ps1')
. (Join-Path $PSScriptRoot 'ClaudeRunner.ps1')
. (Join-Path $PSScriptRoot 'ClaudeProjectionChecks.ps1')
. (Join-Path $PSScriptRoot 'ClaudeProjectionPackage.ps1')
. (Join-Path $PSScriptRoot 'ClaudeProjectionSwitch.ps1')
function Step($m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Note($m) { Write-Host "    $m" -ForegroundColor DarkGray }
function Ok($m) { Write-Host "    [OK]   $m" -ForegroundColor Green }

function Invoke-WithRetry {
    param([Parameter(Mandatory)][scriptblock]$Action, [string]$Name)
    for ($i = 1; $i -le $RetryCount; $i++) {
        try { return & $Action }
        catch {
            if ($i -ge $RetryCount) { throw }
            Write-Warning "$Name failed on attempt $i/${RetryCount}: $($_.Exception.Message) Retrying in $RetryDelaySeconds s."
            Start-Sleep -Seconds $RetryDelaySeconds
        }
    }
}

function Get-DeploymentOutput {
    param([Parameter(Mandatory)][string]$DeploymentName)
    $obj = Invoke-ClaudeNetworkAz @('deployment','group','show','-g',$ResourceGroup,'-n',$DeploymentName,'--query','properties.outputs')
    if (-not $obj) { throw "Deployment $DeploymentName returned no outputs." }
    $out = @{}
    foreach ($p in $obj.PSObject.Properties) { $out[$p.Name] = $p.Value.value }
    return $out
}

if (-not $ResolverInboundAccess) {
    $ResolverInboundAccess = switch ($Sku) {
        'BasicV2' { 'public' }
        'StandardV2' { 'private' }
        'PremiumV2' { 'private' }
    }
}
if ($FlipAfterCleanCompare) {
    $null = Invoke-ClaudeProjectionSwitch -ResourceGroup $ResourceGroup -ApimName $ApimName -NamePrefix $NamePrefix -StandardGroup $StandardGroup -PremiumGroup $PremiumGroup -CompareBaseline $CompareBaseline
    return
}
$preflight = Invoke-ClaudeProjectionPreflight -ResourceGroup $ResourceGroup -ApimName $ApimName -NamePrefix $NamePrefix `
    -SubscriptionId $SubscriptionId -Location $Location -Sku $Sku -ResolverInboundAccess $ResolverInboundAccess `
    -ResolverAppId $ResolverAppId -StandardGroup $StandardGroup -PremiumGroup $PremiumGroup
# Before any write, and for -PreflightOnly and -WhatIf too: on a gateway that serves from the projection, this run
# continues only when it redeploys the resolver the gateway calls, with the app its tokens are for.
Assert-ClaudeProjectionResolverRedeploy -ResourceGroup $ResourceGroup -ApimName $ApimName -NamePrefix $NamePrefix -SubscriptionId ([string]$preflight.SubscriptionId) -ResolverAppId ([string]$preflight.ResolverAppId)
if ($PreflightOnly) { return }
if ($WhatIfPreference) {
    Note 'WhatIf: app registration if needed; private Cosmos/network; resolver publish; gateway resolver named values; fresh snapshot/apply/compare. No Azure writes or projection switch.'
    return
}
$Location = $preflight.Location
$ResolverAppId = $preflight.ResolverAppId
if ($Sku -in @('StandardV2','PremiumV2') -and $ResolverInboundAccess -ne 'private') {
    $reason = if ($ResolverPublicByDefault) { 'the ADR-0052 installer default selected public resolver access' } else { 'public resolver access was selected for this deployment' }
    Write-Warning "$Sku can use a private resolver; $reason."
}

$apim = $preflight.Apim
$gatewayObjectId = [string]$apim.identity.principalId
$gatewayAppId = $preflight.GatewayAppId

if (-not $ResolverAppId) {
    if ($PSCmdlet.ShouldProcess("claude-projection-resolver-$NamePrefix", 'create resolver app registration')) {
        $ResolverAppId = New-ClaudeProjectionResolverApp -NamePrefix $NamePrefix
    } else { throw 'Resolver registration was declined; no further steps run.' }
}
if (-not $ResolverAppId) { throw 'Resolver app registration was not created or selected. No projection deployment was attempted.' }

Step 'Deploy private Cosmos projection'
$projectionName = "projection-$NamePrefix"
if ($PSCmdlet.ShouldProcess($projectionName, 'deploy projection.bicep with networkAccess=private-only')) {
    Invoke-WithRetry -Name 'projection deployment' -Action {
        az deployment group create -g $ResourceGroup -n $projectionName --template-file (Join-Path $root 'infra/projection.bicep') `
            --parameters namePrefix=$NamePrefix location=$Location networkAccess='private-only' -o none
        if ($LASTEXITCODE -ne 0) { throw 'projection deployment failed' }
    }
} else { throw 'Projection deployment was declined; no further steps run.' }
$projection = Get-DeploymentOutput $projectionName
$cosmosAccount = if ($projection.accountName) { $projection.accountName } else { "cosmos-$NamePrefix" }
$accountResourceId = "/subscriptions/$(([string]$apim.id -split '/')[2])/resourceGroups/$ResourceGroup/providers/Microsoft.DocumentDB/databaseAccounts/$cosmosAccount"

Step 'Deploy projection network'
$networkName = "projection-network-$NamePrefix"
if ($PSCmdlet.ShouldProcess($networkName, 'deploy private endpoints and DNS')) {
    Invoke-WithRetry -Name 'projection network deployment' -Action {
        az deployment group create -g $ResourceGroup -n $networkName --template-file (Join-Path $root 'infra/projection-network.bicep') `
            --parameters namePrefix=$NamePrefix location=$Location cosmosAccountName=$cosmosAccount runnerEnabled=true -o none
        if ($LASTEXITCODE -ne 0) { throw 'projection network deployment failed' }
    }
} else { throw 'Projection network deployment was declined; no further steps run.' }
$network = Get-DeploymentOutput $networkName

Step 'Deploy resolver'
$resolverName = "projection-resolver-$NamePrefix"
if ($PSCmdlet.ShouldProcess($resolverName, "deploy resolver.bicep inboundAccess=$ResolverInboundAccess")) {
    $resolverParamFile = Join-Path ([IO.Path]::GetTempPath()) ("claude-resolver-params-" + [guid]::NewGuid().ToString('N') + '.json')
    $resolverParams = @{
        '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters = @{
            namePrefix = @{ value = $NamePrefix }
            location = @{ value = $Location }
            cosmosAccountName = @{ value = $cosmosAccount }
            integrationSubnetId = @{ value = $network.resolverSubnetId }
            privateEndpointSubnetId = @{ value = $network.endpointsSubnetId }
            sitesDnsZoneId = @{ value = $network.sitesDnsZoneId }
            blobDnsZoneId = @{ value = $network.blobDnsZoneId }
            queueDnsZoneId = @{ value = $network.queueDnsZoneId }
            tableDnsZoneId = @{ value = $network.tableDnsZoneId }
            resolverAppId = @{ value = $ResolverAppId }
            allowedCallerAppIds = @{ value = @($gatewayAppId) }
            allowedCallerObjectIds = @{ value = @($gatewayObjectId) }
            inboundAccess = @{ value = $ResolverInboundAccess }
        }
    }
    [IO.File]::WriteAllText($resolverParamFile, ($resolverParams | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
    try {
        Invoke-WithRetry -Name 'resolver deployment' -Action {
            az deployment group create -g $ResourceGroup -n $resolverName --template-file (Join-Path $root 'infra/resolver.bicep') `
                --parameters "@$resolverParamFile" -o none
            if ($LASTEXITCODE -ne 0) { throw 'resolver deployment failed' }
        }
    } finally { Remove-Item -LiteralPath $resolverParamFile -Force }
} else { throw 'Resolver deployment was declined; no further steps run.' }
$resolver = Get-DeploymentOutput $resolverName
$resolverUrl = [string]$resolver.resolverUrl
$resolverAudience = [string]$resolver.resolverAudience
if (-not $resolverUrl -or -not $resolverAudience) { throw 'Resolver deployment did not return resolverUrl and resolverAudience outputs.' }

Step 'Publish resolver code'
if ($PSCmdlet.ShouldProcess($resolver.siteName, 'package and publish resolver code')) {
    $stage = Join-Path ([IO.Path]::GetTempPath()) ("claude-resolver-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    try {
        Copy-Item (Join-Path $root 'resolver/host.json'), (Join-Path $root 'resolver/package.json') $stage
        Copy-Item (Join-Path $root 'resolver/src') $stage -Recurse
        Push-Location $stage
        try {
            npm install --omit=dev --no-audit --fund=false
            if ($LASTEXITCODE -ne 0) { throw 'resolver dependency installation failed' }
            tar -a -c -f resolver.zip host.json package.json src node_modules
            if ($LASTEXITCODE -ne 0) { throw 'resolver ZIP creation failed' }
            az functionapp deployment source config-zip -g $ResourceGroup -n $($resolver.siteName) --src resolver.zip -o none
            if ($LASTEXITCODE -ne 0) { throw 'resolver publish failed' }
        } finally { Pop-Location }
    }
    finally {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
} else { throw 'Resolver publication was declined; no further steps run.' }

Step 'Point the gateway at the resolver'
Confirm-ClaudeProjectionResolverServicePrincipal -AppId $ResolverAppId | Out-Null
if ($PSCmdlet.ShouldProcess($ApimName, 'set resolver named values and entitlement-projection-prefix to the deployed resolver')) {
    $null = Set-ClaudeProjectionGatewayResolver -ResourceGroup $ResourceGroup -ApimName $ApimName -NamePrefix $NamePrefix -ResolverUrl $resolverUrl -ResolverAudience $resolverAudience
} else { throw 'Pointing the gateway at the resolver was declined; no further steps run.' }
Ok "entitlement-resolver-url is $resolverUrl; entitlement-projection-prefix is $NamePrefix; entitlement-source is unchanged"
$work = Join-Path ([IO.Path]::GetTempPath()) ("claude-projection-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $work | Out-Null
$snapshot = Join-Path $work 'snapshot.json'
$gateway = Join-Path $work 'gateway-decisions.json'
$syncArchive = Join-Path $work 'sync.tar.gz'

try {
    Step 'Populate projection from Entra'
    if ($PSCmdlet.ShouldProcess($cosmosAccount, 'export Entra membership and apply projection')) {
        & (Join-Path $PSScriptRoot 'Sync-ClaudeProjection.ps1') -Account $cosmosAccount -ApimName $ApimName -ResourceGroup $ResourceGroup `
            -StandardGroup $StandardGroup -PremiumGroup $PremiumGroup -ExportPath $snapshot
        if ($LASTEXITCODE -ne 0) { throw 'projection snapshot export failed' }
        if (-not $network.runnerName -or -not $network.runnerPrincipalId) { throw 'Projection network did not return an in-VNet runner.' }
        az cosmosdb sql role assignment create --account-name $cosmosAccount --resource-group $ResourceGroup `
            --scope /dbs/claude/colls/entitlement --principal-id $($network.runnerPrincipalId) `
            --role-definition-id 00000000-0000-0000-0000-000000000002 -o none 2>$null
        if ($LASTEXITCODE -ne 0) { throw 'Runner Cosmos role assignment failed; projection apply was not attempted.' }
        $null = New-ClaudeProjectionSyncArchive -Path $syncArchive -Root $root
        Start-ClaudeProjectionRunner -ResourceGroup $ResourceGroup -Name $($network.runnerName) -SubscriptionId $SubscriptionId | Out-Null
        Send-RunnerFile -ResourceGroup $ResourceGroup -Name $($network.runnerName) -Path $syncArchive -Destination /work/sync-source.tar.gz | Out-Null
        Send-RunnerFile -ResourceGroup $ResourceGroup -Name $($network.runnerName) -Path $snapshot -Destination /work/snapshot.json -Deadline (Get-RunnerFileDeadline -Path $snapshot) | Out-Null
        Invoke-RunnerCommand -ResourceGroup $ResourceGroup -Name $($network.runnerName) -Command "node -e require('fs').mkdirSync('/work',{recursive:true})" | Out-Null
        Invoke-RunnerCommand -ResourceGroup $ResourceGroup -Name $($network.runnerName) -Command 'tar -x -z -f /work/sync-source.tar.gz -C /work' | Out-Null
        Invoke-RunnerCommand -ResourceGroup $ResourceGroup -Name $($network.runnerName) -Command 'npm --prefix /work/sync ci --omit=dev --ignore-scripts --no-audit --fund=false' | Out-Null
        $applyRaw = Invoke-RunnerCommand -ResourceGroup $ResourceGroup -Name $($network.runnerName) -Command "node /work/sync/src/apply-projection.mjs --cosmos https://$cosmosAccount.documents.azure.com:443/ --tenant $($apim.identity.tenantId) --account-resource-id $accountResourceId --snapshot /work/snapshot.json"
        $apply = ConvertFrom-ClaudeRunnerResult -RawOutput $applyRaw -Step 'projection apply'
    } else { throw 'Projection population was declined; no further steps run.' }

    Step 'Compare before flip'
    if ($PSCmdlet.ShouldProcess($ApimName, 'export gateway decisions and compare projection')) {
        $compare = Invoke-ClaudeProjectionDeployerCompare -ResourceGroup $ResourceGroup -ApimName $ApimName -RunnerName $($network.runnerName) `
            -CosmosAccount $cosmosAccount -TenantId $($apim.identity.tenantId) -GatewayPath $gateway -StandardGroup $StandardGroup -PremiumGroup $PremiumGroup -CompareBaseline $CompareBaseline
        Ok "clean comparison: $($compare.compared) identities"
    } else { throw 'Projection comparison was declined; no further steps run.' }
    Note 'Clean comparison complete; named values remain authoritative. To switch now, rerun with -FlipAfterCleanCompare.'
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
