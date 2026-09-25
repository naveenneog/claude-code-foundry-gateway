$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$fail=0
function Assert([string]$Name,[bool]$Pass) {
    if($Pass){Write-Host "  [OK] $Name"}else{Write-Host "  [FAIL] $Name";$script:fail++}
}
function Throws([string]$Name,[scriptblock]$Action,[string]$Pattern) {
    try{& $Action|Out-Null;Assert $Name $false}catch{Assert $Name ($_.Exception.Message -match $Pattern)}
}
$helper=Join-Path $root 'scripts\ClaudeNetworkImpact.ps1'
Assert 'impact analysis helper exists' (Test-Path $helper)
if(-not(Test-Path $helper)){exit 1}
. (Join-Path $root 'scripts\ClaudeNetwork.ps1')
. $helper

Assert 'IPv4 prefix membership is exact' ((Test-ClaudeNetworkIpInRange '10.20.1.4' '10.20.0.0/16') -and -not(Test-ClaudeNetworkIpInRange '10.21.1.4' '10.20.0.0/16'))
Assert 'IPv6 is not silently counted as private or lost' ((Test-ClaudeNetworkIpInRange 'fd10:20::4' 'fd10:20::/64') -and -not(Test-ClaudeNetworkIpInRange 'fd10:21::4' 'fd10:20::/64'))
Assert 'IPv4-mapped IPv6 can be compared to the actual IPv4 path' (Test-ClaudeNetworkIpInRange '::ffff:10.20.1.4' '10.20.0.0/16')
Throws 'invalid CIDR cannot waive impact' {Test-ClaudeNetworkIpInRange '10.20.1.4' 'not-a-cidr'} 'CIDR'
Throws 'IPv6 prefix length is bounded' {Test-ClaudeNetworkIpInRange 'fd10::4' 'fd10::/129'} 'prefix'

$apim='/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/contoso/providers/Microsoft.ApiManagement/service/contoso-gateway'
$app='/subscriptions/00000000-0000-0000-0000-000000000002/resourceGroups/monitoring/providers/Microsoft.Insights/components/contoso-insights'
$ws='/subscriptions/00000000-0000-0000-0000-000000000002/resourceGroups/monitoring/providers/Microsoft.OperationalInsights/workspaces/contoso-logs'
$script:reads=@()
function Invoke-ClaudeNetworkArm {
    param($Url,$Method='get',[switch]$AllowNotFound)
    if($Method -ne 'get'){throw 'Impact discovery attempted a write'}
    $script:reads+=$Url
    if($Url -match '/providers/microsoft.insights/diagnosticSettings\?'){
        return [pscustomobject]@{value=@([pscustomobject]@{properties=[pscustomobject]@{workspaceId=$ws;logs=@([pscustomobject]@{category='GatewayLogs';enabled=$true})}})}
    }
    if($Url -match '/apis\?'){return [pscustomobject]@{value=@([pscustomobject]@{name='claude'})}}
    if($Url -match '/diagnostics\?'){
        return [pscustomobject]@{value=@([pscustomobject]@{properties=[pscustomobject]@{loggerId="$apim/loggers/insights";sampling=[pscustomobject]@{percentage=100}}})}
    }
    if($Url -match '/loggers/insights\?'){return [pscustomobject]@{properties=[pscustomobject]@{resourceId=$app}}}
    if($Url.StartsWith("https://management.azure.com$app`?")){return [pscustomobject]@{id=$app;properties=[pscustomobject]@{WorkspaceResourceId=$ws;DisableIpMasking=$false}}}
    if($Url.StartsWith("https://management.azure.com$ws`?")){return [pscustomobject]@{id=$ws;location='regiona';properties=[pscustomobject]@{customerId='00000000-0000-0000-0000-000000000003';retentionInDays=30}}}
    throw 'Unexpected telemetry discovery URL'
}
$bindings=Resolve-ClaudeNetworkTelemetry -ApimId $apim
Assert 'workspace comes from the actual logger and resource diagnostic IDs' ($bindings.Workspaces.Count -eq 1 -and $bindings.Workspaces[0].ResourceId -eq $ws)
Assert 'a component in another group/subscription is never reconstructed under the gateway group' ($script:reads -contains "https://management.azure.com${app}?api-version=2020-02-02")
Assert 'service and API diagnostics are both examined' (@($script:reads|Where-Object{$_ -match '/apis/claude/diagnostics\?'}).Count -eq 1 -and @($script:reads|Where-Object{$_ -match '/service/contoso-gateway/diagnostics\?'}).Count -eq 1)
Assert 'IP masking is part of the evidence, not ignored' (-not $bindings.Components[0].IpMaskingDisabled)

