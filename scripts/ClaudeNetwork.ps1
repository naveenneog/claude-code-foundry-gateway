# Shared discovery and validation. Importing this file performs no Azure writes.
function Invoke-ClaudeNetworkAz {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    foreach ($arg in $Arguments) {
        if ($arg -match '[&|<>\r\n]') { throw 'Unsafe Azure CLI argument. Send JSON in a file; use the ARM helper for paged URLs.' }
    }
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & az @Arguments --only-show-errors --output json 2>&1
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $saved }
    if ($code -ne 0) { throw "Azure CLI failed ($code): $($output -join "`n")" }
    if ($output) { return (($output -join "`n") | ConvertFrom-Json) }
}

function Invoke-ClaudeNetworkArm {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [ValidateSet('get','put','patch','delete','post')][string]$Method = 'get',
        [object]$Body,
        [string]$StateDirectory,
        [switch]$AllowNotFound
    )
    if ($Url -notmatch '^https://management\.azure\.com/(subscriptions|providers)/') { throw 'Expected an Azure Resource Manager URL.' }
    $file = $null
    try {
        # az rest has no bounded connect timeout on the measured CLI version.
        # Keep authentication in az, but bound ARM transport and never pass
        # continuation URLs or policy expressions through cmd.exe.
        if (-not $script:ClaudeNetworkTokens) { $script:ClaudeNetworkTokens = @{} }
        $scope = if ($Url -match '/subscriptions/([^/]+)/') { $Matches[1] } else { 'current' }
        $cached = $script:ClaudeNetworkTokens[$scope]
        if (-not $cached -or [DateTime]::UtcNow -ge $cached.refresh) {
            $tokenArgs = @('account','get-access-token','--resource','https://management.azure.com')
            if ($scope -ne 'current') { $tokenArgs += @('--subscription',$scope) }
            $token = Invoke-ClaudeNetworkAz $tokenArgs
            $cached = @{token=$token.accessToken;refresh=[DateTime]::UtcNow.AddMinutes(5)}
            $script:ClaudeNetworkTokens[$scope] = $cached
        }
        $request = @{Method=$Method;Uri=$Url;Headers=@{Authorization="Bearer $($cached.token)"};TimeoutSec=45;ErrorAction='Stop'}
        if ($null -ne $Body) {
            if (-not $StateDirectory -or -not (Test-Path $StateDirectory -PathType Container)) { throw 'A local state directory is required for ARM request files.' }
            $file = Join-Path $StateDirectory ('request-' + [guid]::NewGuid().ToString('N') + '.json')
            [IO.File]::WriteAllText($file, ($Body | ConvertTo-Json -Depth 100), (New-Object Text.UTF8Encoding $false))
            $request.Body = [IO.File]::ReadAllBytes($file)
            $request.ContentType = 'application/json; charset=utf-8'
        }
        for ($attempt=0; $attempt -lt 3; $attempt++) {
            try { return Invoke-RestMethod @request }
            catch {
                $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
                if ($Method -eq 'post' -or $attempt -eq 2 -or ($status -ne 0 -and $status -ne 429 -and $status -lt 500)) { throw }
                Start-Sleep -Seconds (2 + 2*$attempt)
            }
        }
    }
    catch {
        $httpStatus = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
        if ($AllowNotFound -and ($httpStatus -eq 404 -or $_.Exception.Message -match 'ResourceNotFound|ResourceGroupNotFound|NotFound|could not be found|\(404\)|404.*Not Found')) { return $null }
        throw
    }
    finally { if ($file) { Remove-Item $file -Force -ErrorAction SilentlyContinue } }
}

function Get-ClaudeNetworkPages {
    param([string]$Url)
    $all = @()
    $seen = @{}
    while ($Url) {
        if ($seen.ContainsKey($Url)) { throw 'Azure discovery returned a repeated continuation link.' }
        $seen[$Url] = $true
        $page = Invoke-ClaudeNetworkArm -Url $Url
        $all += @($page.value)
        $Url = $page.nextLink
    }
    return ,$all
}

