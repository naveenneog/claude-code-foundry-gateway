# Read-only historical impact. This never enables logging or changes the gateway.
function ConvertTo-ClaudeNetworkUtcText {
    param([object]$Value)
    if ($Value -is [datetime]) { return $Value.ToUniversalTime().ToString('o') }
    return [DateTimeOffset]::Parse([string]$Value,[Globalization.CultureInfo]::InvariantCulture).UtcDateTime.ToString('o')
}

function Test-ClaudeNetworkIpInRange {
    param([string]$Address,[string]$Cidr)
    $parts=$Cidr.Split('/')
    $network=$null; $prefix=0; $ip=$null
    if ($parts.Count -ne 2 -or -not [Net.IPAddress]::TryParse($parts[0],[ref]$network)) { throw 'Invalid client-path CIDR.' }
    if (-not [int]::TryParse($parts[1],[ref]$prefix)) { throw 'Invalid CIDR prefix.' }
    if ($network.IsIPv4MappedToIPv6) { $network=$network.MapToIPv4() }
    $bytes=$network.GetAddressBytes()
    if ($prefix -lt 0 -or $prefix -gt $bytes.Length*8) { throw 'Invalid CIDR prefix length.' }
    if (-not [Net.IPAddress]::TryParse($Address,[ref]$ip)) { return $false }
    if ($ip.IsIPv4MappedToIPv6) { $ip=$ip.MapToIPv4() }
    $candidate=$ip.GetAddressBytes()
    if ($candidate.Length -ne $bytes.Length) { return $false }
    for ($i=0;$i -lt $bytes.Length;$i++) {
        $bits=[Math]::Min(8,[Math]::Max(0,$prefix-8*$i))
        $mask=if($bits){256-[int][Math]::Pow(2,8-$bits)}else{0}
        if (($candidate[$i] -band $mask) -ne ($bytes[$i] -band $mask)) { return $false }
    }
    return $true
}

function Get-ClaudeNetworkIpEvidence {
    param([string]$Address,[bool]$Reliable=$true)
    $ip=$null
    if (-not $Reliable -or -not [Net.IPAddress]::TryParse($Address,[ref]$ip)) { return [pscustomobject]@{Known=$false;Address='';Range='<unknown or masked>'} }
    if ($ip.IsIPv4MappedToIPv6) { $ip=$ip.MapToIPv4() }
    if ($ip.Equals([Net.IPAddress]::Any) -or $ip.Equals([Net.IPAddress]::IPv6Any)) { return [pscustomobject]@{Known=$false;Address='';Range='<unknown or masked>'} }
    $prefix=if($ip.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork){32}else{128}
    return [pscustomobject]@{Known=$true;Address=$ip.ToString();Range=($ip.ToString()+"/$prefix")}
}

