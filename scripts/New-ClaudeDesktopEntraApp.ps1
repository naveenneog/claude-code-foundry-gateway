<#
.SYNOPSIS
    Creates or discovers the public-client Entra app for Claude Desktop gateway sign-in.

.DESCRIPTION
    Claude Desktop external-idp sign-in needs a public-client app registration.
    This script is idempotent: it first discovers an existing registration by
    display name, then adds the required mobile/desktop redirect URIs if they
    are missing. It never grants tenant-wide admin consent.

.EXAMPLE
    ./New-ClaudeDesktopEntraApp.ps1 -DisplayName 'Claude Desktop gateway'

.EXAMPLE
    ./New-ClaudeDesktopEntraApp.ps1 -DisplayName 'Claude Desktop gateway' -Broker -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$DisplayName = 'Claude Desktop gateway',
    [switch]$Broker
)

$ErrorActionPreference = 'Stop'

function Write-Ok($t) { Write-Host "  [OK]   $t" -ForegroundColor Green }
function Write-Note($t) { Write-Host "  $t" -ForegroundColor DarkGray }

$acct = az account show -o json 2>$null | ConvertFrom-Json
if (-not $acct) { throw 'Run az login first.' }

$apps = @(az ad app list --display-name $DisplayName -o json 2>$null | ConvertFrom-Json)
$app = $apps | Where-Object { $_.displayName -eq $DisplayName } | Select-Object -First 1

if (-not $app) {
    if ($PSCmdlet.ShouldProcess($DisplayName, 'create Desktop public-client app registration')) {
        $app = az ad app create --display-name $DisplayName --sign-in-audience AzureADMyOrg -o json | ConvertFrom-Json
        Write-Ok "created $DisplayName"
    }
    else {
        Write-Note "would create $DisplayName"
        return
    }
}
else { Write-Ok "found $DisplayName" }

$clientId = [string]$app.appId
$redirects = @('http://127.0.0.1/callback')
if ($Broker) {
    $redirects += "ms-appx-web://Microsoft.AAD.BrokerPlugin/$clientId"
    $redirects += 'msauth.com.anthropic.claudefordesktop://auth'
}
$redirects = @($redirects | Select-Object -Unique)

$existing = @($app.publicClient.redirectUris)
$missing = @($redirects | Where-Object { $existing -notcontains $_ })
if ($missing.Count) {
    $all = @($existing + $missing | Where-Object { $_ } | Select-Object -Unique)
    if ($PSCmdlet.ShouldProcess($DisplayName, "add redirect URI(s): $($missing -join ', ')")) {
        az ad app update --id $clientId --is-fallback-public-client true --public-client-redirect-uris @all -o none
        Write-Ok "redirect URIs: $($all -join ', ')"
    }
    else { Write-Note "would add redirect URI(s): $($missing -join ', ')" }
}
else { Write-Ok 'redirect URIs already present' }

[pscustomobject]@{
    displayName = $DisplayName
    clientId = $clientId
    tenantId = $acct.tenantId
    issuer = "https://login.microsoftonline.com/$($acct.tenantId)/v2.0"
    redirectUris = $redirects
    consent = 'Browser id_token mode uses the public client with openid/profile/email/offline_access. access_token mode also needs the gateway API delegated scope and may fail with AADSTS65001 until an admin grants consent.'
}
