<#
.SYNOPSIS
    Creates, or brings into line, the Microsoft Entra application that makes Turnstile admin-only.

.DESCRIPTION
    Turnstile's fork (naveenneog/turnstile, branch claude-gateway) signs people in with
    Microsoft Entra and lets in only those holding its admin app role. This creates the
    pieces that rule depends on, and is safe to run again: anything already right is left
    alone, and anything missing is added.

      application        single tenant, access tokens v2, Application ID URI api://<appId>
      app role           Turnstile.Admin, for users and for applications (workload identities)
      delegated scope    Turnstile.Manage, pre-authorized for the Azure CLI, so `az login`
                         users and scripts get a token without a consent prompt
      enterprise app     assignment required: Entra refuses a token to anyone not assigned
                         (AADSTS50105, measured in docs/TURNSTILE.md)
      admin group        a security group assigned the role. Assigning a group needs
                         Microsoft Entra ID P1 or P2; without it, use -AssignUser
      sign-in redirect   the Turnstile web address as a single-page-app redirect, once known

    Run it twice. Before deploying Turnstile, to get the client id the deployment needs;
    after, with -WebUrl, to add the sign-in redirect.

.PARAMETER WebUrl
    Turnstile's web address, for example https://<api-app>.azurewebsites.net. Known after
    the deployment; omit on the first run.

.PARAMETER AdminGroupName
    The security group whose members administer Turnstile. Created if missing, with you as
    its first member.

.PARAMETER AssignUser
    UPNs or object ids to assign the role directly, for tenants without P1.

.EXAMPLE
    ./scripts/New-ClaudeTurnstileEntraApp.ps1

.EXAMPLE
    ./scripts/New-ClaudeTurnstileEntraApp.ps1 -WebUrl https://api-turnstile-contoso.azurewebsites.net
#>
[CmdletBinding()]
param(
    [string]$DisplayName = 'Turnstile - Claude FinOps',
    [string]$WebUrl,
    [string]$AdminGroupName = 'turnstile-claude-admins',
    [string[]]$AssignUser = @(),
    [switch]$NoGroup,
    [string]$RoleValue = 'Turnstile.Admin',
    [string]$ScopeValue = 'Turnstile.Manage'
)

$ErrorActionPreference = 'Stop'
$graph = 'https://graph.microsoft.com/v1.0'
# The Azure CLI's public client id, published by Microsoft. Pre-authorizing it is what lets
# `az account get-access-token --scope api://<app>/Turnstile.Manage` work without consent.
$azureCli = '04b07795-8ddb-461a-bbee-02f9e1bf7b46'

$tenant = az account show --query tenantId -o tsv 2>$null
if (-not $tenant) { throw 'Not signed in. Run: az login' }
$changes = New-Object System.Collections.Generic.List[string]

# Bodies go through a file: on Windows az is a .cmd shim, and cmd.exe strips the double
# quotes out of an inline JSON argument (docs/TURNSTILE.md, troubleshooting).
function Invoke-Graph([string]$Method, [string]$Path, $Body = $null) {
    $cmd = @('rest', '--method', $Method, '--url', "$graph$Path")
    $file = $null
    if ($null -ne $Body) {
        $file = [IO.Path]::GetTempFileName()
        [IO.File]::WriteAllText($file, ($Body | ConvertTo-Json -Depth 10 -Compress), (New-Object System.Text.UTF8Encoding($false)))
        $cmd += @('--headers', 'Content-Type=application/json', '--body', "@$file")
    }
    try {
        $raw = az @cmd 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { throw "Graph $Method $Path failed: $($raw.Trim())" }
        if ($raw.Trim()) { return ($raw | ConvertFrom-Json) }
    }
    finally { if ($file) { Remove-Item $file -ErrorAction SilentlyContinue } }
}

function Get-Single([string]$Path) { @((Invoke-Graph GET $Path).value) }

