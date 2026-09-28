function Get-ClaudeAddressRecoveryHosts {
    param($Gateway)
    $hosts = if ($Gateway.properties) { $Gateway.properties.hostnameConfigurations } else { $Gateway.hostnameConfigurations }
    @($hosts | Where-Object { $_.certificateSource -ne 'BuiltIn' } | Sort-Object type,hostName | ForEach-Object {
        [ordered]@{
            type=[string]$_.type; hostname=([string]$_.hostName).ToLowerInvariant(); certificateSource=[string]$_.certificateSource
            thumbprint=[string]$_.certificate.thumbprint; keyVaultId=[string]$_.keyVaultId; identityClientId=[string]$_.identityClientId
            defaultSslBinding=[bool]$_.defaultSslBinding; negotiateClientCertificate=[bool]$_.negotiateClientCertificate
        }
    })
}

function New-ClaudeAddressRecoveryReceipt {
    param($Record,$Gateway,$Plan)
    $d=$Plan.Data
    $binding=@{
        type='Proxy';hostName=$d.Hostname;certificateSource=$(if($d.CertificateSource -eq 'Pfx'){'Custom'}else{'KeyVault'})
        certificate=@{thumbprint=$d.Certificate.Thumbprint};keyVaultId=$d.Certificate.SecretId
        defaultSslBinding=$false;negotiateClientCertificate=$false
    }
    $same=@($Gateway.properties.hostnameConfigurations|Where-Object { $_.type -eq 'Proxy' -and $_.hostName -ieq $d.Hostname })
    if($same.Count){$binding.defaultSslBinding=[bool]$same[0].defaultSslBinding;$binding.negotiateClientCertificate=[bool]$same[0].negotiateClientCertificate}
    $patch=Get-ClaudeAddressHostnamePatch -Gateway $Gateway -Plan $Plan -Binding $binding
    $data=[ordered]@{
        gatewayId=$d.GatewayId;previousGatewayUrl=$Record.gatewayUrl;approvedPlanFingerprint=(Get-ClaudeFlowFingerprint @($Plan))
        expectedHosts=@(Get-ClaudeAddressRecoveryHosts ([pscustomobject]$patch))
        decision=[ordered]@{
            hostname=$d.Hostname;certificateSource=$d.CertificateSource;keyVaultCertificateId=$d.KeyVaultCertificateId;pfxPath=$d.PfxPath
            dnsZoneResourceId=$d.DnsZoneResourceId;dnsMode=$(if($d.DnsZoneResourceId){'AzureDns'}else{'External'});replaceHostname=''
        }
    }
    [pscustomobject]@{data=[pscustomobject]$data;fingerprint=(Get-ClaudeFlowFingerprint @($data))}
}

function Get-ClaudeAddressRecovery {
    param($Record,$Gateway)
    $receipt=$Record.pendingAddress
    if(-not $receipt -or -not $receipt.data){return [pscustomobject]@{Allowed=$false;Reason='No pending address receipt.'}}
    $d=$receipt.data
    $subscription=Get-ClaudeFlowRecordSubscription -Record $Record
    $expectedId="/subscriptions/$subscription/resourceGroups/$($Record.resourceGroup)/providers/Microsoft.ApiManagement/service/$($Record.apimName)"
    $valid=$receipt.fingerprint -eq (Get-ClaudeFlowFingerprint @($d)) -and
        $d.gatewayId -ieq $expectedId -and $Gateway.id -ieq $expectedId -and
        $Record.gatewayUrl -ceq $d.previousGatewayUrl -and
        (ConvertTo-ClaudeFlowCanonical @(Get-ClaudeAddressRecoveryHosts $Gateway)) -ceq (ConvertTo-ClaudeFlowCanonical @($d.expectedHosts))
    if(-not $valid){return [pscustomobject]@{Allowed=$false;Reason='The receipt, target, previous URL or live hostname collection does not match.'}}
    [pscustomobject]@{Allowed=$true;Decision=(Copy-ClaudeFlowValue $d.decision);Fingerprint=$receipt.fingerprint}
}
