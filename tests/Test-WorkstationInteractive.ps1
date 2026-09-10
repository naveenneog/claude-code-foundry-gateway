$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'scripts/Setup-ClaudeWorkstation.ps1'), [ref]$tokens, [ref]$errors)
$definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Resolve-GatewayInteractive' }, $true)
if (-not $definition) { throw 'Missing interactive gateway configuration resolver' }
. ([scriptblock]::Create($definition.Extent.Text))
$tenant = '11111111-1111-1111-1111-111111111111'
$client = '22222222-2222-2222-2222-222222222222'
$script:discoveryCalls = 0
function Invoke-RestMethod {
    param($Uri, $TimeoutSec, $MaximumRedirection)
    $script:discoveryCalls++
    if ($Uri -ne "https://login.microsoftonline.com/$tenant/v2.0/.well-known/openid-configuration" -or $MaximumRedirection -ne 0) { throw 'Unsafe discovery request' }
    return [pscustomobject]@{
        issuer = "https://login.microsoftonline.com/$tenant/v2.0"
        authorization_endpoint = "https://login.microsoftonline.com/$tenant/oauth2/v2.0/authorize"
        token_endpoint = "https://login.microsoftonline.com/$tenant/oauth2/v2.0/token"
    }
}
$inputConfig = [pscustomobject]@{ clientId = $client; sessionLifetimeSec = 3600; redirectPort = 8400; additionalRedirectReferrerHosts = 'login.microsoftonline.com' }
$result = Resolve-GatewayInteractive $inputConfig $tenant
if ($result.inferenceCredentialKind -ne 'interactive' -or $result.inferenceGatewayOidc.clientId -ne $client) { throw 'Wrong credential mode or client ID' }
if ($result.inferenceSessionLifetimeSec -ne 3600 -or $result.inferenceGatewayOidc.redirectPort -ne 8400) { throw 'Numeric UI fields missing' }
if ($result.inferenceGatewayOidc.issuer -ne "https://login.microsoftonline.com/$tenant/v2.0" -or
    $result.inferenceGatewayOidc.authorizationUrl -ne "https://login.microsoftonline.com/$tenant/oauth2/v2.0/authorize" -or
    $result.inferenceGatewayOidc.tokenUrl -ne "https://login.microsoftonline.com/$tenant/oauth2/v2.0/token" -or
    $result.inferenceGatewayOidcAuthFlow -ne 'browser') { throw 'OIDC UI fields missing' }
if ($result.inferenceGatewayOidc.bearerTokenType -ne 'access_token' -or $result.inferenceGatewayOidc.scopes -notmatch 'https://cognitiveservices.azure.com/.default') { throw 'Wrong gateway token audience' }
if ($script:discoveryCalls -ne 1) { throw 'Expected OIDC discovery' }
foreach ($invalid in @(
    @{ clientId = 'invalid' },
    @{ clientId = $client; redirectPort = 70000 },
    @{ clientId = $client; redirectPort = '8400' },
    @{ clientId = $client; sessionLifetimeSec = 0 },
    @{ clientId = $client; authFlow = 'invalid' },
    @{ clientId = $client; issuer = 'https://evil.example' },
    @{ clientId = $client; bearerTokenType = 'id_token' },
    @{ clientId = $client; bearerTokenType = @('access_token') },
    @{ clientId = $client; issuer = @("https://login.microsoftonline.com/$tenant/v2.0") },
    @{ clientId = $client; scopes = 'openid profile' },
    @{ clientId = $client; additionalRedirectReferrerHosts = 'https://evil.example/path' },
    @{ clientId = $client; clientSecret = 'must-not-be-accepted' }
)) {
    $caught = $false
    try { Resolve-GatewayInteractive ([pscustomobject]$invalid) $tenant | Out-Null } catch { $caught = $true }
    if (-not $caught) { throw 'Accepted invalid interactive configuration' }
}
if ($script:discoveryCalls -ne 1) { throw 'Invalid input reached OIDC discovery' }
$minimal = Resolve-GatewayInteractive ([pscustomobject]@{ clientId = $client; authFlow = 'broker' }) $tenant
if ($minimal.inferenceGatewayOidcAuthFlow -ne 'broker' -or $minimal.Contains('inferenceSessionLifetimeSec') -or $minimal.inferenceGatewayOidc.Contains('redirectPort')) { throw 'Wrong optional-field defaults' }
Write-Host 'Interactive gateway discovery and validation passed.'