<#
.SYNOPSIS
    Which network destinations the Claude clients need, tested rather than listed.

.DESCRIPTION
    A firewall allowlist written from documentation is a guess. The binaries
    carry 157 hostnames between them - documentation links, certificate
    authority URLs, example.com, endpoints for clouds you are not using - and
    allowing all of them is both over-permissive and beside the point, because
    what a client needs at runtime is a much shorter list than what it mentions.

    This checks the short list. Every destination here was observed on the wire
    from this repository's clients, not read off a page, and each is marked with
    what actually breaks when it is blocked. That matters because the failure is
    rarely legible: a blocked endpoint usually surfaces as a hang, an ENOTFOUND,
    or a 'model not found', none of which name the host.

    Two things worth knowing before reading the output.

    The scope is not the endpoint. `https://cognitiveservices.azure.com` is the
    token *audience* - the string in the OAuth scope - and not an address any
    client connects to. An allowlist containing it without a wildcard looks like
    it covers Foundry and does not. The data-plane host is
    `<resource>.services.ai.azure.com`, measured.

    The two paths need different things. On the direct path the client talks to
    Foundry. On the gateway path it talks to API Management at
    `<name>.azure-api.net` and never to Foundry at all - the gateway does that
    with its own identity. Allowing one does not allow the other.

.PARAMETER FoundryResource
    The Foundry account name. Read from the Claude settings when omitted.

.PARAMETER GatewayHost
    The API Management host. Read from the Claude settings when omitted.

.PARAMETER IncludeOptional
    Also test destinations that are not required - telemetry, update checks.
    Blocking these is a supported configuration; they are listed so that an
    allowlist author knows they were considered rather than missed.

.PARAMETER AsJson
    Emit the result as JSON for a change request or a ticket.

.EXAMPLE
    ./scripts/Test-ClaudeNetwork.ps1
    ./scripts/Test-ClaudeNetwork.ps1 -IncludeOptional
    ./scripts/Test-ClaudeNetwork.ps1 -FoundryResource contoso-ai -AsJson
#>
[CmdletBinding()]
param(
    [string]$FoundryResource,
    [string]$GatewayHost,
    [switch]$IncludeOptional,
    [switch]$SkipRoundTrip,
    [switch]$AsJson
)

$ErrorActionPreference = 'Stop'

# TLS 1.2 explicitly. PowerShell 5.1 still defaults to SSL3/TLS1.0 on some
# builds, and a handshake failure here would be reported as a blocked host.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Read-ClaudeEnv {
    $p = Join-Path $env:USERPROFILE '.claude/settings.json'
    if (-not (Test-Path $p)) { return $null }
    try { return (Get-Content $p -Raw | ConvertFrom-Json).env } catch { return $null }
}

$cfg = Read-ClaudeEnv
# An explicitly supplied argument wins over the configuration file. Detected via
# PSBoundParameters rather than by testing the variable, because an empty string
# is a deliberate 'do not use this path' and is indistinguishable from unset by
# a truthiness check - which silently re-filled it from settings and pointed the
# round trip at the gateway while the report named a resource.
$explicitResource = $PSBoundParameters.ContainsKey('FoundryResource')
$explicitGateway = $PSBoundParameters.ContainsKey('GatewayHost')

if (-not $explicitResource -and $cfg -and $cfg.PSObject.Properties['ANTHROPIC_FOUNDRY_RESOURCE']) {
    $FoundryResource = $cfg.ANTHROPIC_FOUNDRY_RESOURCE
}
if (-not $explicitGateway -and $cfg -and $cfg.PSObject.Properties['ANTHROPIC_FOUNDRY_BASE_URL']) {
    $u = $cfg.ANTHROPIC_FOUNDRY_BASE_URL
    if ($u -match '^https?://([^/]+)') { $GatewayHost = $Matches[1] }
}

# Each destination carries what breaks without it, so that an allowlist review
# is a conversation about consequences rather than about hostnames.
$targets = New-Object System.Collections.ArrayList

function Add-Target {
    param($TargetHost, $Port, $Need, $Path, $Breaks, $Note)
    $null = $targets.Add([pscustomobject]@{
            Host = $TargetHost; Port = $Port; Need = $Need; Path = $Path
            Breaks = $Breaks; Note = $Note
        })
}

