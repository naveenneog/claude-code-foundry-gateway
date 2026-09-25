<#
.SYNOPSIS
    Creates or reconciles AUM's owned, single-tenant Entra registration without tenant consent.
.DESCRIPTION
    Follows New-ClaudeTurnstileEntraApp: v2 tokens, assignment required,
    ApplicationGroup claims, and Azure CLI pre-authorized for a delegated scope.
    No password, client secret, Graph application permission or developer sign-in.
    The signed-in person is assigned Admin unless -SkipOwnerAssignment is passed.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact='Medium')]
param(
    [string]$DisplayName = 'AUM',
    [string]$ClientId,
    [string]$SubscriptionId,
    [switch]$SkipOwnerAssignment
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ClaudeAumDeployment.ps1')
$graph = 'https://graph.microsoft.com/v1.0'
# Published public-client id; this is a Microsoft platform constant, not deployment data.
$cliId = '04b07795-8ddb-461a-bbee-02f9e1bf7b46'
function Invoke-AumGraph {
    param([string]$Method, [string]$Path, $Body)
    if ($Method -eq 'GET' -and $Path.Contains('&')) {
        $access = Invoke-ClaudeAumAz @('account','get-access-token','--subscription',$SubscriptionId,'--resource','https://graph.microsoft.com','-o','json')
        return Invoke-RestMethod -Method Get -Uri "$graph$Path" -Headers @{ Authorization=('Bearer ' + $access.accessToken) }
    }
    $args = @('rest','--method',$Method,'--url',"$graph$Path",'--subscription',$SubscriptionId,'-o','json')
    $file = $null
    try {
        if ($null -ne $Body) {
            $file = New-ClaudeAumLocalFile
            Write-ClaudeAumJson $file $Body
            $args += @('--headers','Content-Type=application/json','--body',"@$file")
        }
        return Invoke-ClaudeAumAz $args
    }
    finally { if ($file) { Remove-Item $file -ErrorAction SilentlyContinue } }
}
if (-not $SubscriptionId) { $SubscriptionId = (Invoke-ClaudeAumAz @('account','show','-o','json')).id }
$account = Invoke-ClaudeAumAz @('account','show','--subscription',$SubscriptionId,'-o','json')
$me = Invoke-AumGraph GET '/me'
if (-not $me.id) { throw 'Sign in as a person who can create and own app registrations: az login' }
$filter = if ($ClientId) { "appId eq '$([guid]$ClientId)'" } else { "displayName eq '$($DisplayName.Replace("'","''"))'" }
$found = @((Invoke-AumGraph GET ("/applications?`$filter=" + [uri]::EscapeDataString($filter))).value)
if ($found.Count -gt 1) { throw 'More than one AUM registration matches. Pass -ClientId or a unique -DisplayName.' }
if ($ClientId -and -not $found.Count) { throw 'The requested AUM application was not found.' }
if (-not $PSCmdlet.ShouldProcess($DisplayName, 'Create/reconcile owned AUM app, three roles, CLI scope and assignment-required enterprise app')) {
    return [pscustomobject]@{ DisplayName=$DisplayName; WhatIf=$true; ChangesPlanned='AUM roles, AUM.Access, Azure CLI pre-authorization; no tenant consent' }
}
$app = if ($found.Count) { $found[0] } else {
    Invoke-AumGraph POST '/applications' @{ displayName=$DisplayName; signInAudience='AzureADMyOrg'; api=@{ requestedAccessTokenVersion=2 } }
}
if ($app.signInAudience -ne 'AzureADMyOrg') { throw 'AUM requires an existing single-tenant AzureADMyOrg application. No multi-tenant token authority is accepted.' }
$owners = @((Invoke-AumGraph GET "/applications/$($app.id)/owners").value)
if (@($owners | Where-Object id -eq $me.id).Count -eq 0) {
    Invoke-AumGraph POST "/applications/$($app.id)/owners/`$ref" @{ '@odata.id'="$graph/directoryObjects/$($me.id)" } | Out-Null
}
$roles = @($app.appRoles)
foreach ($name in @('Admin','Viewer','Manager')) {
    $value = "AUM.$name"
    $existing = @($roles | Where-Object value -eq $value)
    if ($existing.Count) {
        if (-not $existing[0].isEnabled -or @($existing[0].allowedMemberTypes) -notcontains 'User') {
            throw "$value exists but is disabled or cannot be assigned to people. Repair App registrations > App roles before proceeding."
        }
    }
    else {
        $roles += @{ id=[guid]::NewGuid().ToString(); value=$value; displayName="AUM $name"; isEnabled=$true
            allowedMemberTypes=@('User'); description="AUM $name access. Developers are not assigned a service role." }
    }
}
$scopes = @($app.api.oauth2PermissionScopes)
$scope = @($scopes | Where-Object value -eq 'AUM.Access')[0]
if (-not $scope) {
    $scope = @{ id=[guid]::NewGuid().ToString(); value='AUM.Access'; type='User'; isEnabled=$true
        adminConsentDisplayName='Use Azure Usage Management'; adminConsentDescription='Use AUM within the signed-in person role and manager scope.'
        userConsentDisplayName='Use Azure Usage Management'; userConsentDescription='Use AUM with your assigned role.' }
    $scopes += $scope
}
elseif (-not $scope.isEnabled) { throw 'AUM.Access exists but is disabled. Enable it before proceeding.' }
$patch = @{
    appRoles=$roles; groupMembershipClaims='ApplicationGroup'
    identifierUris=@(@($app.identifierUris) + "api://$($app.appId)" | Select-Object -Unique)
    api=@{ requestedAccessTokenVersion=2; oauth2PermissionScopes=$scopes; preAuthorizedApplications=@($app.api.preAuthorizedApplications) }
}
Invoke-AumGraph PATCH "/applications/$($app.id)" $patch | Out-Null
# Add pre-authorization only after the API scope exists. Preserve other authorizations.
$app = Invoke-AumGraph GET "/applications/$($app.id)"
$scopeId = @($app.api.oauth2PermissionScopes | Where-Object value -eq 'AUM.Access')[0].id
$preauthorized = @($app.api.preAuthorizedApplications | Where-Object appId -ne $cliId)
$oldCli = @($app.api.preAuthorizedApplications | Where-Object appId -eq $cliId)[0]
$permissions = @(@($oldCli.delegatedPermissionIds) + $scopeId | Where-Object { $_ } | Select-Object -Unique)
$preauthorized += @{ appId=$cliId; delegatedPermissionIds=$permissions }
Invoke-AumGraph PATCH "/applications/$($app.id)" @{ api=@{ preAuthorizedApplications=$preauthorized } } | Out-Null
$sps = @((Invoke-AumGraph GET ("/servicePrincipals?`$filter=" + [uri]::EscapeDataString("appId eq '$($app.appId)'"))).value)
$sp = if ($sps.Count) { $sps[0] } else { Invoke-AumGraph POST '/servicePrincipals' @{ appId=$app.appId } }
if (-not $sp.appRoleAssignmentRequired) {
    Invoke-AumGraph PATCH "/servicePrincipals/$($sp.id)" @{ appRoleAssignmentRequired=$true } | Out-Null
}
if (-not $SkipOwnerAssignment) {
    $roleId = @($app.appRoles | Where-Object value -eq 'AUM.Admin')[0].id
    # Graph rejects principalId filtering on this relationship in some tenants.
    # Follow the proven Turnstile route, including continuation pages.
    $path = "/servicePrincipals/$($sp.id)/appRoleAssignedTo"
    $alreadyAssigned = $false
    while ($path) {
        $page = Invoke-AumGraph GET $path
        if (@($page.value | Where-Object { $_.principalId -eq $me.id -and $_.appRoleId -eq $roleId }).Count) {
            $alreadyAssigned = $true
            break
        }
        $next = [string]$page.'@odata.nextLink'
        if ($next -and -not $next.StartsWith("$graph/")) { throw 'Graph returned an unexpected assignment continuation address.' }
        $path = if ($next) { $next.Substring($graph.Length) } else { $null }
    }
    if (-not $alreadyAssigned) {
        Invoke-AumGraph POST "/users/$($me.id)/appRoleAssignments" @{ principalId=$me.id; resourceId=$sp.id; appRoleId=$roleId } | Out-Null
    }
}
[pscustomobject]@{
    DisplayName=$app.displayName; ClientId=$app.appId; ApplicationObjectId=$app.id
    ServicePrincipalId=$sp.id; TenantId=$account.tenantId; OwnerObjectId=$me.id
    Scope="api://$($app.appId)/AUM.Access"; AssignmentRequired=$true
    AppRoles=@($app.appRoles | Select-Object value,id)
}