function Resolve-ClaudeNetworkTelemetry {
    param([Parameter(Mandatory=$true)][string]$ApimId)
    if ($ApimId -notmatch '^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft\.ApiManagement/service/[^/]+$') { throw 'Expected a complete APIM resource ID.' }
    $base="https://management.azure.com$ApimId"
    $resourceLogs=Get-ClaudeNetworkPages "$base/providers/microsoft.insights/diagnosticSettings?api-version=2021-05-01-preview"
    $service=Get-ClaudeNetworkPages "$base/diagnostics?api-version=2024-05-01"
    $apis=Get-ClaudeNetworkPages "$base/apis?api-version=2024-05-01"
    $diagnostics=@($service)
    foreach ($api in $apis) {
        $items=Get-ClaudeNetworkPages "$base/apis/$($api.name)/diagnostics?api-version=2024-05-01"
        $diagnostics+=@($items)
    }
    $components=@(); $workspaceIds=@()
    foreach ($setting in $resourceLogs) { if ($setting.properties.workspaceId) { $workspaceIds+=$setting.properties.workspaceId } }
    foreach ($loggerId in @($diagnostics | ForEach-Object { $_.properties.loggerId } | Where-Object { $_ } | Sort-Object -Unique)) {
        $logger=Invoke-ClaudeNetworkArm "https://management.azure.com${loggerId}?api-version=2024-05-01"
        $id=$logger.properties.resourceId
        if (-not $id -or $id -notmatch '/providers/Microsoft.Insights/components/') { continue }
        $app=Invoke-ClaudeNetworkArm "https://management.azure.com${id}?api-version=2020-02-02"
        if (-not $app.properties.WorkspaceResourceId) { throw 'A selected Insights logger has no discoverable workspace. Do not assume that it contains no users.' }
        $workspaceIds+=$app.properties.WorkspaceResourceId
        $samples=@($diagnostics | Where-Object { $_.properties.loggerId -eq $loggerId } | ForEach-Object { $_.properties.sampling.percentage })
        $components+=[pscustomobject]@{
            ResourceId=$app.id; WorkspaceId=$app.properties.WorkspaceResourceId
            IpMaskingDisabled=($app.properties.DisableIpMasking -eq $true)
            SamplingPercentages=$samples
        }
    }
    $workspaces=@()
    foreach ($id in @($workspaceIds | Sort-Object -Unique)) {
        $w=Invoke-ClaudeNetworkArm "https://management.azure.com${id}?api-version=2023-09-01"
        $workspaces+=[pscustomobject]@{ResourceId=$id;CustomerId=$w.properties.customerId;Region=$w.location;RetentionDays=$w.properties.retentionInDays}
    }
    if (-not $workspaces.Count) { throw 'No Log Analytics destination could be discovered from this gateway. Impact is unknown, not zero.' }
    $gatewayLogs=@($resourceLogs | Where-Object {
        @($_.properties.logs | Where-Object { $_.enabled -and ($_.category -eq 'GatewayLogs' -or $_.categoryGroup -eq 'allLogs') }).Count -gt 0
    }).Count -gt 0
    return [pscustomobject]@{
        ApimId=$ApimId;Workspaces=$workspaces;Components=$components
        GatewayLogsConfigured=$gatewayLogs
        SamplingComplete=(@($components | ForEach-Object {$_.SamplingPercentages} | Where-Object {$null -eq $_ -or $_ -lt 100}).Count -eq 0)
    }
}

