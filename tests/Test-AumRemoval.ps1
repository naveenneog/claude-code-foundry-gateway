param()
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'scripts\ClaudeAumDeployment.ps1')
$base = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-aum-contoso'
$network = "$base/providers/Microsoft.Network/virtualNetworks/vnet-aum-contoso"
$zone = "$base/providers/Microsoft.Network/privateDnsZones/privatelink.table.core.windows.net"
$global:AumRemovalTestLinkExists = $true
$global:AumRemovalTestDeletedZone = $false
function az {
    param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments)
    $global:LASTEXITCODE = 0
    $command = $Arguments -join ' '
    $value = switch -Regex ($command) {
        '^resource list' { ,@(@{id=$zone; name='privatelink.table.core.windows.net'; type='Microsoft.Network/privateDnsZones'}); break }
        '^role assignment list' { ,@(); break }
        '^network private-dns link vnet list' { ,@(@{name='aum-contoso'; virtualNetwork=@{id=$network}}); break }
        '^network private-dns link vnet delete' { $global:AumRemovalTestLinkExists=$false; $null; break }
        '^resource delete' {
            if ($global:AumRemovalTestLinkExists) { $global:LASTEXITCODE=1; 'Nested DNS link must be deleted first' }
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
    if ($global:AumRemovalTestLinkExists -or -not $global:AumRemovalTestDeletedZone) { throw 'Removal did not unlink owned private DNS before deleting the zone.' }
    Write-Host 'AUM removal: owned private DNS links precede zone deletion.' -ForegroundColor Green
}
finally {
    Remove-Item $record -ErrorAction SilentlyContinue
    Remove-Variable AumRemovalTestLinkExists,AumRemovalTestDeletedZone -Scope Global -ErrorAction SilentlyContinue
}
