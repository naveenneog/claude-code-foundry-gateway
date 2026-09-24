# Numbered choices follow the installer: configured/active choices are defaults, not guesses.
function Invoke-ClaudeReportAzOptional {
    param([scriptblock]$Command)
    $saved=$ErrorActionPreference;$ErrorActionPreference='Continue'
    try {$value=& $Command 2>$null;if($LASTEXITCODE -ne 0){return $null};return $value}
    catch {return $null}
    finally {$ErrorActionPreference=$saved}
}

function Select-ClaudeReportOption {
    param([string]$Prompt,[object[]]$Options,[string]$SelectedId,[string]$DefaultId,[switch]$NonInteractive,
        [scriptblock]$ReadSelection={param($label,$default) Read-Host "$label [$default]"})
    $items=@($Options | Where-Object {$null -ne $_})
    if(-not $items.Count){throw "No $Prompt options were discovered."}
    if($SelectedId){
        $match=@($items|Where-Object {$_.Id -eq $SelectedId -or $_.Name -eq $SelectedId})
        if($match.Count -ne 1){throw "$Prompt selection was not found or is not unique."}
        return $match[0]
    }
    $default=0
    for($i=0;$i -lt $items.Count;$i++){if($DefaultId -and $items[$i].Id -eq $DefaultId){$default=$i;break}}
    if($NonInteractive){
        if($items.Count -eq 1 -or ($DefaultId -and @($items|Where-Object Id -eq $DefaultId).Count -eq 1)){return $items[$default]}
        throw "$Prompt is ambiguous. Supply an explicit parameter or run the numbered picker interactively."
    }
    Write-Host "`n$Prompt" -ForegroundColor Cyan
    for($i=0;$i -lt $items.Count;$i++){Write-Host ("  {0}. {1}{2}" -f ($i+1),$items[$i].Name,$(if($i -eq $default){' (default)'}else{''}))}
    $answer=& $ReadSelection 'Choose a number' ($default+1)
    if([string]::IsNullOrWhiteSpace($answer)){return $items[$default]}
    $number=0
    if(-not [int]::TryParse([string]$answer,[ref]$number)){throw 'Enter a number from the discovered list.'}
    if($number -lt 1 -or $number -gt $items.Count){throw 'The selected number is outside the discovered range.'}
    return $items[$number-1]
}

function Resolve-ClaudeReportTarget {
    param([string]$ResourceGroup,[string]$ApimName,[string]$SubscriptionId,[switch]$NonInteractive)
    if($ResourceGroup -and $ApimName -and -not $SubscriptionId){
        return [pscustomobject]@{ResourceGroup=$ResourceGroup;ApimName=$ApimName;SubscriptionId=$null}
    }
    $current=az account show -o json 2>$null | ConvertFrom-Json
    if($LASTEXITCODE -ne 0 -or -not $current){throw 'Not signed in. Run az login before discovery.'}
    $accounts=@(az account list -o json | ConvertFrom-Json | Where-Object state -eq Enabled)
    if($LASTEXITCODE -ne 0){throw 'Could not discover accessible subscriptions.'}
    $options=@($accounts|ForEach-Object {[pscustomobject]@{Id=$_.id;Name="$($_.name) ($($_.id))"}})
    $sub=Select-ClaudeReportOption -Prompt Subscription -Options $options -SelectedId $SubscriptionId -DefaultId $current.id -NonInteractive:$NonInteractive
    if($sub.Id -ne $current.id){az account set --subscription $sub.Id;if($LASTEXITCODE -ne 0){throw 'Could not select the subscription.'}}
    $gateways=@(az apim list -o json | ConvertFrom-Json)
    if($LASTEXITCODE -ne 0){throw 'Could not discover API Management gateways.'}
    $groups=@($gateways|Select-Object -ExpandProperty resourceGroup -Unique|Sort-Object|ForEach-Object {[pscustomobject]@{Id=$_;Name=$_}})
    $group=Select-ClaudeReportOption -Prompt 'Gateway resource group' -Options $groups -SelectedId $ResourceGroup -NonInteractive:$NonInteractive
    $options=@($gateways|Where-Object resourceGroup -eq $group.Id|ForEach-Object {[pscustomobject]@{Id=$_.name;Name="$($_.name) - $($_.location), $($_.sku.name)"}})
    $gateway=Select-ClaudeReportOption -Prompt Gateway -Options $options -SelectedId $ApimName -NonInteractive:$NonInteractive
    [pscustomobject]@{ResourceGroup=$group.Id;ApimName=$gateway.Id;SubscriptionId=$sub.Id}
}

