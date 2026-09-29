<#
    Reading group membership from Microsoft Graph.

    Shared because two things need the same answer and must not drift apart:
    Sync-ClaudeAccess.ps1, which writes entitlement into the gateway, and
    Compare-ClaudeEntitlement.ps1, which checks what the gateway is enforcing
    against what the directory says. A comparison that reads membership
    differently from the sync reports drift that is its own.

    The request form here is not obvious and was arrived at by measurement.
    See the comment on the casts below.
#>
. (Join-Path $PSScriptRoot 'ClaudeNetwork.ps1')

function Get-ClaudeGraphFailureRemedy {
    param([string]$Message)
    if ($Message -match 'LocationConditionEvaluationSatisfied|Continuous access evaluation resulted in challenge') {
        return 'CAE location/IP variation: the operator stays fully on or off the VPN for sign-in and Graph. The network team checks split tunneling and IPv6/IPv4 egress. The customer Entra admin reviews the actual addresses in sign-in logs and the named location or a time-limited temporary exclusion. Azure Cloud Shell is an alternative only if its different outbound location is allowed; it is not a Conditional Access bypass and does not inherit private VNet access. Source: https://learn.microsoft.com/entra/identity/conditional-access/howto-continuous-access-evaluation-troubleshoot (2026-09-29).'
    }
    return 'The operator verifies az login and Graph connectivity; the customer Entra admin verifies directory read permission. A denied or failed read is not an absent group.'
}

function Get-GraphToken {
    try {
        $result = Invoke-ClaudeNetworkAz @('account','get-access-token','--resource','https://graph.microsoft.com')
        if (-not $result -or -not $result.accessToken) { throw 'No Microsoft Graph access token was returned.' }
        return [string]$result.accessToken
    } catch {
        throw "Graph token acquisition failed: $($_.Exception.Message) $(Get-ClaudeGraphFailureRemedy $_.Exception.Message)"
    }
}

function Invoke-ClaudeGraphRead {
    param([string]$Uri, [string]$Token, [hashtable]$Headers = @{})
    if ($Uri -notmatch '^https://graph\.microsoft\.com/v1\.0/') { throw 'Graph nextLink is outside the expected Graph endpoint.' }
    $requestHeaders = @{ Authorization = "Bearer $Token" }
    foreach ($key in $Headers.Keys) { $requestHeaders[$key] = $Headers[$key] }
    try {
        Invoke-RestMethod -Uri $Uri -Headers $requestHeaders -Method Get -TimeoutSec 30 -ErrorAction Stop
    } catch {
        throw "Graph read failed: $($_.Exception.Message) $(Get-ClaudeGraphFailureRemedy $_.Exception.Message)"
    }
}

