<#
.SYNOPSIS
    Verifies edge configuration and makes an authenticated SSE call.
.DESCRIPTION
    Run from each real client boundary. Labeling a workstation Spoke does not
    put it in a VNet: private DNS and HTTPS must actually succeed. The same
    token is sent directly to APIM to prove the edge cannot be bypassed.
    No bearer token, prompt or completion is written to the result.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)][string]$StatePath,
    [Parameter(Mandatory = $true)][ValidateSet('Internet','Corporate','Spoke')][string]$NetworkLocation,
    [string]$Model,
    [string]$CaCertificatePath,
    [ValidateSet('Detection','Prevention')][string]$ExpectedWafMode = 'Prevention',
    [switch]$RequirePrivateFoundry,
    [string]$OutputPath
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ClaudeNetwork.ps1')
$state = Get-Content $StatePath -Raw | ConvertFrom-Json
if ($state.Version -ne 1 -or -not $state.Endpoint -or $state.Removed) { throw 'Expected an active network-edge state file.' }
$results = @()
function Check([string]$Name,[bool]$Pass,[object]$Observed) {
    $script:results += [pscustomobject]@{name=$Name;pass=$Pass;observed=$Observed}
    Write-Host ("  [{0}] {1}: {2}" -f $(if($Pass){'PASS'}else{'FAIL'}),$Name,($Observed | ConvertTo-Json -Compress -Depth 8))
}
$edge = Invoke-ClaudeNetworkArm "https://management.azure.com$($state.GatewayId)?api-version=2024-05-01"
Check 'edge provisioned' ($edge.properties.provisioningState -eq 'Succeeded') $edge.properties.provisioningState
Check 'edge running' ($edge.properties.operationalState -eq 'Running') $edge.properties.operationalState
if ($edge.properties.operationalState -ne 'Running') { throw 'Application Gateway is not Running. Check its Activity log and Overview > Start; a stopped gateway can still accept a TCP connection.' }
Check 'response buffering off' ($edge.properties.globalConfiguration.enableResponseBuffering -eq $false) $edge.properties.globalConfiguration.enableResponseBuffering
Check 'frontend HTTP/2 enabled' ($edge.properties.enableHttp2 -eq $true) $edge.properties.enableHttp2
$timeout = @($edge.properties.backendHttpSettingsCollection)[0].properties.requestTimeout
Check 'backend timeout above default' ($timeout -ge 600) $timeout
foreach ($id in @($edge.properties.firewallPolicy.id,@($edge.properties.urlPathMaps)[0].properties.pathRules[0].properties.firewallPolicy.id) | Sort-Object -Unique) {
    $waf = Invoke-ClaudeNetworkArm "https://management.azure.com${id}?api-version=2024-05-01"
    Check "WAF $($waf.name) mode" ($waf.properties.policySettings.mode -eq $ExpectedWafMode -and $waf.properties.policySettings.state -eq 'Enabled') $waf.properties.policySettings.mode
    Check 'WAF body inspection and size enforcement' ($waf.properties.policySettings.requestBodyCheck -and $waf.properties.policySettings.requestBodyEnforcement) $waf.properties.policySettings.requestBodyInspectLimitInKB
}
$apim = Invoke-ClaudeNetworkArm "https://management.azure.com$($state.ApimId)?api-version=2024-05-01"
Check 'APIM public state matches selected origin' ($state.BackendAccess -ne 'private' -or $apim.properties.publicNetworkAccess -eq 'Disabled') $apim.properties.publicNetworkAccess
$foundry = Invoke-ClaudeNetworkArm "https://management.azure.com$($state.FoundryId)?api-version=2024-10-01"
Check 'Foundry public access' ((-not $RequirePrivateFoundry -and $state.NetworkProfile -eq 'public') -or $foundry.properties.publicNetworkAccess -eq 'Disabled') $foundry.properties.publicNetworkAccess
$hostName = ([uri]$state.Endpoint).DnsSafeHost
$addresses = @([Net.Dns]::GetHostAddresses($hostName) | ForEach-Object { $_.IPAddressToString })
$private = @($addresses | Where-Object { Test-ClaudeNetworkPrivateAddress $_ }).Count -gt 0
$expectPrivate = $state.NetworkProfile -eq 'private' -or ($state.NetworkProfile -eq 'hybrid' -and $NetworkLocation -ne 'Internet')
Check "DNS from $NetworkLocation" ($addresses.Count -gt 0 -and $private -eq $expectPrivate) $addresses
if (-not $Model) {
    $deployments = Get-ClaudeNetworkPages "https://management.azure.com$($state.FoundryId)/deployments?api-version=2024-10-01"
    $models = @($deployments | Where-Object { $_.properties.model.format -eq 'Anthropic' -and $_.properties.provisioningState -eq 'Succeeded' })
    if (-not $models.Count) { throw 'No succeeded Anthropic deployment was discovered. Pass a deployed model explicitly.' }
    $Model = @($models | Sort-Object { if($_.properties.model.name -match 'haiku'){0}elseif($_.properties.model.name -match 'sonnet'){1}else{2} })[0].name
}
if ($PSCmdlet.ShouldProcess($state.Endpoint,'Spend a small number of tokens to test TLS, SSE and authenticated direct-origin refusal')) {
    $token = Invoke-ClaudeNetworkAz @('account','get-access-token','--resource','https://cognitiveservices.azure.com','--subscription',$state.SubscriptionId)
    $options = @{url=$state.Endpoint.TrimEnd('/')+'/v1/messages';model=$Model;token=$token.accessToken;maxTokens=32;http2=$true;timeoutMs=90000}
    if ($CaCertificatePath) {
        $options.caPath=Get-ClaudeNetworkLocalPath $CaCertificatePath
        if (-not (Test-Path -LiteralPath $options.caPath -PathType Leaf)) { throw 'The selected public CA PEM file does not exist.' }
    }
    $json = ($options | ConvertTo-Json -Depth 20) | & node (Join-Path $PSScriptRoot 'network-edge-probe.mjs')
    if (-not $json) { throw 'The TLS/SSE probe returned no receipt. Check Node and the public CA file before retrying.' }
    $probe = $json | ConvertFrom-Json
    Check 'TLS chain and hostname verified' $probe.tlsAuthorized $probe.tlsProtocol
    Check 'real streaming inference' ($probe.status -eq 200 -and $probe.completed -and $null -ne $probe.firstTextMs -and $probe.firstTextMs -lt $probe.completedMs) $probe
    Check 'HTTP/2 negotiated with edge' ($probe.httpVersion -eq 'h2') $probe.httpVersion
    $options.url = $apim.properties.gatewayUrl.TrimEnd('/')+'/'+$state.ApiPath+'/v1/messages'
    $options.http2 = $false
    $options.Remove('caPath')
    $bypassJson = ($options | ConvertTo-Json -Depth 20) | & node (Join-Path $PSScriptRoot 'network-edge-probe.mjs')
    $bypass = $bypassJson | ConvertFrom-Json
    Check 'authenticated direct APIM request refused' ($bypass.status -eq 403) @{status=$bypass.status;error=$bypass.error;errorType=$bypass.errorType}
    $token = $null
}
elseif ($WhatIfPreference) { Write-Host 'WhatIf: inference and bypass checks were not run; this is not a verification receipt.'; return }
$receipt = [pscustomobject]@{observedUtc=[DateTime]::UtcNow.ToString('o');networkLocation=$NetworkLocation;checks=$results;passed=(@($results | Where-Object { -not $_.pass }).Count -eq 0)}
if ($OutputPath) { Write-ClaudeNetworkState $receipt $OutputPath }
if (-not $receipt.passed) { throw 'Network verification failed. Inspect each boundary; do not distribute the edge endpoint yet.' }
$receipt
