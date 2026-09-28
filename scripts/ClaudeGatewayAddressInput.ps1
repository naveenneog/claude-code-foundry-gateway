# One effective address selection for the installer and its unattended flow plan.
function Test-ClaudeAddressDraftRecord {
    # The flow writes its run journal before Foundation invokes the installer.
    param($Record)
    return [bool]($Record -and $Record.schemaVersion -eq 2 -and -not $Record.apimName -and -not $Record.resourceGroup -and
        (-not $Record.mode -or $Record.mode -eq 'gateway') -and $Record.activeRun -and
        ($Record.activeRun.action -eq 'Setup' -or ($Record.activeRun.action -eq 'Change' -and $Record.activeRun.change -eq 'foundation')))
}

function Resolve-ClaudeAddressInputs {
    param($Record, [System.Collections.IDictionary]$Values = @{})
    $saved = if ($Record -and $Record.address) { $Record.address } elseif ($Record -and $Record.decisions -and $Record.decisions.address) { $Record.decisions.address } else { $null }
    $mode = if ($Values.Contains('AddressMode') -and $Values['AddressMode']) { $Values['AddressMode'] } elseif ($saved -and $saved.hostname) { 'custom' } else { 'azure' }
    if ($mode -notin @('azure','custom')) { throw 'AddressMode must be azure or custom.' }
    $result = [ordered]@{ AddressMode = [string]$mode }
    if ($mode -eq 'azure') { return $result }
    $map = [ordered]@{
        AddressHostname='hostname'; AddressCertificateSource='certificateSource'; AddressKeyVaultCertificateId='keyVaultCertificateId'
        AddressPfxPath='pfxPath'; AddressDnsZoneResourceId='dnsZoneResourceId'; AddressDnsMode='dnsMode'; AddressReplaceHostname='replaceHostname'
    }
    foreach ($key in $map.Keys) {
        $name = $map[$key]
        $value = if ($Values.Contains($key)) { $Values[$key] } elseif ($saved) { $saved.$name } else { '' }
        if ($null -ne $value -and $value -isnot [string]) { throw "Address input $key must be text, not a list or object." }
        $result[$key] = [string]$value
    }
    if (-not $result.AddressCertificateSource) { $result.AddressCertificateSource = 'KeyVault' }
    if (-not $result.AddressDnsMode) { $result.AddressDnsMode = if ($result.AddressDnsZoneResourceId) { 'AzureDns' } else { 'External' } }
    if ($result.AddressDnsMode -eq 'External') { $result.AddressDnsZoneResourceId = '' }
    if ($result.AddressDnsMode -notin @('AzureDns','External')) { throw 'AddressDnsMode must be AzureDns or External.' }
    if ($result.AddressCertificateSource -eq 'KeyVault') { $result.AddressPfxPath = '' }
    elseif ($result.AddressCertificateSource -eq 'Pfx') { $result.AddressKeyVaultCertificateId = '' }
    else { throw 'AddressCertificateSource must be KeyVault or Pfx.' }
    return $result
}
