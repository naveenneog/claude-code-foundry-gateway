$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$modulePath = Join-Path $root 'scripts\ClaudeProjectionNetwork.psm1'
$fail = 0
$count = 0
function Assert($Label, [bool]$Condition, $Detail = '') {
    $script:count++
    if ($Condition) { Write-Host "  [OK]   $Label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $Label$(if ($Detail) { " - $Detail" })" -ForegroundColor Red; $script:fail++ }
}
function Capture([scriptblock]$Block) {
    $script:Failure = ''
    $script:Result = $null
    try { $script:Result = & $Block }
    catch { $script:Failure = $_.Exception.Message }
}

Write-Host ''
Write-Host 'P116 projection network selection and preflight' -ForegroundColor Cyan

Assert 'the focused projection network module ships' (Test-Path -LiteralPath $modulePath)
if (-not (Test-Path -LiteralPath $modulePath)) {
    Write-Host ''
    Write-Host "$fail of $count assertion(s) failed." -ForegroundColor Red
    exit 1
}
Import-Module $modulePath -Force

$subscription = '11111111-2222-4333-8444-555555555555'
$rgId = "/subscriptions/$subscription/resourceGroups/rg-p116"
$vnetId = "$rgId/providers/Microsoft.Network/virtualNetworks/vnet-customer"
$ids = [ordered]@{
    EndpointsSubnetId = "$vnetId/subnets/endpoints"
    RunnerSubnetId = "$vnetId/subnets/runner"
    ResolverSubnetId = "$vnetId/subnets/resolver"
    RenewalSubnetId = "$vnetId/subnets/renewal"
    ApimSubnetId = "$vnetId/subnets/apim"
}
$apim = [pscustomobject]@{
    id = "$rgId/providers/Microsoft.ApiManagement/service/apim-p116"
    location = 'East US 2'
    identity = [pscustomobject]@{ type = 'SystemAssigned'; principalId = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee' }
    properties = [pscustomobject]@{ publicNetworkAccess = 'Enabled'; customProperties = [pscustomobject]@{ 'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Protocols.Tls10' = 'False' } }
}
$vnet = [pscustomobject]@{ id = $vnetId; location = 'eastus2' }
$apimNsgId = "$rgId/providers/Microsoft.Network/networkSecurityGroups/nsg-apim-customer"
function New-Subnet($Id, $Prefix, $Delegation, $Policies = '', $NsgId = '') {
    $delegations = if ($Delegation) { @([pscustomobject]@{ properties = [pscustomobject]@{ serviceName = $Delegation } }) } else { @() }
    [pscustomobject]@{
        id = $Id
        properties = [pscustomobject]@{
            addressPrefix = $Prefix
            delegations = $delegations
            privateEndpointNetworkPolicies = $Policies
            networkSecurityGroup = $(if ($NsgId) { [pscustomobject]@{ id = $NsgId } } else { $null })
        }
    }
}
function New-ApimNsg {
    [pscustomobject]@{
        id = $apimNsgId
        properties = [pscustomobject]@{
            securityRules = @([pscustomobject]@{
                name = 'key-vault-dependency'
                properties = [pscustomobject]@{
                    priority = 100
                    direction = 'Outbound'
                    access = 'Allow'
                    protocol = 'Tcp'
                    sourceAddressPrefix = 'VirtualNetwork'
                    destinationAddressPrefix = 'AzureKeyVault'
                    destinationPortRange = '443'
                }
            })
        }
    }
}
function New-SubnetMap {
    @{
        Endpoints = New-Subnet $ids.EndpointsSubnetId '10.20.1.0/24' '' 'Disabled'
        Runner = New-Subnet $ids.RunnerSubnetId '10.20.2.0/24' 'Microsoft.ContainerInstance/containerGroups'
        Resolver = New-Subnet $ids.ResolverSubnetId '10.20.3.0/27' 'Microsoft.App/environments'
        Renewal = New-Subnet $ids.RenewalSubnetId '10.20.3.32/27' 'Microsoft.App/environments'
        Apim = New-Subnet $ids.ApimSubnetId '10.20.4.0/24' 'Microsoft.Web/serverFarms' '' $apimNsgId
    }
}
function New-ExistingPlan {
    Resolve-ClaudeProjectionNetworkSelection -Mode existing -VnetId $vnetId `
        -EndpointsSubnetId $ids.EndpointsSubnetId -RunnerSubnetId $ids.RunnerSubnetId `
        -ResolverSubnetId $ids.ResolverSubnetId -RenewalSubnetId $ids.RenewalSubnetId `
        -ApimSubnetId $ids.ApimSubnetId -NonInteractive
}

$managed = Resolve-ClaudeProjectionNetworkSelection -NonInteractive
Assert 'omitted parameters preserve managed-network behavior' ($managed.Mode -eq 'managed' -and -not $managed.VnetId)
Capture { Test-ClaudeProjectionNetworkPlan -Plan $managed -Apim $apim -ProjectionResourceGroupId $rgId -NamePrefix p116 -DeploymentLocation westus2 }
Assert 'managed mode refuses a deployment region different from APIM' ($Failure -match 'managed VNet region' -and $Failure -match 'Nothing was changed') $Failure
$options = @(Get-ClaudeProjectionNetworkOptions)
Assert 'interactive selection clearly presents managed and existing choices' (
    ($options.Value -join ',') -eq 'managed,existing' -and
    ($options.Label -join ' ') -match 'Managed projection VNet' -and
    ($options.Label -join ' ') -match 'Existing customer VNet'
) ($options | ConvertTo-Json -Depth 4)
$seenOptions = @()
$interactiveManaged = Resolve-ClaudeProjectionNetworkSelection -Selector {
    param($Presented)
    $script:seenOptions = @($Presented)
    'managed'
}
Assert 'the selector receives both network choices in one interactive decision' ($interactiveManaged.Mode -eq 'managed' -and $seenOptions.Count -eq 2) ($seenOptions | ConvertTo-Json -Depth 4)
Capture { Resolve-ClaudeProjectionNetworkSelection -Mode existing -VnetId $vnetId -NonInteractive }
Assert 'existing mode requires all five explicit subnet ids' ($Failure -match 'EndpointsSubnetId' -and $Failure -match 'ApimSubnetId' -and $Failure -match 'Nothing was changed') $Failure
$plan = New-ExistingPlan
Assert 'existing selection keeps every explicit id without name inference' (
    $plan.Mode -eq 'existing' -and $plan.VnetId -eq $vnetId -and
    @($ids.Keys | Where-Object { $plan.$_ -ne $ids[$_] }).Count -eq 0
) ($plan | ConvertTo-Json -Depth 4)

$result = Test-ClaudeProjectionNetworkPlan -Plan $plan -Apim $apim -VirtualNetwork $vnet `
    -Subnets (New-SubnetMap) -ApimNetworkSecurityGroup (New-ApimNsg) -DnsZones @() -ProjectionResourceGroupId $rgId -NamePrefix p116
Assert 'a valid customer network passes and reports every owned DNS namespace' (
    $result.Valid -and $result.RequiredPrivateDnsZones.Count -eq 5 -and
    $result.RequiredPrivateDnsZones -contains 'privatelink.documents.azure.com' -and
    $result.RequiredPrivateDnsZones -contains 'privatelink.azurewebsites.net' -and
    $result.RequiredPrivateDnsZones -contains 'privatelink.blob.core.windows.net'
) ($result | ConvertTo-Json -Depth 8)

$mutations = [ordered]@{
    'wrong subscription' = { param($p,$a,$v,$s,$d) $p.VnetId = $p.VnetId.Replace($subscription, '99999999-8888-4777-8666-555555555555') }
    'wrong region' = { param($p,$a,$v,$s,$d) $v.location = 'westus2' }
    'shared subnet id' = { param($p,$a,$v,$s,$d) $p.RenewalSubnetId = $p.ResolverSubnetId }
    'APIM wrong delegation' = { param($p,$a,$v,$s,$d) $s.Apim.properties.delegations[0].properties.serviceName = 'Microsoft.App/environments' }
    'APIM extra delegation' = { param($p,$a,$v,$s,$d) $s.Apim.properties.delegations = @($s.Apim.properties.delegations) + @([pscustomobject]@{ properties = [pscustomobject]@{ serviceName = 'Microsoft.App/environments' } }) }
    'APIM undersized subnet' = { param($p,$a,$v,$s,$d) $s.Apim.properties.addressPrefix = '10.20.4.0/28' }
    'APIM missing NSG' = { param($p,$a,$v,$s,$d,$n) $s.Apim.properties.networkSecurityGroup = $null }
    'APIM NSG missing Key Vault rule' = { param($p,$a,$v,$s,$d,$n) $n.properties.securityRules[0].properties.destinationAddressPrefix = 'Storage' }
    'resolver wrong delegation' = { param($p,$a,$v,$s,$d) $s.Resolver.properties.delegations[0].properties.serviceName = 'Microsoft.Web/serverFarms' }
    'resolver undersized subnet' = { param($p,$a,$v,$s,$d) $s.Resolver.properties.addressPrefix = '10.20.3.0/28' }
    'renewal wrong delegation' = { param($p,$a,$v,$s,$d) $s.Renewal.properties.delegations[0].properties.serviceName = 'Microsoft.ContainerInstance/containerGroups' }
    'renewal undersized subnet' = { param($p,$a,$v,$s,$d) $s.Renewal.properties.addressPrefix = '10.20.3.32/28' }
    'runner wrong delegation' = { param($p,$a,$v,$s,$d) $s.Runner.properties.delegations[0].properties.serviceName = 'Microsoft.App/environments' }
    'endpoint delegated' = { param($p,$a,$v,$s,$d) $s.Endpoints.properties.delegations = @([pscustomobject]@{ properties = [pscustomobject]@{ serviceName = 'Microsoft.Web/serverFarms' } }) }
    'endpoint policies incompatible' = { param($p,$a,$v,$s,$d) $s.Endpoints.properties.privateEndpointNetworkPolicies = 'Unsupported' }
    'conflicting DNS namespace link' = {
        param($p,$a,$v,$s,$d)
        $d.Add([pscustomobject]@{
            Name = 'privatelink.documents.azure.com'
            Id = "/subscriptions/$subscription/resourceGroups/network-rg/providers/Microsoft.Network/privateDnsZones/privatelink.documents.azure.com"
            Links = @([pscustomobject]@{ Name = 'customer-link'; VirtualNetworkId = $vnetId })
        })
    }
}
foreach ($mutation in $mutations.GetEnumerator()) {
    $mutatedPlan = New-ExistingPlan
    $mutatedApim = $apim | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $mutatedVnet = $vnet | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $mutatedSubnets = New-SubnetMap
    $mutatedNsg = New-ApimNsg
    $mutatedDns = [Collections.Generic.List[object]]::new()
    & $mutation.Value $mutatedPlan $mutatedApim $mutatedVnet $mutatedSubnets $mutatedDns $mutatedNsg
    Capture {
        Test-ClaudeProjectionNetworkPlan -Plan $mutatedPlan -Apim $mutatedApim -VirtualNetwork $mutatedVnet `
            -Subnets $mutatedSubnets -ApimNetworkSecurityGroup $mutatedNsg -DnsZones $mutatedDns.ToArray() -ProjectionResourceGroupId $rgId -NamePrefix p116
    }
    Assert "mutation is refused: $($mutation.Key)" ($Failure -match 'Projection network preflight refused' -and $Failure -match 'Nothing was changed') $Failure
}

$discoveries = [Collections.Generic.List[string]]::new()
$resourceMap = @{
    $vnetId = $vnet
    $ids.EndpointsSubnetId = (New-SubnetMap).Endpoints
    $ids.RunnerSubnetId = (New-SubnetMap).Runner
    $ids.ResolverSubnetId = (New-SubnetMap).Resolver
    $ids.RenewalSubnetId = (New-SubnetMap).Renewal
    $ids.ApimSubnetId = (New-SubnetMap).Apim
    $apimNsgId = New-ApimNsg
}
$discovered = Invoke-ClaudeProjectionNetworkPreflight -Plan $plan -Apim $apim -ProjectionResourceGroupId $rgId -NamePrefix p116 `
    -DiscoverResource {
        param($Id)
        $discoveries.Add("resource $Id")
        $resourceMap[$Id]
    } -DiscoverDnsZones {
        param($SubscriptionId)
        $discoveries.Add("dns $SubscriptionId")
        @()
    }
Assert 'stub-testable discovery reads the VNet, all five subnets and DNS without a query expression' (
    $discovered.Valid -and $discoveries.Count -eq 8 -and
    -not (($discoveries -join ' ') -match '--query')
) ($discoveries -join ' | ')

$armCalls = [Collections.Generic.List[object]]::new()
$state = Join-Path ([IO.Path]::GetTempPath()) ('p116-network-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $state
try {
    $integration = Set-ClaudeProjectionApimOutboundIntegration -Apim $apim -SubnetId $ids.ApimSubnetId -StateDirectory $state -InvokeArm {
        param($Url,$Method,$Body,$StateDirectory,$IfMatch)
        $armCalls.Add([pscustomobject]@{ Url=$Url; Method=$Method; Body=$Body; StateDirectory=$StateDirectory; IfMatch=$IfMatch })
        if ($Method -eq 'get') {
            $isBaseline = @($armCalls | Where-Object Method -eq 'get').Count -eq 1
            [pscustomobject]@{
                etag = '"p116-etag"'
                identity = [pscustomobject]@{ type = 'SystemAssigned'; principalId = $apim.identity.principalId }
                properties = [pscustomobject]@{
                    provisioningState = 'Succeeded'
                    virtualNetworkType = $(if ($isBaseline) { 'None' } else { 'External' })
                    virtualNetworkConfiguration = $(if ($isBaseline) { $null } else { [pscustomobject]@{ subnetResourceId = $ids.ApimSubnetId } })
                    publicNetworkAccess = 'Enabled'
                    customProperties = $apim.properties.customProperties
                }
            }
        }
    }
}
finally { Remove-Item -LiteralPath $state -Recurse -Force -ErrorAction SilentlyContinue }
Assert 'APIM outbound integration uses ARM 2024-05-01 and never az apim update' (
    $armCalls.Count -eq 3 -and $armCalls[0].Method -eq 'get' -and $armCalls[1].Method -eq 'patch' -and $armCalls[2].Method -eq 'get' -and
    @($armCalls | Where-Object { $_.Url -notmatch 'api-version=2024-05-01$' }).Count -eq 0
) ($armCalls | ConvertTo-Json -Depth 8)
Assert 'the APIM integration patch preserves identity and changes only VNet properties' (
    $armCalls[1].Body.identity.type -eq 'SystemAssigned' -and
    $armCalls[1].IfMatch -eq '"p116-etag"' -and
    $armCalls[1].Body.properties.virtualNetworkType -eq 'External' -and
    $armCalls[1].Body.properties.virtualNetworkConfiguration.subnetResourceId -eq $ids.ApimSubnetId -and
    -not $armCalls[1].Body.properties.PSObject.Properties['publicNetworkAccess'] -and
    -not $armCalls[1].Body.properties.PSObject.Properties['customProperties']
) ($armCalls[1].Body | ConvertTo-Json -Depth 8)
Assert 'the verified APIM state keeps identity and unrelated settings' (
    $integration.Result.identity.principalId -eq $apim.identity.principalId -and
    $integration.Result.properties.publicNetworkAccess -eq 'Enabled' -and
    $integration.Result.properties.customProperties.'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Protocols.Tls10' -eq 'False'
) ($integration.Result | ConvertTo-Json -Depth 8)
$failedOrder = [Collections.Generic.List[string]]::new()
Capture {
    $failedOrder.Add('integration')
    Set-ClaudeProjectionApimOutboundIntegration -Apim $apim -SubnetId $ids.ApimSubnetId -StateDirectory $env:TEMP -InvokeArm {
        param($Url,$Method,$Body,$StateDirectory,$IfMatch)
        if ($Method -eq 'patch') { throw 'fixture integration failure' }
        [pscustomobject]@{
            etag = '"failure-etag"'
            identity = [pscustomobject]@{ type = 'SystemAssigned'; principalId = $apim.identity.principalId }
            properties = [pscustomobject]@{
                provisioningState = 'Succeeded'
                virtualNetworkType = 'None'
                virtualNetworkConfiguration = $null
                publicNetworkAccess = 'Enabled'
                customProperties = $apim.properties.customProperties
            }
        }
    }
    $failedOrder.Add('resolver')
}
Assert 'an APIM integration failure is explicit and stops before resolver deployment' (
    $Failure -match 'APIM outbound VNet integration failed' -and $Failure -match 'fixture integration failure' -and
    ($failedOrder -join ',') -eq 'integration'
) "$Failure | order $($failedOrder -join ',')"

$networkBicep = Get-Content (Join-Path $root 'infra\projection-network.bicep') -Raw
$deployer = Get-Content (Join-Path $root 'scripts\Deploy-ClaudeProjection.ps1') -Raw
$installer = Get-Content (Join-Path $root 'Install-ClaudeGateway.ps1') -Raw
$installProjection = Get-Content (Join-Path $root 'scripts\ClaudeInstallProjection.ps1') -Raw
Assert 'managed Bicep creates a dedicated /24 APIM subnet with Key Vault NSG egress' (
    $networkBicep -match "name: 'apim'" -and $networkBicep -match 'cidrSubnet\(vnetAddressPrefix, 24, 4\)' -and
    $networkBicep -match "serviceName: 'Microsoft.Web/serverFarms'" -and
    $networkBicep -match "destinationAddressPrefix: 'AzureKeyVault'" -and $networkBicep -match "destinationPortRange: '443'"
)
Assert 'existing Bicep takes and returns every subnet id without modifying the existing VNet' (
    $networkBicep -match 'param resolverSubnetId string' -and $networkBicep -match 'param apimSubnetId string' -and
    $networkBicep -match 'output runnerSubnetId string = runnerSubnet' -and
    $networkBicep -match "output resolverSubnetId string = createVnet .* : resolverSubnetId" -and
    $networkBicep -match "output apimSubnetId string = createVnet .* : apimSubnetId" -and
    $networkBicep -notmatch "resource existingVnet .*="
)
Assert 'the deployer passes explicit existing network ids to projection-network.bicep' (
    $deployer -match 'ProjectionNetworkMode' -and $deployer -match 'ProjectionVnetId' -and
    $deployer -match 'ProjectionEndpointsSubnetId' -and $deployer -match 'ProjectionRunnerSubnetId' -and
    $deployer -match 'ProjectionResolverSubnetId' -and $deployer -match 'ProjectionRenewalSubnetId' -and
    $deployer -match 'ProjectionApimSubnetId'
)
$integrationAt = $deployer.IndexOf('Set-ClaudeProjectionApimOutboundIntegration')
$resolverAt = $deployer.IndexOf("Step 'Deploy resolver'")
Assert 'Standard/Premium private APIM integration is attempted before resolver deployment' (
    $integrationAt -ge 0 -and $resolverAt -gt $integrationAt -and $deployer -notmatch 'az apim update'
) "integration=$integrationAt resolver=$resolverAt"
Assert 'installer parameters flow through the helper and deployer' (
    $installer -match 'ProjectionNetworkMode' -and $installer -match 'ProjectionApimSubnetId' -and
    $installProjection -match 'ProjectionNetworkMode' -and $installProjection -match 'ProjectionApimSubnetId'
)

Write-Host ''
if ($fail) { Write-Host "$fail of $count assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "$count projection network assertion(s) passed, including $($mutations.Count) mutations." -ForegroundColor Green