function Get-ClaudeNetworkImpactQuery {
    param([string]$ApimId,[object[]]$Components,[string]$WindowStartUtc,[string]$WindowEndUtc,[ValidateRange(1,50000)][int]$Limit=10000)
    $gateway="@'"+$ApimId.ToLowerInvariant().Replace("'","''")+"'"
    $name="@'"+(($ApimId -split '/')[-1]).ToLowerInvariant().Replace("'","''")+"'"
    $apps=ConvertTo-Json -InputObject @($Components | ForEach-Object {$_.ResourceId.ToLowerInvariant()} | Sort-Object -Unique) -Compress
    $unmasked=ConvertTo-Json -InputObject @($Components | Where-Object IpMaskingDisabled | ForEach-Object {$_.ResourceId.ToLowerInvariant()} | Sort-Object -Unique) -Compress
    $start=ConvertTo-ClaudeNetworkUtcText $WindowStartUtc
    $end=ConvertTo-ClaudeNetworkUtcText $WindowEndUtc
    $query=@'
let Start = datetime(__START__);
let End = datetime(__END__);
let GatewayId = __GATEWAY__;
let GatewayName = __NAME__;
let Apps = dynamic(__APPS__);
let UnmaskedApps = dynamic(__UNMASKED__);
let Traces = union isfuzzy=true
    (datatable(TimeGenerated:datetime, _ResourceId:string, Properties:dynamic, OperationId:string) []),
    AppTraces
| where TimeGenerated between (Start .. End)
| where tolower(_ResourceId) in (Apps)
| where tolower(tostring(Properties["Service ID"])) in (GatewayId, GatewayName)
    or tolower(tostring(Properties["Service Name"])) == GatewayName
| where isnotempty(tostring(Properties.RequestId))
| project TimeGenerated, Rid=tostring(Properties.RequestId),
    EntraUser=tostring(Properties.UserId), Actor=tostring(Properties.User),
    TrustedClientIp=tostring(Properties.ClientIp), Op=tostring(OperationId)
| summarize arg_max(TimeGenerated, *) by Rid;
let Requests = union isfuzzy=true
    (datatable(TimeGenerated:datetime, _ResourceId:string, Properties:dynamic, OperationId:string, ClientIP:string) []),
    AppRequests
| where TimeGenerated between (Start .. End)
| where tolower(_ResourceId) in (Apps)
| where tolower(tostring(Properties["Service ID"])) in (GatewayId, GatewayName)
    or tolower(tostring(Properties["Service Name"])) == GatewayName
| project TimeGenerated, Op=tostring(OperationId), RequestIp=tostring(ClientIP),
    RequestIpReliable=tolower(_ResourceId) in (UnmaskedApps)
| summarize arg_max(TimeGenerated, *) by Op;
let GatewayRows = union isfuzzy=true
    (datatable(TimeGenerated:datetime, Rid:string, PeerIp:string, PortalUser:string, Source:string) []),
    (ApiManagementGatewayLogs
     | where TimeGenerated between (Start .. End)
     | where tolower(_ResourceId) == GatewayId
     | project TimeGenerated, Rid=tostring(CorrelationId), PeerIp=tostring(CallerIpAddress),
        PortalUser=tostring(UserId), Source="GatewayLogs"),
    (AzureDiagnostics
     | where TimeGenerated between (Start .. End)
     | where tolower(tostring(column_ifexists("_ResourceId", ""))) == GatewayId
     | where Category == "GatewayLogs"
     | project TimeGenerated,
        Rid=tostring(column_ifexists("correlationId_g", column_ifexists("correlationId_s", ""))),
        PeerIp=tostring(column_ifexists("callerIpAddress_s", "")),
        PortalUser=tostring(column_ifexists("userId_s", "")), Source="AzureDiagnostics");
let Observations = union
    (GatewayRows
     | join kind=leftouter Traces on Rid
     | project TimeGenerated, UserId=iff(isnotempty(EntraUser), EntraUser, iff(isnotempty(PortalUser), strcat("apim:",PortalUser), "")),
        Actor=coalesce(Actor, PortalUser), IdentityKind=iff(isnotempty(EntraUser),"Entra",iff(isnotempty(PortalUser),"APIM user","Unattributed")),
        ClientIp=coalesce(TrustedClientIp,PeerIp), GatewayPeerIp=PeerIp,
        IpReliable=isnotempty(TrustedClientIp) or isnotempty(PeerIp), Source),
    (Traces
     | join kind=leftouter Requests on Op
     | project TimeGenerated, UserId=EntraUser, Actor,
        IdentityKind=iff(isnotempty(EntraUser),"Entra","Unattributed"),
        ClientIp=coalesce(TrustedClientIp,RequestIp), GatewayPeerIp="",
        IpReliable=isnotempty(TrustedClientIp) or RequestIpReliable == true, Source="Ledger/Insights"),
    (Requests
     | join kind=leftouter (Traces | summarize arg_max(TimeGenerated, *) by Op) on Op
     | where isempty(Rid)
     | project TimeGenerated, UserId="", Actor="", IdentityKind="Unattributed",
        ClientIp=RequestIp, GatewayPeerIp="", IpReliable=RequestIpReliable, Source="Insights request");
Observations
| summarize Observations=count(), LastSeenUtc=max(TimeGenerated) by UserId, Actor, IdentityKind, ClientIp, GatewayPeerIp, IpReliable, Source
| order by UserId asc, ClientIp asc, Source asc
| take __LIMIT__
'@
    return $query.Replace('__START__',$start).Replace('__END__',$end).Replace('__GATEWAY__',$gateway).Replace('__NAME__',$name).Replace('__APPS__',$apps).Replace('__UNMASKED__',$unmasked).Replace('__LIMIT__',[string]($Limit+1))
}

