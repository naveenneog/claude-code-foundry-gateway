# Shared, side-effect-free choice and plan helpers. Azure calls are explicit functions.
. (Join-Path $PSScriptRoot 'AzureRetailPrice.ps1')

function Invoke-ClaudeAumAz {
    param([Parameter(Mandatory)][string[]]$Arguments)
    foreach ($argument in $Arguments) {
        if ($argument -match '[&|]') { throw 'Unsafe Azure CLI argument: use a JSON file or Invoke-RestMethod for query continuations.' }
    }
    $raw = & az @Arguments --only-show-errors 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI failed ($($Arguments[0])): $($raw.Trim())" }
    if ($raw.Trim()) { return ($raw | ConvertFrom-Json) }
}

function New-ClaudeAumLocalFile {
    param([string]$Extension = 'json')
    $folder = Join-Path (Split-Path $PSScriptRoot -Parent) '.aum-local'
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    return (Join-Path $folder ("aum-{0}.{1}" -f [guid]::NewGuid().ToString('N'), $Extension))
}

function Write-ClaudeAumJson {
    param([string]$Path, $Value)
    $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    [IO.File]::WriteAllText($resolved, ($Value | ConvertTo-Json -Depth 30), (New-Object System.Text.UTF8Encoding($false)))
}

function Get-ClaudeAumPrices {
    param([Parameter(Mandatory)][string]$Region)
    $lookup = {
        param($Service, $Meter, $Sku, $Product, $At = $Region)
        $p = Get-AzureRetailPrice -ServiceName $Service -Region $At -MeterName $Meter -SkuName $Sku -ProductName $Product
        if ($null -eq $p) { return $null }
        return [decimal]$p.UnitPrice
    }
    $baseline = & $lookup 'Functions' 'Always Ready Baseline' 'Always Ready' 'Flex Consumption'
    $storage = @{}
    foreach ($sku in @('LRS','ZRS','GRS')) {
        $storage[$sku] = & $lookup 'Storage' "$sku Data Stored" "Standard $sku" 'Tables'
    }
    $pe = & $lookup 'Virtual Network' 'Standard Private Endpoint' '' '' 'Global'
    $dnsPrice = Get-AzureRetailPrice -ServiceName 'Azure DNS' -Region 'Zone 1' -MeterName 'Private Zone' -Tier First
    $dns = if ($null -ne $dnsPrice) { [decimal]$dnsPrice.UnitPrice } else { $null }
    $ingestion = & $lookup 'Log Analytics' 'Analytics Logs Data Ingestion' '' ''
    $execution = & $lookup 'Functions' 'On Demand Execution Time' 'On Demand' 'Flex Consumption'
    $runs = & $lookup 'Functions' 'On Demand Total Executions' 'On Demand' 'Flex Consumption'
    return [pscustomobject]@{
        Region = $Region; PricedAtUtc = [datetime]::UtcNow.ToString('o')
        AlwaysReadyMonthly = $(if ($null -ne $baseline) { $baseline * [decimal]0.5 * 730 * 3600 } else { $null })
        StorageGbMonthly = $storage
        PrivateMonthly = $(if ($null -ne $pe -and $null -ne $dns) { $pe * 730 * 3 + $dns * 3 } else { $null })
        PrivateEndpointHourly = $pe; DnsZoneMonthly = $dns
        InsightsGb = $ingestion; ExecutionGbSecond = $execution; ExecutionsPerTen = $runs
    }
}

function Format-ClaudeAumCost {
    param($Value, [string]$Unit = '/month')
    if ($null -eq $Value) { return "unknown $Unit (Retail API has no verified meter; not zero)" }
    return ('$' + ([decimal]$Value).ToString('0.00####', [Globalization.CultureInfo]::InvariantCulture) + " $Unit USD list price")
}

