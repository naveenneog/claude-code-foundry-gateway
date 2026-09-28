if (-not (Get-Command Get-ClaudeAddressPlan -ErrorAction SilentlyContinue)) {
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'ClaudeGatewayAddress.ps1')
}

function Get-ClaudeFlowStepInfo {
    [pscustomobject]@{ Name = 'Address'; Title = 'Company gateway address'; DecisionKey = 'address'; DependsOn = @('Foundation'); Actions = @('Change') }
}

function Get-ClaudeFlowStepQuestions {
    param($Record, $Discovery)
    if ($Discovery -and $Discovery.addressRecovery -and $Discovery.addressRecovery.Allowed) {
        Set-ClaudeDecision $Record address (Copy-ClaudeFlowValue $Discovery.addressRecovery.Decision)
    }
    @(
        [pscustomobject]@{ Key = 'address.hostname'; Type = 'Text'; Question = 'Company DNS hostname (not a URL)'; Optional = $false }
        [pscustomobject]@{
            Key = 'address.certificateSource'; Question = 'Certificate source; no v2 tier offers free managed issuance'
            Options = @(
                New-ClaudeChoiceOption -Value KeyVault -Label 'Key Vault certificate' -Detail 'Gateway identity reads its backing secret; versionless reference permits rotation.'
                New-ClaudeChoiceOption -Value Pfx -Label 'Uploaded PFX' -Detail 'Private key and chain; a password is passed as -AddressCertificatePassword, never in the answers file.'
            ); AcceptRecommendedWithoutConsole = $false
        }
        [pscustomobject]@{ Key = 'address.keyVaultCertificateId'; Type = 'Text'; Question = 'Key Vault certificate or secret URL'; Optional = $false; When = { param($r) $r.decisions.address.certificateSource -eq 'KeyVault' } }
        [pscustomobject]@{ Key = 'address.pfxPath'; Type = 'Text'; Question = 'PFX file path'; Optional = $false; When = { param($r) $r.decisions.address.certificateSource -eq 'Pfx' } }
        [pscustomobject]@{
            Key = 'address.dnsMode'; Question = 'Where is the company DNS zone hosted?'
            Options = @(
                New-ClaudeChoiceOption -Value AzureDns -Label 'Existing Azure public DNS zone' -Detail 'Creates the CNAME in this subscription.'
                New-ClaudeChoiceOption -Value External -Label 'Another DNS provider' -Detail 'Prints the exact record and waits for it to resolve.'
            ); AcceptRecommendedWithoutConsole = $false
        }
        [pscustomobject]@{ Key = 'address.dnsZoneResourceId'; Type = 'Text'; Question = 'Azure public DNS zone resource ID'; Optional = $false; When = { param($r) $r.decisions.address.dnsMode -eq 'AzureDns' } }
        [pscustomobject]@{ Key = 'address.replaceHostname'; Type = 'Text'; Question = 'Existing custom Proxy hostname to replace (Enter to retain all others)'; Optional = $true }
    )
}

function Get-ClaudeFlowStepPlan {
    param($Record, $Discovery)
    $d = Get-ClaudeDecision -Record $Record -Key address
    if (-not $d) { throw 'The address decision is missing; supply the hostname and certificate source.' }
    if ($d.dnsMode -notin @('AzureDns','External')) { throw 'The address dnsMode must be AzureDns or External.' }
    if ($d.dnsMode -eq 'AzureDns' -and -not $d.dnsZoneResourceId) { throw 'AzureDns requires dnsZoneResourceId.' }
    $subscription = Get-ClaudeFlowRecordSubscription $Record
    if (-not $subscription) { $subscription = (Invoke-ClaudeNetworkAz @('account','show')).id }
    $password = if (Get-Variable AddressCertificatePassword -ErrorAction SilentlyContinue) { Get-Variable AddressCertificatePassword -ValueOnly } else { $null }
    $recovery = if ($Discovery) { $Discovery.addressRecovery } else { $null }
    if ($recovery -and $recovery.Allowed -and (ConvertTo-ClaudeFlowCanonical $d) -cne (ConvertTo-ClaudeFlowCanonical $recovery.Decision)) {
        throw 'Address recovery must retain the pending hostname, certificate and DNS choice. Complete or restore that operation before another change.'
    }
    $plan = Get-ClaudeAddressPlan -SubscriptionId $subscription -ResourceGroup $Record.resourceGroup -ApimName $Record.apimName `
        -Hostname $d.hostname -CertificateSource $d.certificateSource -KeyVaultCertificateId $d.keyVaultCertificateId `
        -PfxPath $d.pfxPath -CertificatePassword $password -ReplaceHostname $d.replaceHostname `
        -DnsZoneResourceId $(if ($d.dnsMode -eq 'AzureDns') { $d.dnsZoneResourceId } else { '' })
    if ($recovery -and $recovery.Allowed) {
        $plan.Data.RecoveryFingerprint = $recovery.Fingerprint
        $plan.Summary = "Recover the unverified address $($d.hostname); publish only after proof."
    }
    return $plan
}

function Invoke-ClaudeFlowStep {
    param($Record, $Plan, [securestring]$CertificatePassword)
    $result = Invoke-ClaudeAddressPlan -Plan $Plan -CertificatePassword $CertificatePassword -RecordPath $Record.__recordPath
    Set-ClaudeRecordProperty $Record address $result.Address
    $Record.PSObject.Properties.Remove('pendingAddress')
    @{ gatewayUrl = $result.GatewayUrl; address = $result.Address; RecordChanges = @{ address = $result.Address }; RemovedProperties = @('pendingAddress') }
}

function Test-ClaudeFlowStep {
    param($Record)
    $d = Get-ClaudeDecision -Record $Record -Key address
    $passed = $false; $evidence = ''
    try {
        if (-not $d.hostname -or -not $d.certificateThumbprint) { throw 'No verified company address is recorded.' }
        $proof = Invoke-ClaudeAddressHttps -Hostname $d.hostname -Thumbprint $d.certificateThumbprint
        $passed = ($proof.StatusCode -eq 401 -and $proof.Trusted -and $proof.Thumbprint -ieq $d.certificateThumbprint -and $Record.gatewayUrl -eq "https://$($d.hostname)/claude")
        $evidence = "HTTPS $($proof.StatusCode); certificate $($proof.Thumbprint); recorded URL $($Record.gatewayUrl)"
    }
    catch { $evidence = $_.Exception.Message }
    [pscustomobject]@{ Step = 'Address'; Passed = $passed; Checks = @(@{ Name = 'company DNS/TLS gateway address'; Passed = $passed; Evidence = $evidence; Fix = 'The company hostname must resolve to this gateway and present the recorded, trusted certificate.' }) }
}
