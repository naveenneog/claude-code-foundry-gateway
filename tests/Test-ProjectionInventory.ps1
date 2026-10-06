param([string]$RepositoryRoot)
$ErrorActionPreference = 'Stop'
$root = if ($RepositoryRoot) { $RepositoryRoot } else { Split-Path $PSScriptRoot -Parent }
$script:assertions = 0
$script:failures = 0
function Assert($Name, $Condition, $Detail = '') {
    $script:assertions++
    if ($Condition) { Write-Host "  [OK] $Name" }
    else { $script:failures++; Write-Host "  [FAIL] $Name $Detail" }
}
function Capture([scriptblock]$Action) {
    $script:CapturedError = ''
    $script:CapturedResult = $null
    try { $script:CapturedResult = & $Action }
    catch { $script:CapturedError = $_.Exception.Message }
}

function Add-CompiledResourceType($Resource, [Collections.Generic.List[string]]$Types) {
    if ($null -eq $Resource) { return }
    $existing = $false
    if ($Resource.PSObject.Properties.Name -contains 'existing') { $existing = [bool]$Resource.existing }
    if (-not $existing -and ($Resource.PSObject.Properties.Name -contains 'type') -and $Resource.type) {
        $Types.Add([string]$Resource.type)
    }
    if ($Resource.PSObject.Properties.Name -contains 'resources' -and $Resource.resources) {
        if ($Resource.resources -is [System.Array]) {
            foreach ($child in @($Resource.resources)) { Add-CompiledResourceType $child $Types }
        }
        else {
            foreach ($property in $Resource.resources.PSObject.Properties) { Add-CompiledResourceType $property.Value $Types }
        }
    }
}

function Get-CompiledResourceTypes([string]$RelativePath) {
    $path = Join-Path $root $RelativePath
    $raw = & az bicep build --file $path --stdout 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "az bicep build failed for ${RelativePath}: $raw" }
    $start = $raw.IndexOf('{')
    if ($start -lt 0) { throw "az bicep build returned no JSON for $RelativePath" }
    $template = $raw.Substring($start) | ConvertFrom-Json -Depth 100
    $types = [Collections.Generic.List[string]]::new()
    if ($template.resources -is [System.Array]) {
        foreach ($resource in @($template.resources)) { Add-CompiledResourceType $resource $types }
    }
    else {
        foreach ($property in $template.resources.PSObject.Properties) { Add-CompiledResourceType $property.Value $types }
    }
    return @($types | Sort-Object -Unique)
}

function Get-ResourceByName($Plan, [string]$Name) {
    @($Plan.Resources | Where-Object { $_.Name -eq $Name }) | Select-Object -First 1
}

Write-Host 'P100 projection resource inventory'
$inventoryPath = Join-Path $root 'scripts\ClaudeProjectionInventory.ps1'
$script:CapturedError = ''
try { . $inventoryPath }
catch { $script:CapturedError = $_.Exception.Message }
Assert 'inventory script is dot-sourceable' (-not $CapturedError) $CapturedError

$compiled = [ordered]@{}
foreach ($template in @(
    'infra\projection.bicep',
    'infra\projection-network.bicep',
    'infra\resolver.bicep',
    'infra\projection-registry.bicep',
    'infra\projection-renewal.bicep'
)) {
    Capture { Get-CompiledResourceTypes $template }
    Assert "compiled $template offline" (-not $CapturedError -and @($CapturedResult).Count -gt 0) $CapturedError
    $compiled[$template] = @($CapturedResult)
}