function Select-ClaudeNetworkOption {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][object[]]$Options,
        [string]$SelectedId,
        [string]$RecommendedId,
        [string]$Prompt,
        [switch]$NonInteractive
    )
    if (-not $Options.Count) { throw "No $Prompt options were discovered. Check scope, permissions and prerequisites." }
    if ($SelectedId) {
        $chosen = @($Options | Where-Object { $_.id -eq $SelectedId })
        if ($chosen.Count -ne 1) { throw "$Prompt '$SelectedId' was not uniquely discovered. Refresh discovery or correct the parameter." }
        return $chosen[0]
    }
    if ($NonInteractive) {
        if ($Options.Count -eq 1) { return $Options[0] }
        throw "Select $Prompt explicitly; $($Options.Count) real options are available."
    }
    $default = 1
    Write-Host "`n$Prompt" -ForegroundColor Cyan
    for ($i = 0; $i -lt $Options.Count; $i++) {
        $recommended = $Options[$i].id -eq $RecommendedId
        if ($recommended) { $default = $i + 1 }
        Write-Host ("  {0}. {1}{2}" -f ($i + 1),$Options[$i].label,$(if ($recommended) { ' [recommended]' }))
        if ($Options[$i].consequence) { Write-Host "     $($Options[$i].consequence)" -ForegroundColor DarkGray }
    }
    while ($true) {
        $answer = Read-Host "Choose 1-$($Options.Count) [$default]"
        if (-not $answer) { $answer = "$default" }
        $number = 0
        if ([int]::TryParse($answer, [ref]$number) -and $number -ge 1 -and $number -le $Options.Count) { return $Options[$number - 1] }
        Write-Warning 'Enter one of the displayed numbers.'
    }
}

function Test-ClaudeNetworkInventoryFresh {
    param([object]$RetrievedUtc,[datetime]$NowUtc = [DateTime]::UtcNow)
    # PS 7 can deserialize ISO dates as DateTime; PS 5.1 returns a string.
    # Parsing the former's culture-formatted string loses its UTC kind.
    $retrieved = if ($RetrievedUtc -is [datetime]) { $RetrievedUtc.ToUniversalTime() }
        else { [DateTime]::Parse([string]$RetrievedUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime() }
    $age = $NowUtc.ToUniversalTime() - $retrieved
    return ($age -ge [TimeSpan]::FromMinutes(-5) -and $age -le [TimeSpan]::FromMinutes(30))
}

function Get-ClaudeNetworkStableGuid {
    param([string]$Value)
    $hash = [Security.Cryptography.SHA256]::Create()
    try { $bytes = $hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value)) }
    finally { $hash.Dispose() }
    return [guid]::new([byte[]]$bytes[0..15]).ToString()
}

function ConvertFrom-ClaudeNetworkNumber {
    param([uint64]$Number)
    return ((24,16,8,0 | ForEach-Object { [math]::Floor($Number / [math]::Pow(2,$_)) % 256 }) -join '.')
}

