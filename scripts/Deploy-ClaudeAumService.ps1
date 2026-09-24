<#
.SYNOPSIS
    Discovers, prices and deploys the optional AUM authority, independently of Turnstile.
.DESCRIPTION
    Every cost/operational choice is shown before confirmation. -WhatIf performs
    discovery and pricing only: no app, resource, role, token or package is created.
    Re-running with the same resource group and prefix updates the same service.
    No gateway policy or network is changed. Use -DiscoveryOnly for inventory.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
param(
    [string]$SubscriptionId, [string]$GatewayResourceGroup, [string]$ApimName,
    [string]$WorkspaceResourceId, [string]$ResourceGroup, [string]$Location,
    [string]$NamePrefix, [string]$ClientId, [string]$AppDisplayName = 'AUM',
    [ValidateSet('0','1')][string]$AlwaysReady,
    [ValidateSet('LRS','ZRS','GRS')][string]$Redundancy,
    [ValidateSet('On','Off')][string]$Insights,
    [ValidateSet('Public','Private')][string]$Network,
    [string]$ExistingStorageName, [string]$ExistingPlanName,
    [string]$IntegrationSubnetId, [string]$PrivateEndpointSubnetId,
    [string]$SitesDnsZoneId, [string]$BlobDnsZoneId, [string]$TableDnsZoneId,
    [switch]$DiscoveryOnly, [switch]$Accept, [switch]$SkipCodeDeploy
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'ClaudeAumDeployment.ps1')
$discovery = Get-ClaudeAumDiscovery -SubscriptionId $SubscriptionId -GatewayResourceGroup $GatewayResourceGroup -ApimName $ApimName -WorkspaceResourceId $WorkspaceResourceId
if ($DiscoveryOnly) { return $discovery }
$SubscriptionId = $discovery.Account.id
$regionChoices = @($discovery.Locations | ForEach-Object {
    [pscustomobject]@{ Value=$_.name; Label=$_.name; Cost='regional quote follows selection'; Implications='Flex Consumption availability; choose near the gateway and permitted data residency.' }
})
if (-not $Location) {
    $Location = Select-ClaudeAumChoice -Title 'Function region (no location is assumed)' -Choices $regionChoices
}
elseif (@($discovery.Locations | Where-Object name -eq $Location).Count -ne 1) { throw "Flex Consumption is not available in '$Location'." }
$prices = Get-ClaudeAumPrices -Region $Location
$choices = @(Get-ClaudeAumChoices -Prices $prices)
$AlwaysReady = [string](Select-ClaudeAumChoice 'Always-ready HTTP capacity' @($choices | Where-Object Category -eq 'AlwaysReady') $AlwaysReady)
$Redundancy = Select-ClaudeAumChoice 'Storage redundancy (per actual GB stored)' @($choices | Where-Object Category -eq 'Redundancy') $Redundancy
$Insights = Select-ClaudeAumChoice 'Application Insights' @($choices | Where-Object Category -eq 'Insights') $Insights
$Network = Select-ClaudeAumChoice 'Network' @($choices | Where-Object Category -eq 'Network') $Network
if (-not $ResourceGroup) {
    $groupChoices = @([pscustomobject]@{ Value='new'; Label='New isolated resource group'; Cost='$0 group overhead'; Implications='Recommended; clean removal without touching the gateway.' })
    $groupChoices += @($discovery.Groups | ForEach-Object { [pscustomobject]@{
        Value=$_.name; Label="Existing: $($_.name)"; Cost='$0 group overhead'; Implications='Shares resource lifecycle. Remove the service resources only, not the whole group.'
    } })
    $ResourceGroup = Select-ClaudeAumChoice 'Resource group' $groupChoices
    if ($ResourceGroup -eq 'new') { $ResourceGroup = Read-Host 'New resource group name' }
}
if (-not $NamePrefix) { $NamePrefix = Read-Host 'Unique service name prefix (3-26 lowercase letters/digits/hyphens)' }

