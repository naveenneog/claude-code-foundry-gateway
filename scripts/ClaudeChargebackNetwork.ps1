. (Join-Path $PSScriptRoot 'ClaudeChoice.ps1')
function Resolve-ClaudeReportLocation {
    param([string]$Location,[string]$SuggestedLocation,[switch]$NonInteractive)
    $locations=@(az account list-locations -o json|ConvertFrom-Json)
    if($LASTEXITCODE -ne 0){throw 'Could not discover subscription locations.'}
    $provider=az provider show --namespace Microsoft.App -o json|ConvertFrom-Json
    if($LASTEXITCODE -ne 0){throw 'Could not discover Container Apps regional availability.'}
    $supported=@($provider.resourceTypes|Where-Object resourceType -eq managedEnvironments|ForEach-Object {$_.locations})
    $offered=@($locations|Where-Object {$_.displayName -in $supported -or $_.name -in $supported})
    $explicit=@($offered|Where-Object {$_.name -eq $Location -or $_.displayName -eq $Location})
    if($Location -and $explicit.Count -ne 1){throw 'The selected location does not advertise Container Apps environments in this subscription.'}
    $suggested=@($offered|Where-Object {$_.name -eq $SuggestedLocation -or $_.displayName -eq $SuggestedLocation})
    $options=@($offered|Sort-Object displayName|ForEach-Object {[pscustomobject]@{Id=$_.name;Name="$($_.displayName) ($($_.name))"}})
    $selection=Select-ClaudeReportOption -Prompt 'Reports region (actual Container Apps locations)' -Parameter Location -Options $options `
        -SelectedId $(if($Location){[string]$explicit.name}else{''}) -DefaultId $(if($suggested.Count -eq 1){[string]$suggested.name}else{''}) -NonInteractive:$NonInteractive `
        -WhereToFind @('az account list-locations -o table; az provider show --namespace Microsoft.App -o json','Azure portal: Subscriptions > Resource providers > Microsoft.App; API Management > Overview > Location')
    return $selection.Id
}