function Get-ClaudeNetworkCidr {
    param([Parameter(Mandatory = $true)][string]$Cidr)
    $parts = $Cidr.Split('/')
    $ip = $null
    if ($parts.Count -ne 2 -or -not [Net.IPAddress]::TryParse($parts[0], [ref]$ip) -or $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { throw "Expected an IPv4 CIDR: $Cidr" }
    $prefix = 0
    if (-not [int]::TryParse($parts[1], [ref]$prefix) -or $prefix -lt 0 -or $prefix -gt 32) { throw "Invalid IPv4 prefix: $Cidr" }
    $bytes = $ip.GetAddressBytes()
    [uint64]$n = ([uint64]$bytes[0] * 16777216) + ([uint64]$bytes[1] * 65536) + ([uint64]$bytes[2] * 256) + $bytes[3]
    [uint64]$size = [math]::Pow(2,32-$prefix)
    [uint64]$first = [math]::Floor($n / $size) * $size
    if ($first -ne $n) { throw "CIDR must use its network address, not host bits: $Cidr" }
    return [pscustomobject]@{ First=$first; Last=($first+$size-1); Size=$size; Prefix=$prefix; Cidr=$Cidr }
}

function Test-ClaudeNetworkOverlap {
    param([string]$Left,[string]$Right)
    $a = Get-ClaudeNetworkCidr $Left
    $b = Get-ClaudeNetworkCidr $Right
    return ($a.First -le $b.Last -and $b.First -le $a.Last)
}

function Test-ClaudeNetworkPrivateAddress {
    param([string]$Address)
    try { $hostRange = Get-ClaudeNetworkCidr "$Address/32" } catch { return $false }
    foreach ($cidr in @('10.0.0.0/8','172.16.0.0/12','192.168.0.0/16')) {
        $range = Get-ClaudeNetworkCidr $cidr
        if ($hostRange.First -ge $range.First -and $hostRange.Last -le $range.Last) { return $true }
    }
    return $false
}

function Get-ClaudeNetworkFreePrefix {
    param([string[]]$Existing, [ValidateRange(16,28)][int]$PrefixLength = 22, [int]$Count = 5)
    $used = @($Existing | Where-Object { $_ -notmatch ':' } | ForEach-Object { Get-ClaudeNetworkCidr $_ })
    $found = @()
    [uint64]$step = [math]::Pow(2,32-$PrefixLength)
    foreach ($space in @('10.0.0.0/8','172.16.0.0/12','192.168.0.0/16')) {
        $block = Get-ClaudeNetworkCidr $space
        [uint64]$cursor = $block.First
        while ($cursor + $step - 1 -le $block.Last -and $found.Count -lt $Count) {
            $overlap = @($used | Where-Object { $_.First -le $cursor+$step-1 -and $_.Last -ge $cursor } | Sort-Object Last)
            if ($overlap.Count) { $cursor = [uint64]([math]::Floor($overlap[-1].Last / $step) + 1) * $step; continue }
            $found += "$(ConvertFrom-ClaudeNetworkNumber $cursor)/$PrefixLength"
            $cursor += $step
        }
        if ($found.Count -ge $Count) { break }
    }
    return ,$found
}

function Get-ClaudeApimNetworkCapability {
    param([string]$Sku,[string]$NetworkMode = 'None')
    return [pscustomobject]@{
        Sku = $Sku
        ClaudeTokenMetering = $Sku -in @('BasicV2','StandardV2','PremiumV2')
        PrivateEndpoint = $Sku -in @('Developer','Basic','Standard','Premium','StandardV2','PremiumV2')
        OutboundIntegration = $Sku -in @('StandardV2','PremiumV2')
        Injection = $Sku -in @('Developer','Premium','PremiumV2')
        Internal = $NetworkMode -eq 'Internal'
        InjectionAtCreationOnly = $Sku -eq 'PremiumV2'
    }
}

function Assert-ClaudeNetworkSku {
    param([string]$Sku,[ValidateSet('private','public','hybrid')][string]$Profile)
    $cap = Get-ClaudeApimNetworkCapability $Sku
    if (-not $cap.ClaudeTokenMetering) { throw 'Claude token governance requires an APIM v2 SKU; classic tiers do not meter Anthropic tokens.' }
    if ($Profile -ne 'public' -and -not $cap.OutboundIntegration) { throw 'Private and hybrid profiles require StandardV2 or PremiumV2; BasicV2 cannot reach private backends.' }
    return $true
}

function Get-ClaudeNetworkSkuLocation {
    param([object[]]$Skus,[string]$Sku)
    $locations = @()
    foreach ($row in @($Skus | Where-Object { $_.name -eq $Sku })) {
        foreach ($location in $row.locations) {
            $denied = @($row.restrictions | Where-Object { $_.type -eq 'Location' -and ($_.values -contains $location -or $_.restrictionInfo.locations -contains $location) })
            if (-not $denied.Count) { $locations += $location }
        }
    }
    return ,@($locations | Sort-Object -Unique)
}

function Assert-ClaudeNetworkWafExclusions {
    param([object[]]$Exclusions,$RuleSet)
    foreach ($exclusion in $Exclusions) {
        if ($exclusion.matchVariable -ne 'RequestArgValues' -or $exclusion.selectorMatchOperator -notin @('Equals','StartsWith') -or -not $exclusion.selector -or $exclusion.selector -eq '*') {
            throw 'Use specific Claude argument values with Equals or StartsWith; header, cookie and all-argument exemptions are not automated.'
        }
        if (-not $exclusion.exclusionManagedRuleSets) { throw 'An exclusion must name individual managed rules.' }
        foreach ($set in $exclusion.exclusionManagedRuleSets) {
            if ($set.ruleSetType -ne $RuleSet.ruleSetType -or $set.ruleSetVersion -ne $RuleSet.ruleSetVersion) { throw 'Exclusions must target the selected discovered managed rule set.' }
            if (-not $set.ruleGroups) { throw 'An exclusion must name individual managed rules.' }
            foreach ($group in $set.ruleGroups) {
                if (-not $group.rules) { throw 'An exclusion must name individual rules, not exempt an entire rule group.' }
                $discovered = @($RuleSet.ruleGroups | Where-Object { $_.ruleGroupName -eq $group.ruleGroupName })
                if ($discovered.Count -ne 1) { throw 'The exclusion names a rule group not discovered in this rule set.' }
                foreach ($rule in $group.rules) {
                    if (-not $rule.ruleId -or @($discovered[0].rules | Where-Object { [string]$_.ruleId -eq [string]$rule.ruleId }).Count -ne 1) { throw 'The exclusion names an individual rule not discovered in this group.' }
                }
            }
        }
    }
    return $true
}

function Get-ClaudeNetworkInventory {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$SubscriptionId,[string[]]$DiscoverySubscriptionId = @())
    if ($SubscriptionId -notmatch '^[0-9a-fA-F-]{36}$') { throw 'Invalid subscription ID.' }
    $base = "https://management.azure.com/subscriptions/$SubscriptionId"
    $resources = @()
    $groups = @()
    $subscriptions = Invoke-ClaudeNetworkAz @('account','list')
    foreach ($scope in @(@($SubscriptionId) + @($DiscoverySubscriptionId) | Sort-Object -Unique)) {
        if (@($subscriptions | Where-Object { $_.id -eq $scope -and $_.state -eq 'Enabled' }).Count -ne 1) { throw "Discovery subscription '$scope' is not an enabled visible subscription." }
        $items = Get-ClaudeNetworkPages "$('https://management.azure.com/subscriptions')/$scope/resources?api-version=2021-04-01"
        $resources += $items
        $items = Get-ClaudeNetworkPages "$('https://management.azure.com/subscriptions')/$scope/resourcegroups?api-version=2022-09-01"
        $groups += $items
    }
    $hydrate = @{
        'Microsoft.Network/virtualNetworks' = '2024-05-01'
        'Microsoft.Network/azureFirewalls' = '2024-05-01'
        'Microsoft.Network/routeTables' = '2024-05-01'
        'Microsoft.Network/publicIPAddresses' = '2024-05-01'
        'Microsoft.Network/applicationGateways' = '2024-05-01'
        'Microsoft.Network/ApplicationGatewayWebApplicationFirewallPolicies' = '2024-05-01'
        'Microsoft.ApiManagement/service' = '2024-05-01'
        'Microsoft.CognitiveServices/accounts' = '2024-10-01'
        'Microsoft.KeyVault/vaults' = '2023-07-01'
        'Microsoft.OperationalInsights/workspaces' = '2023-09-01'
        'Microsoft.Network/privateDnsZones' = '2020-06-01'
    }
    $detailed = @()
    foreach ($resource in $resources) {
        if ($hydrate.ContainsKey($resource.type)) {
            $detailed += Invoke-ClaudeNetworkArm "https://management.azure.com$($resource.id)?api-version=$($hydrate[$resource.type])"
        }
    }
    $locations = Get-ClaudeNetworkPages "$base/locations?api-version=2022-12-01"
    $skus = Get-ClaudeNetworkPages "$base/providers/Microsoft.ApiManagement/skus?api-version=2024-05-01"
    $rules = Get-ClaudeNetworkPages "$base/providers/Microsoft.Network/applicationGatewayAvailableWafRuleSets?api-version=2024-05-01"
    $provider = Invoke-ClaudeNetworkArm "$base/providers/Microsoft.Network?api-version=2021-04-01"
    $feature = Invoke-ClaudeNetworkArm "$base/providers/Microsoft.Features/providers/Microsoft.Network/features/EnableApplicationGatewayNetworkIsolation?api-version=2021-07-01"
    return [pscustomobject]@{
        RetrievedUtc = [DateTime]::UtcNow.ToString('o')
        SubscriptionId = $SubscriptionId
        Subscriptions = @($subscriptions)
        ResourceGroups = $groups
        Resources = $resources
        DetailedResources = $detailed
        Locations = $locations
        ApimSkus = $skus
        WafRuleSets = $rules
        GatewayLocations = @($provider.resourceTypes | Where-Object { $_.resourceType -eq 'applicationGateways' } | ForEach-Object { $_.locations })
        NetworkIsolation = $feature.properties.state
    }
}