if ($FoundryResource) {
    Add-Target "$FoundryResource.services.ai.azure.com" 443 'required' 'direct' `
        'Claude Code cannot reach Foundry. Every prompt fails.' `
        'Measured: this is the host the client dials, not cognitiveservices.azure.com.'
}
if ($GatewayHost) {
    Add-Target $GatewayHost 443 'required' 'gateway' `
        'Claude Code cannot reach the gateway. Every prompt fails.' `
        'API Management. Not covered by any *.azure.com rule - the suffix is azure-api.net.'
}

Add-Target 'login.microsoftonline.com' 443 'required' 'both' `
    'No Entra token can be issued. Sign-in and every call fail.' `
    'Also login.windows.net and sts.windows.net on older stacks.'

Add-Target 'management.azure.com' 443 'required' 'admin' `
    'Setup and the health checks cannot discover resources or deployments.' `
    'Admin and diagnostics only. A developer running Claude Code does not need it.'

Add-Target 'graph.microsoft.com' 443 'required' 'admin' `
    'Entitlement sync cannot resolve group membership.' `
    'Admin only, on the machine that runs the sync.'

if ($IncludeOptional) {
    Add-Target 'registry.npmjs.org' 443 'install' 'both' `
        'The CLI cannot be installed or updated. An installed one keeps working.' `
        'Corporate feeds substitute for this; observed here as packagefeedproxy.microsoft.io.'

    Add-Target 'marketplace.visualstudio.com' 443 'install' 'both' `
        'The VS Code extension cannot be installed or updated.' `
        'Extension download also uses *.vsassets.io and *.gallerycdn.vsassets.io.'

    Add-Target 'dc.services.visualstudio.com' 443 'optional' 'both' `
        'Nothing. Azure CLI telemetry only.' `
        'Observed during az calls. Turn it off with: az config set core.collect_telemetry=false'

    Add-Target 'api.anthropic.com' 443 'should-not-be-needed' 'both' `
        'Nothing in Foundry mode. Listed so its absence can be proved.' `
        'If this is blocked and Claude Code still works, no inference is leaving to Anthropic.'
}

function Test-Destination {
    param([string]$TargetHost, [int]$Port)

    $r = [ordered]@{ Host = $TargetHost; Port = $Port; Dns = $null; Tcp = $false; Tls = $false; Issuer = $null; Ms = 0; Error = $null }
    $sw = [Diagnostics.Stopwatch]::StartNew()

    try {
        $ips = [Net.Dns]::GetHostAddresses($TargetHost)
        $r.Dns = ($ips | Select-Object -First 2 | ForEach-Object { $_.IPAddressToString }) -join ', '
    }
    catch {
        $r.Error = 'DNS did not resolve'
        $sw.Stop(); $r.Ms = $sw.ElapsedMilliseconds
        return [pscustomobject]$r
    }

    $client = New-Object Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($TargetHost, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne(8000)) {
            $r.Error = 'timed out - silently dropped rather than refused'
            $client.Close(); $sw.Stop(); $r.Ms = $sw.ElapsedMilliseconds
            return [pscustomobject]$r
        }
        $client.EndConnect($iar)
        $r.Tcp = $true
    }
    catch {
        $r.Error = $_.Exception.Message.Split([char]10)[0]
        $client.Close(); $sw.Stop(); $r.Ms = $sw.ElapsedMilliseconds
        return [pscustomobject]$r
    }

    # The certificate issuer is read rather than validated. A corporate CA here
    # means TLS is being terminated and re-signed in the middle, which is worth
    # knowing: it is legitimate on most corporate networks, but it is also what
    # breaks clients that pin, and it is invisible from a plain reachability
    # test that only asks whether the port opened.
    try {
        $ssl = New-Object Net.Security.SslStream($client.GetStream(), $false, { param($a, $b, $c, $d) $true })
        $ssl.AuthenticateAsClient($TargetHost)
        $r.Tls = $true
        if ($ssl.RemoteCertificate) {
            $r.Issuer = (New-Object Security.Cryptography.X509Certificates.X509Certificate2($ssl.RemoteCertificate)).Issuer
        }
        $ssl.Dispose()
    }
    catch {
        $r.Error = 'TLS handshake failed: ' + $_.Exception.Message.Split([char]10)[0]
    }

    $client.Close()
    $sw.Stop(); $r.Ms = $sw.ElapsedMilliseconds
    return [pscustomobject]$r
}

