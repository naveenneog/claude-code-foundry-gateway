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
function Get-GraphToken {
    $t = az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv 2>$null
    if (-not $t) { throw "Could not acquire a Microsoft Graph token. Run: az login" }
    return $t.Trim()
}

function Get-GroupMemberOids {
    param([string]$GroupName, [string]$Token)

    $gid = az ad group show --group $GroupName --query id -o tsv 2>$null
    if (-not $gid) {
        Write-Warning "Group '$GroupName' not found - treating as empty."
        return @()
    }
    $gid = $gid.Trim()

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

        do {
            $page = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get -ErrorAction Stop
            foreach ($m in $page.value) {
                $members += [pscustomobject]@{
                    Oid  = $m.id
                    Name = if ($m.userPrincipalName) { $m.userPrincipalName } else { $m.displayName }
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
