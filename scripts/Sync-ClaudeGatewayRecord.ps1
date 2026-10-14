<#
.SYNOPSIS
    Regenerates onboarding/claude-gateway.json from a live gateway without changing Azure.

.DESCRIPTION
    Reads one API Management gateway, its Claude API backend, non-secret named values and
    Foundry Claude deployments. Values Azure does not own are preserved from the existing
    record or supplied explicitly. The only write is the local decision record.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)][string]$ResourceGroup,
    [Parameter(Mandatory = $true)][string]$ApimName,
    [string]$RecordPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'onboarding\claude-gateway.json'),
    [string]$StandardGroup,
    [string]$PremiumGroup
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'flow\FlowContract.ps1')
. (Join-Path $PSScriptRoot 'ClaudeModelDeployment.ps1')
. (Join-Path $PSScriptRoot 'ClaudeEntitlementGroups.ps1')
. (Join-Path $PSScriptRoot 'ClaudeGatewayRegion.ps1')

function Assert-ClaudeRecordSyncSafeName {
    param([Parameter(Mandatory = $true)][string]$Value, [Parameter(Mandatory = $true)][string]$Label)
    if ($Value -notmatch '^[A-Za-z0-9._-]{1,90}$') {
        throw "$Label must be a safe Azure resource name containing only letters, digits, periods, underscores or hyphens. Nothing was read or written."
    }
}

function Invoke-ClaudeRecordSyncAz {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$What,
        [switch]$Array
    )
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Azure CLI (az) is required.' }
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $global:LASTEXITCODE = 0
        $output = @(& az @Arguments -o json --only-show-errors 2>&1)
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $saved }
    if ($code -ne 0) {
        $detail = @($output | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ }) -join ' '
        throw "$What failed (az exit $code). $detail"
    }
    $text = @($output | ForEach-Object { [string]$_ }) -join "`n"
    if (-not $text -or ($Array -and -not $text.TrimStart().StartsWith('[')) -or
        (-not $Array -and -not $text.TrimStart().StartsWith('{'))) {
        throw "$What returned an invalid JSON $(if ($Array) { 'array' } else { 'object' })."
    }
    try { return ($text | ConvertFrom-Json) }
    catch { throw "$What returned JSON that could not be read: $($_.Exception.Message)" }
}