if (-not $CapturedError) {
    Capture { Get-ClaudeProjectionResourcePlan -NamePrefix 'projtest' -Location 'eastus2' -Sku BasicV2 -ResolverInboundAccess public }
    $publicPlan = $CapturedResult
    Assert 'public inventory plan is returned' (-not $CapturedError -and $publicPlan.Resources.Count -gt 0) $CapturedError
    Capture { Get-ClaudeProjectionResourcePlan -NamePrefix 'projtest' -Location 'eastus2' -Sku StandardV2 -ResolverInboundAccess private }
    $privatePlan = $CapturedResult
    Assert 'private inventory plan is returned' (-not $CapturedError -and $privatePlan.Resources.Count -gt 0) $CapturedError
    Capture { Get-ClaudeProjectionResourcePlan -NamePrefix 'projtest' -Location 'eastus2' -Sku BasicV2 -ResolverInboundAccess public -IncludeSyncJob }
    $publicSyncPlan = $CapturedResult
    Assert 'public sync inventory plan is returned' (-not $CapturedError -and $publicSyncPlan.Resources.Count -gt $publicPlan.Resources.Count) $CapturedError
    Capture { Get-ClaudeProjectionResourcePlan -NamePrefix 'projtest' -Location 'eastus2' -Sku PremiumV2 -ResolverInboundAccess private -IncludeSyncJob }
    $privateSyncPlan = $CapturedResult
    Assert 'private sync inventory plan is returned' (-not $CapturedError -and $privateSyncPlan.Resources.Count -gt $privatePlan.Resources.Count) $CapturedError

    $allCompiledTypes = @($compiled.Values | ForEach-Object { $_ } | Sort-Object -Unique)
    $allPlans = @($publicPlan, $privatePlan, $publicSyncPlan, $privateSyncPlan)
    $allInventoryTypes = @($allPlans | ForEach-Object { $_.Resources } | ForEach-Object { $_.Type } | Sort-Object -Unique)
    foreach ($type in $allCompiledTypes) {
        Assert "compiled type appears in inventory: $type" ($allInventoryTypes -contains $type) ($allInventoryTypes -join ', ')
    }
    foreach ($type in $allInventoryTypes) {
        Assert "inventory type appears in compiled templates: $type" ($allCompiledTypes -contains $type) ($allCompiledTypes -join ', ')
    }

    foreach ($pair in @(
        @('cosmos-projtest', 'Microsoft.DocumentDB/databaseAccounts'),
        @('vnet-projtest', 'Microsoft.Network/virtualNetworks'),
        @('pe-cosmos-projtest', 'Microsoft.Network/privateEndpoints'),
        @('aci-projtest-projtest', 'Microsoft.ContainerInstance/containerGroups'),
        @('func-resolver-projtest', 'Microsoft.Web/sites'),
        @('plan-resolver-projtest', 'Microsoft.Web/serverfarms'),
        @('appi-resolver-projtest', 'Microsoft.Insights/components'),
        @('log-resolver-projtest', 'Microsoft.OperationalInsights/workspaces')
    )) {
        $resource = Get-ResourceByName $privatePlan $pair[0]
        Assert "resource $($pair[0]) uses template name and type" ($resource -and $resource.Type -eq $pair[1] -and $resource.Region -eq 'eastus2') ($resource | ConvertTo-Json -Compress)
    }
    Assert 'Cosmos account uses serverless Standard offer wording' ((Get-ResourceByName $privatePlan 'cosmos-projtest').Sku -match 'serverless' -and (Get-ResourceByName $privatePlan 'cosmos-projtest').Sku -match 'Standard')
    Assert 'resolver storage name says it is derived' (@($privatePlan.Resources | Where-Object { $_.Name -like 'stres<13 characters*' -and $_.Type -eq 'Microsoft.Storage/storageAccounts' }).Count -eq 1)
    Assert 'registry name says it is derived when sync job is included' (@($publicSyncPlan.Resources | Where-Object { $_.Name -like 'acr<13 characters*' -and $_.Type -eq 'Microsoft.ContainerRegistry/registries' }).Count -eq 1)
    Assert 'renewal environment and job names say they are derived' (
        @($publicSyncPlan.Resources | Where-Object { $_.Name -like 'cae-renew-<13 characters*' -and $_.Type -eq 'Microsoft.App/managedEnvironments' }).Count -eq 1 -and
        @($publicSyncPlan.Resources | Where-Object { $_.Name -like 'caj-renew-<13 characters*' -and $_.Type -eq 'Microsoft.App/jobs' }).Count -eq 1)

    Assert 'VNet address space matches projection-network default' ($privatePlan.Network.VirtualNetwork -eq 'vnet-projtest' -and $privatePlan.Network.AddressSpace -eq '10.10.0.0/16')
    $subnets = @{}
    foreach ($subnet in $privatePlan.Network.Subnets) { $subnets[$subnet.Name] = $subnet }
    Assert 'endpoints subnet prefix and no delegation match template' ($subnets['endpoints'].Prefix -eq '10.10.1.0/24' -and $subnets['endpoints'].Delegation -eq '')
    Assert 'runner subnet prefix and delegation match template' ($subnets['runner'].Prefix -eq '10.10.2.0/24' -and $subnets['runner'].Delegation -eq 'Microsoft.ContainerInstance/containerGroups')
    Assert 'resolver subnet prefix and delegation match template' ($subnets['resolver'].Prefix -eq '10.10.3.0/26' -and $subnets['resolver'].Delegation -eq 'Microsoft.App/environments')
    Assert 'renewal subnet prefix and delegation match template' ($subnets['renewal'].Prefix -eq '10.10.3.64/27' -and $subnets['renewal'].Delegation -eq 'Microsoft.App/environments')
    Assert 'private DNS zones include Cosmos, sites and resolver storage zones' (@($privatePlan.Network.PrivateDnsZones | Where-Object { $_ -in @('privatelink.documents.azure.com','privatelink.azurewebsites.net','privatelink.blob.core.windows.net','privatelink.queue.core.windows.net','privatelink.table.core.windows.net') }).Count -eq 5)
    Assert 'public resolver plan omits the resolver site private endpoint' (@($publicPlan.Network.PrivateEndpoints | Where-Object { $_ -eq 'pe-func-resolver-projtest' }).Count -eq 0)
    Assert 'private resolver plan includes the resolver site private endpoint' (@($privatePlan.Network.PrivateEndpoints | Where-Object { $_ -eq 'pe-func-resolver-projtest' }).Count -eq 1)
    Assert 'runner details match image, CPU, memory and lifetime defaults' (
        $privatePlan.Network.Runner.Name -eq 'aci-projtest-projtest' -and
        $privatePlan.Network.Runner.Image -eq 'mcr.microsoft.com/devcontainers/javascript-node:22' -and
        $privatePlan.Network.Runner.Cpu -eq 2 -and
        $privatePlan.Network.Runner.MemoryGB -eq 4 -and
        $privatePlan.Network.Runner.Command -eq '/bin/sh -c sleep 10800')
    Assert 'resolver Flex Consumption settings match resolver defaults' (
        (Get-ResourceByName $privatePlan 'plan-resolver-projtest').Sku -match 'FlexConsumption' -and
        (Get-ResourceByName $privatePlan 'func-resolver-projtest').Sku -match 'alwaysReady=2' -and
        (Get-ResourceByName $privatePlan 'func-resolver-projtest').Sku -match 'httpConcurrency=100' -and
        (Get-ResourceByName $privatePlan 'func-resolver-projtest').Sku -match 'maximumInstanceCount=100' -and
        (Get-ResourceByName $privatePlan 'func-resolver-projtest').Sku -match 'instanceMemoryMB=2048')

    $identityLines = @($privateSyncPlan.Identities | ForEach-Object { "$($_.Principal)|$($_.Role)|$($_.Scope)|$($_.Purpose)" })
    Assert 'identities include runner Cosmos writer role' (($identityLines -join "`n") -match 'aci-projtest-projtest.*Cosmos DB Built-in Data Contributor.*/dbs/claude/colls/entitlement')
    Assert 'identities include resolver Cosmos reader role' (($identityLines -join "`n") -match 'func-resolver-projtest.*Cosmos DB Built-in Data Reader.*/dbs/claude/colls/entitlement')
    Assert 'identities include renewal identity and AcrPull role' (($identityLines -join "`n") -match 'id-projection-renewal-projtest.*AcrPull')
    Assert 'identities include resolver app registration and service principal' (($identityLines -join "`n") -match 'claude-projection-resolver-projtest.*app registration and service principal')

    Capture { Format-ClaudeProjectionResourcePlan -Plan $privateSyncPlan }
    $formatted = @($CapturedResult)
    $formattedText = $formatted -join "`n"
    Assert 'formatted output returns lines' (-not $CapturedError -and $formatted.Count -gt 10) $CapturedError
    foreach ($resource in @($privateSyncPlan.Resources)) {
        Assert "formatted output names $($resource.Name)" ($formattedText.Contains([string]$resource.Name))
    }
    Assert 'formatted output has no TODO or placeholder text' ($formattedText -notmatch '(?i)TODO|TBD|placeholder')

    foreach ($badPrefix in @('ProjTest','proj--test','-proj','proj-','proj_test',('a' * 38))) {
        Capture { Get-ClaudeProjectionResourcePlan -NamePrefix $badPrefix -Location 'eastus2' -Sku BasicV2 -ResolverInboundAccess public }
        Assert "invalid prefix '$badPrefix' throws" ($CapturedError -match '1-37 lowercase letters or digits')
    }

    $tokens = $null
    $parseErrors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile($inventoryPath, [ref]$tokens, [ref]$parseErrors)
    Assert 'inventory script parses with the PowerShell parser' (@($parseErrors).Count -eq 0) (@($parseErrors | ForEach-Object Message) -join '; ')
}

Write-Host "P100_INVENTORY assertions=$assertions failed=$failures"
exit ([int]($failures -gt 0))
