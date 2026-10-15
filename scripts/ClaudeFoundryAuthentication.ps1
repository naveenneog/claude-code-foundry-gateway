# Cross-tenant Foundry authentication metadata. This file never calls the APIM
# named-value listValue operation and never returns a named value's value.

function Get-ClaudeApimNamedValueMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$ApimName,
        [Parameter(Mandatory)][string]$Id,
        [string]$SubscriptionId,
        [scriptblock]$InvokeRead
    )
    $arguments = @('apim','nv','show','-g',$ResourceGroup,'--service-name',$ApimName,'--named-value-id',$Id,'-o','json')
    if ($SubscriptionId) { $arguments += @('--subscription',$SubscriptionId) }
    try {
        $raw = if ($InvokeRead) { & $InvokeRead $arguments } else {
            $output = & az @arguments --only-show-errors 2>&1
            if ($LASTEXITCODE -ne 0) { return $null }
            $output -join "`n"
        }
        if (-not $raw) { return $null }
        $record = $raw | ConvertFrom-Json -ErrorAction Stop
        $name = if ($record.name) { [string]$record.name } elseif ($record.displayName) { [string]$record.displayName } else { $Id }
        [pscustomobject]@{
            Id = $name
            Secret = [bool]$record.secret
        }
    }
    catch { return $null }
}

function Assert-ClaudeFoundryAuthenticationConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('managed-identity','client-credentials')][string]$Mode,
        [string]$Endpoint,
        [string]$TenantId,
        [string]$ClientId,
        [string]$ClientSecretNamedValue,
        [string]$ExistingApimName,
        [object]$ClientSecretMetadata
    )
    if ($Mode -eq 'managed-identity') { return }
    $missing = @(
        [pscustomobject]@{ Name='FoundryEndpoint'; Value=$Endpoint },
        [pscustomobject]@{ Name='FoundryTenantId'; Value=$TenantId },
        [pscustomobject]@{ Name='FoundryClientId'; Value=$ClientId },
        [pscustomobject]@{ Name='FoundryCredentialNamedValue'; Value=$ClientSecretNamedValue },
        [pscustomobject]@{ Name='ExistingApimName'; Value=$ExistingApimName }
    ) | Where-Object { -not $_.Value }
    if ($missing.Count) { throw "Client-credentials Foundry authentication requires: $($missing.Name -join ', '). Nothing was changed." }
    $uri = $null
    if (-not [uri]::TryCreate($Endpoint, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https' -or $uri.Query -or $uri.Fragment) {
        throw 'FoundryEndpoint must be an HTTPS origin or path without a query or fragment. Nothing was changed.'
    }
    foreach ($entry in @{ FoundryTenantId=$TenantId; FoundryClientId=$ClientId }.GetEnumerator()) {
        $parsed = [guid]::Empty
        if (-not [guid]::TryParse([string]$entry.Value, [ref]$parsed) -or $parsed -eq [guid]::Empty) {
            throw "$($entry.Key) must be a non-empty GUID. Nothing was changed."
        }
    }
    if ($ClientSecretNamedValue -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$') {
        throw 'FoundryCredentialNamedValue is not a valid APIM named-value identifier. Nothing was changed.'
    }
    if (-not $ClientSecretMetadata) {
        throw "APIM named value '$ClientSecretNamedValue' was not found. Create it as a secret named value before this run. Nothing was changed."
    }
    if (-not $ClientSecretMetadata.Secret) {
        throw "APIM named value '$ClientSecretNamedValue' exists but is not marked secret. Mark it secret before this run. Nothing was changed."
    }
}
