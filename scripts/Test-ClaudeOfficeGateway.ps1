[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][uri]$GatewayUrl,
    [string]$Origin = 'https://pivot.claude.ai'
)

$ErrorActionPreference = 'Stop'
$base = $GatewayUrl.AbsoluteUri.TrimEnd('/')
$messages = "$base/v1/messages"
$requestedHeaders = @(
    'authorization',
    'content-type',
    'accept',
    'anthropic-version',
    'anthropic-beta',
    'x-api-key',
    'x-claude-code-session-id'
)
$requestHeaders = @{
    Origin = $Origin
    'Access-Control-Request-Method' = 'POST'
    'Access-Control-Request-Headers' = $requestedHeaders -join ','
}

function Get-HeaderValue($response, $name) {
    $value = $response.Headers[$name]
    if ($value -is [array]) { return ($value -join ', ') }
    return [string]$value
}

function Get-HeaderTokens($response, $name) {
    return @((Get-HeaderValue $response $name).Split(',', [StringSplitOptions]::RemoveEmptyEntries) |
        ForEach-Object { $_.Trim().ToLowerInvariant() })
}

function Invoke-ProbeRequest {
    param(
        [ValidateSet('OPTIONS', 'POST')][string]$Method,
        [hashtable]$Headers,
        [string]$Body
    )
    try {
        return Invoke-WebRequest -Uri $messages -Method $Method -Headers $Headers `
            -Body $Body -ContentType 'application/json' -SkipHttpErrorCheck
    }
    catch {
        throw "Office gateway probe request failed before a response was received: $($_.Exception.Message)"
    }
}

$failures = [Collections.Generic.List[string]]::new()
$preflight = Invoke-ProbeRequest -Method OPTIONS -Headers $requestHeaders -Body ''
$preflightOrigin = Get-HeaderValue $preflight 'Access-Control-Allow-Origin'
$preflightMethods = @(Get-HeaderTokens $preflight 'Access-Control-Allow-Methods')
$preflightHeaders = @(Get-HeaderTokens $preflight 'Access-Control-Allow-Headers')
if ($preflight.StatusCode -lt 200 -or $preflight.StatusCode -ge 300) {
    $failures.Add("preflight returned HTTP $($preflight.StatusCode), expected 2xx")
}
if ($preflightOrigin -ne $Origin) {
    $failures.Add("preflight Access-Control-Allow-Origin was '$preflightOrigin', expected '$Origin'")
}
if ($preflightMethods -notcontains 'post') {
    $failures.Add("preflight Access-Control-Allow-Methods was '$($preflightMethods -join ',')', expected POST")
}
foreach ($header in $requestedHeaders) {
    if ($preflightHeaders -notcontains $header) {
        $failures.Add("preflight did not allow requested header '$header'")
    }
}

$unauthenticated = Invoke-ProbeRequest -Method POST -Headers @{ Origin = $Origin } -Body '{}'
$errorOrigin = Get-HeaderValue $unauthenticated 'Access-Control-Allow-Origin'
if ($unauthenticated.StatusCode -ne 401) {
    $failures.Add("unauthenticated POST returned HTTP $($unauthenticated.StatusCode), expected 401")
}
if ($errorOrigin -ne $Origin) {
    $failures.Add("401 Access-Control-Allow-Origin was '$errorOrigin', expected '$Origin'")
}

$foreignHeaders = @{
    Origin = 'https://office.example.invalid'
    'Access-Control-Request-Method' = 'POST'
    'Access-Control-Request-Headers' = 'authorization,content-type'
}
$foreign = Invoke-ProbeRequest -Method OPTIONS -Headers $foreignHeaders -Body ''
$foreignOrigin = Get-HeaderValue $foreign 'Access-Control-Allow-Origin'
if (-not [string]::IsNullOrEmpty($foreignOrigin)) {
    $failures.Add("foreign origin received Access-Control-Allow-Origin '$foreignOrigin'")
}

Write-Host "Office gateway probe: $base"
Write-Host "  preflight: HTTP $($preflight.StatusCode), allow-origin '$preflightOrigin'"
Write-Host "  preflight methods: '$($preflightMethods -join ',')'"
Write-Host "  preflight headers: '$($preflightHeaders -join ',')'"
Write-Host "  unauthenticated POST: HTTP $($unauthenticated.StatusCode), allow-origin '$errorOrigin'"
Write-Host "  foreign preflight: HTTP $($foreign.StatusCode), allow-origin '$foreignOrigin'"
if ($failures.Count) {
    $failures | ForEach-Object { Write-Host "  [FAIL] $_" -ForegroundColor Red }
    exit 1
}
Write-Host 'Office gateway CORS probe passed.' -ForegroundColor Green
