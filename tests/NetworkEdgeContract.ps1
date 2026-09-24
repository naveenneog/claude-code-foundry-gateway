function Test-ClaudeNetworkTemplateContract {
    param([string]$Root)
    $edge = Get-Content (Join-Path $Root 'infra\network-edge.bicep') -Raw
    $waf = Get-Content (Join-Path $Root 'infra\network-edge-waf.bicep') -Raw
    $deploy = Get-Content (Join-Path $Root 'scripts\New-ClaudeNetworkEdge.ps1') -Raw
    $remove = Get-Content (Join-Path $Root 'scripts\Remove-ClaudeNetworkEdge.ps1') -Raw
    $pe = Get-Content (Join-Path $Root 'infra\network-private-endpoint.bicep') -Raw
    if ($edge -notmatch 'enableResponseBuffering:\s*false') { 'SSE response buffering is not off' }
    if ($edge -notmatch 'requestTimeout:\s*backendTimeoutSeconds' -or $edge -notmatch 'param backendTimeoutSeconds int = 600') { 'backend timeout contract lost' }
    if ($edge -notmatch "protocol:\s*'Https'" -or $edge -notmatch 'keyVaultSecretId:\s*certificateSecretId') { 'end-to-end TLS or Key Vault lost' }
    if ($edge -notmatch "headerName:\s*'X-Claude-Client-IP'" -or $edge -notmatch "headerValue:\s*'\{var_client_ip\}'") { 'trusted IP rewrite lost' }
    if ($edge -notmatch 'pickHostNameFromBackendAddress:\s*true' -or $edge -notmatch 'status-0123456789abcdef') { 'APIM SNI or health probe lost' }
    if ($edge -notmatch 'enableHttp2:\s*true') { 'frontend HTTP/2 lost' }
    if ($waf -notmatch "mode:\s*wafMode" -or $waf -notmatch "'Detection'" -or $waf -notmatch "'Prevention'") { 'explicit WAF modes lost' }
    if ($waf -notmatch 'exclusions:\s*exclusions' -or $waf -notmatch 'requestBodyCheck:\s*true') { 'inspectable scoped exclusions lost' }
    if ($waf -match "action:\s*'Allow'") { 'a custom Allow can bypass managed WAF rules' }
    if ($waf -notmatch 'requestBodyEnforcement:\s*true') { 'oversized requests no longer fail closed' }
    if ($pe -notmatch 'privateDnsZoneGroups' -or $pe -notmatch 'privateDnsZoneId:\s*zoneId') { 'PE DNS wiring lost' }
    if ($deploy -notmatch 'ShouldProcess' -or $deploy -notmatch 'Assert-ClaudeNetworkOwnership') { 'deployment ownership or WhatIf guard lost' }
    if ($remove -notmatch 'ShouldProcess' -or $remove -notmatch 'Assert-ClaudeNetworkOwnership') { 'removal ownership or WhatIf guard lost' }
    if ($remove -match 'az group delete') { 'removal must not delete a shared resource group' }
}