function Invoke-ClaudeNetworkLogQuery {
    param($Workspace,[string]$Query)
    $sub=($Workspace.ResourceId -split '/')[2]
    $token=Invoke-ClaudeNetworkAz @('account','get-access-token','--resource','https://api.loganalytics.io','--subscription',$sub)
    $body=@{query=$Query}|ConvertTo-Json -Compress
    $response=Invoke-RestMethod -Method Post -Uri "https://api.loganalytics.azure.com/v1/workspaces/$($Workspace.CustomerId)/query" -Headers @{Authorization="Bearer $($token.accessToken)";Prefer='wait=60'} -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 90 -ErrorAction Stop
    if ($response.error) { throw 'Log query returned partial/error results. Treat impact coverage as incomplete.' }
    $rows=@()
    foreach ($table in $response.tables) {
        if ($table.name -ne 'PrimaryResult') { continue }
        foreach ($values in $table.rows) {
            $row=[ordered]@{}
            for($i=0;$i -lt $table.columns.Count;$i++) { $row[$table.columns[$i].name]=$values[$i] }
            $rows+=[pscustomobject]$row
        }
    }
    return ,$rows
}

function New-ClaudeNetworkImpactReport {
    param(
        [string]$ApimId,[object[]]$Observations,[string[]]$PrivateClientCidrs=@(),
        [string[]]$EdgeSourceCidrs=@(),[string[]]$Actions=@(),
        [switch]$BackendPathValidated,$Coverage,
        [string]$WindowStartUtc,[string]$WindowEndUtc,[object[]]$Destinations=@()
    )
    foreach($cidr in @($PrivateClientCidrs)+@($EdgeSourceCidrs)) { [void](Test-ClaudeNetworkIpInRange '0.0.0.0' $cidr) }
    $warnings=@($Coverage.Warnings | Where-Object {$_})
    $grouped=@{}
    foreach($observation in $Observations) {
        $ip=Get-ClaudeNetworkIpEvidence $observation.ClientIp ([bool]$observation.IpReliable)
        $pathStatus='Unknown'
        if($ip.Known) {
            $pathStatus='Outside'
            foreach($cidr in $PrivateClientCidrs) { if(Test-ClaudeNetworkIpInRange $ip.Address $cidr){$pathStatus='Inside';break} }
        }
        $peer=Get-ClaudeNetworkIpEvidence $observation.GatewayPeerIp
        $edgeKnown=$false
        if($peer.Known) { foreach($cidr in $EdgeSourceCidrs){if(Test-ClaudeNetworkIpInRange $peer.Address $cidr){$edgeKnown=$true;break}} }
        $effects=@()
        if($Actions -contains 'GatewayPrivate' -and $pathStatus -ne 'Inside'){$effects+='Gateway private path not established for this observed client'}
        if($Actions -contains 'EdgeOnly' -and -not $edgeKnown){$effects+='Client must use the selected edge; existing trusted edge peer not established'}
        if($Actions -contains 'FoundryPrivate' -and -not $BackendPathValidated){$effects+='All gateway calls depend on proving the private Foundry backend path'}
        if($Actions -contains 'EdgeRemoval'){$effects+='The edge URL is being removed; migrate and verify every remaining client path'}
        $key="$($observation.UserId)|$($ip.Range)"
        $time=ConvertTo-ClaudeNetworkUtcText $observation.LastSeenUtc
        if(-not $grouped.ContainsKey($key)){
            $grouped[$key]=[pscustomobject]@{
                UserId=[string]$observation.UserId;Actor=$(if($observation.Actor){[string]$observation.Actor}else{'<unattributed>'})
                IdentityKind=[string]$observation.IdentityKind;ClientRange=$ip.Range
                PathStatus=$pathStatus;LastSeenUtc=$time;Observations=[long]0
                PotentiallyAffected=$false;Reasons=@();Sources=@()
            }
        }
        $row=$grouped[$key]
        if([string]::CompareOrdinal($time,$row.LastSeenUtc) -gt 0){$row.LastSeenUtc=$time}
        $row.Observations+=[long]$observation.Observations
        $row.PotentiallyAffected=$row.PotentiallyAffected -or $effects.Count -gt 0
        $row.Reasons=@(@($row.Reasons)+$effects|Sort-Object -Unique)
        $row.Sources=@(@($row.Sources)+@($observation.Source)|Sort-Object -Unique)
    }
    $rows=@($grouped.Values|Sort-Object UserId,ClientRange)
    $unknown=@($rows|Where-Object PathStatus -eq Unknown)
    if($unknown.Count){$warnings+='Some client IPs are missing or masked. They are not evidence of a reachable private path.'}
    if(-not $rows.Count){$warnings+='No observed traffic in the queried window. This does not prove that no clients will be affected.'}
    if($Actions -contains 'FoundryPrivate'){$warnings+='Gateway logs cannot enumerate direct Foundry consumers that bypass the gateway.'}
    if($Actions -contains 'EdgeOnly' -and @($Observations|Where-Object{-not $_.GatewayPeerIp}).Count){$warnings+='Some observations lack a gateway peer IP; the forwarded developer IP cannot prove the existing edge path.'}
    $summary=[ordered]@{
        ObservedUsers=@($rows.UserId|Where-Object{$_}|Sort-Object -Unique).Count
        ObservedEntraUsers=@($rows|Where-Object{$_.IdentityKind -eq 'Entra' -and $_.UserId}|ForEach-Object {$_.UserId}|Sort-Object -Unique).Count
        KnownClientRanges=@($rows|Where-Object PathStatus -ne Unknown|ForEach-Object {$_.ClientRange}|Sort-Object -Unique).Count
        OutsidePathUsers=@($rows|Where-Object{$_.PathStatus -eq 'Outside' -and $_.UserId}|ForEach-Object {$_.UserId}|Sort-Object -Unique).Count
        OutsidePathRanges=@($rows|Where-Object PathStatus -eq Outside|ForEach-Object {$_.ClientRange}|Sort-Object -Unique).Count
        UnknownIpUsers=@($unknown.UserId|Where-Object{$_}|Sort-Object -Unique).Count
        UnattributedRows=@($rows|Where-Object{-not $_.UserId}).Count
        PotentiallyAffectedUsers=@($rows|Where-Object{$_.PotentiallyAffected -and $_.UserId}|ForEach-Object {$_.UserId}|Sort-Object -Unique).Count
    }
    $report=[ordered]@{
        Version=1;ApimId=$ApimId;WindowStartUtc=(ConvertTo-ClaudeNetworkUtcText $WindowStartUtc);WindowEndUtc=(ConvertTo-ClaudeNetworkUtcText $WindowEndUtc)
        Actions=@($Actions|Sort-Object -Unique);PrivateClientCidrs=@($PrivateClientCidrs|Sort-Object -Unique);EdgeSourceCidrs=@($EdgeSourceCidrs|Sort-Object -Unique)
        BackendPathValidated=[bool]$BackendPathValidated;Summary=[pscustomobject]$summary;Rows=$rows
        Coverage=[pscustomobject]@{Complete=([bool]$Coverage.Complete -and -not $unknown.Count -and $rows.Count -gt 0 -and -not $Coverage.Truncated);Truncated=[bool]$Coverage.Truncated}
        Warnings=@($warnings|Sort-Object -Unique);Destinations=$Destinations
    }
    $reviewJson=$report|ConvertTo-Json -Depth 35 -Compress
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$digest=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($reviewJson)))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
    $report.Acknowledgement=$digest
    return [pscustomobject]$report
}

