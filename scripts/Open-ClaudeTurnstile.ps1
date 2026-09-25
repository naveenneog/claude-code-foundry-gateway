<#
.SYNOPSIS
    Opens Turnstile in your browser, signed in as you, through the Azure CLI.

.DESCRIPTION
    For a tenant where Turnstile's "Sign in with Microsoft" still needs an administrator's
    consent. The Azure CLI is pre-authorized on Turnstile's API, so it gets a token for
    Turnstile with no consent. Turnstile checks that token exactly as it checks a script's -
    its tenant, and a console role: Turnstile.Admin, Turnstile.Viewer or Turnstile.Manager -
    and exchanges it for a single-use code that lives a minute. The browser redeems the code
    once and is signed in. The token itself never reaches the browser, the screen or a file;
    only the one-minute code travels, in the link.

    Turnstile's address and API scope are read from the gateway's turnstile-integration named
    value when you can read it, as an administrator can. Anyone else passes them; they are not
    secrets, and an administrator can give them out.

.PARAMETER TurnstileUrl
    Turnstile's address, for example https://<api-app>.azurewebsites.net.

.PARAMETER Scope
    Turnstile's API scope: api://<Turnstile client id>/Turnstile.Manage.

.PARAMETER NoBrowser
    Return the link instead of opening it.

.EXAMPLE
    ./scripts/Open-ClaudeTurnstile.ps1

.EXAMPLE
    ./scripts/Open-ClaudeTurnstile.ps1 -TurnstileUrl https://api-turnstile.azurewebsites.net -Scope api://00000000-0000-0000-0000-000000000000/Turnstile.Manage
#>
[CmdletBinding()]
param(
    [string]$TurnstileUrl,
    [string]$Scope,
    [switch]$NoBrowser,
    [string]$ResourceGroup,
    [string]$ApimName
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ClaudeChoice.ps1')
. (Join-Path $PSScriptRoot 'ApimNamedValue.ps1')
. (Join-Path $PSScriptRoot 'ClaudeTurnstileGovernance.ps1')

if (-not $TurnstileUrl -or -not $Scope) {
    if (-not $ResourceGroup) { $ResourceGroup = & (Join-Path $PSScriptRoot 'Get-ClaudeGatewayTarget.ps1') ResourceGroup 3>$null }
    if (-not $ResourceGroup) { $ResourceGroup = Select-ClaudeResourceGroup }
    if (-not $ApimName) { $ApimName = Select-ClaudeGateway -ResourceGroup $ResourceGroup }
    $integration = $null
    if ($ResourceGroup -and $ApimName) {
        $integration = ConvertFrom-ClaudeTurnstileIntegrationValue (Get-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id $script:TurnstileIntegrationNamedValue)
    }
    if (-not $integration) {
        throw ("Pass -TurnstileUrl and -Scope. The gateway's Turnstile connection could not be read; an administrator can give you both values. " +
            "Where to find it: az apim nv show -g $ResourceGroup --service-name $ApimName --named-value-id turnstile-integration --query value -o tsv; " +
            'Azure portal: API Management > Named values > turnstile-integration > url and scope.')
    }
    if (-not $TurnstileUrl) { $TurnstileUrl = [string]$integration['url'] }
    if (-not $Scope) { $Scope = [string]$integration['scope'] }
}
$url = $TurnstileUrl.TrimEnd('/')

$token = az account get-access-token --scope $Scope --query accessToken -o tsv 2>$null
if (-not $token) {
    throw ("No token for $Scope. Sign in with az login as yourself, in the tenant Turnstile trusts. " +
        'If Entra answers AADSTS50105, your account holds no Turnstile role: ask an administrator to assign one.')
}
try {
    $grant = Invoke-RestMethod -Method Post -Uri "$url/api/v1/auth/cli" -Headers @{ Authorization = "Bearer $($token.Trim())" } -TimeoutSec 60
}
catch {
    $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
    # A missing route answers 405, not 404: Turnstile's page fallback owns the path.
    if ($status -in 404, 405) { throw 'This Turnstile has no sign-in through the Azure CLI. Deploy the fork''s claude-gateway branch.' }
    if ($status -eq 403) { throw 'Turnstile refused the sign-in: your account holds none of its roles, or it is a workload identity.' }
    throw
}
$link = "$url/?login_code=$([uri]::EscapeDataString($grant.code))"
if ($NoBrowser) { return $link }
Start-Process $link
Write-Host "Opened Turnstile. The link works once, until $(([datetime]$grant.expires_at).ToLocalTime().ToString('T'))."