function Observation($User,$Ip,$Peer,$Reliable,$Time,$Source='GatewayLogs') {
    [pscustomobject]@{UserId=$User;Actor=$User;IdentityKind='Entra';ClientIp=$Ip;GatewayPeerIp=$Peer;IpReliable=$Reliable;LastSeenUtc=$Time;Observations=1;Source=$Source}
}
$rows=@(
    (Observation 'alice' '10.20.1.4' '10.20.1.4' $true '2026-09-24T10:00:00Z'),
    (Observation 'bob' '203.0.113.5' '203.0.113.5' $true '2026-09-24T11:00:00Z'),
    (Observation 'bob' '203.0.113.5' '203.0.113.5' $true '2026-09-24T12:00:00Z'),
    (Observation 'carol' '10.99.1.9' '10.99.1.9' $true '2026-09-24T12:30:00Z'),
    (Observation 'dana' '0.0.0.0' '' $false '2026-09-24T13:00:00Z' 'AppRequests'),
    (Observation 'erin' 'fd10:20::4' 'fd10:20::4' $true '2026-09-24T13:30:00Z')
)
$coverage=[pscustomobject]@{Complete=$true;Warnings=@();Truncated=$false}
$report=New-ClaudeNetworkImpactReport -ApimId $apim -Observations $rows -PrivateClientCidrs @('10.20.0.0/16','fd10:20::/64') -EdgeSourceCidrs @('10.20.2.0/24') -Actions @('GatewayPrivate') -Coverage $coverage -WindowStartUtc '2026-09-17T14:00:00Z' -WindowEndUtc '2026-09-24T14:00:00Z'
Assert 'distinct users are counted, not requests' ($report.Summary.ObservedUsers -eq 5)
Assert 'private addresses outside the selected path are still affected' ($report.Summary.OutsidePathUsers -eq 2)
Assert 'missing/masked client IP is uncertainty, not a safe private route' ($report.Summary.UnknownIpUsers -eq 1 -and -not $report.Coverage.Complete)
Assert 'the affected list is grouped by user and exact IP range' ($report.Rows.Count -eq 5 -and @($report.Rows|Where-Object PathStatus -eq 'Outside').Count -eq 2)
Assert 'most recent observation is retained for each user/range' ((@($report.Rows|Where-Object UserId -eq bob)[0].LastSeenUtc) -eq '2026-09-24T12:00:00.0000000Z')
Assert 'a review has a SHA-256 acknowledgement token' ($report.Acknowledgement -match '^[0-9a-f]{64}$')
$oldWhatIf=$WhatIfPreference
try{
    $WhatIfPreference=$true
    $dry=New-ClaudeNetworkImpactReport -ApimId $apim -Observations $rows -PrivateClientCidrs @('10.20.0.0/16','fd10:20::/64') -EdgeSourceCidrs @('10.20.2.0/24') -Actions @('GatewayPrivate') -Coverage $coverage -WindowStartUtc '2026-09-17T14:00:00Z' -WindowEndUtc '2026-09-24T14:00:00Z'
}finally{$WhatIfPreference=$oldWhatIf}
Assert 'WhatIf computes the identical affected-user summary and acknowledgement' ($dry.Acknowledgement -eq $report.Acknowledgement -and $dry.Summary.PotentiallyAffectedUsers -eq $report.Summary.PotentiallyAffectedUsers)

$proxied=@(Observation 'alice' '203.0.113.5' '10.20.2.4' $true '2026-09-24T11:00:00Z')
$edge=New-ClaudeNetworkImpactReport -ApimId $apim -Observations $proxied -PrivateClientCidrs @('10.20.0.0/16') -EdgeSourceCidrs @('10.20.2.0/24') -Actions @('EdgeOnly') -Coverage $coverage -WindowStartUtc '2026-09-17T14:00:00Z' -WindowEndUtc '2026-09-24T14:00:00Z'
Assert 'edge restriction uses the observed gateway peer, not the forwarded developer IP' ($edge.Summary.PotentiallyAffectedUsers -eq 0)
$unknownPeer=@(Observation 'alice' '203.0.113.5' '' $true '2026-09-24T11:00:00Z' 'Ledger')
$edgeUnknown=New-ClaudeNetworkImpactReport -ApimId $apim -Observations $unknownPeer -PrivateClientCidrs @('10.20.0.0/16') -EdgeSourceCidrs @('10.20.2.0/24') -Actions @('EdgeOnly') -Coverage $coverage -WindowStartUtc '2026-09-17T14:00:00Z' -WindowEndUtc '2026-09-24T14:00:00Z'
Assert 'a missing gateway peer cannot prove an existing edge path' ($edgeUnknown.Summary.PotentiallyAffectedUsers -eq 1)
$backend=New-ClaudeNetworkImpactReport -ApimId $apim -Observations $proxied -PrivateClientCidrs @('10.20.0.0/16') -Actions @('FoundryPrivate') -BackendPathValidated -Coverage $coverage -WindowStartUtc '2026-09-17T14:00:00Z' -WindowEndUtc '2026-09-24T14:00:00Z'
Assert 'a private backend does not itself move public-gateway clients onto a VPN' ($backend.Summary.PotentiallyAffectedUsers -eq 0)
Assert 'direct Foundry users are explicitly outside gateway-log coverage' (@($backend.Warnings -match 'direct Foundry').Count -gt 0)

$query=Get-ClaudeNetworkImpactQuery -ApimId $apim -Components @([pscustomobject]@{ResourceId=$app;IpMaskingDisabled=$false}) -WindowStartUtc '2026-09-17T14:00:00Z' -WindowEndUtc '2026-09-24T14:00:00Z' -Limit 100
Assert 'the query scopes gateway logs to the actual ARM resource' ($query.Contains($apim.ToLowerInvariant()) -and $query -match '_ResourceId')
Assert 'the query does not export body, bearer header or completion content' ($query -notmatch 'RequestBody|ResponseBody|RequestHeaders|ResponseHeaders')
Assert 'both modern and legacy gateway log tables are considered' ($query -match 'ApiManagementGatewayLogs' -and $query -match 'AzureDiagnostics')
Assert 'a sentinel row permits zero tables without inventing zero impact' ($query -match 'datatable')
Assert 'query output is bounded with an overflow detector row' ($query -match 'take 101')

if($fail){exit 1}
Write-Host 'Network impact contract holds.'
exit 0
