# Certificate metadata and pinned HTTPS for the company-address path (ADR-0033).
function Get-ClaudeCertificateDnsNames {
    param([Security.Cryptography.X509Certificates.X509Certificate2]$Certificate)
    $san = @($Certificate.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.17' })
    if (-not $san.Count) { return @($Certificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)) }
    [byte[]]$bytes = $san[0].RawData
    $length = {
        param([ref]$Offset)
        if ($Offset.Value -ge $bytes.Length) { throw 'Invalid certificate SAN encoding.' }
        [int]$n = $bytes[$Offset.Value]; $Offset.Value++
        if ($n -band 128) {
            $count = $n -band 127
            if ($count -lt 1 -or $count -gt 4 -or $Offset.Value + $count -gt $bytes.Length) { throw 'Invalid certificate SAN length.' }
            $n = 0
            for ($j = 0; $j -lt $count; $j++) { $n = $n * 256 + $bytes[$Offset.Value]; $Offset.Value++ }
        }
        return $n
    }
    if ($bytes.Length -lt 2 -or $bytes[0] -ne 48) { throw 'Invalid certificate SAN sequence.' }
    $i = 1; $size = & $length ([ref]$i); $end = $i + $size
    if ($end -ne $bytes.Length) { throw 'Invalid certificate SAN boundary.' }
    while ($i -lt $end) {
        $tag = $bytes[$i]; $i++
        $size = & $length ([ref]$i)
        if ($size -lt 0 -or $i + $size -gt $end) { throw 'Invalid certificate SAN entry.' }
        if ($tag -eq 130) { [Text.Encoding]::ASCII.GetString($bytes, $i, $size) }
        $i += $size
    }
}

function Assert-ClaudeAddressCertificate {
    param([Security.Cryptography.X509Certificates.X509Certificate2]$Certificate, [string]$Hostname, [switch]$RequirePrivateKey)
    if ($RequirePrivateKey -and -not $Certificate.HasPrivateKey) { throw 'The PFX must contain its private key.' }
    $now = [DateTime]::UtcNow
    if ($Certificate.NotBefore.ToUniversalTime() -gt $now -or $Certificate.NotAfter.ToUniversalTime() -le $now) {
        throw 'Certificate validity does not include today (expired or not yet valid).'
    }
    $rsa = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($Certificate)
    try { if (-not $rsa -or $rsa.KeySize -lt 2048) { throw 'The gateway certificate needs an RSA key of at least 2048 bits.' } }
    finally { if ($rsa) { $rsa.Dispose() } }
    $covered = $false
    foreach ($name in @(Get-ClaudeCertificateDnsNames $Certificate)) {
        if ($name -ieq $Hostname) { $covered = $true }
        elseif ($name.StartsWith('*.') -and $Hostname.Contains('.')) {
            if ($Hostname.Substring($Hostname.IndexOf('.') + 1) -ieq $name.Substring(2)) { $covered = $true }
        }
    }
    if (-not $covered) { throw "The certificate does not cover hostname '$Hostname'." }
}

