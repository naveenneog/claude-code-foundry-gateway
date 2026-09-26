<#
.SYNOPSIS
    Read-only discovery for the guided flow.
#>

function Invoke-ClaudeFlowAzJson {
    param([string[]]$Arguments)
    try {
        $out = & az @Arguments -o json 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $out) { return $null }
        return ($out | Out-String | ConvertFrom-Json)
    } catch { return $null }
}

function Get-ClaudeFlowDiscovery {
    param(
        [string]$RecordPath = 'onboarding/claude-gateway.json',
        $Record = $null
    )
    if ($env:CLAUDE_FLOW_SKIP_AZ_DISCOVERY -eq '1') {
        return [pscustomobject][ordered]@{
            signedIn = $null
            subscriptions = @()
            apiManagement = @()
            foundryAccounts = @()
            claudeDeployments = @()
            logAnalyticsWorkspaces = @()
            record = $Record
            comparison = [pscustomobject]@{ status = 'skipped'; differences = @() }
        }
    }
    $account = Invoke-ClaudeFlowAzJson @('account', 'show')
    $subscriptions = @(Invoke-ClaudeFlowAzJson @('account', 'list'))
    $apim = @(Invoke-ClaudeFlowAzJson @('apim', 'list'))
    $foundry = @(Invoke-ClaudeFlowAzJson @('cognitiveservices', 'account', 'list') | Where-Object { $_.kind -in @('AIServices', 'OpenAI') })
    $workspaces = @(Invoke-ClaudeFlowAzJson @('monitor', 'log-analytics', 'workspace', 'list'))

    $deployments = @()
    foreach ($acct in $foundry) {
        if (-not $acct.name -or -not $acct.resourceGroup) { continue }
        $items = @(Invoke-ClaudeFlowAzJson @('cognitiveservices', 'account', 'deployment', 'list', '-g', $acct.resourceGroup, '-n', $acct.name))
        foreach ($deployment in $items) {
            $deployments += [pscustomobject]@{
                account = $acct.name
                resourceGroup = $acct.resourceGroup
                name = $deployment.name
                model = $deployment.properties.model.name
                version = $deployment.properties.model.version
            }
        }
    }

    if (-not $Record -and (Test-Path -LiteralPath $RecordPath)) {
        try { $Record = Get-Content -LiteralPath $RecordPath -Raw | ConvertFrom-Json }
        catch { $Record = $null }
    }

    $differences = [System.Collections.Generic.List[string]]::new()
    if ($Record) {
        $recordApim = if ($Record.apimName) { [string]$Record.apimName } else { '' }
        $recordGroup = if ($Record.resourceGroup) { [string]$Record.resourceGroup } else { '' }
        $recordUrl = if ($Record.gatewayUrl) { [string]$Record.gatewayUrl } else { '' }
        if ($recordApim -and $recordGroup) {
            $live = @($apim | Where-Object { $_.name -eq $recordApim -and $_.resourceGroup -eq $recordGroup })
            if ($apim.Count -and -not $live.Count) {
                $differences.Add("record names API Management '$recordApim' in '$recordGroup', but discovery did not find it")
            }
            elseif ($live.Count -eq 1 -and $recordUrl) {
                $urls = @($live[0].gatewayUrl, $live[0].properties.gatewayUrl) | Where-Object { $_ }
                if ($urls.Count -and $recordUrl -notin $urls -and $recordUrl.TrimEnd('/') -notin @($urls | ForEach-Object { ([string]$_).TrimEnd('/') })) {
                    $differences.Add("record gatewayUrl '$recordUrl' differs from live '$($urls[0])'")
                }
            }
        }
    }

    [pscustomobject][ordered]@{
        signedIn = if ($account) { [pscustomobject]@{ user = $account.user.name; tenantId = $account.tenantId; subscriptionId = $account.id; subscriptionName = $account.name } } else { $null }
        subscriptions = @($subscriptions | ForEach-Object { [pscustomobject]@{ name = $_.name; id = $_.id; tenantId = $_.tenantId; isDefault = $_.isDefault; state = $_.state } })
        apiManagement = @($apim | ForEach-Object { [pscustomobject]@{ name = $_.name; resourceGroup = $_.resourceGroup; location = $_.location; sku = $_.sku.name; gatewayUrl = $_.gatewayUrl } })
        foundryAccounts = @($foundry | ForEach-Object { [pscustomobject]@{ name = $_.name; resourceGroup = $_.resourceGroup; location = $_.location; kind = $_.kind; endpoint = $_.properties.endpoint } })
        claudeDeployments = @($deployments)
        logAnalyticsWorkspaces = @($workspaces | ForEach-Object { [pscustomobject]@{ name = $_.name; resourceGroup = $_.resourceGroup; location = $_.location; id = $_.id } })
        record = $Record
        comparison = [pscustomobject]@{
            status = if ($differences.Count) { 'drift' } else { 'match-or-unknown' }
            differences = @($differences)
        }
    }
}
