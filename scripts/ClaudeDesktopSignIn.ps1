<#
.SYNOPSIS
    Shared validation and rendering for Claude Desktop third-party sign-in.
#>

function Test-ClaudeGuid {
    param([string]$Value)
    $g = [guid]::Empty
    return [guid]::TryParse($Value, [ref]$g)
}

function Get-ClaudeDesktopSignIn {
    param(
        [Parameter(Mandatory)]$Config
    )

    $raw = $Config.desktopSignIn
    if (-not $raw) {
        return [pscustomobject]@{
            kind = 'helper-script'
            flow = $null
            bearerTokenType = $null
            clientId = $null
            issuer = $null
            scopes = $null
            audience = $null
            resource = $null
        }
    }

    $kind = [string]$raw.kind
    if ([string]::IsNullOrWhiteSpace($kind)) { $kind = 'helper-script' }
    if ($kind -notin @('helper-script', 'external-idp')) {
        throw "Invalid desktopSignIn.kind '$kind'. Use helper-script or external-idp."
    }

    if ($kind -eq 'helper-script') {
        return [pscustomobject]@{
            kind = 'helper-script'
            flow = $null
            bearerTokenType = $null
            clientId = $null
            issuer = $null
            scopes = $null
            audience = $null
            resource = $null
        }
    }

    $flow = [string]$raw.flow
    if ($flow -notin @('browser', 'broker')) {
        throw "Invalid desktopSignIn.flow '$flow'. Use browser or broker."
    }

    $tokenType = [string]$raw.bearerTokenType
    if ([string]::IsNullOrWhiteSpace($tokenType)) { $tokenType = 'id_token' }
    if ($tokenType -notin @('id_token', 'access_token')) {
        throw "Invalid desktopSignIn.bearerTokenType '$tokenType'. Use id_token or access_token."
    }

    $clientId = [string]$raw.clientId
    if (-not (Test-ClaudeGuid $clientId)) {
        throw 'desktopSignIn.clientId must be the Desktop public-client application id.'
    }

    $issuer = [string]$raw.issuer
    if ($issuer -notmatch '^https://login\.microsoftonline\.com/[^/]+/v2\.0/?$') {
        throw 'desktopSignIn.issuer must be the tenant-pinned Entra v2 issuer, https://login.microsoftonline.com/<tenant-id>/v2.0.'
    }
    $issuer = $issuer.TrimEnd('/')

    $scopes = [string]$raw.scopes
    $audience = [string]$raw.audience
    if ($tokenType -eq 'access_token') {
        if ([string]::IsNullOrWhiteSpace($scopes)) {
            throw 'desktopSignIn.scopes is required for access_token mode.'
        }
        if ([string]::IsNullOrWhiteSpace($audience)) {
            throw 'desktopSignIn.audience is required for access_token mode so the gateway can validate aud.'
        }
    }

    [pscustomobject]@{
        kind = 'external-idp'
        flow = $flow
        bearerTokenType = $tokenType
        clientId = $clientId
        issuer = $issuer
        scopes = if ([string]::IsNullOrWhiteSpace($scopes)) { $null } else { $scopes }
        audience = if ([string]::IsNullOrWhiteSpace($audience)) { $clientId } else { $audience }
        resource = if ([string]::IsNullOrWhiteSpace([string]$raw.resource)) { $null } else { [string]$raw.resource }
    }
}

function Get-ClaudeDesktopGatewayAudience {
    param(
        [Parameter(Mandatory)]$DesktopSignIn
    )
    if ($DesktopSignIn.kind -ne 'external-idp') { return '' }
    if ($DesktopSignIn.bearerTokenType -eq 'access_token') { return [string]$DesktopSignIn.audience }
    return [string]$DesktopSignIn.clientId
}

function New-ClaudeDesktopSettings {
    param(
        [Parameter(Mandatory)][string]$GatewayUrl,
        [Parameter(Mandatory)][string[]]$Models,
        [string]$HelperPath,
        [Parameter(Mandatory)]$DesktopSignIn,
        [switch]$NoCowork
    )

    $settings = [ordered]@{
        inferenceProvider             = 'gateway'
        inferenceGatewayBaseUrl       = $GatewayUrl
        inferenceGatewayAuthScheme    = 'bearer'
        inferenceCredentialKind       = $DesktopSignIn.kind
        inferenceModels               = @($Models | ForEach-Object { [ordered]@{ name = $_ } })
        chatTabEnabled                = $true
        isClaudeCodeForDesktopEnabled = $true
        inferenceModelPricingEnabled  = $true
    }
    if (-not $NoCowork) { $settings['coworkTabEnabled'] = $true }

    if ($DesktopSignIn.kind -eq 'helper-script') {
        if ([string]::IsNullOrWhiteSpace($HelperPath)) {
            throw 'HelperPath is required when Desktop uses helper-script sign-in.'
        }
        $settings['inferenceCredentialHelper'] = $HelperPath
        $settings['inferenceCredentialHelperTimeoutSec'] = 60
        $settings['inferenceCredentialHelperTtlSec'] = 1800
        $settings['inferenceCredentialHelperSilentRefreshEnabled'] = $true
        return $settings
    }

    $oidc = [ordered]@{
        issuer = $DesktopSignIn.issuer
        clientId = $DesktopSignIn.clientId
        bearerTokenType = $DesktopSignIn.bearerTokenType
    }
    if ($DesktopSignIn.scopes) { $oidc['scopes'] = $DesktopSignIn.scopes }
    if ($DesktopSignIn.resource) { $oidc['resource'] = $DesktopSignIn.resource }

    $settings['inferenceIdpAuthFlow'] = $DesktopSignIn.flow
    $settings['inferenceIdpOidc'] = $oidc
    return $settings
}

function ConvertTo-ClaudeDesktopRegistryString {
    param([Parameter(Mandatory)]$Value)
    if ($Value -is [bool]) { if ($Value) { return 'true' } else { return 'false' } }
    if ($Value -is [string]) { return $Value }
    if ($Value -is [int] -or $Value -is [long]) { return [string]$Value }
    return (ConvertTo-Json -InputObject $Value -Depth 8 -Compress)
}
