param()
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'scripts\ClaudeAumDeployment.ps1')
$base = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-aum-contoso'
$network = "$base/providers/Microsoft.Network/virtualNetworks/vnet-aum-contoso"
$zone = "$base/providers/Microsoft.Network/privateDnsZones/privatelink.table.core.windows.net"
$endpoint = "$base/providers/Microsoft.Network/privateEndpoints/pe-aum-contoso-table"
$global:AumRemovalTestLinkExists = $true
$global:AumRemovalTestDeletedZone = $false
$global:AumRemovalTestDeletedEndpoint = $false
function az {
    param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments)
    $global:LASTEXITCODE = 0
    $command = $Arguments -join ' '
    $value = switch -Regex ($command) {
        '^resource list' {
            ,@(@{id=$zone; name='privatelink.table.core.windows.net'; type='Microsoft.Network/privateDnsZones'},
                @{id=$endpoint; name='pe-aum-contoso-table'; type='Microsoft.Network/privateEndpoints'})
            break
        }
        '^role assignment list' { ,@(); break }
        '^network private-endpoint delete' {
            if ($Arguments -notcontains $endpoint) { throw 'The network remover must target only the recorded endpoint ID.' }
            $global:AumRemovalTestDeletedEndpoint=$true
            $null; break
        }
        '^network private-dns link vnet list' {
            if (-not $global:AumRemovalTestDeletedEndpoint) { throw 'Private endpoints must be removed before DNS.' }
            ,@(@{name='aum-contoso'; virtualNetwork=@{id=$network}}); break
        }
        '^network private-dns link vnet delete' { $global:AumRemovalTestLinkExists=$false; $null; break }
        '^resource delete' {
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
    }
    & (Join-Path $root 'scripts\Remove-ClaudeAumService.ps1') -RecordPath $record -Confirm:$false
    if ($global:AumRemovalTestLinkExists -or -not $global:AumRemovalTestDeletedZone -or -not $global:AumRemovalTestDeletedEndpoint) {
        throw 'Removal did not delete the recorded endpoint, then unlink owned DNS before deleting the zone.'
    }
    Write-Host 'AUM removal: scoped network endpoint operation, then owned DNS links and zone deletion.' -ForegroundColor Green
}
finally {
    Remove-Item $record -ErrorAction SilentlyContinue
    Remove-Variable AumRemovalTestLinkExists,AumRemovalTestDeletedZone,AumRemovalTestDeletedEndpoint -Scope Global -ErrorAction SilentlyContinue
}
