param([ValidateSet('subscriptions','foundryAccounts','deployments')][string]$Kind = 'subscriptions', [string]$SubscriptionId, [string]$FoundryAccount, [string]$FoundryResourceGroup)
$ErrorActionPreference = 'Stop'
$result = [ordered]@{ schemaVersion = 1; subscriptions = @(); foundryAccounts = @(); deployments = @() }
try {
    if ($Kind -eq 'subscriptions') {
        $azOutput = & az account list -o json 2>&1
        if ($LASTEXITCODE -ne 0) { throw (($azOutput | ForEach-Object { [string]$_ }) -join "`n") }
        $result.subscriptions = @($azOutput | ConvertFrom-Json | ForEach-Object { [pscustomobject]@{ id = [string]$_.id; name = [string]$_.name; tenantId = [string]$_.tenantId } })
    }
    elseif ($Kind -eq 'foundryAccounts') {
        $azArgs = @('cognitiveservices','account','list','-o','json')
        if ($SubscriptionId) { $azArgs += @('--subscription', $SubscriptionId) }
        $azOutput = & az @azArgs 2>&1
        if ($LASTEXITCODE -ne 0) { throw (($azOutput | ForEach-Object { [string]$_ }) -join "`n") }
        $result.foundryAccounts = @($azOutput | ConvertFrom-Json | ForEach-Object { [pscustomobject]@{ name = [string]$_.name; resourceGroup = [string]$_.resourceGroup; location = [string]$_.location } })
    }
    elseif ($Kind -eq 'deployments') {
        $azArgs = @('cognitiveservices','account','deployment','list','-g',$FoundryResourceGroup,'-n',$FoundryAccount,'-o','json')
        if ($SubscriptionId) { $azArgs += @('--subscription', $SubscriptionId) }
        $azOutput = & az @azArgs 2>&1
        if ($LASTEXITCODE -ne 0) { throw (($azOutput | ForEach-Object { [string]$_ }) -join "`n") }
        $result.deployments = @($azOutput | ConvertFrom-Json | ForEach-Object { [pscustomobject]@{ name = [string]$_.name; model = [string]$_.properties.model.name; version = [string]$_.properties.model.version } })
    }
}
catch { $result.error = $_.Exception.Message }
$result | ConvertTo-Json -Compress -Depth 6