function Get-ClaudeAumChoices {
    param([Parameter(Mandatory)]$Prices)
    @(
        [pscustomobject]@{ Category='AlwaysReady'; Value=0; Label='0 always-ready instances'; Cost='$0/month fixed compute + executions'; Implications='Scales to zero; the first request after idle has a cold start. Timer executions still bill.' }
        [pscustomobject]@{ Category='AlwaysReady'; Value=1; Label='1 always-ready HTTP instance (512 MiB)'; Cost=(Format-ClaudeAumCost $Prices.AlwaysReadyMonthly); Implications='Reduces HTTP cold starts. Baseline and active execution both bill; no always-ready free grant.' }
        [pscustomobject]@{ Category='Redundancy'; Value='LRS'; Label='Storage LRS'; Cost=(Format-ClaudeAumCost $Prices.StorageGbMonthly.LRS '/GB-month'); Implications='Three local copies. Lowest cost; a regional outage can interrupt approvals and expiry.' }
        [pscustomobject]@{ Category='Redundancy'; Value='ZRS'; Label='Storage ZRS'; Cost=(Format-ClaudeAumCost $Prices.StorageGbMonthly.ZRS '/GB-month'); Implications='Zone-resilient in supported regions; not a second-region service.' }
        [pscustomobject]@{ Category='Redundancy'; Value='GRS'; Label='Storage GRS'; Cost=(Format-ClaudeAumCost $Prices.StorageGbMonthly.GRS '/GB-month'); Implications='Asynchronous region replication; failover can lose recent writes. No automatic Function failover.' }
        [pscustomobject]@{ Category='Insights'; Value='Off'; Label='Application Insights off'; Cost='$0/month added ingestion'; Implications='Durable audit and Azure platform metrics remain; no request tracing in Insights.' }
        [pscustomobject]@{ Category='Insights'; Value='On'; Label='Application Insights on'; Cost=(Format-ClaudeAumCost $Prices.InsightsGb '/GB ingested'); Implications='Identity-authenticated telemetry in the gateway workspace; ingestion/retention bill by usage.' }
        [pscustomobject]@{ Category='Network'; Value='Public'; Label='Public endpoint, Entra-only'; Cost='$0/month private networking'; Implications='Internet-reachable HTTPS, every route checks Entra. Storage shared-key and blob-public access are off.' }
        [pscustomobject]@{ Category='Network'; Value='Private'; Label='Private endpoints'; Cost=(Format-ClaudeAumCost $Prices.PrivateMonthly); Implications='Three endpoints and three DNS zones; requires connected clients, DNS and an integration subnet. VPN/ExpressRoute costs excluded. Does not change the gateway network.' }
    )
}

function Select-ClaudeAumChoice {
    param([Parameter(Mandatory)][string]$Title, [Parameter(Mandatory)][object[]]$Choices, [string]$Selected)
    Write-Host "`n$Title" -ForegroundColor Cyan
    for ($i=0; $i -lt $Choices.Count; $i++) {
        Write-Host ("  {0}. {1} - {2}" -f ($i + 1), $Choices[$i].Label, $Choices[$i].Cost)
        Write-Host ("     {0}" -f $Choices[$i].Implications) -ForegroundColor DarkGray
    }
    if ($Selected) {
        $match = @($Choices | Where-Object { [string]$_.Value -eq $Selected })
        if ($match.Count -ne 1) { throw "No '$Selected' choice in $Title." }
        return $match[0].Value
    }
    $answer = Read-Host 'Choose a number (no default)'
    $number = 0
    if (-not [int]::TryParse($answer, [ref]$number) -or $number -lt 1 -or $number -gt $Choices.Count) { throw 'Choose one of the numbered options.' }
    return $Choices[$number - 1].Value
}

function Get-ClaudeAumReusablePlans {
    param([object[]]$Plans, [string]$Region)
    return @($Plans | Where-Object {
        $count = if ($null -ne $_.numberOfSites) { $_.numberOfSites } else { $_.properties.numberOfSites }
        ($_.location -replace ' ', '') -eq ($Region -replace ' ', '') -and
        $_.sku.name -eq 'FC1' -and $null -ne $count -and [int]$count -eq 0
    })
}

