# Whether the projection sync job's identity holds the Microsoft Graph application permission
# GroupMember.Read.All (ADR-0058 decision 3). Read only: granting stays with a Privileged Role Administrator
# or Global Administrator (scripts/Grant-ClaudeProjectionRenewalGraphAccess.ps1). The read uses the signed-in
# operator's Graph access, and a read that fails reports unknown rather than a guess. The role is matched
# here, not with az --query: on Windows az is az.cmd, and cmd.exe re-reads | and quotes in its arguments.

function Get-ClaudeProjectionGraphGrant {
    param([Parameter(Mandatory = $true)][string]$PrincipalId)
    if ($PrincipalId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
        throw "-PrincipalId '$PrincipalId' is not an object id."
    }
    $permission = 'GroupMember.Read.All'
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # Lines az writes to stderr stay out of the parse: a warning with exit code 0 would otherwise break it.
        $graphOutput = @(az ad sp show --id '00000003-0000-0000-c000-000000000000' -o json 2>&1)
        if ($LASTEXITCODE -ne 0) { return [pscustomobject]@{ State = 'unknown'; Detail = "the Microsoft Graph service principal could not be read: $((($graphOutput | Out-String).Trim()))" } }
        $graph = (@($graphOutput | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] }) | Out-String) | ConvertFrom-Json
        $roleId = @($graph.appRoles | Where-Object { [string]::Equals([string]$_.value, $permission, [StringComparison]::Ordinal) } | ForEach-Object { [string]$_.id })[0]
        if (-not $graph.id -or -not $roleId) { return [pscustomobject]@{ State = 'unknown'; Detail = "Microsoft Graph lists no $permission application role." } }
        $assignmentsOutput = @(az rest --method get --url "https://graph.microsoft.com/v1.0/servicePrincipals/$PrincipalId/appRoleAssignments" -o json 2>&1)
        if ($LASTEXITCODE -ne 0) { return [pscustomobject]@{ State = 'unknown'; Detail = "the identity's app role assignments could not be read: $((($assignmentsOutput | Out-String).Trim()))" } }
        $assignments = (@($assignmentsOutput | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] }) | Out-String) | ConvertFrom-Json
        $held = @(@($assignments.value) | Where-Object {
                [string]::Equals([string]$_.resourceId, [string]$graph.id, [StringComparison]::OrdinalIgnoreCase) -and
                [string]::Equals([string]$_.appRoleId, $roleId, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
        return [pscustomobject]@{ State = $(if ($held) { 'held' } else { 'missing' }); Detail = '' }
    }
    catch { return [pscustomobject]@{ State = 'unknown'; Detail = $_.Exception.Message } }
    finally { $ErrorActionPreference = $previous }
}