function Get-ClaudeNetworkImpact {
    param(
        [string]$ApimId,[ValidateRange(1,90)][int]$LookbackDays,
        [string[]]$PrivateClientCidrs=@(),[string[]]$EdgeSourceCidrs=@(),
        [string[]]$Actions=@(),[switch]$BackendPathValidated,
        [ValidateRange(1,50000)][int]$MaximumRows=10000
    )
    $bindings=Resolve-ClaudeNetworkTelemetry $ApimId
    $end=[DateTime]::UtcNow
    $start=$end.AddDays(-$LookbackDays)
    $warnings=@('Historical observations are not a future reachability guarantee. Review VPN, DNS and routing separately.')
    $complete=$true;$truncated=$false;$observations=@()
    if(-not $bindings.GatewayLogsConfigured){$warnings+='GatewayLogs is not configured; peer IP and non-ledger traffic coverage may be incomplete.';$complete=$false}
    if(-not $bindings.SamplingComplete){$warnings+='At least one Insights diagnostic samples requests; absent callers are not proof of no usage.';$complete=$false}
    foreach($workspace in $bindings.Workspaces){
        if($workspace.RetentionDays -lt $LookbackDays){$warnings+='Workspace retention is shorter than the chosen window.';$complete=$false}
        $components=@($bindings.Components|Where-Object WorkspaceId -eq $workspace.ResourceId)
        $query=Get-ClaudeNetworkImpactQuery -ApimId $ApimId -Components $components -WindowStartUtc $start.ToString('o') -WindowEndUtc $end.ToString('o') -Limit $MaximumRows
        try {
            $found=Invoke-ClaudeNetworkLogQuery -Workspace $workspace -Query $query
            if($found.Count -gt $MaximumRows){$truncated=$true;$warnings+='The impact row limit was reached. Export/query a narrower window; this is not a complete caller list.'}
            $observations+=@($found|Select-Object -First $MaximumRows)
        }
        catch{$complete=$false;$warnings+='A discovered telemetry destination could not be queried completely. Do not interpret the missing destination as zero callers.'}
    }
    $coverage=[pscustomobject]@{Complete=$complete;Truncated=$truncated;Warnings=$warnings}
    $report=New-ClaudeNetworkImpactReport -ApimId $ApimId -Observations $observations -PrivateClientCidrs $PrivateClientCidrs -EdgeSourceCidrs $EdgeSourceCidrs -Actions $Actions -BackendPathValidated:$BackendPathValidated -Coverage $coverage -WindowStartUtc $start.ToString('o') -WindowEndUtc $end.ToString('o') -Destinations $bindings.Workspaces
    return $report
}