$results = @()
foreach ($t in $targets) {
    $probe = Test-Destination -TargetHost $t.Host -Port $t.Port
    $ok = $probe.Tcp -and $probe.Tls
    $results += [pscustomobject]@{
        Host = $t.Host; Port = $t.Port; Need = $t.Need; Path = $t.Path
        Reachable = $ok; Ms = $probe.Ms; Issuer = $probe.Issuer
        Error = $probe.Error; Breaks = $t.Breaks; Note = $t.Note
    }
}

# The instance metadata service. Not a firewall rule and not on anyone's
# allowlist, but the Azure identity chain probes it before it falls back to the
# Azure CLI, so its behaviour is felt on every token acquisition. Refused is
# healthy - the chain moves on in milliseconds. Silently dropped is not: the
# chain waits for a timeout it cannot distinguish from a slow answer, and the
# cost is paid on every call. Measured here rather than assumed because the two
# look identical from the client and differ by seconds.
$imds = [ordered]@{ Behaviour = $null; Ms = 0 }
$sw = [Diagnostics.Stopwatch]::StartNew()
$c = New-Object Net.Sockets.TcpClient
try {
    $iar = $c.BeginConnect('169.254.169.254', 80, $null, $null)
    if ($iar.AsyncWaitHandle.WaitOne(3000)) {
        try { $c.EndConnect($iar); $imds.Behaviour = 'answers' } catch { $imds.Behaviour = 'refused' }
    }
    else { $imds.Behaviour = 'dropped' }
}
catch { $imds.Behaviour = 'refused' }
finally { $c.Close(); $sw.Stop(); $imds.Ms = $sw.ElapsedMilliseconds }

# The round trip. Reachability is not the same as working, and the gap between
# them is where the hard cases live: a host can resolve, accept TCP and complete
# a TLS handshake, and still reset the connection the moment a response starts
# streaming. An allowlist review passes that machine. The developer sees
# ECONNRESET and a retry counter.
#
# So the last check is an actual streaming Messages call, because streaming is
# what Claude Code does and streaming is what inspecting proxies break. A
# proxy that buffers a response to scan it cannot forward server-sent events,
# and many resolve that by cutting the connection rather than by failing the
# request in a way that names a cause.
function Test-RoundTrip {
    param([string]$Url, [string]$Model)

    $result = [ordered]@{
        Url = $Url; Model = $Model; Http = $null; Events = 0
        Streamed = $false; Ms = 0; Verdict = $null; Detail = $null
    }

    $token = $null
    try { $token = az account get-access-token --resource https://cognitiveservices.azure.com --query accessToken -o tsv 2>$null }
    catch { }
    if (-not $token) {
        $result.Verdict = 'skipped'
        $result.Detail = 'no Azure CLI token; run az login'
        return [pscustomobject]$result
    }

    $bodyFile = Join-Path ([IO.Path]::GetTempPath()) ("claude-net-" + [guid]::NewGuid().ToString('N') + '.json')
    $payload = '{"model":"' + $Model + '","max_tokens":32,"stream":true,"messages":[{"role":"user","content":"count to five"}]}'
    Set-Content -Path $bodyFile -Value $payload -Encoding ascii

    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        # curl rather than Invoke-WebRequest: Invoke-WebRequest buffers the whole
        # response before returning, which is precisely the behaviour under test.
        # A buffered client cannot tell a stream that completed from one that was
        # cut, because it only ever sees the end.
        $raw = & curl.exe -sS -N --no-buffer --max-time 60 -X POST $Url `
            -H "Authorization: Bearer $token" `
            -H 'content-type: application/json' `
            -H 'anthropic-version: 2023-06-01' `
            -d "@$bodyFile" `
            -w "`n[[HTTP:%{http_code}]]" 2>&1 | Out-String
    }
    catch {
        $raw = $_.Exception.Message
    }
    finally {
        $sw.Stop()
        Remove-Item $bodyFile -ErrorAction SilentlyContinue
    }
    $result.Ms = $sw.ElapsedMilliseconds

    if ($raw -match '\[\[HTTP:(\d+)\]\]') { $result.Http = [int]$Matches[1] }
    $result.Events = ([regex]::Matches($raw, '(?m)^event:\s')).Count
    $result.Streamed = $result.Events -gt 1

    if ($raw -match '(?i)reset by peer|ECONNRESET|connection was reset|Recv failure') {
        $result.Verdict = 'reset'
        $result.Detail = 'the connection was established and then cut mid-response'
    }
    elseif ($raw -match '(?i)Could not resolve host') {
        $result.Verdict = 'dns'
        $result.Detail = 'the hostname did not resolve'
    }
    elseif ($raw -match '(?i)Operation timed out|timed out') {
        $result.Verdict = 'timeout'
        $result.Detail = 'no response within the deadline'
    }
    elseif ($raw -match '(?i)SSL certificate problem|certificate verify failed|SSL_ERROR') {
        $result.Verdict = 'tls'
        $result.Detail = 'the certificate was not trusted - an inspecting proxy whose CA is not installed'
    }
    elseif ($result.Http -eq 200 -and $result.Streamed) {
        $result.Verdict = 'ok'
        $result.Detail = "$($result.Events) server-sent events received"
    }
    elseif ($result.Http -eq 200) {
        $result.Verdict = 'buffered'
        $result.Detail = 'HTTP 200 but no server-sent events arrived - something between here and Foundry is buffering'
    }
    elseif ($result.Http -eq 401 -or $result.Http -eq 403) {
        $result.Verdict = 'auth'
        $result.Detail = "HTTP $($result.Http) - the network is fine; this is a role or a firewall on the resource"
    }
    elseif ($result.Http -eq 404) {
        $result.Verdict = 'notfound'
        $result.Detail = "HTTP 404 - reachable, but '$Model' is not a deployment on this resource"
    }
    elseif ($result.Http) {
        $result.Verdict = "http$($result.Http)"
        $result.Detail = ($raw -replace '\s+', ' ')
        if ($result.Detail.Length -gt 200) { $result.Detail = $result.Detail.Substring(0, 200) }
    }
    else {
        $result.Verdict = 'failed'
        $result.Detail = ($raw -replace '\s+', ' ')
        if ($result.Detail.Length -gt 200) { $result.Detail = $result.Detail.Substring(0, 200) }
    }

    return [pscustomobject]$result
}

