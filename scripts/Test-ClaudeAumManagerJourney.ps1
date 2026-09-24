<#
.SYNOPSIS
    Plans, or explicitly executes, an owned-group manager-only AUM journey.
.DESCRIPTION
    Default is READ-ONLY. Execute only after the lead sends "go": this changes
    the CLI account's membership in two shared test groups. No tenant admin is
    needed. All group/role changes and the test budget are restored in finally.

    TokenAcquirer can supply a freshly issued delegated token after a role
    change. The default Azure CLI cache can retain old role claims; the script
    detects those through /me and refuses rather than calling that a manager test.
    It never clears or modifies the shared Azure CLI token cache.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
param(
    [string]$RecordPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'onboarding\aum-service.json'),
    [Parameter(Mandatory)][guid]$UnitManagerGroupId,
    [Parameter(Mandatory)][guid]$TeamManagerGroupId,
    [Parameter(Mandatory)][string]$UnitId,
    [Parameter(Mandatory)][string]$TeamId,
    [Parameter(Mandatory)][string]$OutsideTeamId,
    [switch]$Execute,
    [ValidateSet('go')][string]$LeadApproval,
    [scriptblock]$TokenAcquirer
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ClaudeAumDeployment.ps1')
$record = Get-Content $RecordPath -Raw | ConvertFrom-Json
$graph = 'https://graph.microsoft.com/v1.0'
$me = Invoke-ClaudeAumAz @('ad','signed-in-user','show','-o','json')
function Invoke-GraphJourney {
    param([string]$Method, [string]$Path, $Body)
    $file = $null
    try {
        $arguments = @('rest','--method',$Method,'--url',"$graph$Path",'-o','json')
        if ($null -ne $Body) {
            $file = New-ClaudeAumLocalFile
            Write-ClaudeAumJson $file $Body
            $arguments += @('--headers','Content-Type=application/json','--body',"@$file")
        }
        return Invoke-ClaudeAumAz $arguments
    }
    finally { if ($file) { Remove-Item $file -ErrorAction SilentlyContinue } }
}
function Get-Membership([string]$Group) {
    return [bool](Invoke-ClaudeAumAz @('ad','group','member','check','--group',$Group,'--member-id',$me.id,'-o','json')).value
}
function Set-Membership([string]$Group, [bool]$Present) {
    if ((Get-Membership $Group) -eq $Present) { return }
    $verb = if ($Present) { 'add' } else { 'remove' }
    Invoke-ClaudeAumAz @('ad','group','member',$verb,'--group',$Group,'--member-id',$me.id,'-o','json') | Out-Null
}
function Get-JourneyToken {
    param([string]$Phase)
    if ($TokenAcquirer) { return ([string](& $TokenAcquirer $record.scope $Phase)).Trim() }
    $token = Invoke-ClaudeAumAz @('account','get-access-token','--scope',$record.scope,'-o','json')
    return [string]$token.accessToken
}
function Invoke-JourneyApi {
    param([string]$Token, [string]$Method, [string]$Path, $Body, [string]$Revision)
    $headers = @{ Authorization='Bearer ' + $Token }
    if ($Revision) { $headers['If-Match'] = Format-ClaudeAumIfMatch $Revision }
    $arguments = @{ Uri="$($record.endpoint)/api/v1/$Path"; Headers=$headers; Method=$Method; TimeoutSec=90 }
    if ($null -ne $Body) { $arguments.ContentType='application/json'; $arguments.Body=($Body | ConvertTo-Json -Depth 10) }
    return Invoke-RestMethod @arguments
}
function Set-JourneyMapping([string]$Key, $Group) {
    $current = Invoke-JourneyApi $adminToken GET 'budgets'
    Invoke-JourneyApi $adminToken PUT "manager-groups/$Key" @{manager_group_id=$Group; reason='Manager-journey controlled mapping'} $current.revision | Out-Null
}
function Assert-Forbidden([string]$Token, [string]$Method, [string]$Path, $Body, [string]$Revision) {
    try { Invoke-JourneyApi $Token $Method $Path $Body $Revision | Out-Null }
    catch {
        if ([int]$_.Exception.Response.StatusCode -eq 403) { return }
        throw
    }
    throw "Expected 403 for $Method $Path; manager isolation failed."
}
$app = Invoke-GraphJourney GET "/applications/$($record.applicationObjectId)"
$role = @($app.appRoles | Where-Object value -eq 'AUM.Manager')[0]
$privilegedIds = @($app.appRoles | Where-Object { $_.value -in @('AUM.Admin','AUM.Viewer') } | ForEach-Object id)
$assigned = @((Invoke-GraphJourney GET "/servicePrincipals/$($record.servicePrincipalId)/appRoleAssignedTo").value)
$direct = @($assigned | Where-Object { $_.principalId -eq $me.id -and $_.appRoleId -in $privilegedIds })
$groups = @([string]$UnitManagerGroupId, [string]$TeamManagerGroupId)
$privilegedGroups = @($assigned | Where-Object { $_.principalType -eq 'Group' -and $_.appRoleId -in $privilegedIds } |
    Where-Object { Get-Membership $_.principalId } | ForEach-Object principalId)