function Get-ClaudeReportIpv4Range {
    param([string]$Prefix)
    if($Prefix -notmatch '^(\d{1,3}\.){3}\d{1,3}/\d{1,2}$'){throw 'Use an IPv4 CIDR network prefix.'}
    $parts=$Prefix.Split('/')
    $address=$null
    if(-not [Net.IPAddress]::TryParse($parts[0],[ref]$address) -or $address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork){throw 'Invalid IPv4 address.'}
    $length=[int]$parts[1]
    if($length -lt 1 -or $length -gt 32){throw 'Invalid IPv4 prefix length.'}
    [uint64]$start=0
    foreach($byte in $address.GetAddressBytes()){$start=$start*256+$byte}
    [uint64]$size=[math]::Pow(2,32-$length)
    if($start % $size -ne 0){throw 'CIDR network addresses must be aligned to their prefix length.'}
    [pscustomobject]@{Start=$start;End=$start+$size-1;Length=$length;Prefix=$Prefix}
}

function Get-ClaudeReportNetworkPlan {
    param([string]$VirtualNetworkPrefix,[string]$JobsSubnetPrefix,[string]$EndpointSubnetPrefix)
    if(-not $VirtualNetworkPrefix -or -not $JobsSubnetPrefix -or -not $EndpointSubnetPrefix){throw 'Supply VirtualNetworkPrefix, JobsSubnetPrefix and EndpointSubnetPrefix for a new private network.'}
    $vnet=Get-ClaudeReportIpv4Range $VirtualNetworkPrefix
    $jobs=Get-ClaudeReportIpv4Range $JobsSubnetPrefix
    $endpoints=Get-ClaudeReportIpv4Range $EndpointSubnetPrefix
    $private=@(@{Start=[uint64]167772160;End=[uint64]184549375},@{Start=[uint64]2886729728;End=[uint64]2887778303},@{Start=[uint64]3232235520;End=[uint64]3232301055})
    if(-not @($private|Where-Object {$vnet.Start -ge $_.Start -and $vnet.End -le $_.End}).Count){throw 'The new VNet must use private RFC1918 address space.'}
    if($jobs.Length -gt 27){throw 'Container Apps workload-profile subnet must be /27 or larger.'}
    if($endpoints.Length -gt 29){throw 'Private endpoint subnet must be /29 or larger.'}
    foreach($subnet in @($jobs,$endpoints)){if($subnet.Start -lt $vnet.Start -or $subnet.End -gt $vnet.End){throw 'Both subnets must be inside the selected VNet address space.'}}
    if($jobs.Start -le $endpoints.End -and $endpoints.Start -le $jobs.End){throw 'Job and private-endpoint subnets must not overlap.'}
    [pscustomobject]@{VirtualNetworkPrefix=$VirtualNetworkPrefix;JobsSubnetPrefix=$JobsSubnetPrefix;EndpointSubnetPrefix=$EndpointSubnetPrefix}
}

function Get-ClaudeReportInventory {
    param([string]$ResourceGroup,[string]$ApimName)
    $account=az account show -o json | ConvertFrom-Json
    if($LASTEXITCODE -ne 0){throw 'Could not read the selected subscription.'}
    $resources=@(az resource list -g $ResourceGroup -o json | ConvertFrom-Json | Where-Object {$_.tags.'claude-chargeback-gateway' -eq $ApimName})
    if($LASTEXITCODE -ne 0){throw 'Could not discover reports resources.'}
    $operatorJson=Invoke-ClaudeReportAzOptional {az ad signed-in-user show -o json}
    $operator=if($operatorJson){$operatorJson|ConvertFrom-Json}else{$null}
    $tenantJson=Invoke-ClaudeReportAzOptional {az rest --method get --url 'https://management.azure.com/tenants?api-version=2022-12-01' -o json}
    $tenant=if($tenantJson){@(($tenantJson|ConvertFrom-Json).value|Where-Object tenantId -eq $account.tenantId)|Select-Object -First 1}else{$null}
    . (Join-Path $PSScriptRoot 'ClaudeTurnstileGovernance.ps1')
    $workspace=Get-ClaudeGatewayWorkspaceId $ResourceGroup $ApimName
    [pscustomobject]@{
        SchemaVersion=1;GeneratedUtc=[datetime]::UtcNow.ToString('o');ResourceGroup=$ResourceGroup;ApimName=$ApimName
        SubscriptionId=$account.id;SubscriptionName=$account.name;TenantId=$account.tenantId
        TenantName=$tenant.displayName;TenantDomain=$tenant.defaultDomain
        OperatorName=$operator.displayName;OperatorAddress=$operator.userPrincipalName
        WorkspaceResourceId=$workspace;Resources=$resources
    }
}