$roundTrip = $null
if (-not $SkipRoundTrip) {
    $model = 'claude-sonnet-5'
    if ($cfg -and $cfg.PSObject.Properties['ANTHROPIC_DEFAULT_SONNET_MODEL']) { $model = $cfg.ANTHROPIC_DEFAULT_SONNET_MODEL }
    $url = $null
    $testedPath = $null
    # A machine mid-migration has both configured. Testing whichever is found
    # first would report the gateway as healthy to someone debugging the direct
    # path, so the caller's explicit choice decides, and the path tested is
    # always named in the output.
    if ($explicitResource -and $FoundryResource) {
        $url = "https://$FoundryResource.services.ai.azure.com/anthropic/v1/messages"
        $testedPath = 'direct'
    }
    elseif ($GatewayHost -and $cfg -and $cfg.PSObject.Properties['ANTHROPIC_FOUNDRY_BASE_URL']) {
        $url = ($cfg.ANTHROPIC_FOUNDRY_BASE_URL.TrimEnd('/')) + '/v1/messages'
        $testedPath = 'gateway'
    }
    elseif ($GatewayHost) {
        $url = "https://$GatewayHost/v1/messages"
        $testedPath = 'gateway'
    }
    elseif ($FoundryResource) {
        $url = "https://$FoundryResource.services.ai.azure.com/anthropic/v1/messages"
        $testedPath = 'direct'
    }
    if ($url) {
        $roundTrip = Test-RoundTrip -Url $url -Model $model
        $roundTrip | Add-Member -NotePropertyName TestedPath -NotePropertyValue $testedPath -Force
    }
}

if ($AsJson) {
    [ordered]@{
        checkedUtc      = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        foundryResource = $FoundryResource
        gatewayHost     = $GatewayHost
        destinations    = $results
        roundTrip       = $roundTrip
        imds            = $imds
    } | ConvertTo-Json -Depth 6
    exit $(if (@($results | Where-Object { $_.Need -eq 'required' -and -not $_.Reachable }).Count -or ($roundTrip -and $roundTrip.Verdict -notin @('ok', 'skipped'))) { 1 } else { 0 })
}

