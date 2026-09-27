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
        [switch]$NoCowork,
        # The Desktop release that will read the profile. Empty means unknown.
        [string]$DesktopVersion,
        # auto: the current spelling for a release that reads it (2.7032.0 or later), otherwise the
        # original spelling that every release since 1.25927.0 reads. original or current force one.
        [ValidateSet('auto', 'original', 'current')][string]$KeySpelling = 'auto'
    )

    $settings = [ordered]@{
        inferenceProvider             = 'gateway'
        inferenceGatewayBaseUrl       = $GatewayUrl
        inferenceGatewayAuthScheme    = 'bearer'
        inferenceCredentialKind       = 'helper-script'
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

    # ADR-0031. The configuration reference adds external-idp, inferenceIdpOidc and
    # inferenceIdpAuthFlow in Desktop 2.7032.0 and reads the original spelling - interactive with
    # inferenceGatewayOidc and inferenceGatewayOidcAuthFlow - as external-idp, with no end date.
    # A release before 2.7032.0 reads only the original spelling. Browser is the default flow.
    $useCurrent = switch ($KeySpelling) {
        'current' { $true }
        'original' { $false }
        default {
            $m = [regex]::Match([string]$DesktopVersion, '\d+\.\d+\.\d+')
            $m.Success -and ([version]$m.Value -ge [version]'2.7032.0')
        }
    }
    if ($useCurrent) {
        $settings['inferenceCredentialKind'] = 'external-idp'
        $settings['inferenceIdpOidc'] = $oidc
        if ($DesktopSignIn.flow -eq 'broker') { $settings['inferenceIdpAuthFlow'] = 'broker' }
    }
    else {
        $settings['inferenceCredentialKind'] = 'interactive'
        $settings['inferenceGatewayOidc'] = $oidc
        if ($DesktopSignIn.flow -eq 'broker') { $settings['inferenceGatewayOidcAuthFlow'] = 'broker' }
    }
    return $settings
}

# The Claude Desktop release that added each sign-in key and credential kind, from the
# configuration reference (https://claude.com/docs/third-party/claude-desktop/configuration,
# retrieved 2026-09-27). external-idp arrived with inferenceIdpOidc; Desktop 2.2553.1.0 lacks it.
$script:ClaudeDesktopKeyAddedIn = @{
    inferenceProvider                             = '1.2581.0'
    inferenceGatewayBaseUrl                       = '1.2581.0'
    inferenceGatewayAuthScheme                    = '1.3036.0'
    inferenceCredentialHelper                     = '1.2581.0'
    inferenceCredentialHelperTimeoutSec           = '1.8089.0'
    inferenceCredentialHelperTtlSec               = '1.2581.0'
    inferenceCredentialHelperSilentRefreshEnabled = '1.10628.0'
    inferenceCredentialHelperWindows              = '2.2553.0'
    inferenceCredentialKind                       = '1.8555.0'
    inferenceGatewayOidc                          = '1.6889.0'
    inferenceGatewayOidcAuthFlow                  = '1.25927.0'
    inferenceIdpOidc                              = '2.7032.0'
    inferenceIdpAuthFlow                          = '2.7032.0'
}
$script:ClaudeDesktopKindAddedIn = @{
    'static'         = '1.8555.0'
    'helper-script'  = '1.8555.0'
    'interactive'    = '1.8555.0'
    'vendor-profile' = '1.8555.0'
    'workforce'      = '1.15200.0'
    'external-idp'   = '2.7032.0'
}

function Get-ClaudeDesktopRequiredVersion {
    <#
    .SYNOPSIS
        The oldest Claude Desktop release that reads every sign-in key in a rendered profile.
    #>
    param([Parameter(Mandatory)]$Settings)
    $keys = if ($Settings -is [System.Collections.IDictionary]) { @($Settings.Keys) } else { @($Settings.PSObject.Properties.Name) }
    $needed = [version]'0.0.0'
    foreach ($key in $keys) {
        if ($script:ClaudeDesktopKeyAddedIn.ContainsKey([string]$key)) {
            $v = [version]$script:ClaudeDesktopKeyAddedIn[[string]$key]
            if ($v -gt $needed) { $needed = $v }
        }
    }
    $kind = if ($Settings -is [System.Collections.IDictionary]) { $Settings['inferenceCredentialKind'] } else { $Settings.inferenceCredentialKind }
    if ($kind -and $script:ClaudeDesktopKindAddedIn.ContainsKey([string]$kind)) {
        $v = [version]$script:ClaudeDesktopKindAddedIn[[string]$kind]
        if ($v -gt $needed) { $needed = $v }
    }
    if ($needed -eq [version]'0.0.0') { return $null }
    return $needed.ToString()
}

function Test-ClaudeDesktopCredentialKindSupported {
    <#
    .SYNOPSIS
        Whether a Desktop release reads a credential kind: $true, $false, or $null when either
        the kind or the version is unknown.
    #>
    param([string]$Kind, [string]$Version)
    if (-not $Kind -or -not $script:ClaudeDesktopKindAddedIn.ContainsKey($Kind)) { return $null }
    $m = [regex]::Match([string]$Version, '\d+\.\d+\.\d+')
    if (-not $m.Success) { return $null }
    return ([version]$m.Value -ge [version]$script:ClaudeDesktopKindAddedIn[$Kind])
}

function ConvertTo-ClaudeDesktopRegistryString {
    param([Parameter(Mandatory)]$Value)
    if ($Value -is [bool]) { if ($Value) { return 'true' } else { return 'false' } }
    if ($Value -is [string]) { return $Value }
    if ($Value -is [int] -or $Value -is [long]) { return [string]$Value }
    return (ConvertTo-Json -InputObject $Value -Depth 8 -Compress)
}
