param([switch]$StartSignIn)
$ErrorActionPreference = 'Stop'
if ($env:P93_INSTALLER_UI_IDENTITY_JSON) { $env:P93_INSTALLER_UI_IDENTITY_JSON; exit 0 }
if ($StartSignIn) {
    [pscustomobject]@{ schemaVersion = 1; signInCommand = 'az login --use-device-code' } | ConvertTo-Json -Compress
    exit 0
}
$signInCommand = 'az login --use-device-code'
try {
    $raw = & az account show -o json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $raw) { throw 'not signed in' }
    $account = $raw | ConvertFrom-Json -ErrorAction Stop
    [pscustomobject]@{
        schemaVersion = 1
        signedIn = $true
        user = [string]$account.user.name
        tenantId = [string]$account.tenantId
        subscriptionName = [string]$account.name
        subscriptionId = [string]$account.id
        signInCommand = $signInCommand
    } | ConvertTo-Json -Compress
}
catch {
    [pscustomobject]@{
        schemaVersion = 1
        signedIn = $false
        message = 'Azure CLI is not signed in'
        signInCommand = $signInCommand
    } | ConvertTo-Json -Compress
}
