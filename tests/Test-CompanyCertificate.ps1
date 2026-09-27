$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$script:failed = 0
$script:assertions = 0
function Check([string]$Name, [scriptblock]$Test) {
    $script:assertions++
    try { $ok = [bool](& $Test); $why = '' } catch { $ok = $false; $why = $_.Exception.Message }
    if ($ok) { Write-Host "  [OK] $Name" } else { $script:failed++; Write-Host "  [FAIL] $Name $why" }
}
function Reject([scriptblock]$Test, [string]$Pattern) {
    try { & $Test | Out-Null; return $false } catch { return ($_.Exception.Message -match $Pattern) }
}
$lib = Join-Path $root 'scripts\ClaudeGatewayCertificate.ps1'
Check 'the company certificate helper exists' { Test-Path -LiteralPath $lib }
if (Test-Path -LiteralPath $lib) { . $lib }
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('company-certificate-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch -Force | Out-Null
$sub = '00000000-0000-0000-0000-000000000001'
$script:certs = @()
$script:keys = @()
function New-TestCertificate([string[]]$Names = @('claude.contoso.test'), [int]$Bits = 2048, [int]$FromDays = -1, [int]$ToDays = 30) {
    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider($Bits)
    $rsa.PersistKeyInCsp = $false
    $script:keys += $rsa
    $req = [Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=claude.contoso.test', $rsa, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    if ($Names.Count) {
        $san = [Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new()
        foreach ($name in $Names) { $san.AddDnsName($name) }
        $req.CertificateExtensions.Add($san.Build())
    }
    $c = $req.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays($FromDays), [DateTimeOffset]::UtcNow.AddDays($ToDays))
    $script:certs += $c
    return $c
}
try {
    $valid = New-TestCertificate @('first.contoso.test','claude.contoso.test')
    $pfx = Join-Path $scratch 'company.pfx'
    $password = ConvertTo-SecureString 'fixture-only-password' -AsPlainText -Force
    [IO.File]::WriteAllBytes($pfx, $valid.Export([Security.Cryptography.X509Certificates.X509ContentType]::Pfx, 'fixture-only-password'))
    Check 'a non-first DNS SAN covers the hostname' { Assert-ClaudeAddressCertificate -Certificate $valid -Hostname 'claude.contoso.test' -RequirePrivateKey; $true }
    Check 'the certificate hostname is case insensitive' { Assert-ClaudeAddressCertificate -Certificate $valid -Hostname 'CLAUDE.CONTOSO.TEST'; $true }
    Check 'an unrelated certificate hostname fails' { Reject { Assert-ClaudeAddressCertificate -Certificate $valid -Hostname 'other.contoso.test' } 'cover.*hostname' }
    Check 'a SAN overrides the subject common name' {
        $wrong = New-TestCertificate @('other.contoso.test')
        Reject { Assert-ClaudeAddressCertificate -Certificate $wrong -Hostname 'claude.contoso.test' } 'cover.*hostname'
    }
    Check 'an absent SAN can use the common name' {
        $cn = New-TestCertificate @()
        Assert-ClaudeAddressCertificate -Certificate $cn -Hostname 'claude.contoso.test'
        $true
    }
    $wildcard = New-TestCertificate @('*.contoso.test')
    Check 'a wildcard certificate matches one label' { Assert-ClaudeAddressCertificate -Certificate $wildcard -Hostname 'claude.contoso.test'; $true }
    Check 'a wildcard certificate cannot match two labels' { Reject { Assert-ClaudeAddressCertificate -Certificate $wildcard -Hostname 'a.claude.contoso.test' } 'cover.*hostname' }
    Check 'an expired certificate is refused' { Reject { Assert-ClaudeAddressCertificate -Certificate (New-TestCertificate -FromDays -3 -ToDays -1) -Hostname 'claude.contoso.test' } 'expired|validity' }
    Check 'a not-yet-valid certificate is refused' { Reject { Assert-ClaudeAddressCertificate -Certificate (New-TestCertificate -FromDays 1 -ToDays 2) -Hostname 'claude.contoso.test' } 'validity|not yet' }
    Check 'a 1024-bit RSA key is refused' { Reject { Assert-ClaudeAddressCertificate -Certificate (New-TestCertificate -Bits 1024) -Hostname 'claude.contoso.test' } '2048' }
    $public = [Security.Cryptography.X509Certificates.X509Certificate2]::new($valid.Export([Security.Cryptography.X509Certificates.X509ContentType]::Cert))
    $script:certs += $public
    Check 'PFX validation requires a private key' { Reject { Assert-ClaudeAddressCertificate -Certificate $public -Hostname 'claude.contoso.test' -RequirePrivateKey } 'private key' }
    Check 'a PFX descriptor binds its hash and never contains bytes or password' {
        $d = Read-ClaudeAddressCertificate -CertificateSource Pfx -PfxPath $pfx -CertificatePassword $password -Hostname 'claude.contoso.test' -SubscriptionId $sub
        $d.Thumbprint -eq $valid.Thumbprint -and $d.PfxSha256 -eq (Get-FileHash -LiteralPath $pfx -Algorithm SHA256).Hash -and
            ($d | ConvertTo-Json -Depth 6) -notmatch 'fixture-only-password|encodedCertificate'
    }
    Check 'a wrong PFX password is refused without echoing it' {
        try { Read-ClaudeAddressCertificate -CertificateSource Pfx -PfxPath $pfx -CertificatePassword (ConvertTo-SecureString 'wrong-fixture-value' -AsPlainText -Force) -Hostname 'claude.contoso.test' -SubscriptionId $sub; $false }
        catch { $_.Exception.Message -match 'PFX' -and $_.Exception.Message -notmatch 'wrong-fixture-value' }
    }
    $script:azCalls = @()
    $script:enabled = $true
    $script:exportable = $true
    function Invoke-ClaudeNetworkAz {
        param($Arguments)
        $script:azCalls += ,@($Arguments)
        if ($Arguments -contains 'certificate') {
            return [pscustomobject]@{
                cer = [Convert]::ToBase64String($valid.RawData); sid = 'https://kv-contoso.vault.azure.net/secrets/company/abc123'
                attributes = @{ enabled = $script:enabled }
                policy = @{ keyProperties = @{ exportable = $script:exportable }; secretProperties = @{ contentType = 'application/x-pkcs12' } }
            }
        }
        [pscustomobject]@{ id = "/subscriptions/$sub/resourceGroups/rg-contoso/providers/Microsoft.KeyVault/vaults/kv-contoso"; properties = @{ enableRbacAuthorization = $true } }
    }
    Check 'a Key Vault certificate is referenced through its versionless backing secret' {
        $d = Read-ClaudeAddressCertificate -CertificateSource KeyVault -KeyVaultCertificateId 'https://kv-contoso.vault.azure.net/certificates/company' -Hostname 'claude.contoso.test' -SubscriptionId $sub
        $d.SecretId -eq 'https://kv-contoso.vault.azure.net/secrets/company' -and $d.Thumbprint -eq $valid.Thumbprint -and
            @($script:azCalls | Where-Object { $_ -contains 'secret' }).Count -eq 0
    }
    Check 'an explicit Key Vault secret version stays pinned' {
        $d = Read-ClaudeAddressCertificate -CertificateSource KeyVault -KeyVaultCertificateId 'https://kv-contoso.vault.azure.net/secrets/company/abc123' -Hostname 'claude.contoso.test' -SubscriptionId $sub
        $d.SecretId -eq 'https://kv-contoso.vault.azure.net/secrets/company/abc123' -and @($script:azCalls[-2]) -contains '--version'
    }
    Check 'a disabled Key Vault certificate is refused' {
        $script:enabled = $false
        $result = Reject { Read-ClaudeAddressCertificate -CertificateSource KeyVault -KeyVaultCertificateId 'https://kv-contoso.vault.azure.net/certificates/company' -Hostname 'claude.contoso.test' -SubscriptionId $sub } 'disabled'
        $script:enabled = $true; $result
    }
    Check 'a nonexportable Key Vault key is refused' {
        $script:exportable = $false
        $result = Reject { Read-ClaudeAddressCertificate -CertificateSource KeyVault -KeyVaultCertificateId 'https://kv-contoso.vault.azure.net/certificates/company' -Hostname 'claude.contoso.test' -SubscriptionId $sub } 'exportable'
        $script:exportable = $true; $result
    }
    foreach ($bad in 'http://kv-contoso.vault.azure.net/secrets/company','https://evil.test/secrets/company','https://kv-contoso.vault.azure.net/secrets/company?x=1','https://kv-contoso.vault.azure.net/secrets/a&whoami') {
        Check "untrusted certificate reference is refused: $bad" {
            $before = $script:azCalls.Count
            (Reject { Read-ClaudeAddressCertificate -CertificateSource KeyVault -KeyVaultCertificateId $bad -Hostname 'claude.contoso.test' -SubscriptionId $sub } 'Key Vault.*URL') -and $script:azCalls.Count -eq $before
        }
    }
    Check 'ordinary TLS requires both a trusted chain and the exact certificate' { Test-ClaudeAddressTlsPolicy -Errors 0 -Thumbprint 'ABC' -ExpectedThumbprint 'ABC' }
    Check 'trusted TLS with another certificate is refused' { -not (Test-ClaudeAddressTlsPolicy -Errors 0 -Thumbprint 'WRONG' -ExpectedThumbprint 'ABC') }
    Check 'a self-signed certificate is refused by production TLS' { -not (Test-ClaudeAddressTlsPolicy -Errors 4 -Thumbprint 'ABC' -ExpectedThumbprint 'ABC') }
    Check 'isolated proof allows only chain errors with the exact certificate' { Test-ClaudeAddressTlsPolicy -Errors 4 -Thumbprint 'ABC' -ExpectedThumbprint 'ABC' -IsolatedProof }
    Check 'isolated proof still refuses a hostname mismatch' { -not (Test-ClaudeAddressTlsPolicy -Errors 6 -Thumbprint 'ABC' -ExpectedThumbprint 'ABC' -IsolatedProof) }
    Check 'isolated proof still refuses another certificate' { -not (Test-ClaudeAddressTlsPolicy -Errors 4 -Thumbprint 'WRONG' -ExpectedThumbprint 'ABC' -IsolatedProof) }
    Check 'isolated proof still refuses a missing certificate' { -not (Test-ClaudeAddressTlsPolicy -Errors 1 -Thumbprint 'ABC' -ExpectedThumbprint 'ABC' -IsolatedProof) }
    Check 'global retail meters accept an empty ARM region without becoming unknown' {
        . (Join-Path $root 'scripts\AzureRetailPrice.ps1')
        $script:RetailPriceCache['Azure DNS|'] = @([pscustomobject]@{ meterName = 'Public Zone'; type = 'Consumption'; skuName = 'Public'; productName = 'Azure DNS'; tierMinimumUnits = 0; retailPrice = 0.5; unitOfMeasure = '1'; currencyCode = 'USD' })
        $p = Get-AzureRetailPrice -ServiceName 'Azure DNS' -Region '' -MeterName 'Public Zone' -SkuName Public -Tier First
        $p.UnitPrice -eq [decimal]0.5
    }
}
finally {
    foreach ($c in $script:certs) { $c.Dispose() }
    foreach ($key in $script:keys) { $key.Dispose() }
    Remove-Item -LiteralPath $scratch -Recurse -Force
}
Write-Host ("Company certificate: {0} assertions, {1} passed, {2} failed." -f $script:assertions, ($script:assertions - $script:failed), $script:failed)
if ($script:failed) { exit 1 }
