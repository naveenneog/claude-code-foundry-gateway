param()
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'scripts\ClaudeAumDeployment.ps1')
$base = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-aum-contoso'
$network = "$base/providers/Microsoft.Network/virtualNetworks/vnet-aum-contoso"
$zone = "$base/providers/Microsoft.Network/privateDnsZones/privatelink.table.core.windows.net"
$endpoint = "$base/providers/Microsoft.Network/privateEndpoints/pe-aum-contoso-table"
$unrelated = "$base/providers/Microsoft.Compute/virtualMachines/func-aum-contoso"
$unselectedInsights = "$base/providers/Microsoft.Insights/components/appi-aum-contoso"
$unselectedSite = "$base/providers/Microsoft.Network/privateEndpoints/pe-aum-contoso-sites"
$global:AumRemovalTestLinkExists = $true
$global:AumRemovalTestDeletedZone = $false
$global:AumRemovalTestDeletedEndpoint = $false
$global:AumRemovalTestOptionalEnabled = $false
$global:AumRemovalTestDeletedOptional = @()
function az {
    param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments)
    $global:LASTEXITCODE = 0
    $command = $Arguments -join ' '
    $value = switch -Regex ($command) {
        '^resource list' {
            ,@(@{id=$zone; name='privatelink.table.core.windows.net'; type='Microsoft.Network/privateDnsZones'},
                @{id=$endpoint; name='pe-aum-contoso-table'; type='Microsoft.Network/privateEndpoints'},
                @{id=$unrelated; name='func-aum-contoso'; type='Microsoft.Compute/virtualMachines'},
                @{id=$unselectedInsights; name='appi-aum-contoso'; type='Microsoft.Insights/components'},
                @{id=$unselectedSite; name='pe-aum-contoso-sites'; type='Microsoft.Network/privateEndpoints'})
            break
        }
        '^role assignment list' { ,@(); break }
        '^network private-endpoint delete' {
            if ($Arguments -contains $endpoint) { $global:AumRemovalTestDeletedEndpoint=$true }
            elseif ($Arguments -contains $unselectedSite -and $global:AumRemovalTestOptionalEnabled) {
                $global:AumRemovalTestDeletedOptional += $unselectedSite
            }
            else { throw 'The network remover must target only an enabled recorded endpoint ID.' }
            $null; break
        }
        '^network private-dns link vnet list' {
            if (-not $global:AumRemovalTestDeletedEndpoint) { throw 'Private endpoints must be removed before DNS.' }
            ,@(@{name='aum-contoso'; virtualNetwork=@{id=$network}}); break
        }
        '^network private-dns link vnet delete' { $global:AumRemovalTestLinkExists=$false; $null; break }
        '^resource delete' {
            if ($Arguments -contains $unrelated) {
                throw 'Unrelated types and unselected optional resources must never be deleted.'
            }
            if ($Arguments -contains $unselectedInsights) {
                if (-not $global:AumRemovalTestOptionalEnabled) { throw 'Insights was not selected.' }
                $global:AumRemovalTestDeletedOptional += $unselectedInsights
                $null; break
            }
            if ($Arguments -contains $endpoint) { $global:LASTEXITCODE=1; 'Generic resource deletion failed for the private endpoint; use its network operation' }
            elseif ($global:AumRemovalTestLinkExists) { $global:LASTEXITCODE=1; 'Nested DNS link must be deleted first' }
            else { $global:AumRemovalTestDeletedZone=$true; $null }
            break
        }
        default { throw "Unexpected removal command: $command" }
    }
    if ($null -ne $value) { ConvertTo-Json -InputObject $value -Depth 8 -Compress }
}
$record = New-ClaudeAumLocalFile
try {
    Write-ClaudeAumJson $record @{
        schemaVersion=1; subscriptionId='00000000-0000-0000-0000-000000000001'; resourceGroup='rg-aum-contoso'
        functionName='func-aum-contoso'; planName='plan-aum-contoso'; storageName='staumcontoso'
        principalId='00000000-0000-0000-0000-000000000002'; roleAssignmentIds=@()
        networkResourceIds=@($network,$zone); storageReused=$false; planReused=$false
        choices=@{insights='Off';network='Public';storageNetwork='Private'}
    }
    & (Join-Path $root 'scripts\Remove-ClaudeAumService.ps1') -RecordPath $record -Confirm:$false
    if ($global:AumRemovalTestLinkExists -or -not $global:AumRemovalTestDeletedZone -or -not $global:AumRemovalTestDeletedEndpoint) {
        throw 'Removal did not delete the recorded endpoint, then unlink owned DNS before deleting the zone.'
    }
    $enabled = Get-Content $record -Raw | ConvertFrom-Json
    $enabled.choices.insights='On'; $enabled.choices.network='Private'; $enabled.choices.storageNetwork='Public'
    Write-ClaudeAumJson $record $enabled
    $global:AumRemovalTestLinkExists=$true; $global:AumRemovalTestDeletedZone=$false
    $global:AumRemovalTestDeletedEndpoint=$false; $global:AumRemovalTestOptionalEnabled=$true
    & (Join-Path $root 'scripts\Remove-ClaudeAumService.ps1') -RecordPath $record -Confirm:$false
    if ($global:AumRemovalTestLinkExists -or -not $global:AumRemovalTestDeletedZone -or
        -not $global:AumRemovalTestDeletedEndpoint -or $global:AumRemovalTestDeletedOptional.Count -ne 2) {
        throw 'Enabled Insights/private ingress or its required private storage was not removed.'
    }
    Write-Host 'AUM removal: typed recorded choices only, scoped endpoint operation, then owned DNS links and zone deletion.' -ForegroundColor Green
}
finally {
    Remove-Item $record -ErrorAction SilentlyContinue
    Remove-Variable AumRemovalTestLinkExists,AumRemovalTestDeletedZone,AumRemovalTestDeletedEndpoint,AumRemovalTestOptionalEnabled,AumRemovalTestDeletedOptional -Scope Global -ErrorAction SilentlyContinue
}