# --- application ------------------------------------------------------------------------
$filterName = [uri]::EscapeDataString("displayName eq '$($DisplayName -replace "'", "''")'")
$apps = Get-Single "/applications?`$filter=$filterName"
if ($apps.Count -gt 1) { throw "$($apps.Count) applications are named '$DisplayName'. Rename all but one, or pass a unique -DisplayName." }
if ($apps.Count -eq 1) { $app = $apps[0] }
else {
    $app = Invoke-Graph POST '/applications' @{
        displayName    = $DisplayName
        signInAudience = 'AzureADMyOrg'
        api            = @{ requestedAccessTokenVersion = 2 }
    }
    $changes.Add("created application $($app.appId)")
}

# Single tenant, always: Turnstile accepts bearer tokens only from a pinned tenant, because
# in a multi-tenant app another tenant's administrator can assign the app role to anyone.
if ($app.signInAudience -ne 'AzureADMyOrg') { throw "'$DisplayName' is $($app.signInAudience). Turnstile's admin-only rule needs a single-tenant application (AzureADMyOrg)." }

$patch = @{}
$role = @($app.appRoles | Where-Object value -eq $RoleValue)[0]
if (-not $role) {
    $role = @{ id = [guid]::NewGuid().ToString(); value = $RoleValue; displayName = 'Turnstile administrator'
        description = 'Administers Turnstile: budgets, catalog, people and usage.'; allowedMemberTypes = @('User', 'Application'); isEnabled = $true }
    $patch.appRoles = @(@($app.appRoles) + $role)
    $changes.Add("added app role $RoleValue")
}
elseif (@($role.allowedMemberTypes) -notcontains 'Application') {
    throw "App role $RoleValue does not allow applications, so a workload identity cannot hold it. Allow 'Applications' on the role in the portal."
}
$scope = @($app.api.oauth2PermissionScopes | Where-Object value -eq $ScopeValue)[0]
$api = @{ requestedAccessTokenVersion = 2; oauth2PermissionScopes = @($app.api.oauth2PermissionScopes); preAuthorizedApplications = @($app.api.preAuthorizedApplications) }
if (-not $scope) {
    $scope = @{ id = [guid]::NewGuid().ToString(); value = $ScopeValue; type = 'User'; isEnabled = $true
        adminConsentDisplayName = 'Manage Turnstile'; adminConsentDescription = 'Manage Turnstile as the signed-in administrator.'
        userConsentDisplayName = 'Manage Turnstile'; userConsentDescription = 'Manage Turnstile as you.' }
    $api.oauth2PermissionScopes = @($api.oauth2PermissionScopes + $scope)
    $patch.api = $api
    $changes.Add("added scope $ScopeValue")
}
if ($app.api.requestedAccessTokenVersion -ne 2) { $patch.api = $api; $changes.Add('access tokens set to v2') }
if (@($app.identifierUris) -notcontains "api://$($app.appId)") {
    $patch.identifierUris = @(@($app.identifierUris) + "api://$($app.appId)")
    $changes.Add("Application ID URI api://$($app.appId)")
}
if ($WebUrl) {
    $redirect = $WebUrl.TrimEnd('/')
    if (@($app.spa.redirectUris) -notcontains $redirect) {
        $patch.spa = @{ redirectUris = @(@($app.spa.redirectUris) + $redirect) }
        $changes.Add("sign-in redirect $redirect")
    }
}
if ($patch.Count) { Invoke-Graph PATCH "/applications/$($app.id)" $patch | Out-Null }

# Pre-authorization names the scope by id, so it can only be added once the scope exists.
$app = Invoke-Graph GET "/applications/$($app.id)"
$scopeId = @($app.api.oauth2PermissionScopes | Where-Object value -eq $ScopeValue)[0].id
$cli = @($app.api.preAuthorizedApplications | Where-Object appId -eq $azureCli)[0]
if (-not $cli -or @($cli.delegatedPermissionIds) -notcontains $scopeId) {
    $others = @($app.api.preAuthorizedApplications | Where-Object appId -ne $azureCli)
    Invoke-Graph PATCH "/applications/$($app.id)" @{ api = @{ preAuthorizedApplications = @($others + @{ appId = $azureCli; delegatedPermissionIds = @($scopeId) }) } } | Out-Null
    $changes.Add('Azure CLI pre-authorized')
}
$roleId = @($app.appRoles | Where-Object value -eq $RoleValue)[0].id

# --- enterprise application -------------------------------------------------------------
$sps = Get-Single "/servicePrincipals?`$filter=$([uri]::EscapeDataString("appId eq '$($app.appId)'"))"
$sp = if ($sps.Count) { $sps[0] } else { $changes.Add('created enterprise application'); Invoke-Graph POST '/servicePrincipals' @{ appId = $app.appId } }
if (-not $sp.appRoleAssignmentRequired) {
    Invoke-Graph PATCH "/servicePrincipals/$($sp.id)" @{ appRoleAssignmentRequired = $true } | Out-Null
    $changes.Add('assignment required: Yes')
}
$assigned = @((Invoke-Graph GET "/servicePrincipals/$($sp.id)/appRoleAssignedTo").value)

function Grant-Role([string]$PrincipalId, [string]$PrincipalPath, [string]$Label) {
    if (@($assigned | Where-Object { $_.principalId -eq $PrincipalId -and $_.appRoleId -eq $roleId }).Count) { return }
    Invoke-Graph POST "$PrincipalPath/$PrincipalId/appRoleAssignments" @{ principalId = $PrincipalId; resourceId = $sp.id; appRoleId = $roleId } | Out-Null
    $changes.Add("assigned $RoleValue to $Label")
}

# --- admin group ------------------------------------------------------------------------
$group = $null
if (-not $NoGroup) {
    $groups = Get-Single "/groups?`$filter=$([uri]::EscapeDataString("displayName eq '$($AdminGroupName -replace "'", "''")'"))"
    if ($groups.Count -gt 1) { throw "$($groups.Count) groups are named '$AdminGroupName'. Pass a unique -AdminGroupName." }
    if ($groups.Count) { $group = $groups[0] }
    else {
        $nick = ($AdminGroupName -replace '[^A-Za-z0-9]', '').ToLowerInvariant()
        $group = Invoke-Graph POST '/groups' @{ displayName = $AdminGroupName; mailEnabled = $false; mailNickname = $nick; securityEnabled = $true
            description = "Administers Turnstile ($DisplayName)." }
        $me = az ad signed-in-user show --query id -o tsv
        Invoke-Graph POST "/groups/$($group.id)/members/`$ref" @{ '@odata.id' = "$graph/directoryObjects/$me" } | Out-Null
        $changes.Add("created group $AdminGroupName with you as its member")
    }
    Grant-Role $group.id '/groups' "group $AdminGroupName"
}
foreach ($u in $AssignUser) {
    $user = Invoke-Graph GET "/users/$([uri]::EscapeDataString($u))"
    Grant-Role $user.id '/users' $user.userPrincipalName
}

