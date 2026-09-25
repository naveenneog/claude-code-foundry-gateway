# Numbered choices follow the installer: configured/active choices are defaults, not guesses.
. (Join-Path $PSScriptRoot 'ClaudeChoice.ps1')
function Invoke-ClaudeReportAzOptional {
    param([scriptblock]$Command)
    $saved=$ErrorActionPreference;$ErrorActionPreference='Continue'
    try {$value=& $Command 2>$null;if($LASTEXITCODE -ne 0){return $null};return $value}
    catch {return $null}
    finally {$ErrorActionPreference=$saved}
}

function Select-ClaudeReportOption {
    param([string]$Prompt,[object[]]$Options,[string]$SelectedId,[string]$DefaultId,[switch]$NonInteractive,
        [string]$Parameter='Selection',[string[]]$WhereToFind=@(),
        [scriptblock]$ReadSelection={param($label,$default) Read-Host "$label [$default]"})
    $items=@($Options | Where-Object {$null -ne $_})
    if($SelectedId){
        $match=@($items|Where-Object {$_.Id -eq $SelectedId -or $_.Name -eq $SelectedId})
        if($match.Count -ne 1){throw ("$Prompt selection was not found or is not unique. Pass -$Parameter. Where to find it: " + ($WhereToFind -join '; '))}
        return $match[0]
    }
    $default=0
    $choices=@(for($i=0;$i -lt $items.Count;$i++){
        $recommended=$items.Count -eq 1 -or ($DefaultId -and $items[$i].Id -eq $DefaultId)
        if($recommended){$default=$i+1}
        $reason=if($items.Count -eq 1){'the only discovered option'}else{'the configured or active resource supplied by the caller'}
        $source=if($WhereToFind.Count){$WhereToFind[0]}else{"the discovered $Prompt inventory"}
        New-ClaudeChoiceOption -Value $items[$i].Id -Label $items[$i].Name -Detail "from $source; id $($items[$i].Id)" -Recommended:$recommended -Reason $reason
    })
    $console=if($NonInteractive){$false}elseif($PSBoundParameters.ContainsKey('ReadSelection')){$true}else{Test-ClaudeInteractive}
    $choice=@{
        Parameter=$Parameter;Question=$Prompt;Options=$choices;WhereToFind=$WhereToFind
        Interactive=$console;AcceptRecommendedWithoutConsole=$true
        NoneMessage="No $Prompt options were discovered."
        AmbiguousMessage="$Prompt is ambiguous. Supply an explicit parameter or run the numbered picker interactively."
    }
    $choice.Reader={
        param($label)
        $answer=& $ReadSelection $label $default
        if(-not [string]::IsNullOrWhiteSpace($answer) -and $answer -notin @('q','quit')){
            $number=0
            if(-not [int]::TryParse([string]$answer,[ref]$number)){throw 'Enter a number from the discovered list.'}
            if($number -lt 1 -or $number -gt $items.Count){throw 'The selected number is outside the discovered range.'}
        }
        $answer
    }.GetNewClosure()
    $selected=Select-ClaudeChoice @choice
    $match=@($items|Where-Object Id -eq $selected)
    if($match.Count -ne 1){throw "$Prompt selection was not found or is not unique."}
    return $match[0]
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
    $sub=Select-ClaudeReportOption -Prompt Subscription -Parameter SubscriptionId -Options $options -SelectedId $SubscriptionId -DefaultId $current.id -NonInteractive:$NonInteractive `
        -WhereToFind @('az account list -o table','Azure portal: Subscriptions > Overview > Subscription ID')
    if($sub.Id -ne $current.id){az account set --subscription $sub.Id;if($LASTEXITCODE -ne 0){throw 'Could not select the subscription.'}}
    $gateways=@(az apim list -o json | ConvertFrom-Json)
    if($LASTEXITCODE -ne 0){throw 'Could not discover API Management gateways.'}
    $groups=@($gateways|Select-Object -ExpandProperty resourceGroup -Unique|Sort-Object|ForEach-Object {[pscustomobject]@{Id=$_;Name=$_}})
    $group=Select-ClaudeReportOption -Prompt 'Gateway resource group' -Parameter ResourceGroup -Options $groups -SelectedId $ResourceGroup -NonInteractive:$NonInteractive `
        -WhereToFind @('az apim list -o table','Azure portal: API Management services > the gateway > Overview > Resource group')
    $options=@($gateways|Where-Object resourceGroup -eq $group.Id|ForEach-Object {[pscustomobject]@{Id=$_.name;Name="$($_.name) - $($_.location), $($_.sku.name)"}})
    $gateway=Select-ClaudeReportOption -Prompt Gateway -Parameter ApimName -Options $options -SelectedId $ApimName -NonInteractive:$NonInteractive `
        -WhereToFind @("az apim list -g $($group.Id) -o table","Azure portal: Resource groups > $($group.Id) > API Management service")
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
