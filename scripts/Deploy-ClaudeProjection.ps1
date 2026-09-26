<#
.SYNOPSIS
    Deploys, populates and compare-gates the entitlement projection.

.DESCRIPTION
    One idempotent command for P61. It deploys a private Cosmos projection,
    creates the private network endpoints that the resolver needs to reach it,
    deploys the resolver with SKU-valid inbound access, exports the gateway's
    current named-value decisions, populates the projection from Entra, compares
    the resolver records against those decisions, and flips only the projection
    named values after a clean comparison and an explicit switch.

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
    [string]$Location,
    [ValidateSet('BasicV2','StandardV2','PremiumV2')]
    [string]$Sku = 'BasicV2',
    [ValidateSet('private','public')]
    [string]$ResolverInboundAccess,
    [string]$ResolverAppId,
    [string]$StandardGroup = 'claude-code-standard',
    [string]$PremiumGroup = 'claude-code-premium',
    [switch]$FlipAfterCleanCompare,
    [ValidateRange(1,10)][int]$RetryCount = 3,
    [ValidateRange(5,120)][int]$RetryDelaySeconds = 15
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'ApimNamedValue.ps1')

function Step($m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Note($m) { Write-Host "    $m" -ForegroundColor DarkGray }
function Ok($m) { Write-Host "    [OK]   $m" -ForegroundColor Green }

function Invoke-WithRetry {
    param([Parameter(Mandatory)][scriptblock]$Action, [string]$Name)
    for ($i = 1; $i -le $RetryCount; $i++) {
        try { return & $Action }
        catch {
            if ($i -ge $RetryCount) { throw }
            Write-Warning "$Name failed on attempt $i/${RetryCount}: $($_.Exception.Message)"
            Start-Sleep -Seconds $RetryDelaySeconds
        }
    }
}

function Get-DeploymentOutput {
    param([Parameter(Mandatory)][string]$DeploymentName)
    $raw = az deployment group show -g $ResourceGroup -n $DeploymentName --query properties.outputs -o json 2>$null
    if (-not $raw) { return @{} }
    $obj = $raw | ConvertFrom-Json
    $out = @{}
    foreach ($p in $obj.PSObject.Properties) { $out[$p.Name] = $p.Value.value }
    return $out
}

if (-not $Location) { $Location = az group show -n $ResourceGroup --query location -o tsv }
if (-not $ResolverInboundAccess) {
    $ResolverInboundAccess = switch ($Sku) {
        'BasicV2' { 'public' }
        'StandardV2' { 'private' }
        'PremiumV2' { 'private' }
    }
}
if ($Sku -eq 'BasicV2' -and $ResolverInboundAccess -ne 'public') {
    throw 'BasicV2 requires ResolverInboundAccess public; it cannot reach a private resolver.'
}
if ($Sku -in @('StandardV2','PremiumV2') -and $ResolverInboundAccess -ne 'private') {
    Write-Warning "$Sku can use a private resolver; public was explicitly requested."
}

Step 'Gateway identity'
$apim = az apim show -g $ResourceGroup -n $ApimName -o json | ConvertFrom-Json
if (-not $apim.identity.principalId) { throw "$ApimName has no system-assigned managed identity." }
$gatewayObjectId = [string]$apim.identity.principalId
$gatewayAppId = az ad sp show --id $gatewayObjectId --query appId -o tsv 2>$null
if (-not $gatewayAppId) { throw "Could not resolve the managed identity application id for $ApimName." }
Ok "gateway managed identity resolved"

if (-not $ResolverAppId) {
    $display = "claude-projection-resolver-$NamePrefix"
    Note "using or creating resolver app registration $display"
    $existing = az ad app list --display-name $display --query "[0].appId" -o tsv 2>$null
    if ($existing) { $ResolverAppId = $existing.Trim() }
    elseif ($PSCmdlet.ShouldProcess($display, 'create resolver app registration')) {
        $made = az ad app create --display-name $display --sign-in-audience AzureADMyOrg -o json | ConvertFrom-Json
        $ResolverAppId = [string]$made.appId
        az ad app update --id $ResolverAppId --identifier-uris "api://$ResolverAppId" -o none
    }
}
if (-not $ResolverAppId) { throw 'ResolverAppId is required when running with -WhatIf before the app registration exists.' }

Step 'Deploy private Cosmos projection'
$projectionName = "projection-$NamePrefix"
if ($PSCmdlet.ShouldProcess($projectionName, 'deploy projection.bicep with networkAccess=private-only')) {
    Invoke-WithRetry -Name 'projection deployment' -Action {
        az deployment group create -g $ResourceGroup -n $projectionName --template-file (Join-Path $root 'infra/projection.bicep') `
            --parameters namePrefix=$NamePrefix location=$Location networkAccess='private-only' -o none
        if ($LASTEXITCODE -ne 0) { throw 'projection deployment failed' }
    }
}
$projection = Get-DeploymentOutput $projectionName
$cosmosAccount = if ($projection.accountName) { $projection.accountName } else { "cosmos-$NamePrefix" }

Step 'Deploy projection network'
$networkName = "projection-network-$NamePrefix"
if ($PSCmdlet.ShouldProcess($networkName, 'deploy private endpoints and DNS')) {
    Invoke-WithRetry -Name 'projection network deployment' -Action {
        az deployment group create -g $ResourceGroup -n $networkName --template-file (Join-Path $root 'infra/projection-network.bicep') `
            --parameters namePrefix=$NamePrefix location=$Location cosmosAccountName=$cosmosAccount runnerEnabled=false -o none
        if ($LASTEXITCODE -ne 0) { throw 'projection network deployment failed' }
    }
}
$network = Get-DeploymentOutput $networkName

Step 'Deploy resolver'
$resolverName = "projection-resolver-$NamePrefix"
if ($PSCmdlet.ShouldProcess($resolverName, "deploy resolver.bicep inboundAccess=$ResolverInboundAccess")) {
    Invoke-WithRetry -Name 'resolver deployment' -Action {
        az deployment group create -g $ResourceGroup -n $resolverName --template-file (Join-Path $root 'infra/resolver.bicep') `
            --parameters namePrefix=$NamePrefix location=$Location cosmosAccountName=$cosmosAccount `
                integrationSubnetId=$($network.resolverSubnetId) privateEndpointSubnetId=$($network.endpointsSubnetId) `
                sitesDnsZoneId=$($network.sitesDnsZoneId) blobDnsZoneId=$($network.blobDnsZoneId) `
                queueDnsZoneId=$($network.queueDnsZoneId) tableDnsZoneId=$($network.tableDnsZoneId) `
                resolverAppId=$ResolverAppId allowedCallerAppIds="[$gatewayAppId]" `
                allowedCallerObjectIds="[$gatewayObjectId]" inboundAccess=$ResolverInboundAccess -o none
        if ($LASTEXITCODE -ne 0) { throw 'resolver deployment failed' }
    }
}
$resolver = Get-DeploymentOutput $resolverName
$resolverUrl = [string]$resolver.resolverUrl
$resolverAudience = [string]$resolver.resolverAudience
if (-not $resolverUrl -or -not $resolverAudience) { throw 'Resolver deployment did not return resolverUrl and resolverAudience outputs.' }

$work = Join-Path ([IO.Path]::GetTempPath()) "claude-projection-$NamePrefix-$PID"
New-Item -ItemType Directory -Force -Path $work | Out-Null
$snapshot = Join-Path $work 'snapshot.json'
$gateway = Join-Path $work 'gateway-decisions.json'

try {
    Step 'Populate projection from Entra'
    if ($PSCmdlet.ShouldProcess($cosmosAccount, 'export Entra membership and apply projection')) {
        & (Join-Path $PSScriptRoot 'Sync-ClaudeProjection.ps1') -Account $cosmosAccount -ApimName $ApimName -ResourceGroup $ResourceGroup `
            -StandardGroup $StandardGroup -PremiumGroup $PremiumGroup -ExportPath $snapshot
        if ($LASTEXITCODE -ne 0) { throw 'projection snapshot export failed' }
        node (Join-Path $root 'sync/src/apply-projection.mjs') --cosmos "https://$cosmosAccount.documents.azure.com:443/" --tenant $($apim.identity.tenantId) --snapshot $snapshot
        if ($LASTEXITCODE -ne 0) { throw 'projection apply failed' }
    }

    Step 'Compare before flip'
    if ($PSCmdlet.ShouldProcess($ApimName, 'export gateway decisions and compare projection')) {
        & (Join-Path $PSScriptRoot 'Compare-ClaudeEntitlement.ps1') -ResourceGroup $ResourceGroup -ApimName $ApimName `
            -StandardGroup $StandardGroup -PremiumGroup $PremiumGroup -ExportGatewayPath $gateway
        if ($LASTEXITCODE -ne 0) { throw 'named-value lists drift from Entra; refusing projection comparison and flip.' }
        $compareRaw = node (Join-Path $root 'sync/src/apply-projection.mjs') --cosmos "https://$cosmosAccount.documents.azure.com:443/" --tenant $($apim.identity.tenantId) --compare $gateway
        $compareCode = $LASTEXITCODE
        $compare = $compareRaw | Out-String | ConvertFrom-Json
        if ($compareCode -ne 0 -or -not $compare.ok) {
            throw "Refusing to flip because projection drift remains: $($compare.differences) difference(s)."
        }
        Ok "clean comparison: $($compare.compared) identities"
    }

    if (-not $FlipAfterCleanCompare) {
        Note 'Clean comparison complete. Re-run with -FlipAfterCleanCompare to switch entitlement-source.'
        return
    }

    Step 'Flip gateway'
    if ($PSCmdlet.ShouldProcess($ApimName, 'flip only projection named values')) {
        Set-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id 'entitlement-resolver-url' -Value $resolverUrl
        Set-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id 'entitlement-resolver-audience' -Value $resolverAudience
        Set-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id 'entitlement-source' -Value 'projection'
    }
    Ok 'gateway now reads entitlement from the projection'
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