Write-Host ''
Write-Host 'Claude client network access' -ForegroundColor Cyan
if ($FoundryResource) { Write-Host ("  Foundry resource : {0}" -f $FoundryResource) -ForegroundColor DarkGray }
if ($GatewayHost) { Write-Host ("  Gateway          : {0}" -f $GatewayHost) -ForegroundColor DarkGray }
if (-not $FoundryResource -and -not $GatewayHost) {
    Write-Host '  Neither a resource nor a gateway is configured; pass -FoundryResource or -GatewayHost.' -ForegroundColor Yellow
}

Write-Host ''
Write-Host ("  {0,-46} {1,-9} {2,-8} {3,-7} {4}" -f 'Destination', 'Needed by', 'Result', 'ms', 'TLS terminated by')
Write-Host ('  ' + ('-' * 118)) -ForegroundColor DarkGray
foreach ($r in $results) {
    $verdict = if ($r.Reachable) { 'reachable' } else { 'BLOCKED' }
    $colour = if ($r.Reachable) { 'Green' } elseif ($r.Need -eq 'required') { 'Red' } else { 'Yellow' }
    $issuer = ''
    if ($r.Issuer -and $r.Issuer -match 'CN=([^,]+)') { $issuer = $Matches[1] }
    Write-Host ("  {0,-46} {1,-9} {2,-8} {3,-7} {4}" -f "$($r.Host):$($r.Port)", $r.Path, $verdict, $r.Ms, $issuer) -ForegroundColor $colour
    if (-not $r.Reachable) {
        Write-Host ("      {0}" -f $r.Error) -ForegroundColor DarkGray
        Write-Host ("      breaks: {0}" -f $r.Breaks) -ForegroundColor DarkGray
    }
}

Write-Host ''
Write-Host '  Instance metadata (169.254.169.254)' -ForegroundColor Cyan
switch ($imds.Behaviour) {
    'refused' {
        Write-Host ("  refused in {0} ms - healthy. The credential chain falls through to the CLI at once." -f $imds.Ms) -ForegroundColor Green
    }
    'answers' {
        Write-Host '  answers - this machine has a managed identity. It will be tried before the Azure CLI.' -ForegroundColor Yellow
        Write-Host '  On a developer workstation that is usually not what you want; pin the chain with' -ForegroundColor DarkGray
        Write-Host '  AZURE_TOKEN_CREDENTIALS. See DEVELOPER.md.' -ForegroundColor DarkGray
    }
    'dropped' {
        Write-Host ("  silently dropped - every token acquisition waits {0} ms+ for this before falling back." -f $imds.Ms) -ForegroundColor Yellow
        Write-Host '  Ask the network team to refuse rather than drop it, or pin the credential chain.' -ForegroundColor DarkGray
    }
}

$blocked = @($results | Where-Object { $_.Need -eq 'required' -and -not $_.Reachable })
$mitm = @($results | Where-Object { $_.Issuer -and $_.Issuer -notmatch 'Microsoft|DigiCert|Baltimore|Entrust|GlobalSign|Amazon|Google|Let''s Encrypt|Sectigo|GeoTrust' })