$summary = [pscustomobject][ordered]@{
    DisplayName       = $DisplayName
    entraClientId     = $app.appId
    entraTenantId     = $tenant
    entraAdminRole    = $RoleValue
    Scope             = "api://$($app.appId)/$ScopeValue"
    AssignmentRequired = $true
    AdminGroup        = $(if ($group) { $group.displayName } else { $null })
    AdminGroupId      = $(if ($group) { $group.id } else { $null })
    SignInRedirects   = @($app.spa.redirectUris) + $(if ($WebUrl -and @($app.spa.redirectUris) -notcontains $WebUrl.TrimEnd('/')) { $WebUrl.TrimEnd('/') } else { @() })
    Changes           = $(if ($changes.Count) { $changes.ToArray() } else { @('none - already configured') })
}
Write-Host ''
Write-Host "Entra application for Turnstile: $DisplayName" -ForegroundColor Cyan
foreach ($c in $summary.Changes) { Write-Host "  $c" }
Write-Host ''
Write-Host '  In Turnstile''s main.parameters.json:' -ForegroundColor DarkGray
Write-Host "    entraClientId  = $($app.appId)" -ForegroundColor DarkGray
Write-Host "    entraTenantId  = $tenant" -ForegroundColor DarkGray
Write-Host "    entraAdminRole = $RoleValue" -ForegroundColor DarkGray
if (-not $WebUrl) { Write-Host '  After deploying, run this again with -WebUrl <Turnstile address> to add the sign-in redirect.' -ForegroundColor DarkGray }
$summary
