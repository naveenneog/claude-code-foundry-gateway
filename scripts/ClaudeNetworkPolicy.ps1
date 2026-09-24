function Set-ClaudeNetworkPolicyText {
    param([string]$Policy,[string[]]$AllowedCidrs,[string]$EdgeId)
    if ($EdgeId -notmatch '^[a-zA-Z0-9-]{1,80}$' -or $EdgeId.Contains('--')) { throw 'Invalid edge identifier.' }
    if (-not $AllowedCidrs.Count) { throw 'At least one explicit edge source range is required.' }
    if ($Policy -match '<!-- claude-network-edge:([^:]+):begin -->' -and $Matches[1] -ne $EdgeId) { throw 'This policy belongs to another edge; remove that edge restriction explicitly first.' }
    $Policy = Remove-ClaudeNetworkPolicyText -Policy $Policy -EdgeId $EdgeId
    $addresses = @()
    foreach ($cidr in $AllowedCidrs) {
        $range = Get-ClaudeNetworkCidr $cidr
        if ($range.Prefix -lt 8) { throw 'Refusing an unrestricted or excessively broad edge source range.' }
        if ($range.Prefix -eq 32) { $addresses += "<address>$(ConvertFrom-ClaudeNetworkNumber $range.First)</address>" }
        else { $addresses += "<address-range from=`"$(ConvertFrom-ClaudeNetworkNumber $range.First)`" to=`"$(ConvertFrom-ClaudeNetworkNumber $range.Last)`" />" }
    }
    $block = @"
<!-- claude-network-edge:${EdgeId}:begin -->
<ip-filter action="allow">$($addresses -join '')</ip-filter>
<set-variable name="claude-edge-client-ip" value="@(context.Request.Headers.GetValueOrDefault(&quot;X-Claude-Client-IP&quot;, context.Request.IpAddress))" />
<set-header name="X-Claude-Client-IP" exists-action="delete" />
<!-- claude-network-edge:${EdgeId}:end -->
"@
    $count = @(0)
    $result = [regex]::Replace($Policy, '(?s)<!--.*?-->|<inbound\s*/?>', [Text.RegularExpressions.MatchEvaluator]{
        param($match)
        if ($match.Value.StartsWith('<!--')) { return $match.Value }
        $count[0]++
        $close = if ($match.Value -match '/>') { '</inbound>' } else { '' }
        return "<inbound>$block$close"
    })
    if ($count[0] -ne 1) { throw 'Cannot uniquely locate service inbound policy. No policy was changed.' }
    return $result
}

function Remove-ClaudeNetworkPolicyText {
    param([string]$Policy,[string]$EdgeId)
    if ($EdgeId -notmatch '^[a-zA-Z0-9-]{1,80}$' -or $EdgeId.Contains('--')) { throw 'Invalid edge identifier.' }
    $pattern = '(?s)<!-- claude-network-edge:' + [regex]::Escape($EdgeId) + ':begin -->.*?<!-- claude-network-edge:' + [regex]::Escape($EdgeId) + ':end -->'
    return [regex]::Replace($Policy,$pattern,'')
}
