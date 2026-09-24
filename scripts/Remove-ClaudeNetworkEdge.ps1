<#
.SYNOPSIS
    Restores the selected APIM and removes only resources owned by an edge state.
.DESCRIPTION
    Never deletes a resource group. Shared DNS zones, vaults, policies, networks,
    public IPs and workspaces are retained. Owner tags and role principals are
    re-read before deletion. Key Vault soft deletion is not purged.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)][string]$StatePath,
    [switch]$RestoreApim,
    [switch]$RestoreFoundryPublicAccess
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ClaudeNetwork.ps1')
. (Join-Path $PSScriptRoot 'ClaudeNetworkPolicy.ps1')
$StatePath = Get-ClaudeNetworkLocalPath $StatePath
$state = Get-Content $StatePath -Raw | ConvertFrom-Json
$directory = Split-Path $StatePath -Parent
if ($state.Version -ne 1 -or -not $state.OwnerId -or -not $state.ApimId) { throw 'Invalid network-edge state.' }
if ($state.Removed) { Write-Host 'The edge was already removed.'; return }
if (-not $RestoreApim) { throw 'Pass -RestoreApim to confirm restoring the previous APIM public access and integration before the edge is deleted.' }
if ($state.VnetSelection -eq 'new') {
    $rgId="/subscriptions/$($state.SubscriptionId)/resourceGroups/$($state.ResourceGroup)"
    $policyNsgs=Get-ClaudeNetworkOwnedNsgs -VnetId $state.VnetId -ResourceGroupId $rgId -OwnerId $state.OwnerId
    foreach ($nsg in $policyNsgs) {
        if (@($state.OwnedResources | Where-Object id -eq $nsg.id).Count -eq 0) { $state.OwnedResources=@($nsg)+@($state.OwnedResources) }
    }
}
$liveResources = @{}
foreach ($resource in $state.OwnedResources) {
    $live = Invoke-ClaudeNetworkArm "https://management.azure.com$($resource.id)?api-version=$($resource.apiVersion)" -AllowNotFound
    if ($resource.kind -eq 'role') {
        if ($live -and $live.properties.principalId -ne $resource.principalId) { throw 'Role assignment principal changed; refusing removal.' }
    }
    else { Assert-ClaudeNetworkOwnership -Resource $live -OwnerId $state.OwnerId }
    $liveResources[$resource.id] = $live
}
$apim = Invoke-ClaudeNetworkArm "https://management.azure.com$($state.ApimId)?api-version=2024-05-01"
$currentSubnet = $apim.properties.virtualNetworkConfiguration.subnetResourceId
$originalSubnet = $state.OriginalApimNetwork.virtualNetworkConfiguration.subnetResourceId
if ($currentSubnet -and $currentSubnet -ne $originalSubnet -and -not $currentSubnet.StartsWith($state.VnetId+'/',[StringComparison]::OrdinalIgnoreCase)) { throw 'APIM network changed outside this edge. Resolve the drift before removal.' }
if (-not $PSCmdlet.ShouldProcess($state.GatewayId,'Restore the selected APIM and delete only manifest-owned edge resources')) { return }
Write-ClaudeNetworkState $state $StatePath
$apim=Wait-ClaudeNetworkResourceReady -ResourceId $state.ApimId -ApiVersion '2024-05-01'
$policy = Invoke-ClaudeNetworkArm "https://management.azure.com$($state.ApimId)/policies/policy?api-version=2024-05-01" -AllowNotFound
if ($policy -and $policy.properties.value.Contains("claude-network-edge:$($state.OwnerId):begin")) {
    $restored = Remove-ClaudeNetworkPolicyText -Policy $policy.properties.value -EdgeId $state.OwnerId
    [void](Invoke-ClaudeNetworkArm "https://management.azure.com$($state.ApimId)/policies/policy?api-version=2024-05-01" -Method put -Body @{properties=@{format='rawxml';value=$restored}} -StateDirectory $directory)
}
$previous = $state.OriginalApimNetwork
$network = @{publicNetworkAccess=$previous.publicNetworkAccess;virtualNetworkType=$previous.virtualNetworkType;virtualNetworkConfiguration=$previous.virtualNetworkConfiguration}
if ($apim.properties.publicNetworkAccess -ne $previous.publicNetworkAccess -or $apim.properties.virtualNetworkType -ne $previous.virtualNetworkType -or $apim.properties.virtualNetworkConfiguration.subnetResourceId -ne $originalSubnet) {
    [void](Invoke-ClaudeNetworkArm "https://management.azure.com$($state.ApimId)?api-version=2024-05-01" -Method patch -Body @{properties=$network} -StateDirectory $directory)
    [void](Wait-ClaudeNetworkResourceReady -ResourceId $state.ApimId -ApiVersion '2024-05-01')
}
if ($RestoreFoundryPublicAccess) {
    [void](Invoke-ClaudeNetworkArm "https://management.azure.com$($state.FoundryId)?api-version=2024-10-01" -Method patch -Body @{properties=@{publicNetworkAccess=$state.FoundryOriginalPublicAccess}} -StateDirectory $directory)
}
$resources = @($state.OwnedResources)
[array]::Reverse($resources)
foreach ($resource in $resources) {
    if (-not $liveResources[$resource.id]) { continue }
    Remove-ClaudeNetworkOwnedResource -Resource $resource -OwnerId $state.OwnerId
    Write-Host ('Removed ' + (($resource.id -split '/providers/')[-1] -split '/')[0])
}
$state.Removed = $true
$state.Applied = $false
$state | Add-Member -NotePropertyName RemovedUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
Write-ClaudeNetworkState $state $StatePath
Write-Host 'Owned resources removed. The resource group and every shared resource remain; a deleted test vault stays recoverable for its retention period.'