function Get-ClaudeAumDiscovery {
    param([string]$SubscriptionId, [string]$GatewayResourceGroup, [string]$ApimName, [string]$WorkspaceResourceId)
    if (-not $SubscriptionId) {
        $accounts = @(Invoke-ClaudeAumAz @('account','list','-o','json'))
        if (-not $accounts.Count) { throw 'Not signed in. Run: az login' }
        $options = @($accounts | ForEach-Object { [pscustomobject]@{
            Value=$_.id; Label=$_.name; Cost='$0 to select'; Implications='Creates resources and role assignments only in this subscription.'
        } })
        $current = Invoke-ClaudeAumAz @('account','show','-o','json')
        if ($accounts.Count -eq 1) { $SubscriptionId = $accounts[0].id }
        else { $SubscriptionId = Select-ClaudeAumChoice -Title 'Subscription' -Choices $options }
    }
    $account = Invoke-ClaudeAumAz @('account','show','--subscription',$SubscriptionId,'-o','json')
    if (-not $GatewayResourceGroup) { $GatewayResourceGroup = & (Join-Path $PSScriptRoot 'Get-ClaudeGatewayTarget.ps1') ResourceGroup }
    if (-not $ApimName) { $ApimName = & (Join-Path $PSScriptRoot 'Get-ClaudeGatewayTarget.ps1') ApimName }
    $args = @('apim','list','--subscription',$SubscriptionId,'-o','json')
    if ($GatewayResourceGroup) { $args += @('-g',$GatewayResourceGroup) }
    $gateways = @(Invoke-ClaudeAumAz $args)
    if ($ApimName) { $gateways = @($gateways | Where-Object name -eq $ApimName) }
    if (-not $gateways.Count) { throw 'No matching gateway found. Pass -GatewayResourceGroup and -ApimName.' }
    if ($gateways.Count -eq 1) { $gateway = $gateways[0] }
    else {
        $options = @($gateways | ForEach-Object { [pscustomobject]@{
            Value=$_.id; Label="$($_.name) ($($_.resourceGroup), $($_.location))"; Cost='$0 additional gateway cost'; Implications='AUM reads this gateway and changes named values only; never policy or network.'
        } })
        $id = Select-ClaudeAumChoice -Title 'Gateway' -Choices $options
        $gateway = @($gateways | Where-Object id -eq $id)[0]
    }
    if (-not $WorkspaceResourceId) {
        $loggerUrl = "https://management.azure.com$($gateway.id)/loggers?api-version=2024-05-01"
        $loggerResponse = Invoke-ClaudeAumAz @('rest','--method','GET','--url',$loggerUrl,'--subscription',$SubscriptionId,'-o','json')
        $loggers = @($loggerResponse.value | ForEach-Object { $_.properties })
        $insights = @($loggers | Where-Object { $_.loggerType -eq 'applicationInsights' -and $_.resourceId })
        if ($insights.Count -ne 1) { throw 'Gateway telemetry is ambiguous. Pass -WorkspaceResourceId from the gateway Application Insights Properties blade.' }
        $component = Invoke-ClaudeAumAz @('resource','show','--ids',$insights[0].resourceId,'-o','json')
        $WorkspaceResourceId = [string]$component.properties.WorkspaceResourceId
        if (-not $WorkspaceResourceId) { throw 'Gateway Application Insights has no linked Log Analytics workspace.' }
    }
    $workspace = Invoke-ClaudeAumAz @('resource','show','--ids',$WorkspaceResourceId,'-o','json')
    if (-not $workspace.properties.customerId) { throw 'Selected resource is not a Log Analytics workspace.' }
    return @{
        Account=$account; Gateway=$gateway; Workspace=$workspace
        Groups=@(Invoke-ClaudeAumAz @('group','list','--subscription',$SubscriptionId,'-o','json'))
        Locations=@(Invoke-ClaudeAumAz @('functionapp','list-flexconsumption-locations','--subscription',$SubscriptionId,'-o','json'))
        Storage=@(Invoke-ClaudeAumAz @('storage','account','list','--subscription',$SubscriptionId,'-o','json'))
        Plans=@(Invoke-ClaudeAumAz @('appservice','plan','list','--subscription',$SubscriptionId,'-o','json'))
    }
}

function New-ClaudeAumPlan {
    param([hashtable]$Discovery, [string]$ResourceGroup, [string]$Location, [string]$NamePrefix,
          [int]$AlwaysReady, [string]$Redundancy, [string]$Insights, [string]$Network)
    if ($NamePrefix -notmatch '^[a-z][a-z0-9-]{2,25}$') { throw 'NamePrefix must be 3-26 lower-case letters, digits or hyphens, starting with a letter.' }
    if (-not $ResourceGroup -or -not $Location) { throw 'Choose a resource group and location.' }
    return [ordered]@{
        subscriptionId=$Discovery.Account.id; resourceGroup=$ResourceGroup
        parameters=[ordered]@{
            namePrefix=$NamePrefix; location=$Location; tenantId=$Discovery.Account.tenantId
            apimResourceId=$Discovery.Gateway.id; workspaceResourceId=$Discovery.Workspace.id
            workspaceCustomerId=$Discovery.Workspace.properties.customerId
            alwaysReadyInstances=$AlwaysReady; storageRedundancy=$Redundancy
            enableInsights=($Insights -eq 'On'); inboundAccess=$Network.ToLowerInvariant()
        }
    }
}