function Resolve-ClaudeReportNetwork {
    param([string]$ResourceGroup,[string]$Location,[string]$VirtualNetworkId,[string]$JobsSubnetId,[string]$EndpointSubnetId,
        [string]$VirtualNetworkPrefix,[string]$JobsSubnetPrefix,[string]$EndpointSubnetPrefix,[string]$PrivateDnsZoneId,[switch]$NonInteractive)
    if(-not (Test-ClaudeInteractive)){$NonInteractive=$true}
    $vnets=@(az network vnet list -o json | ConvertFrom-Json | Where-Object location -eq $Location)
    if($LASTEXITCODE -ne 0){throw 'Could not discover regional VNets and subnets.'}
    $newNetwork=[bool]($VirtualNetworkPrefix -or $JobsSubnetPrefix -or $EndpointSubnetPrefix)
    if(-not $VirtualNetworkId -and -not $newNetwork){
        $options=@([pscustomobject]@{Id='new';Name='Create a dedicated reports VNet with an explicit private address plan'})
        $options+=@($vnets|ForEach-Object {[pscustomobject]@{Id=$_.id;Name="$($_.name) ($($_.resourceGroup)) - $($_.addressSpace.addressPrefixes -join ', ')"} })
        if($NonInteractive){throw 'Choose -VirtualNetworkId with both subnet IDs, or supply the three new-network CIDR parameters. Where to find it: az network vnet list -o json; Azure portal: Virtual networks > Address space and Subnets. A new address plan is an operator decision, not a discovered value.'}
        $chosen=Select-ClaudeReportOption -Prompt 'Reports network' -Parameter VirtualNetworkId -Options $options -DefaultId new `
            -WhereToFind @('az network vnet list -o json','Azure portal: Virtual networks > Overview > Resource ID; Address space')
        if($chosen.Id -ne 'new'){$VirtualNetworkId=$chosen.Id}else{$newNetwork=$true}
    }
    if($VirtualNetworkId){
        if($newNetwork){throw 'Choose an existing VNet or a new address plan, not both.'}
        $vnet=@($vnets|Where-Object id -eq $VirtualNetworkId)
        if($vnet.Count -ne 1){throw 'Selected VNet was not found in the deployment region.'}
        $jobs=@($vnet[0].subnets|Where-Object {
            @($_.delegations|Where-Object {$_.serviceName -eq 'Microsoft.App/environments' -or $_.properties.serviceName -eq 'Microsoft.App/environments'}).Count -gt 0
        }|ForEach-Object {[pscustomobject]@{Id=$_.id;Name="$($_.name) - $($_.addressPrefix) (Container Apps delegation)"}})
        $job=Select-ClaudeReportOption -Prompt 'Delegated jobs subnet (must be unused by another environment)' -Parameter JobsSubnetId -Options $jobs -SelectedId $JobsSubnetId -NonInteractive:$NonInteractive `
            -WhereToFind @("az network vnet show --ids $VirtualNetworkId --query subnets -o json",'Azure portal: Virtual networks > the selected VNet > Subnets > Microsoft.App/environments delegation')
        $ends=@($vnet[0].subnets|Where-Object {$_.id -ne $job.Id -and -not @($_.delegations|Where-Object {$_}).Count}|ForEach-Object {[pscustomobject]@{Id=$_.id;Name="$($_.name) - $($_.addressPrefix)"}})
        $endpoint=Select-ClaudeReportOption -Prompt 'Private endpoint subnet' -Parameter EndpointSubnetId -Options $ends -SelectedId $EndpointSubnetId -NonInteractive:$NonInteractive `
            -WhereToFind @("az network vnet show --ids $VirtualNetworkId --query subnets -o json",'Azure portal: Virtual networks > the selected VNet > Subnets > an undelegated subnet')
        $JobsSubnetId=$job.Id;$EndpointSubnetId=$endpoint.Id
    } else {
        if(-not $VirtualNetworkPrefix -and -not $NonInteractive){
            Write-Host 'Existing regional address spaces (avoid overlap with networks you will peer):'
            $vnets|ForEach-Object {Write-Host ("  {0}: {1}" -f $_.name,($_.addressSpace.addressPrefixes -join ', '))}
            $VirtualNetworkPrefix=Read-Host 'New VNet private CIDR (no hard-coded default)'
            $JobsSubnetPrefix=Read-Host 'Jobs subnet CIDR (/27 or larger)'
            $EndpointSubnetPrefix=Read-Host 'Private endpoint subnet CIDR (/29 or larger)'
        }
        Get-ClaudeReportNetworkPlan $VirtualNetworkPrefix $JobsSubnetPrefix $EndpointSubnetPrefix | Out-Null
    }
    $zones=@(az network private-dns zone list -o json | ConvertFrom-Json | Where-Object name -eq 'privatelink.blob.core.windows.net')
    if($LASTEXITCODE -ne 0){throw 'Could not discover blob private DNS zones.'}
    if(-not $PrivateDnsZoneId){
        $local=@($zones|Where-Object resourceGroup -eq $ResourceGroup)
        if($NonInteractive){
            if($local.Count -eq 1){$PrivateDnsZoneId=$local[0].id}
            elseif($zones.Count){throw ('Existing blob DNS zones were found: ' + (($zones | ForEach-Object {$_.id}) -join ', ') + '. Pass -PrivateDnsZoneId or choose one interactively. Where to find it: az network private-dns zone list -o table; Azure portal: Private DNS zones > privatelink.blob.core.windows.net > Overview.')}
        } else {
            $options=@([pscustomobject]@{Id='new';Name="Create a blob private DNS zone in $ResourceGroup"})
            $options+=@($zones|ForEach-Object {[pscustomobject]@{Id=$_.id;Name="$($_.name) ($($_.resourceGroup))"}})
            $default=if($local.Count -eq 1){$local[0].id}else{'new'}
            $choice=Select-ClaudeReportOption -Prompt 'Blob private DNS zone' -Parameter PrivateDnsZoneId -Options $options -DefaultId $default `
                -WhereToFind @('az network private-dns zone list -o table','Azure portal: Private DNS zones > privatelink.blob.core.windows.net > Overview')
            if($choice.Id -ne 'new'){$PrivateDnsZoneId=$choice.Id}
        }
    }
    if($PrivateDnsZoneId -and @($zones|Where-Object id -eq $PrivateDnsZoneId).Count -ne 1){throw 'PrivateDnsZoneId was not found in the accessible zone inventory.'}
    $skus=@(az storage sku list -o json | ConvertFrom-Json | Where-Object {$_.name -eq 'Standard_LRS' -and $_.kind -eq 'StorageV2' -and $_.locations -contains $Location})
    if($LASTEXITCODE -ne 0 -or -not $skus.Count){throw 'Standard_LRS StorageV2 is not advertised in this region. Select another region rather than assuming availability.'}
    $profiles=@(az containerapp env workload-profile list-supported -l $Location -o json|ConvertFrom-Json)
    if($LASTEXITCODE -ne 0 -or -not @($profiles|Where-Object name -eq Consumption).Count){throw 'Consumption workload profile was not advertised in this region.'}
    [pscustomobject]@{ExistingVirtualNetworkId=$VirtualNetworkId;ExistingJobsSubnetId=$JobsSubnetId;ExistingEndpointSubnetId=$EndpointSubnetId
        VirtualNetworkPrefix=$VirtualNetworkPrefix;JobsSubnetPrefix=$JobsSubnetPrefix;EndpointSubnetPrefix=$EndpointSubnetPrefix;ExistingPrivateDnsZoneId=$PrivateDnsZoneId}
}
