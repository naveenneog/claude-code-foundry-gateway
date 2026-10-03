param([ValidateSet('subscriptions','foundryAccounts','deployments')][string]$Kind = 'subscriptions', [string]$SubscriptionId, [string]$FoundryAccount, [string]$FoundryResourceGroup)
$ErrorActionPreference = 'Stop'
if ($env:P93_INSTALLER_UI_PREFILL_JSON) { $env:P93_INSTALLER_UI_PREFILL_JSON; exit 0 }
$result = [ordered]@{ schemaVersion = 1; subscriptions = @(); foundryAccounts = @(); deployments = @() }
try {
    if ($Kind -eq 'subscriptions') {
        $result.subscriptions = @(& az account list -o json | ConvertFrom-Json | ForEach-Object { [pscustomobject]@{ id = [string]$_.id; name = [string]$_.name; tenantId = [string]$_.tenantId } })
    }
    elseif ($Kind -eq 'foundryAccounts') {
        $args = @('cognitiveservices','account','list','-o','json')
        if ($SubscriptionId) { $args += @('--subscription', $SubscriptionId) }
        $result.foundryAccounts = @(& az @args | ConvertFrom-Json | ForEach-Object { [pscustomobject]@{ name = [string]$_.name; resourceGroup = [string]$_.resourceGroup; location = [string]$_.location } })
    }
    elseif ($Kind -eq 'deployments') {
        $args = @('cognitiveservices','account','deployment','list','-g',$FoundryResourceGroup,'-n',$FoundryAccount,'-o','json')
        if ($SubscriptionId) { $args += @('--subscription', $SubscriptionId) }
        $result.deployments = @(& az @args | ConvertFrom-Json | ForEach-Object { [pscustomobject]@{ name = [string]$_.name; model = [string]$_.properties.model.name; version = [string]$_.properties.model.version } })
    }
}
catch { $result.error = $_.Exception.Message }
$result | ConvertTo-Json -Compress -Depth 6