function ConvertFrom-ClaudeRecordSyncModelList {
    param([Parameter(Mandatory = $true)][string]$Value, [Parameter(Mandatory = $true)][string]$Tier)
    if ($Value -notmatch '^,.*,$' -or $Value -match '\s') {
        throw "models-$Tier needs comma sentinels and no whitespace."
    }
    $items = @($Value.Trim(',') -split ',' | Where-Object { $_ })
    foreach ($item in $items) {
        if ($item -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { throw "models-$Tier contains an unsafe deployment name '$item'." }
    }
    if ($Value -ne ',,' -and (',' + ($items -join ',') + ',') -ne $Value) {
        throw "models-$Tier contains an empty or duplicate separator."
    }
    return @(Sort-ClaudeFlowOrdinal -InputObject $items -Unique)
}

function ConvertTo-ClaudeRecordSyncInt {
    param([hashtable]$NamedValues, [Parameter(Mandatory = $true)][string]$Name)
    $parsed = 0
    if (-not $NamedValues.ContainsKey($Name) -or
        -not [int]::TryParse([string]$NamedValues[$Name], [Globalization.NumberStyles]::Integer,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed) -or $parsed -lt 1) {
        throw "Named value '$Name' must be a positive integer before the onboarding record can be generated."
    }
    return $parsed
}

function Get-ClaudeRecordSyncGroupName {
    param([Parameter(Mandatory = $true)][string]$Id)
    if ($Id -eq 'none') { return 'none' }
    $group = Invoke-ClaudeRecordSyncAz -Arguments @('ad','group','show','--group',$Id) -What "Reading Entra group $Id"
    if (-not $group.id -or -not $group.displayName -or -not [string]::Equals([string]$group.id, $Id, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Entra group '$Id' did not resolve to one matching group."
    }
    return [string]$group.displayName
}

function Get-ClaudeRecordSyncGatewayUrl {
    param($Gateway, $Existing)
    $default = ([string]$Gateway.gatewayUrl).TrimEnd('/') + '/claude'
    if (-not $Existing -or -not $Existing.gatewayUrl) { return $default }
    $uri = $null
    if (-not [uri]::TryCreate([string]$Existing.gatewayUrl, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -ne 'https' -or $uri.Port -ne 443 -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) {
        return $default
    }
    $configured = @($Gateway.hostnameConfigurations | Where-Object {
            $_.type -eq 'Proxy' -and [string]::Equals([string]$_.hostName, $uri.DnsSafeHost, [StringComparison]::OrdinalIgnoreCase)
        }).Count -eq 1
    return $(if ($configured) { ([string]$Existing.gatewayUrl).TrimEnd('/') } else { $default })
}

Assert-ClaudeRecordSyncSafeName -Value $ResourceGroup -Label 'ResourceGroup'
Assert-ClaudeRecordSyncSafeName -Value $ApimName -Label 'ApimName'
$RecordPath = Resolve-ClaudeFlowFilePath $RecordPath
$existing = if (Test-Path -LiteralPath $RecordPath -PathType Leaf) { Read-ClaudeDecisionRecord -Path $RecordPath } else { $null }
if ($existing) {
    $foundation = if ($existing.decisions -and $existing.decisions.foundation) { $existing.decisions.foundation } else { $null }
    $existingGroup = if ($existing.resourceGroup) { [string]$existing.resourceGroup } elseif ($foundation -and $foundation.resourceGroup) { [string]$foundation.resourceGroup } else { '' }
    $existingApim = if ($existing.apimName) { [string]$existing.apimName } elseif ($foundation -and $foundation.apimName) { [string]$foundation.apimName } else { '' }
    if (($existingGroup -and -not [string]::Equals($existingGroup, $ResourceGroup, [StringComparison]::OrdinalIgnoreCase)) -or
        ($existingApim -and -not [string]::Equals($existingApim, $ApimName, [StringComparison]::OrdinalIgnoreCase))) {
        throw "The existing record describes '$existingGroup/$existingApim', not '$ResourceGroup/$ApimName'. Use that gateway or a different -RecordPath. Nothing was read or written."
    }
}
$recordSubscription = if ($existing) { Get-ClaudeFlowRecordSubscription -Record $existing } else { '' }
$accountArgs = @('account','show')
if (Test-ClaudeFlowSubscriptionId $recordSubscription) { $accountArgs += @('--subscription', $recordSubscription) }
$account = Invoke-ClaudeRecordSyncAz -Arguments $accountArgs -What 'Reading the selected Azure account'
$subscriptionId = if ($recordSubscription) { $recordSubscription } else { [string]$account.id }
if (-not (Test-ClaudeFlowSubscriptionId $subscriptionId)) { throw 'The selected Azure subscription must be a GUID.' }
$scope = @('--subscription', $subscriptionId)

$gateway = Invoke-ClaudeRecordSyncAz -Arguments (@('apim','show','-g',$ResourceGroup,'-n',$ApimName) + $scope) -What "Reading gateway $ResourceGroup/$ApimName"
$expectedId = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.ApiManagement/service/$ApimName"
if (-not $gateway.id -or -not [string]::Equals(([string]$gateway.id).TrimEnd('/'), $expectedId, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Gateway discovery returned '$($gateway.id)', not the requested gateway '$expectedId'."
}
if (-not $gateway.gatewayUrl -or -not $gateway.sku.name -or -not $gateway.location) {
    throw 'Gateway discovery returned no gateway URL, SKU or location.'
}

$api = Invoke-ClaudeRecordSyncAz -Arguments (@('apim','api','show','-g',$ResourceGroup,'--service-name',$ApimName,'--api-id','claude-foundry') + $scope) -What 'Reading the Claude API backend'
$backend = $null
if (-not [uri]::TryCreate([string]$api.serviceUrl, [UriKind]::Absolute, [ref]$backend) -or
    $backend.Scheme -ne 'https' -or $backend.AbsolutePath.TrimEnd('/') -ne '/anthropic' -or
    $backend.DnsSafeHost -notmatch '^([A-Za-z0-9][A-Za-z0-9-]*)\.services\.ai\.azure\.com$') {
    throw "The Claude API backend '$($api.serviceUrl)' is not a Foundry Anthropic endpoint."
}
$foundryAccount = $Matches[1]
Assert-ClaudeRecordSyncSafeName -Value $foundryAccount -Label 'Foundry account'

$resources = @(Invoke-ClaudeRecordSyncAz -Arguments (@('resource','list','--name',$foundryAccount,'--resource-type','Microsoft.CognitiveServices/accounts') + $scope) -What "Locating Foundry account $foundryAccount" -Array)
$resources = @($resources | Where-Object { $_.name -eq $foundryAccount })
if ($resources.Count -ne 1 -or -not $resources[0].resourceGroup) {
    throw "Foundry backend '$foundryAccount' did not resolve to exactly one Cognitive Services account in subscription $subscriptionId."
}
$foundryResourceGroup = [string]$resources[0].resourceGroup
Assert-ClaudeRecordSyncSafeName -Value $foundryResourceGroup -Label 'Foundry resource group'

$rows = @(Invoke-ClaudeRecordSyncAz -Arguments (@('apim','nv','list','-g',$ResourceGroup,'--service-name',$ApimName) + $scope) -What 'Reading non-secret gateway settings' -Array)
$named = @{}
foreach ($row in $rows) {
    $properties = if ($row.PSObject.Properties.Name -contains 'properties' -and $row.properties) { $row.properties } else { $row }
    if ($properties.secret) { continue }
    $name = [string]$row.name
    if (-not $name) { continue }
    if ($named.ContainsKey($name)) { throw "Named value '$name' was returned more than once." }
    $named[$name] = [string]$properties.value
}

$tenantId = if ($named['tenant-id']) { [string]$named['tenant-id'] } else { [string]$account.tenantId }
if (-not (Test-ClaudeFlowSubscriptionId $tenantId)) { throw "The gateway tenant id '$tenantId' is not a GUID." }
if ($account.tenantId -and -not [string]::Equals([string]$account.tenantId, $tenantId, [StringComparison]::OrdinalIgnoreCase)) {
    throw "The selected Azure account tenant '$($account.tenantId)' differs from the gateway tenant '$tenantId'."
}

$rawGroups = @{}
if ($named.ContainsKey('entitlement-groups')) {
    $rawGroupValue = [string]$named['entitlement-groups']
    $rawGroups = ConvertFrom-ClaudeEntitlementGroups $rawGroupValue
    if (@($rawGroupValue -split ',').Count -ne 2 -or
        -not $rawGroups.ContainsKey('standard') -or -not $rawGroups.ContainsKey('premium')) {
        throw "Named value 'entitlement-groups' must contain one valid standard group object id and one valid premium group object id or none."
    }
}
$resolvedStandard = if ($StandardGroup) { $StandardGroup } elseif ($rawGroups['standard']) {
    Get-ClaudeRecordSyncGroupName -Id $rawGroups['standard']
} elseif ($existing -and $existing.standardGroup) { [string]$existing.standardGroup } else { '' }
$resolvedPremium = if ($PSBoundParameters.ContainsKey('PremiumGroup')) { $(if ($PremiumGroup) { $PremiumGroup } else { 'none' }) } elseif ($rawGroups.ContainsKey('premium')) {
    Get-ClaudeRecordSyncGroupName -Id $rawGroups['premium']
} elseif ($existing -and $existing.premiumGroup) { [string]$existing.premiumGroup } else { 'none' }
if (-not $resolvedStandard) {
    throw 'The live gateway does not record entitlement-groups and no existing standardGroup is available. Pass -StandardGroup <group name or object id>. Nothing was written.'
}
if ([string]::Equals($resolvedStandard, $resolvedPremium, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The standard and premium group values must differ. Nothing was written.'
}

$rawDeployments = @(Invoke-ClaudeRecordSyncAz -Arguments (@('cognitiveservices','account','deployment','list','-g',$foundryResourceGroup,'-n',$foundryAccount) + $scope) -What 'Reading Foundry Claude deployments' -Array)
Assert-ClaudeDeploymentIdentities -Deployments $rawDeployments
$deployments = @(Sort-ClaudeFlowOrdinal -InputObject @($rawDeployments |
        ConvertTo-FlatDeployment |
        Where-Object { $_.state -eq 'Succeeded' } |
        Where-Object { $_.model -like '*claude*' -or $_.format -eq 'Anthropic' }) -Key { [string]$_.name })
if (-not $deployments.Count) { throw 'The Foundry account has no succeeded Claude deployment to record.' }
$duplicateNames = @($deployments | Group-Object name | Where-Object Count -gt 1 | ForEach-Object Name)
if ($duplicateNames.Count) { throw "Foundry discovery returned duplicate deployment name(s): $($duplicateNames -join ', ')." }
$liveNames = @($deployments | ForEach-Object { [string]$_.name })
$location = ConvertTo-ClaudeArmRegionName ([string]$gateway.location)

$tierModels = @{}
$tierRaw = @{}
foreach ($tier in 'standard','premium') {
    $id = "models-$tier"
    if (-not $named.ContainsKey($id)) { throw "Missing named value '$id'; no tier model access is assumed." }
    $tierRaw[$tier] = [string]$named[$id]
    $listed = @(ConvertFrom-ClaudeRecordSyncModelList -Value $tierRaw[$tier] -Tier $tier)
    $tierModels[$tier] = if ($listed.Count) { $listed } else { $liveNames }
    $missing = @($tierModels[$tier] | Where-Object { $_ -notin $liveNames })
    if ($missing.Count) { throw "models-$tier names deployment(s) not found in the live succeeded Claude set: $($missing -join ', ')." }
}

$record = if ($existing) { Copy-ClaudeFlowValue $existing } else { [pscustomobject]@{} }
$recordedDeployments = @($deployments | ForEach-Object {
        [pscustomobject][ordered]@{
            name = [string]$_.name
            model = [string]$_.model
            version = [string]$_.version
            sku = [string]$_.sku
            capacity = [int]$_.capacity
        }
    })
$gatewayUrl = Get-ClaudeRecordSyncGatewayUrl -Gateway $gateway -Existing $existing
$entitlementStore = if ($named['entitlement-source']) { [string]$named['entitlement-source'] } else { 'named-value' }
if ($entitlementStore -notin @('named-value','projection')) { throw "Unsupported entitlement-source '$entitlementStore'." }

foreach ($pair in ([ordered]@{
        mode = 'gateway'
        gatewayUrl = $gatewayUrl
        tenantId = $tenantId
        apimName = $ApimName
        resourceGroup = $ResourceGroup
        subscriptionId = $subscriptionId
        sku = [string]$gateway.sku.name
        location = $location
        foundryAccount = $foundryAccount
        foundryResourceGroup = $foundryResourceGroup
        standardGroup = $resolvedStandard
        premiumGroup = $resolvedPremium
        authMode = $(if ($existing -and $existing.authMode) { [string]$existing.authMode } else { 'interactive' })
        entitlementStore = $entitlementStore
        resolverInboundAccess = $(if ($existing -and $existing.resolverInboundAccess) { [string]$existing.resolverInboundAccess } else { 'private' })
        projectionDeployer = './scripts/Deploy-ClaudeProjection.ps1'
        deployments = $recordedDeployments
        models = $liveNames
        tiers = [pscustomobject][ordered]@{
            standard = [pscustomobject][ordered]@{
                tokensPerMinute = ConvertTo-ClaudeRecordSyncInt -NamedValues $named -Name 'tpm-standard'
                tokensPerDay = ConvertTo-ClaudeRecordSyncInt -NamedValues $named -Name 'quota-standard'
                models = @($tierModels.standard)
                modelAllowList = $tierRaw.standard
            }
            premium = [pscustomobject][ordered]@{
                tokensPerMinute = ConvertTo-ClaudeRecordSyncInt -NamedValues $named -Name 'tpm-premium'
                tokensPerDay = ConvertTo-ClaudeRecordSyncInt -NamedValues $named -Name 'quota-premium'
                models = @($tierModels.premium)
                modelAllowList = $tierRaw.premium
            }
        }
        organisation = [pscustomobject][ordered]@{
            tokensPerMonth = ConvertTo-ClaudeRecordSyncInt -NamedValues $named -Name 'quota-org'
            shared = $true
            softCap = $true
        }
        requestsPerMinute = ConvertTo-ClaudeRecordSyncInt -NamedValues $named -Name 'calls-per-minute'
        generated = [DateTime]::Now.ToString('yyyy-MM-dd HH:mm')
    }).GetEnumerator()) {
    Set-ClaudeRecordProperty $record $pair.Key $pair.Value
}
if (-not $record.desktopSignIn) { Set-ClaudeRecordProperty $record 'desktopSignIn' ([pscustomobject]@{ kind = 'helper-script' }) }
Set-ClaudeDecision -Record $record -Key foundation -Value ([pscustomobject][ordered]@{
        subscriptionId = $subscriptionId
        resourceGroup = $ResourceGroup
        apimName = $ApimName
        sku = [string]$gateway.sku.name
        location = $location
        foundryAccount = $foundryAccount
        foundryResourceGroup = $foundryResourceGroup
        standardGroup = $resolvedStandard
        premiumGroup = $resolvedPremium
        entitlementStore = $entitlementStore
    })
$release = Get-ClaudeFlowReleaseInfo
Set-ClaudeDecisionRelease -Record $record -Version $release.version -Commit $release.commit
Add-ClaudeDecisionHistory -Record $record -Action Sync -Decision onboardingRecord -From $(if ($existing) { 'existing' } else { 'absent' }) -To 2 -Commit $release.commit

$backupPath = $null
if ($PSCmdlet.ShouldProcess($RecordPath, 'write synchronized gateway onboarding record')) {
    if ($existing) {
        $leaf = [IO.Path]::GetFileNameWithoutExtension($RecordPath)
        $backupPath = Join-Path (Split-Path $RecordPath -Parent) ("$leaf.before-sync-$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ'))-$([guid]::NewGuid().ToString('N').Substring(0,8)).json")
        Copy-Item -LiteralPath $RecordPath -Destination $backupPath
    }
    Write-ClaudeDecisionRecord -Record $record -Path $RecordPath
    Write-Host "Synchronized record: $RecordPath" -ForegroundColor Green
    if ($backupPath) { Write-Host "Previous record:     $backupPath" -ForegroundColor DarkGray }
}

[pscustomobject]@{
    RecordPath = $RecordPath
    BackupPath = $backupPath
    ResourceGroup = $ResourceGroup
    ApimName = $ApimName
    FoundryAccount = $foundryAccount
    Models = $liveNames
}
