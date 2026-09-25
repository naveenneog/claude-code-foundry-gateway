[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory=$true)][string]$StatePath,
    [Parameter(Mandatory=$true)][ValidateRange(1,90)][int]$LookbackDays,
    [string[]]$PrivateClientCidrs=@(),
    [switch]$RestoreFoundryPublicAccess,
    [switch]$AsJson
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'ClaudeNetwork.ps1')
. (Join-Path $PSScriptRoot 'ClaudeNetworkImpact.ps1')
. (Join-Path $PSScriptRoot 'ClaudeNetworkPricing.ps1')
. (Join-Path $PSScriptRoot 'ClaudeNetworkDecisions.ps1')
. (Join-Path $PSScriptRoot 'ClaudeNetworkReview.ps1')
$StatePath=Get-ClaudeNetworkLocalPath $StatePath
$state=Get-Content $StatePath -Raw|ConvertFrom-Json
if($state.Version -ne 1){throw 'Unsupported state file.'}
if($state.Removed){Write-Host 'Already removed; no change or cost delta is planned.';return}
$apim=Invoke-ClaudeNetworkArm "https://management.azure.com$($state.ApimId)?api-version=2024-05-01"
$region=($apim.location -replace ' ','').ToLowerInvariant()
$book=Get-ClaudeNetworkRateBook $region
$actions=@();$costs=@();$snapshots=@();$records=@($state.OwnedResources)
$snapshots+=@([pscustomobject]@{Id=$state.ApimId;Etag=$apim.etag;ApiVersion='2024-05-01'})
if($state.VnetSelection -eq 'new'){
    $nsgs=Get-ClaudeNetworkOwnedNsgs -VnetId $state.VnetId -ResourceGroupId "/subscriptions/$($state.SubscriptionId)/resourceGroups/$($state.ResourceGroup)" -OwnerId $state.OwnerId
    foreach($nsg in $nsgs){if(@($records|Where-Object id -eq $nsg.id).Count -eq 0){$records+=@($nsg)}}
}
foreach($record in $records){
    $resource=Invoke-ClaudeNetworkArm "https://management.azure.com$($record.id)?api-version=$($record.apiVersion)" -AllowNotFound
    if(-not $resource){continue}
    if($record.kind -eq 'role'){if($resource.properties.principalId -ne $record.principalId){throw 'Role identity differs from the state.'}}
    else{Assert-ClaudeNetworkOwnership $resource $state.OwnerId}
    $actions+=[pscustomobject]@{Verb='Remove';Target=$record.id;Property=$resource.type;Before='owned existing resource';After='deleted (vault soft-delete retention remains)';DecisionKey='remove-owned-edge';AccessReducing=$true}
    $snapshots+=[pscustomobject]@{Id=$record.id;Etag=$resource.etag;ApiVersion=$record.apiVersion}
    $key=switch -Regex ($record.id){
        '/applicationGateways/[^/]+$' {'appgw.fixed';break}
        '/publicIPAddresses/[^/]+$' {'public-ip';break}
        '/privateEndpoints/[^/]+$' {'private-endpoint';break}
        '/privateDnsZones/[^/]+$' {'dns-zone';break}
        '/containerGroups/[^/]+$' {'verifier.cpu';break}
        default {'configuration'}
    }
    $costs+=New-ClaudeNetworkCostItem $record.id $resource.type $book.Rates[$key] 1 0
    if($key -eq 'appgw.fixed'){$cu=10*[int]$resource.properties.autoscaleConfiguration.minCapacity;$costs+=New-ClaudeNetworkCostItem ($record.id+'/capacity') 'Configured WAF capacity removed' $book.Rates['appgw.cu'] $cu 0}
    if($key -eq 'verifier.cpu'){$memory=0;foreach($c in $resource.properties.containers){$memory+=[decimal]$c.properties.resources.requests.memoryInGB};$costs+=New-ClaudeNetworkCostItem ($record.id+'/memory') 'Verifier memory removed' $book.Rates['verifier.memory'] $memory 0}
}
$actions+=[pscustomobject]@{Verb='Change';Target=$state.ApimId;Property='network/public access and owned service-policy block';Before=$apim.properties.virtualNetworkType+'/'+$apim.properties.publicNetworkAccess;After=$state.OriginalApimNetwork.virtualNetworkType+'/'+$state.OriginalApimNetwork.publicNetworkAccess;DecisionKey='restore-gateway';AccessReducing=$true}
if($RestoreFoundryPublicAccess){$actions+=[pscustomobject]@{Verb='Change';Target=$state.FoundryId;Property='publicNetworkAccess';Before='discovered current state';After=$state.FoundryOriginalPublicAccess;DecisionKey='restore-foundry';AccessReducing=$true}}
$impact=Get-ClaudeNetworkImpact -ApimId $state.ApimId -LookbackDays $LookbackDays -PrivateClientCidrs $PrivateClientCidrs -Actions @('EdgeRemoval')
$decisions=@(
    [pscustomobject]@{Key='remove-owned-edge';Title='Remove only the recorded owned edge';Selected=(New-ClaudeNetworkDecisionOption remove 'Remove recorded edge; retain shared resources' $costs (New-ClaudeNetworkImplications 'Removes WAF/edge connectivity, not the gateway authorization controls.' 'Clients must migrate to the reviewed remaining endpoint.' 'Edge URLs stop serving; coordinate a change window and drain active sessions.' 'Delete owned resources in dependency order and wait for Azure transitions.' 'Every client still using the edge hostname can stop working.' 'Redeploy from a new reviewed state; a soft-deleted vault is not automatically purged.' 'Exact state, live owner tags, historical impact acknowledgement and verified remaining client/backend paths.') remove)},
    [pscustomobject]@{Key='restore-gateway';Title='Restore the recorded gateway state';Selected=(New-ClaudeNetworkDecisionOption original 'Restore original gateway network/policy' @((New-ClaudeNetworkCostItem 'restore/configuration' 'Access configuration' $book.Rates.configuration 1 1)) (New-ClaudeNetworkImplications 'Restores the recorded exposure, which may be broader than the edge-only state.' 'Returns to the original VNet/public-access model.' 'A network transition can take time; wait before deleting subnets.' 'Review original values and consumer reachability rather than assuming rollback is outage-free.' 'Private backends can become unreachable when integration is removed; clients need the correct URL.' 'Reapply a reviewed edge/network plan; no deleted dependency is silently recreated.' 'Explicit RestoreApim approval and unmodified snapshot of the original state.') original)}
)
if($RestoreFoundryPublicAccess){$decisions+=[pscustomobject]@{Key='restore-foundry';Title='Restore Foundry public access';Selected=(New-ClaudeNetworkDecisionOption original 'Restore recorded Foundry access' @((New-ClaudeNetworkCostItem 'foundry/restore' 'Access setting' $book.Rates.configuration 1 1)) (New-ClaudeNetworkImplications 'Restores the original public/private data-plane setting; Entra permissions remain.' 'May re-enable public access or close a changed public path.' 'Direct clients and other gateways must be reviewed.' 'Coordinate every consumer of the shared account.' 'Consumers outside the restored path can lose access.' 'Reapply the reviewed current state, subject to Azure Policy.' 'Explicit RestoreFoundryPublicAccess and acknowledgement of direct-consumer blind spots.') original)}}
$parameters=@{StatePath=$StatePath;StateFingerprint=(Get-ClaudeNetworkReviewFingerprint (Get-Content $StatePath -Raw));RestoreApim=$true;RestoreFoundryPublicAccess=[bool]$RestoreFoundryPublicAccess;LookbackDays=$LookbackDays}
$review=New-ClaudeNetworkReview -Region $region -Decisions $decisions -Actions $actions -CostItems $costs -Impact $impact -Parameters $parameters -Snapshots $snapshots -Warnings @('This removal does not delete a shared resource group, purge a vault or remove the separately installed gateway. Variable usage costs are not represented as guaranteed savings.')
if($AsJson){$review|ConvertTo-Json -Depth 90}else{Show-ClaudeNetworkReview $review;$review}