if ($roundTrip) {
    Write-Host ''
    Write-Host '  Streaming round trip' -ForegroundColor Cyan
    Write-Host ("  {0} path: {1}" -f $roundTrip.TestedPath, $roundTrip.Url) -ForegroundColor DarkGray
    switch ($roundTrip.Verdict) {
        'ok' {
            Write-Host ("  works - {0} in {1} ms." -f $roundTrip.Detail, $roundTrip.Ms) -ForegroundColor Green
        }
        'reset' {
            Write-Host ("  RESET after {0} ms. {1}." -f $roundTrip.Ms, $roundTrip.Detail) -ForegroundColor Red
            Write-Host ''
            Write-Host '  This is not an allowlist problem. The host resolved, the port opened and TLS' -ForegroundColor Yellow
            Write-Host '  completed - adding the hostname again will not change it. Something in the path' -ForegroundColor Yellow
            Write-Host '  is cutting the connection once the response starts streaming.' -ForegroundColor Yellow
            Write-Host ''
            Write-Host '  In order of how often it is the cause:' -ForegroundColor DarkGray
            Write-Host '    1. An inspecting proxy that cannot forward server-sent events. Ask for these' -ForegroundColor DarkGray
            Write-Host '       hosts to be excluded from TLS inspection rather than merely allowed.' -ForegroundColor DarkGray
            Write-Host '    2. An idle or response-duration timeout on the proxy. A long answer streams' -ForegroundColor DarkGray
            Write-Host '       for longer than a short one, which is why this can look intermittent.' -ForegroundColor DarkGray
            Write-Host '    3. A network appliance terminating long-lived connections by policy.' -ForegroundColor DarkGray
            Write-Host ''
            Write-Host '  To confirm which, re-run this from a network without the proxy. If it works' -ForegroundColor DarkGray
            Write-Host '  there, the endpoint and the permissions are both fine and the proxy is the cause.' -ForegroundColor DarkGray
        }
        'buffered' {
            Write-Host ("  BUFFERED after {0} ms. {1}." -f $roundTrip.Ms, $roundTrip.Detail) -ForegroundColor Yellow
            Write-Host '  The request succeeded but nothing streamed. Claude Code will appear to hang and' -ForegroundColor DarkGray
            Write-Host '  then deliver the whole answer at once, or time out. Same fix as a reset: exclude' -ForegroundColor DarkGray
            Write-Host '  these hosts from inspection.' -ForegroundColor DarkGray
        }
        'tls' {
            Write-Host ("  TLS NOT TRUSTED after {0} ms. {1}." -f $roundTrip.Ms, $roundTrip.Detail) -ForegroundColor Red
            Write-Host '  The proxy is re-signing certificates and its authority is not trusted here.' -ForegroundColor DarkGray
            Write-Host '  Install the corporate root, or set NODE_EXTRA_CA_CERTS to a PEM holding it.' -ForegroundColor DarkGray
        }
        'auth' {
            Write-Host ("  {0}" -f $roundTrip.Detail) -ForegroundColor Yellow
            Write-Host '  Network access is proved by this result. Use Test-FoundryDirect.ps1 for the rest.' -ForegroundColor DarkGray
        }
        'notfound' {
            Write-Host ("  {0}" -f $roundTrip.Detail) -ForegroundColor Yellow
            Write-Host '  Network access is proved. The name in settings is not a deployment on the resource.' -ForegroundColor DarkGray
        }
        'skipped' {
            Write-Host ("  skipped - {0}" -f $roundTrip.Detail) -ForegroundColor DarkGray
        }
        default {
            Write-Host ("  {0} after {1} ms: {2}" -f $roundTrip.Verdict, $roundTrip.Ms, $roundTrip.Detail) -ForegroundColor Red
        }
    }
}

Write-Host ''
if ($mitm.Count) {
    Write-Host ("  TLS is terminated by something other than a public authority on {0} destination(s)." -f $mitm.Count) -ForegroundColor Yellow
    Write-Host '  That is normal with an inspecting proxy. It is worth recording, because a client' -ForegroundColor DarkGray
    Write-Host '  that pins certificates will fail against it with an error that names TLS, not the proxy.' -ForegroundColor DarkGray
    Write-Host ''
}

if ($blocked.Count) {
    Write-Host ("  {0} required destination(s) are blocked." -f $blocked.Count) -ForegroundColor Red
    foreach ($b in $blocked) { Write-Host ("    - {0}: {1}" -f $b.Host, $b.Breaks) -ForegroundColor Red }
    Write-Host ''
    exit 1
}

if ($roundTrip -and $roundTrip.Verdict -notin @('ok', 'skipped', 'auth', 'notfound')) {
    Write-Host ''
    Write-Host '  Every host is reachable and the round trip still failed. Reachability was never' -ForegroundColor Red
    Write-Host '  the question; see the round trip above.' -ForegroundColor Red
    Write-Host ''
    exit 1
}

Write-Host '  Every required destination is reachable.' -ForegroundColor Green
if (-not $IncludeOptional) {
    Write-Host '  Install and telemetry destinations were not tested; add -IncludeOptional for those.' -ForegroundColor DarkGray
}
Write-Host ''
exit 0

