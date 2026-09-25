<#
.SYNOPSIS
    Lets the gateway's apply job read Entra groups. Run once, by a tenant administrator.

.DESCRIPTION
    When Turnstile is where governance is edited (Connect-ClaudeTurnstile.ps1
    -GovernanceAuthority Turnstile), the apply job checks that every business unit's, team's
    and tier's Entra group exists, and refreshes membership from those groups. Both read
    Microsoft Graph as the job's managed identity, which needs the application permission
    GroupMember.Read.All: read groups and their members, nothing else.

    Only a tenant administrator can grant an application permission (Privileged Role
    Administrator or Global Administrator). Until it is granted, the job still applies budgets
    and tier limits, trusts groups the gateway already uses, refuses new ones by name, and
    leaves membership as it is.

    Azure caches a managed identity's tokens for up to about 24 hours, so a grant, or a
    revocation, can take that long to reach the job. The job reports which it saw on each run.

.PARAMETER ResourceGroup
    The gateway's resource group, where Register-ClaudeTurnstileSchedule.ps1 put the job.

.PARAMETER PrincipalId
    Object id of the apply job's managed identity. Found for you from the gateway's resource group.

.PARAMETER Revoke
    Removes the permission again. The job then goes back to trusting only groups in use.

.EXAMPLE
    ./scripts/Grant-ClaudeGovernanceGraphAccess.ps1

.EXAMPLE
    ./scripts/Grant-ClaudeGovernanceGraphAccess.ps1 -Revoke
#>
[CmdletBinding()]
param(
    [string]$ResourceGroup = $(& (Join-Path $PSScriptRoot 'Get-ClaudeGatewayTarget.ps1') ResourceGroup),
    [string]$PrincipalId,
    [switch]$Revoke
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ClaudeChoice.ps1')
$graphAppId = '00000003-0000-0000-c000-000000000000'  # Microsoft Graph, the same in every tenant
$permission = 'GroupMember.Read.All'

if (-not $PrincipalId) {
    if (-not $ResourceGroup) { $ResourceGroup = Select-ClaudeResourceGroup }
    $PrincipalId = Select-ClaudeTurnstileIdentity -ResourceGroup $ResourceGroup
}
$graph = az ad sp show --id $graphAppId --query "{id:id, role:appRoles[?value=='$permission'].id | [0]}" -o json | ConvertFrom-Json
$existing = @((az rest --method get --url "https://graph.microsoft.com/v1.0/servicePrincipals/$PrincipalId/appRoleAssignments" | ConvertFrom-Json).value |
    Where-Object { $_.resourceId -eq $graph.id -and $_.appRoleId -eq $graph.role })

if ($Revoke) {
    foreach ($a in $existing) { az rest --method delete --url "https://graph.microsoft.com/v1.0/servicePrincipals/$PrincipalId/appRoleAssignments/$($a.id)" | Out-Null }
    Write-Host "Revoked $permission from $PrincipalId ($($existing.Count) assignment(s))."
    return
}
if ($existing.Count) { Write-Host "$PrincipalId already holds $permission."; return }

# The body goes through a file: on Windows az is a .cmd shim and cmd.exe strips JSON quotes.
$file = [IO.Path]::GetTempFileName()
try {
    @{ principalId = $PrincipalId; resourceId = $graph.id; appRoleId = $graph.role } | ConvertTo-Json | Set-Content $file -Encoding utf8
    $raw = az rest --method post --url "https://graph.microsoft.com/v1.0/servicePrincipals/$PrincipalId/appRoleAssignments" --headers 'Content-Type=application/json' --body "@$file" 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        if ($raw -match '(?i)Authorization_RequestDenied|Insufficient privileges') {
            # Owner of the subscription is an Azure role, for Azure resources; the directory has its own roles.
            $who = az account show --query user.name -o tsv 2>$null
            throw ("Microsoft Graph refused to grant $permission as $who. Granting a Microsoft Graph application " +
                "permission takes the Entra role Privileged Role Administrator or Global Administrator; Owner of the " +
                "subscription is an Azure role and does not count. If you hold one of them through Privileged Identity " +
                "Management, activate it and sign in again. Otherwise ask an administrator to run this script: no portal " +
                "page adds a permission to a managed identity.")
        }
        throw "Granting $permission failed: $($raw.Trim())"
    }
}
finally { Remove-Item $file -ErrorAction SilentlyContinue }
Write-Host "Granted $permission to $PrincipalId. The next apply checks groups and refreshes membership."