Write-Host "`nDiscovered storage accounts: $(@($discovery.Storage).Count); Function/App Service plans: $(@($discovery.Plans).Count)" -ForegroundColor Cyan
Write-Host '  1. Dedicated service storage and Flex plan - selected unless an eligible reuse parameter is supplied.'
Write-Host '     No always-on plan charge; storage charged by GB and operations. Other apps are never modified.'
$reusable = @(Get-ClaudeAumReusablePlans -Plans $discovery.Plans -Region $Location)
foreach ($p in $reusable) { Write-Host "  Reusable empty FC1 plan: $($p.name). Pass -ExistingPlanName; must be in the selected group." }
foreach ($s in @($discovery.Storage | Where-Object { $_.tags.component -eq 'aum-service' })) {
    Write-Host "  Service-owned storage: $($s.name). Pass -ExistingStorageName only for this AUM deployment."
}
if ($ExistingPlanName) {
    $match = @($reusable | Where-Object { $_.name -eq $ExistingPlanName -and $_.resourceGroup -eq $ResourceGroup })
    if ($match.Count -ne 1) { throw 'ExistingPlanName must be an empty FC1 plan in the selected region and resource group.' }
}
if ($ExistingStorageName) {
    $match = @($discovery.Storage | Where-Object { $_.name -eq $ExistingStorageName -and $_.resourceGroup -eq $ResourceGroup -and
        $_.tags.component -eq 'aum-service' -and $_.tags.'aum-gateway' -eq $discovery.Gateway.id -and
        $_.tags.'aum-function' -eq "func-aum-$NamePrefix" -and $_.allowSharedKeyAccess -eq $false -and
        $_.sku.name -eq "Standard_$Redundancy" -and
        $_.publicNetworkAccess -eq $(if ($Network -eq 'Private') { 'Disabled' } else { 'Enabled' }) })
    if ($match.Count -ne 1) { throw 'Reuse requires this same service and gateway, keyless storage in the selected group, and matching redundancy/network. Shared accounts are not modified.' }
}
if ($Network -eq 'Private') {
    foreach ($name in @('IntegrationSubnetId','PrivateEndpointSubnetId','SitesDnsZoneId','BlobDnsZoneId','TableDnsZoneId')) {
        if (-not (Get-Variable $name -ValueOnly)) { throw "Private networking requires -$name. Supply service subnets and linked private DNS; no gateway topology is changed." }
    }
}
$plan = New-ClaudeAumPlan -Discovery $discovery -ResourceGroup $ResourceGroup -Location $Location -NamePrefix $NamePrefix -AlwaysReady ([int]$AlwaysReady) -Redundancy $Redundancy -Insights $Insights -Network $Network
$plan.parameters.existingStorageName = $ExistingStorageName
$plan.parameters.existingPlanName = $ExistingPlanName
$plan.parameters.integrationSubnetId = $IntegrationSubnetId
$plan.parameters.privateEndpointSubnetId = $PrivateEndpointSubnetId
$plan.parameters.sitesDnsZoneId = $SitesDnsZoneId
$plan.parameters.blobDnsZoneId = $BlobDnsZoneId
$plan.parameters.tableDnsZoneId = $TableDnsZoneId
Write-Host "`nConfirmation summary" -ForegroundColor Cyan
Write-Host "  Subscription: $SubscriptionId"
Write-Host "  Gateway: $($discovery.Gateway.id)"
Write-Host "  Workspace: $($discovery.Workspace.id)"
Write-Host "  Service: $ResourceGroup / func-aum-$NamePrefix / $Location"
Write-Host "  Always ready: $AlwaysReady; redundancy: $Redundancy; Insights: $Insights; network: $Network"
Write-Host "  Storage: $(Format-ClaudeAumCost $prices.StorageGbMonthly[$Redundancy] '/GB-month') plus operations"
Write-Host "  Compute while active: $(Format-ClaudeAumCost $prices.ExecutionGbSecond '/GB-second')"
Write-Host '  Entra app owner only; no tenant administrator/consent. Assigns the CLI account AUM.Admin.'
Write-Host '  Grants the service named-value writer on this gateway, Logs Reader on this workspace, data roles on its own storage.'
Write-Host '  No policy/network edits. Budget changes are approximate gateway brakes, not hard money guarantees.'
Write-Host '  Named-value capacity remains 4,096 characters; 500,000 individual overrides require P48.'
if (-not $Accept -and -not $WhatIfPreference) {
    if ((Read-Host 'Type DEPLOY to create these resources and roles') -cne 'DEPLOY') { throw 'Cancelled. Nothing created.' }
}
if (-not $PSCmdlet.ShouldProcess("$ResourceGroup/func-aum-$NamePrefix", 'Deploy the priced AUM service and role assignments')) {
    return [pscustomobject]@{ WhatIf=$true; Plan=$plan; Prices=$prices }
}
$app = & (Join-Path $PSScriptRoot 'New-ClaudeAumEntraApp.ps1') -DisplayName $AppDisplayName -ClientId $ClientId -Confirm:$false
$plan.parameters.clientId = $app.ClientId
$plan.parameters.writerRoleDefinitionId = Set-ClaudeAumWriterRole -GatewayResourceId $discovery.Gateway.id
$exists = Invoke-ClaudeAumAz @('group','exists','--name',$ResourceGroup,'--subscription',$SubscriptionId,'-o','json')
if (-not $exists) {
    Invoke-ClaudeAumAz @('group','create','--name',$ResourceGroup,'--location',$Location,'--subscription',$SubscriptionId,'--tags','component=aum-service','-o','json') | Out-Null
}
$file = New-ClaudeAumLocalFile
$zip = New-ClaudeAumLocalFile -Extension 'zip'
try {
    $parameters = [ordered]@{}
    foreach ($key in @($plan.parameters.Keys)) { $parameters[$key] = @{ value=$plan.parameters[$key] } }
    Write-ClaudeAumJson $file @{ '$schema'='https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'; contentVersion='1.0.0.0'; parameters=$parameters }
    $deployment = Invoke-ClaudeAumAz @('deployment','group','create','--name',"aum-$NamePrefix",'--resource-group',$ResourceGroup,'--subscription',$SubscriptionId,
        '--template-file',(Join-Path $root 'infra\aum-service.bicep'),'--parameters',"@$file",'-o','json')
    $outputs = $deployment.properties.outputs
    $record = [ordered]@{
        schemaVersion=1; subscriptionId=$SubscriptionId; resourceGroup=$ResourceGroup; location=$Location
        functionName=$outputs.functionName.value; endpoint=$outputs.endpoint.value; storageName=$outputs.storageName.value
        planName=$outputs.planName.value; principalId=$outputs.principalId.value; clientId=$app.ClientId
        tenantId=$app.TenantId; applicationObjectId=$app.ApplicationObjectId; servicePrincipalId=$app.ServicePrincipalId
        scope=$app.Scope; gatewayResourceId=$discovery.Gateway.id; workspaceResourceId=$discovery.Workspace.id
        roleAssignmentIds=$outputs.roleAssignmentIds.value; resourceGroupCreated=(-not $exists)
        storageReused=[bool]$ExistingStorageName; planReused=[bool]$ExistingPlanName
        choices=@{ alwaysReady=[int]$AlwaysReady; redundancy=$Redundancy; insights=$Insights; network=$Network }
        prices=$prices; deployedAtUtc=[datetime]::UtcNow.ToString('o')
    }
    $recordPath = Join-Path $root 'onboarding\aum-service.json'
    New-Item -ItemType Directory -Path (Split-Path $recordPath -Parent) -Force | Out-Null
    Write-ClaudeAumJson $recordPath $record
    if (-not $SkipCodeDeploy) {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $source = Join-Path $root 'service\aum'
        $archive = [IO.Compression.ZipFile]::Open($zip, 'Create')
        try {
            foreach ($entry in @(Get-ChildItem $source -Recurse -File | Where-Object { $_.FullName -notmatch '__pycache__|\.pyc$' })) {
                $relative = $entry.FullName.Substring($source.Length + 1).Replace('\','/')
                [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $entry.FullName, $relative) | Out-Null
            }
        }
        finally { $archive.Dispose() }
        Invoke-ClaudeAumAz @('functionapp','deployment','source','config-zip','--name',$record.functionName,'--resource-group',$ResourceGroup,
            '--subscription',$SubscriptionId,'--src',$zip,'--build-remote','true','--timeout','1200','-o','json') | Out-Null
    }
    Write-Host "`nService: $($record.endpoint)" -ForegroundColor Green
    Write-Host "Scope: $($record.scope)"
    Write-Host "Removal: .\scripts\Remove-ClaudeAumService.ps1 -RecordPath '$recordPath'"
    [pscustomobject]$record
}
finally {
    Remove-Item $file -ErrorAction SilentlyContinue
    Remove-Item $zip -ErrorAction SilentlyContinue
}