$groups = @($groups + $privilegedGroups | Select-Object -Unique)
$membership = @{}
foreach ($group in $groups) {
    $owners = @((Invoke-GraphJourney GET "/groups/$group/owners").value)
    if (-not @($owners | Where-Object id -eq $me.id).Count) { throw "The CLI account must own every group it will temporarily change: $group" }
    $membership[$group] = Get-Membership $group
}
$adminToken = Get-JourneyToken 'before'
$beforeMe = Invoke-JourneyApi $adminToken GET 'me'
if ($beforeMe.access -ne 'admin') { throw 'Start this journey as AUM.Admin.' }
$catalog = Invoke-JourneyApi $adminToken GET 'catalog'
$entities = @($catalog.organizations) + @($catalog.departments)
$unit = @($entities | Where-Object id -eq $UnitId)[0]
$team = @($entities | Where-Object id -eq $TeamId)[0]
if (-not $unit -or -not $team -or $team.parent_id -ne $UnitId) { throw 'Choose an existing test unit and its test team.' }
if ($OutsideTeamId -eq $TeamId -or -not @($entities | Where-Object id -eq $OutsideTeamId).Count) { throw 'Choose a different existing team for outside-scope denials.' }
$budgets = Invoke-JourneyApi $adminToken GET 'budgets'
$budget = @($budgets.items | Where-Object { $_.scope_type -eq 'department' -and $_.scope_id -eq $TeamId })[0]
if (-not $budget.token_limit) { throw 'The test team needs a finite existing budget.' }
$plan = [pscustomobject]@{
    Execute=[bool]$Execute; LeadGoRequired=$true; CurrentRole=$beforeMe.access
    DirectPrivilegedAssignments=$direct.Count; PrivilegedGroups=$privilegedGroups.Count
    TestUnit=$UnitId; TestTeam=$TeamId; OutsideTeam=$OutsideTeamId
    OriginalMembership=$membership; OriginalBudget=$budget.token_limit
    Operations=@('Temporarily remove own Admin/Viewer access','Team-only reads and write denials',
                 'Unit-manager reversible team-budget write','Restore every membership, assignment, mapping and budget','Prove Admin access')
}
if (-not $Execute) { return $plan }
if ($LeadApproval -ne 'go') { throw 'No changes made: -Execute requires -LeadApproval go after the lead explicitly sends go.' }
if (-not $PSCmdlet.ShouldProcess($me.id, 'Temporarily change owned-group membership and AUM roles, then restore them in finally')) { return $plan }
$removed = @(); $createdAssignments = @(); $receipts = @(); $restoreErrors = @()
try {
    Set-JourneyMapping $UnitId ([string]$UnitManagerGroupId)
    Set-JourneyMapping $TeamId ([string]$TeamManagerGroupId)
    foreach ($group in @([string]$UnitManagerGroupId, [string]$TeamManagerGroupId)) {
        if (-not @($assigned | Where-Object { $_.principalId -eq $group -and $_.appRoleId -eq $role.id }).Count) {
            $new = Invoke-GraphJourney POST "/groups/$group/appRoleAssignments" @{principalId=$group; resourceId=$record.servicePrincipalId; appRoleId=$role.id}
            $createdAssignments += @{group=$group; id=$new.id}
        }
    }
    foreach ($assignment in $direct) {
        Invoke-GraphJourney DELETE "/users/$($me.id)/appRoleAssignments/$($assignment.id)" | Out-Null
        $removed += $assignment
    }
    foreach ($group in $privilegedGroups) { Set-Membership $group $false }
    Set-Membership ([string]$UnitManagerGroupId) $false
    Set-Membership ([string]$TeamManagerGroupId) $true
    $managerToken = Get-JourneyToken 'team'
    $profile = Invoke-JourneyApi $managerToken GET 'me'
    if ($profile.access -ne 'manager' -or $null -eq $profile.manager_scope -or
        @($profile.manager_scope.organizations).Count -ne 0 -or
        @($profile.manager_scope.departments | Where-Object id -eq $TeamId).Count -ne 1) {
        throw 'Token claims are stale or scope is not team-only. Supply TokenAcquirer for fresh issuance; never count an Admin token as manager evidence.'
    }
    foreach ($view in @('usage','people','trends','requests','budgets')) { Invoke-JourneyApi $managerToken GET $view | Out-Null }
    Assert-Forbidden $managerToken GET "usage?organization_id=$UnitId"
    $revision = (Invoke-JourneyApi $managerToken GET 'budgets').revision
    Assert-Forbidden $managerToken PUT "budgets/department/$OutsideTeamId" @{token_limit=1; reason='Expected outside-scope denial'} $revision
    Assert-Forbidden $managerToken PUT "budgets/department/$TeamId" @{token_limit=1; reason='Expected own-team allocation denial'} $revision
    $receipts += @{phase='team-manager'; utc=[datetime]::UtcNow.ToString('o'); state='passed'}
    Set-Membership ([string]$TeamManagerGroupId) $false
    Set-Membership ([string]$UnitManagerGroupId) $true
    $managerToken = Get-JourneyToken 'unit'
    $profile = Invoke-JourneyApi $managerToken GET 'me'
    if ($profile.access -ne 'manager' -or @($profile.manager_scope.organizations | Where-Object id -eq $UnitId).Count -ne 1) {
        throw 'Token claims are not a fresh unit-manager identity.'
    }
    $revision = (Invoke-JourneyApi $managerToken GET 'budgets').revision
    Invoke-JourneyApi $managerToken PUT "budgets/department/$TeamId" @{token_limit=([long]$budget.token_limit + 1); reason='Reversible manager pilot'} $revision | Out-Null
    $revision = (Invoke-JourneyApi $managerToken GET 'budgets').revision
    Assert-Forbidden $managerToken PUT "budgets/organization/$UnitId" @{token_limit=1; reason='Expected unit-budget denial'} $revision
    $receipts += @{phase='unit-manager'; utc=[datetime]::UtcNow.ToString('o'); state='passed'}
}
finally {
    foreach ($group in $membership.Keys) {
        try { Set-Membership $group ([bool]$membership[$group]) }
        catch { $restoreErrors += "membership $group : $($_.Exception.Message)" }
    }
    foreach ($assignment in $removed) {
        try { Invoke-GraphJourney POST "/users/$($me.id)/appRoleAssignments" @{principalId=$me.id; resourceId=$record.servicePrincipalId; appRoleId=$assignment.appRoleId} | Out-Null }
        catch { $restoreErrors += "role restoration: $($_.Exception.Message)" }
    }
    foreach ($assignment in $createdAssignments) {
        try { Invoke-GraphJourney DELETE "/groups/$($assignment.group)/appRoleAssignments/$($assignment.id)" | Out-Null }
        catch { $restoreErrors += "test group role removal: $($_.Exception.Message)" }
    }
    try {
        $current = Invoke-JourneyApi $adminToken GET 'budgets'
        $now = @($current.items | Where-Object { $_.scope_type -eq 'department' -and $_.scope_id -eq $TeamId })[0]
        if ($now.token_limit -ne $budget.token_limit) {
            Invoke-JourneyApi $adminToken PUT "budgets/department/$TeamId" @{token_limit=[long]$budget.token_limit; reason='Manager pilot finally restoration'} $current.revision | Out-Null
        }
        Set-JourneyMapping $UnitId $unit.attributes.manager_group_id
        Set-JourneyMapping $TeamId $team.attributes.manager_group_id
    }
    catch { $restoreErrors += "service restoration: $($_.Exception.Message)" }
    foreach ($group in $membership.Keys) {
        try { if ((Get-Membership $group) -ne $membership[$group]) { throw 'Membership differs from snapshot' } }
        catch { $restoreErrors += "membership verification $group : $($_.Exception.Message)" }
    }
    try {
        $after = Invoke-JourneyApi (Get-JourneyToken 'restored') GET 'me'
        if ($after.access -ne 'admin' -or $null -ne $after.manager_scope) { throw 'Admin access was not restored' }
        $receipts += @{phase='restored-admin'; utc=[datetime]::UtcNow.ToString('o'); state='passed'}
    }
    catch { $restoreErrors += "access verification: $($_.Exception.Message)" }
    if ($restoreErrors.Count) { throw ('RESTORATION NEEDS ATTENTION: ' + ($restoreErrors -join '; ')) }
}
$receipts