function Get-ClaudeGraphGroup {
    param([string]$GroupName, [string]$Token)
    if ([string]::IsNullOrWhiteSpace($GroupName)) { throw 'Graph group name is required.' }
    $property = if ($GroupName -match '^[0-9a-fA-F-]{36}$') { 'id' } else { 'displayName' }
    $filter = [uri]::EscapeDataString("$property eq '$($GroupName.Replace("'", "''"))'")
    $page = Invoke-ClaudeGraphRead -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=$filter&`$select=id&`$top=2" -Token $Token
    if (-not $page -or -not $page.PSObject.Properties['value'] -or $page.value -isnot [array]) {
        throw "Graph group '$GroupName' lookup returned an invalid collection, not a confirmed absence."
    }
    $groups = @($page.value)
    if ($groups.Count -gt 1 -or $page.PSObject.Properties['@odata.nextLink']) { throw "Graph group '$GroupName' is ambiguous: multiple groups or incomplete lookup." }
    if ($groups.Count -eq 0) { return $null }
    if (-not $groups[0].PSObject.Properties['id'] -or -not $groups[0].id) { throw "Graph group '$GroupName' has no id." }
    return $groups[0]
}

function Get-GroupMemberOids {
    param([string]$GroupName, [string]$Token)

    $group = Get-ClaudeGraphGroup -GroupName $GroupName -Token $Token
    if (-not $group) {
        Write-Warning "Group '$GroupName' not found - treating as empty."
        return @()
    }
    $gid = [string]$group.id

    # Transitive membership so nested groups work the way admins expect, and
    # cast so that nested groups themselves do not come back as members.
    #
    # Measured 2026-09-15: transitiveMembers on claude-code-standard, which has
    # one team group nested inside it, returned 7 objects - 5 users and 2
    # #microsoft.graph.group. Without the cast those group object ids would be
    # written into the entitlement list and the business unit map, spending the
    # 4,096-character named value budget that holds roughly 110 object ids, and
    # inflating the count of developers reported as mapped.
    #
    # The cast filters server-side. Filtering here on @odata.type would not
    # work: under a cast Graph omits that property entirely, so the check would
    # discard every member instead. Measured: the cast returns 5 users, 0 groups.
    #
    # Called through Invoke-RestMethod rather than `az rest`. On Windows az is
    # a .cmd shim, and PowerShell only wraps a native argument in quotes when it
    # contains a space. A Graph URL has no spaces but does have '&' between
    # query parameters, so cmd.exe treated it as a command separator and tried
    # to run '$top=999':
    #
    #   '$top' is not recognized as an internal or external command
    #
    # Quoting the URL here would not help either, because @odata.nextLink URLs
    # carry '&' too, so paging would reintroduce it on the second request.
    # Going direct keeps cmd.exe out of the path entirely.
    #
    # $select and $top are escaped so PowerShell does not expand them itself.
    $headers = @{ Authorization = "Bearer $Token" }
    # Two casts, not one. A group can hold people and workload identities, and
    # both call the gateway: a build agent or scheduled job authenticates as a
    # service principal and needs the same entitlement a developer does.
    #
    # Measured 2026-09-16 on claude-code-premium, which holds one team group and
    # one service principal, every combination against the same group:
    #
    #   transitiveMembers                                    3  SP missing
    #   transitiveMembers/microsoft.graph.user               2
    #   transitiveMembers/microsoft.graph.servicePrincipal   0  SP missing
    #   transitiveMembers/microsoft.graph.servicePrincipal
    #     + ConsistencyLevel: eventual                       0  SP missing
    #     + $count=true                                      0  SP missing
    #     + ConsistencyLevel: eventual AND $count=true       1  found
    #
    # A service principal is only returned when both the header and $count are
    # present. With one or neither Graph returns 200 and an empty collection -
    # it does not error - so the sync read "no service principals" and wrote an
    # entitlement list without them. The service principal sat in the group
    # looking entitled and got 403 at the gateway: adding it was a silent no-op.
    #
    # The user cast returns the same 2 either way, so both casts are issued the
    # same way rather than leaving one subtly different.
    #
    # There is no single cast that returns both, and the uncast call returns
    # nested groups as well, which is what the cast exists to exclude. So the
    # two are fetched separately and merged.
    $headers['ConsistencyLevel'] = 'eventual'

    $casts = @(
        @{ Type = 'microsoft.graph.user';             Select = 'id,displayName,userPrincipalName' }
        @{ Type = 'microsoft.graph.servicePrincipal'; Select = 'id,displayName' }
    )

    $members = @()
    foreach ($cast in $casts) {
        $uri = "https://graph.microsoft.com/v1.0/groups/$gid/transitiveMembers/$($cast.Type)" +
               "?`$select=$($cast.Select)&`$top=999&`$count=true"

        $seenLinks = @{}
        do {
            if ($seenLinks.ContainsKey($uri)) { throw 'Graph membership nextLink repeated; the scan is incomplete.' }
            $seenLinks[$uri] = $true
            $page = Invoke-ClaudeGraphRead -Uri $uri -Token $Token -Headers @{ ConsistencyLevel = $headers['ConsistencyLevel'] }
            if (-not $page -or -not $page.PSObject.Properties['value'] -or $page.value -isnot [array]) {
                throw "Graph membership for '$GroupName' returned an invalid collection."
            }
            foreach ($m in $page.value) {
                if (-not $m.PSObject.Properties['id'] -or -not $m.id) { throw "Graph membership for '$GroupName' contains an identity without an id." }
                $upn = $m.PSObject.Properties['userPrincipalName']
                $displayName = $m.PSObject.Properties['displayName']
                $members += [pscustomobject]@{
                    Oid  = $m.id
                    Name = if ($upn -and $upn.Value) { $upn.Value } elseif ($displayName) { $displayName.Value } else { $m.id }
                }
            }
            # A page is capped at 999, so a larger group arrives over several
            # requests. The previous version ignored nextLink and silently synced
            # only the first 999 members.
            #
            # Read through PSObject rather than as a property: the last page has
            # no nextLink, and under Set-StrictMode - which a caller can impose,
            # as Install-ClaudeGateway.ps1 briefly did - reading a missing
            # property throws and the whole sync stops.
            $next = $page.PSObject.Properties['@odata.nextLink']
            $uri = if ($next) { $next.Value } else { $null }
        } while ($uri)
    }

    return $members
}
