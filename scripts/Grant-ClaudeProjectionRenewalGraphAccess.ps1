<#
.SYNOPSIS
    Grants the projection renewal job permission to read Entra group membership.

.DESCRIPTION
    Run once by a Privileged Role Administrator or Global Administrator. The
    scheduled projection renewal job reads Microsoft Graph as its user-assigned
    managed identity and needs the application permission GroupMember.Read.All.

    Plain az rest equivalent:

      $graphAppId = '00000003-0000-0000-c000-000000000000'
      $graph = az ad sp show --id $graphAppId --query "{id:id, role:appRoles[?value=='GroupMember.Read.All'].id | [0]}" -o json | ConvertFrom-Json
      $body = @{ principalId = '<managed-identity-principal-id>'; resourceId = $graph.id; appRoleId = $graph.role } | ConvertTo-Json
      $file = New-TemporaryFile
      Set-Content -Path $file -Value $body -Encoding utf8
      az rest --method post --url "https://graph.microsoft.com/v1.0/servicePrincipals/<managed-identity-principal-id>/appRoleAssignments" --headers 'Content-Type=application/json' --body "@$file"

.PARAMETER PrincipalId
    Object id of the projection renewal job's user-assigned managed identity.

.PARAMETER Revoke
    Removes the permission again.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PrincipalId,
    [switch]$Revoke
)

$ErrorActionPreference = 'Stop'
$graphAppId = '00000003-0000-0000-c000-000000000000'
$permission = 'GroupMember.Read.All'

$graph = az ad sp show --id $graphAppId --query "{id:id, role:appRoles[?value=='$permission'].id | [0]}" -o json | ConvertFrom-Json
if (-not $graph.id -or -not $graph.role) { throw "Could not resolve Microsoft Graph app role $permission." }

$existing = @((az rest --method get --url "https://graph.microsoft.com/v1.0/servicePrincipals/$PrincipalId/appRoleAssignments" | ConvertFrom-Json).value |
    Where-Object { $_.resourceId -eq $graph.id -and $_.appRoleId -eq $graph.role })

if ($Revoke) {
    foreach ($assignment in $existing) {
        az rest --method delete --url "https://graph.microsoft.com/v1.0/servicePrincipals/$PrincipalId/appRoleAssignments/$($assignment.id)" | Out-Null
    }
    Write-Host "Revoked $permission from $PrincipalId ($($existing.Count) assignment(s))."
    return
}

if ($existing.Count) {
    Write-Host "$PrincipalId already holds $permission."
    return
}

$file = [IO.Path]::GetTempFileName()
try {
    @{ principalId = $PrincipalId; resourceId = $graph.id; appRoleId = $graph.role } | ConvertTo-Json | Set-Content $file -Encoding utf8
    $raw = az rest --method post --url "https://graph.microsoft.com/v1.0/servicePrincipals/$PrincipalId/appRoleAssignments" --headers 'Content-Type=application/json' --body "@$file" 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        if ($raw -match '(?i)Authorization_RequestDenied|Insufficient privileges') {
            $who = az account show --query user.name -o tsv 2>$null
            throw ("Microsoft Graph refused to grant $permission as $who. Granting a Microsoft Graph application " +
                "permission to a managed identity takes Privileged Role Administrator or Global Administrator in Entra ID; " +
                "Azure subscription Owner is not enough.")
        }
        throw "Granting $permission failed: $($raw.Trim())"
    }
}
finally {
    Remove-Item $file -ErrorAction SilentlyContinue
}

Write-Host "Granted $permission to $PrincipalId. Managed identity tokens can take up to about 24 hours to reflect the grant."
