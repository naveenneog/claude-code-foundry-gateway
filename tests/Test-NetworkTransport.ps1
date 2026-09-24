$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'scripts\ClaudeNetwork.ps1')
$sandbox = Join-Path $root ('shots\network-transport-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
$script:azCalls = @()
$script:requests = @()
$script:ClaudeNetworkTokens = @{}
$script:fail = 0
function Assert([string]$Name,[bool]$Pass) {
    if ($Pass) { Write-Host "  [OK] $Name" }
    else { Write-Host "  [FAIL] $Name"; $script:fail++ }
}
function az {
    $script:azCalls += ,@($args)
    $global:LASTEXITCODE = 0
    return '{"accessToken":"example-only-not-a-credential"}'
}
function Invoke-RestMethod {
    param($Method,$Uri,$Headers,$TimeoutSec,$ErrorAction,$Body,$ContentType)
    $script:requests += [pscustomobject]@{Method=$Method;Uri=$Uri;Timeout=$TimeoutSec;Body=$Body;ContentType=$ContentType}
    if ($Uri -match '/missing\?') { throw 'Response status code does not indicate success: 404 (Not Found).' }
    return [pscustomobject]@{id='contoso';properties=[pscustomobject]@{provisioningState='Succeeded'}}
}
try {
    $first = 'https://management.azure.com/subscriptions/00000000-0000-0000-0000-000000000001/providers/Microsoft.Network/test/item?api-version=2024-05-01'
    $other = $first.Replace('000000000001','000000000002')
    [void](Invoke-ClaudeNetworkArm $first)
    [void](Invoke-ClaudeNetworkArm ($first+'&continuation=next'))
    [void](Invoke-ClaudeNetworkArm $other)
    Assert 'one token per discovery subscription is reused' ($script:azCalls.Count -eq 2)
    Assert 'tokens are pinned to each explicit subscription' ($script:azCalls[0] -contains '00000000-0000-0000-0000-000000000001' -and $script:azCalls[1] -contains '00000000-0000-0000-0000-000000000002')
    Assert 'ampersand continuation links never reach cmd.exe' (@($script:azCalls | ForEach-Object { $_ -join ' ' } | Where-Object { $_ -match '&' }).Count -eq 0)
    $body = @{properties=@{value='<policies><inbound>@(a & b | c)</inbound></policies>'}}
    [void](Invoke-ClaudeNetworkArm $first -Method put -Body $body -StateDirectory $sandbox)
    $sent = [Text.Encoding]::UTF8.GetString($script:requests[-1].Body) | ConvertFrom-Json
    Assert 'JSON policy expressions survive without command-line quoting' ($sent.properties.value -eq $body.properties.value)
    Assert 'ARM transport is bounded for reads and writes' (@($script:requests | Where-Object Timeout -ne 45).Count -eq 0)
    Assert 'no ARM body file remains after a successful write' (@(Get-ChildItem $sandbox -Filter 'request-*.json').Count -eq 0)
    $none = Invoke-ClaudeNetworkArm ($first.Replace('/item?','/missing?')) -AllowNotFound
    Assert 'an absent optional resource is represented as null on PS7 too' ($null -eq $none)
    $count = $script:requests.Count
    try { Invoke-ClaudeNetworkArm 'https://contoso.invalid/subscriptions/anything' | Out-Null; Assert 'untrusted continuation URL is rejected' $false }
    catch { Assert 'untrusted continuation URL is rejected' ($script:requests.Count -eq $count) }
    try { Invoke-ClaudeNetworkAz @('rest','--url','https://management.azure.com/?a=b&x=y') | Out-Null; Assert 'raw CLI metacharacters are refused' $false }
    catch { Assert 'raw CLI metacharacters are refused' ($_.Exception.Message -match 'Unsafe') }
    $foreign = [pscustomobject]@{tags=[pscustomobject]@{'claude-network-owner'='another-owner'}}
    try { Assert-ClaudeNetworkOwnership $foreign 'this-owner'; Assert 'shared resource overwrite is refused' $false }
    catch { Assert 'shared resource overwrite is refused' ($_.Exception.Message -match 'not owned') }
    $owned = [pscustomobject]@{tags=[pscustomobject]@{'claude-network-owner'='this-owner'}}
    Assert-ClaudeNetworkOwnership $owned 'this-owner'
    Assert 'the exact owner can re-run' $true
    $script:deleteCalls=0
    $script:deleteIssued=$false
    function Invoke-ClaudeNetworkArm {
        param($Url,$Method='get',[switch]$AllowNotFound)
        if($Method -eq 'delete'){
            $script:deleteCalls++
            if($script:deleteCalls -lt 3){throw 'CannotDeleteResource: nested resources still exist.'}
            $script:deleteIssued=$true
            return
        }
        if($script:deleteIssued){return $null}
        return [pscustomobject]@{tags=[pscustomobject]@{'claude-network-owner'='this-owner'}}
    }
    Remove-ClaudeNetworkOwnedResource -Resource ([pscustomobject]@{id='/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/contoso/providers/Microsoft.Network/privateDnsZones/contoso.invalid';apiVersion='2020-06-01';kind='tag'}) -OwnerId 'this-owner' -RetryDelaySeconds 0
    Assert 'parent deletion retries eventual child cleanup without deleting foreign children' ($script:deleteCalls -eq 3)
    $script:readyReads=0
    function Invoke-ClaudeNetworkArm {
        param($Url)
        $script:readyReads++
        return [pscustomobject]@{properties=[pscustomobject]@{provisioningState=$(if($script:readyReads -lt 3){'Updating'}else{'Succeeded'})}}
    }
    $ready=Wait-ClaudeNetworkResourceReady -ResourceId '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/contoso/providers/Microsoft.ApiManagement/service/contoso' -ApiVersion '2024-05-01' -RetryDelaySeconds 0
    Assert 'APIM transition is awaited before another write or subnet deletion' ($script:readyReads -eq 3 -and $ready.properties.provisioningState -eq 'Succeeded')
    $rg='/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/contoso'
    function Invoke-ClaudeNetworkArm {
        param($Url,[switch]$AllowNotFound)
        if($Url -match '/virtualNetworks/'){
            return [pscustomobject]@{properties=[pscustomobject]@{subnets=@(
                [pscustomobject]@{properties=[pscustomobject]@{networkSecurityGroup=[pscustomobject]@{id="$rg/providers/Microsoft.Network/networkSecurityGroups/policy-owned"}}},
                [pscustomobject]@{properties=[pscustomobject]@{networkSecurityGroup=[pscustomobject]@{id="$rg/providers/Microsoft.Network/networkSecurityGroups/shared"}}}
            )}}
        }
        return [pscustomobject]@{tags=[pscustomobject]@{'claude-network-owner'=$(if($Url -match '/policy-owned\?'){'this-owner'}else{'someone-else'})}}
    }
    $policyNsgs=Get-ClaudeNetworkOwnedNsgs -VnetId "$rg/providers/Microsoft.Network/virtualNetworks/contoso" -ResourceGroupId $rg -OwnerId 'this-owner'
    Assert 'policy-created subnet NSGs are discovered, but shared NSGs are never adopted' ($policyNsgs.Count -eq 1 -and $policyNsgs[0].id -match '/policy-owned$')
}
finally { Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue }
if ($fail) { exit 1 }
Write-Host 'Network ARM transport contract holds.'
exit 0