function Show-ClaudeNetworkImpact {
    param($Report)
    Write-Host "`nACCESS IMPACT - read-only gateway history" -ForegroundColor Yellow
    Write-Host ("UTC window: {0} to {1}" -f $Report.WindowStartUtc,$Report.WindowEndUtc)
    Write-Host ("Users observed: {0}; outside path: {1}; known outside IP ranges: {2}; users with unknown/masked IP: {3}; potentially affected: {4}" -f $Report.Summary.ObservedUsers,$Report.Summary.OutsidePathUsers,$Report.Summary.OutsidePathRanges,$Report.Summary.UnknownIpUsers,$Report.Summary.PotentiallyAffectedUsers)
    foreach($row in $Report.Rows){
        Write-Host ("  Actor: {0} | identity: {1} ({2})" -f $row.Actor,$row.UserId,$row.IdentityKind)
        Write-Host ("    Client range: {0}; path: {1}; potentially affected: {2}" -f $row.ClientRange,$row.PathStatus,$row.PotentiallyAffected)
        Write-Host ("    Last seen UTC: {0}" -f (ConvertTo-ClaudeNetworkUtcText $row.LastSeenUtc))
        foreach($reason in $row.Reasons){Write-Host "    Effect: $reason"}
    }
    foreach($warning in $Report.Warnings){Write-Warning $warning}
    Write-Host "Impact acknowledgement: $($Report.Acknowledgement)"
}