function Get-ClaudeNetworkResourceOptions {
    param($Inventory,[string]$Type,[string]$Location,[string]$Consequence)
    $options = @()
    foreach ($r in @($Inventory.DetailedResources | Where-Object { $_.type -eq $Type })) {
        if ($Location -and ($r.location -replace ' ','').ToLowerInvariant() -ne ($Location -replace ' ','').ToLowerInvariant()) { continue }
        $options += [pscustomobject]@{ id=$r.id; label="$($r.name) | $($r.location) | $($r.sku.name)"; consequence=$Consequence; value=$r }
    }
    return ,$options
}

function Assert-ClaudeNetworkOwnership {
    param($Resource,[string]$OwnerId)
    if ($null -eq $Resource) { return }
    if (-not $OwnerId -or $Resource.tags.'claude-network-owner' -ne $OwnerId) {
        throw 'Resource is not owned by this network-edge state. Refusing to overwrite or delete a shared resource.'
    }
}

function Write-ClaudeNetworkState {
    param([object]$State,[string]$Path)
    $full = Get-ClaudeNetworkLocalPath $Path
    $directory = Split-Path $full -Parent
    if (-not (Test-Path $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $staged = Join-Path $directory ('state-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        [IO.File]::WriteAllText($staged, ($State | ConvertTo-Json -Depth 100), (New-Object Text.UTF8Encoding $false))
        Move-Item $staged $full -Force
    }
    finally { if (Test-Path $staged) { Remove-Item $staged -Force } }
}

function Get-ClaudeNetworkLocalPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Remove-ClaudeNetworkOwnedResource {
    param($Resource,[string]$OwnerId,[ValidateRange(0,60)][int]$RetryDelaySeconds = 5)
    $url = "https://management.azure.com$($Resource.id)?api-version=$($Resource.apiVersion)"
    $deadline = [DateTime]::UtcNow.AddMinutes(15)
    $issued = $false
    do {
        $live = Invoke-ClaudeNetworkArm $url -AllowNotFound
        if (-not $live) { return }
        if ($Resource.kind -eq 'role') {
            if ($live.properties.principalId -ne $Resource.principalId) { throw 'Role assignment principal changed; refusing removal.' }
        }
        else { Assert-ClaudeNetworkOwnership $live $OwnerId }
        if (-not $issued) {
            try { [void](Invoke-ClaudeNetworkArm $url -Method delete); $issued=$true }
            catch {
                $detail = "$($_.Exception.Message) $($_.ErrorDetails.Message)"
                if ($detail -notmatch 'CannotDeleteResource|InUse|AnotherOperationInProgress') { throw }
                # A deleted link can return 404 before its parent's delete
                # constraint clears. Retry this owned parent, not its children.
            }
        }
        Start-Sleep -Seconds $RetryDelaySeconds
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Owned-resource deletion has not completed. Keep the state and re-run; inspect any remaining references instead of force-deleting shared dependencies.'
}

function Get-ClaudeNetworkOwnedNsgs {
    param([string]$VnetId,[string]$ResourceGroupId,[string]$OwnerId)
    $vnet=Invoke-ClaudeNetworkArm "https://management.azure.com${VnetId}?api-version=2024-05-01" -AllowNotFound
    $owned=@()
    if (-not $vnet) { return ,$owned }
    foreach ($id in @($vnet.properties.subnets | ForEach-Object { $_.properties.networkSecurityGroup.id } | Where-Object { $_ } | Sort-Object -Unique)) {
        if (-not $id.StartsWith("$ResourceGroupId/providers/Microsoft.Network/networkSecurityGroups/",[StringComparison]::OrdinalIgnoreCase)) { continue }
        $nsg=Invoke-ClaudeNetworkArm "https://management.azure.com${id}?api-version=2024-05-01"
        if ($nsg.tags.'claude-network-owner' -eq $OwnerId) { $owned += [pscustomobject]@{id=$id;apiVersion='2024-05-01';kind='tag';principalId=''} }
    }
    return ,$owned
}

function Wait-ClaudeNetworkResourceReady {
    param([string]$ResourceId,[string]$ApiVersion,[ValidateRange(0,60)][int]$RetryDelaySeconds = 10)
    $deadline=[DateTime]::UtcNow.AddMinutes(30)
    do {
        $live=Invoke-ClaudeNetworkArm "https://management.azure.com${ResourceId}?api-version=$ApiVersion"
        if ($live.properties.provisioningState -eq 'Succeeded') { return $live }
        if ($live.properties.provisioningState -in @('Failed','Canceled','Deleting')) { throw "Resource is $($live.properties.provisioningState); inspect the deployment before continuing." }
        Start-Sleep -Seconds $RetryDelaySeconds
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Resource is still transitioning after 30 minutes. No dependent write or deletion was attempted.'
}

function Invoke-ClaudeNetworkDeployment {
    param([string]$SubscriptionId,[string]$ResourceGroup,[string]$Name,[string]$Template,[hashtable]$Parameters,[string]$StateDirectory)
    $values = @{}
    foreach ($key in $Parameters.Keys) { $values[$key] = @{ value = $Parameters[$key] } }
    $path = Join-Path $StateDirectory ('parameters-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        [IO.File]::WriteAllText($path, (@{ '$schema'='https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'; contentVersion='1.0.0.0'; parameters=$values } | ConvertTo-Json -Depth 100), (New-Object Text.UTF8Encoding $false))
        return Invoke-ClaudeNetworkAz @('deployment','group','create','--subscription',$SubscriptionId,'--resource-group',$ResourceGroup,'--name',$Name,'--template-file',$Template,'--parameters',('@'+$path),'--mode','Incremental')
    }
    finally { Remove-Item $path -Force -ErrorAction SilentlyContinue }
}