function Read-ClaudeAddressCertificate {
    param(
        [string]$CertificateSource, [string]$KeyVaultCertificateId, [string]$PfxPath,
        [securestring]$CertificatePassword, [string]$Hostname, [string]$SubscriptionId,
        [byte[]]$PfxBytes
    )
    if ($CertificateSource -eq 'Pfx') {
        if ($null -eq $PfxBytes) {
            if (-not $PfxPath -or -not (Test-Path -LiteralPath $PfxPath -PathType Leaf)) { throw 'PfxPath must name an existing PFX file.' }
            $PfxBytes = [IO.File]::ReadAllBytes($PfxPath)
        }
        $collection = New-Object Security.Cryptography.X509Certificates.X509Certificate2Collection
        $plain = if ($CertificatePassword) { (New-Object Net.NetworkCredential('', $CertificatePassword)).Password } else { '' }
        try {
            try { $collection.Import($PfxBytes, $plain, [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet) }
            catch { throw 'The PFX could not be opened. Its format or supplied password is invalid.' }
            $leaf = @($collection | Where-Object HasPrivateKey)
            if ($leaf.Count -ne 1) { throw 'The PFX must contain exactly one certificate with a private key, plus its chain.' }
            Assert-ClaudeAddressCertificate -Certificate $leaf[0] -Hostname $Hostname -RequirePrivateKey
            $sha = [Security.Cryptography.SHA256]::Create()
            try { $hash = -join ($sha.ComputeHash($PfxBytes) | ForEach-Object { $_.ToString('X2') }) }
            finally { $sha.Dispose() }
            return [pscustomobject]@{
                Thumbprint = $leaf[0].Thumbprint; PfxSha256 = $hash
                SecretId = ''; VaultId = ''; Rbac = $false
            }
        }
        finally { $plain = $null; foreach ($c in $collection) { $c.Dispose() } }
    }
    if ($CertificateSource -ne 'KeyVault') { throw 'Free managed certificates are not supported on API Management v2; use KeyVault or Pfx.' }
    if ($KeyVaultCertificateId -notmatch '^https://([a-zA-Z0-9-]{3,24})\.vault\.azure\.net/(certificates|secrets)/([a-zA-Z0-9-]{1,127})(/([a-zA-Z0-9-]+))?$') {
        throw 'Key Vault certificate URL must be an HTTPS certificate or secret identifier in vault.azure.net, without a query.'
    }
    $vaultName = $Matches[1]; $certName = $Matches[3]; $version = $Matches[5]
    $args = @('keyvault','certificate','show','--vault-name',$vaultName,'--name',$certName,'--subscription',$SubscriptionId)
    if ($version) { $args += @('--version', $version) }
    $metadata = Invoke-ClaudeNetworkAz $args
    if (-not $metadata.attributes.enabled) { throw 'The Key Vault certificate is disabled.' }
    if (-not $metadata.policy.keyProperties.exportable -or $metadata.policy.secretProperties.contentType -ne 'application/x-pkcs12') {
        throw 'The Key Vault certificate must have an exportable key and an application/x-pkcs12 backing secret.'
    }
    $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new([Convert]::FromBase64String($metadata.cer))
    try {
        Assert-ClaudeAddressCertificate -Certificate $certificate -Hostname $Hostname
        $vault = Invoke-ClaudeNetworkAz @('keyvault','show','--name',$vaultName,'--subscription',$SubscriptionId)
        if ($vault.id -notmatch "^/subscriptions/$([regex]::Escape($SubscriptionId))/resourceGroups/[^/]+/providers/Microsoft.KeyVault/vaults/$([regex]::Escape($vaultName))$") {
            throw 'The certificate vault was not found in the selected subscription.'
        }
        $secret = "https://$vaultName.vault.azure.net/secrets/$certName"
        if ($version) { $secret += "/$version" }
        return [pscustomobject]@{ Thumbprint = $certificate.Thumbprint; PfxSha256 = ''; SecretId = $secret; VaultId = $vault.id; Rbac = [bool]$vault.properties.enableRbacAuthorization }
    }
    finally { $certificate.Dispose() }
}

function Test-ClaudeAddressTlsPolicy {
    param([int]$Errors, [string]$Thumbprint, [string]$ExpectedThumbprint, [switch]$IsolatedProof)
    if (-not $Thumbprint -or $Thumbprint -ine $ExpectedThumbprint) { return $false }
    return ($Errors -eq 0 -or ($IsolatedProof -and $Errors -eq 4))
}

function Invoke-ClaudeAddressHttps {
    param([string]$Hostname, [string]$Thumbprint, [string]$ConnectAddress, [switch]$IsolatedProof)
    $target = if ($ConnectAddress) { $ConnectAddress } else { $Hostname }
    $client = New-Object Net.Sockets.TcpClient
    $ssl = $null
    $verification = @{ Trusted = $false }
    $expected = $Thumbprint; $isolated = [bool]$IsolatedProof
    $policy = ${function:Test-ClaudeAddressTlsPolicy}
    $callback = {
        param($sender, $certificate, $chain, $errors)
        $verification.Trusted = ([int]$errors -eq 0)
        $actual = if ($certificate) { $certificate.GetCertHashString() } else { '' }
        & $policy -Errors ([int]$errors) -Thumbprint $actual -ExpectedThumbprint $expected -IsolatedProof:$isolated
    }.GetNewClosure()
    try {
        $connect = $client.BeginConnect($target, 443, $null, $null)
        try {
            if (-not $connect.AsyncWaitHandle.WaitOne(15000)) { throw 'HTTPS TCP connection timed out after 15 s.' }
            $client.EndConnect($connect)
        }
        finally { $connect.AsyncWaitHandle.Close() }
        $stream = $client.GetStream()
        $stream.ReadTimeout = 15000; $stream.WriteTimeout = 15000
        $ssl = New-Object Net.Security.SslStream($stream, $false, [Net.Security.RemoteCertificateValidationCallback]$callback)
        $ssl.AuthenticateAsClient($Hostname, $null, [Security.Authentication.SslProtocols]::Tls12, $true)
        $request = "POST /claude/v1/messages HTTP/1.1`r`nHost: $Hostname`r`nContent-Type: application/json`r`nContent-Length: 2`r`nConnection: close`r`n`r`n{}"
        $bytes = [Text.Encoding]::ASCII.GetBytes($request)
        $ssl.Write($bytes, 0, $bytes.Length); $ssl.Flush()
        $reader = New-Object IO.StreamReader($ssl, [Text.Encoding]::ASCII)
        $status = $reader.ReadLine()
        if ($status -notmatch '^HTTP/1\.[01] ([0-9]{3}) ') { throw 'HTTPS returned an invalid HTTP status line.' }
        $code = [int]$Matches[1]
        [pscustomobject]@{ StatusCode = $code; Thumbprint = $ssl.RemoteCertificate.GetCertHashString(); Trusted = $verification.Trusted; Hostname = $Hostname }
    }
    catch { throw "HTTPS proof for '$Hostname' failed: $($_.Exception.Message)" }
    finally { if ($ssl) { $ssl.Dispose() }; $client.Close() }
}