function Get-ClaudeAumWriterRoleDefinition {
    param([string]$Scope)
    . (Join-Path $PSScriptRoot 'ClaudeTurnstileApply.ps1')
    return Get-ClaudeGovernanceWriterDefinition -Scopes @($Scope)
}

function Set-ClaudeAumWriterRole {
    param([string]$GatewayResourceId)
    $scope = $GatewayResourceId.Substring(0, $GatewayResourceId.IndexOf('/providers/'))
    $definition = Get-ClaudeAumWriterRoleDefinition -Scope $scope
    $existing = @(Invoke-ClaudeAumAz @('role','definition','list','--name',$definition.Name,'--custom-role-only','true','-o','json'))
    if ($existing.Count) {
        $definition['Id'] = $existing[0].name
        $definition.AssignableScopes = @(@($existing[0].assignableScopes) + $scope | Select-Object -Unique)
        $difference = @(Compare-Object @($definition.Actions) @($existing[0].permissions[0].actions))
        if (-not $difference.Count -and @($existing[0].assignableScopes) -contains $scope) { return $existing[0].id }
    }
    $file = New-ClaudeAumLocalFile
    try {
        $roleId = if ($existing.Count) { $existing[0].id } else {
            ($GatewayResourceId.Split('/')[0..2] -join '/') + '/providers/Microsoft.Authorization/roleDefinitions/' + [guid]::NewGuid().ToString()
        }
        $body = @{ properties=@{
            roleName=$definition.Name; description=$definition.Description; type='CustomRole'
            assignableScopes=$definition.AssignableScopes
            permissions=@(@{ actions=$definition.Actions; notActions=@(); dataActions=@(); notDataActions=@() })
        } }
        Write-ClaudeAumJson $file $body
        $role = Invoke-ClaudeAumAz @('rest','--method','PUT','--url',"https://management.azure.com$roleId`?api-version=2022-04-01",
            '--headers','Content-Type=application/json','--body',"@$file",'-o','json')
        return $role.id
    }
    finally { Remove-Item $file -ErrorAction SilentlyContinue }
}

function Get-ClaudeFinOpsChoices {
    param($Prices)
    $serviceCost = $(if ($Prices) { Format-ClaudeAumCost $Prices.StorageGbMonthly.LRS '/GB-month + usage' } else { 'regional Retail API quote at deployment' })
    @(
        [pscustomobject]@{ Id='None'; Label='None'; Cost='$0 added'; Who='Azure administrators use the existing scripts'; Needs='No FinOps application'; Implications='Gateway budgets and telemetry continue without a FinOps console.' }
        [pscustomobject]@{ Id='Direct'; Label='AUM Direct'; Cost='$0 added infrastructure'; Who='Azure admins only'; Needs='Python and Azure RBAC'; Implications='No server; Azure RBAC cannot scope managers to units or teams.' }
        [pscustomobject]@{ Id='AumService'; Label='AUM + AUM service'; Cost=$serviceCost; Who='Admins, viewers and scoped managers'; Needs='Functions, Storage and an owned Entra app'; Implications='Independent of Turnstile; adds audited approvals, temporary boosts and service operations.' }
        [pscustomobject]@{ Id='Turnstile'; Label='Turnstile'; Cost='$58-159/month example; regional quote before deployment'; Who='Admins, viewers and scoped managers'; Needs='Turnstile App Service, PostgreSQL and Entra app'; Implications='Web console and database operations. Choose one budget authority.' }
        [pscustomobject]@{ Id='TurnstileAum'; Label='Turnstile + AUM'; Cost='$58-159/month example; AUM client adds $0 infrastructure'; Who='Admins, viewers and scoped managers through Turnstile'; Needs='Turnstile plus the AUM client'; Implications='AUM uses the Turnstile API; no AUM service required. Server capabilities decide which workflows appear.' }
    )
}
