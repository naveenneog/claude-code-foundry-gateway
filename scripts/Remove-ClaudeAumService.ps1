<#
.SYNOPSIS
    Removes only the recorded AUM service and its external role assignments.
.DESCRIPTION
    Gateway, workspace, budgets, networks, reused storage/plans and Entra app
    remain. Pass -RemoveAppRegistration to remove the owned AUM application too.
    Audit/history in dedicated storage are deleted: export them before removal.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
param(
    [string]$RecordPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'onboarding\aum-service.json'),
    [switch]$RemoveAppRegistration
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ClaudeAumDeployment.ps1')
if (-not (Test-Path $RecordPath)) { throw 'No deployment record. Pass -RecordPath from the deployment; never guess resources to delete.' }
$record = Get-Content -Raw $RecordPath | ConvertFrom-Json
if ($record.schemaVersion -ne 1 -or -not $record.functionName -or -not $record.subscriptionId) { throw 'Not an AUM service deployment record.' }
$resources = @(Invoke-ClaudeAumAz @('resource','list','--resource-group',$record.resourceGroup,'--subscription',$record.subscriptionId,'-o','json'))
$names = @($record.functionName)
if (-not $record.planReused) { $names += $record.planName }
if (-not $record.storageReused) { $names += $record.storageName }
$prefix = $record.functionName -replace '^func-aum-',''
$names += "appi-aum-$prefix"
$names += @("pe-aum-$prefix-sites","pe-aum-$prefix-blob","pe-aum-$prefix-table")
$selected = @($resources | Where-Object { $_.name -in $names -or $_.id -in @($record.networkResourceIds) })
Write-Host 'This deletes dedicated audit/history storage. It does not undo budget changes or active boosts.' -ForegroundColor Yellow
Write-Host 'Before removing, wait for boosts to expire or restore their budgets and export audit records.'
foreach ($r in $selected) { Write-Host "  Delete $($r.type): $($r.name)" }
if (-not $PSCmdlet.ShouldProcess($record.functionName, 'Delete recorded AUM resources and external role assignments')) { return }
foreach ($id in @($record.roleAssignmentIds)) {
    $match = @(Invoke-ClaudeAumAz @('role','assignment','list','--assignee-object-id',$record.principalId,'--all','--subscription',$record.subscriptionId,'-o','json') | Where-Object id -eq $id)
    if ($match.Count) { Invoke-ClaudeAumAz @('role','assignment','delete','--ids',$id,'--subscription',$record.subscriptionId,'-o','json') | Out-Null }
}
foreach ($r in @($selected | Sort-Object { if ($_.type -eq 'Microsoft.Network/privateEndpoints') { 0 } elseif ($_.type -eq 'Microsoft.Web/sites') { 1 } elseif ($_.type -eq 'Microsoft.Network/virtualNetworks') { 3 } else { 2 } })) {
    if ($r.type -eq 'Microsoft.Network/privateDnsZones') {
        $links = @(Invoke-ClaudeAumAz @('network','private-dns','link','vnet','list','--resource-group',$record.resourceGroup,
            '--zone-name',$r.name,'--subscription',$record.subscriptionId,'-o','json'))
        foreach ($link in $links) {
            if ($link.virtualNetwork.id -notin @($record.networkResourceIds)) { throw 'A service DNS zone has acquired a link to a shared VNet. Review that dependency before removing it.' }
            Invoke-ClaudeAumAz @('network','private-dns','link','vnet','delete','--name',$link.name,
                '--resource-group',$record.resourceGroup,'--zone-name',$r.name,'--subscription',$record.subscriptionId,
                '--yes','-o','json') | Out-Null
        }
    }
    Invoke-ClaudeAumAz @('resource','delete','--ids',$r.id,'--subscription',$record.subscriptionId,'-o','json') | Out-Null
}
if ($RemoveAppRegistration) {
    Invoke-ClaudeAumAz @('ad','app','delete','--id',$record.applicationObjectId,'-o','json') | Out-Null
}
Write-Host 'AUM service removed. The group, gateway, workspace and any reused resources remain.' -ForegroundColor Green
