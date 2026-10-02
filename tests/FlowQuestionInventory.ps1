# Run in a child PowerShell by tests/Test-InstallerAnswersDrift.ps1: calls every guided-flow module's
# Get-ClaudeFlowStepQuestions over record sets that cover every When branch, with Azure CLI and the
# Retail Prices API replaced by stubs, and writes the question keys each record set shows as JSON.
param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$OutPath)
$ErrorActionPreference = 'Stop'
$env:CLAUDE_FLOW_SKIP_AZ_DISCOVERY = '1'
$sub = '00000000-0000-4000-8000-0000000000a1'
$endpoint = 'https://ai-p92.services.ai.azure.com/'
function global:az {
    $joined = (@($args) | ForEach-Object { [string]$_ }) -join ' '
    $global:LASTEXITCODE = 0
    switch -Wildcard ($joined) {
        'account show*' { return (@{ id = $sub; tenantId = '00000000-0000-4000-8000-0000000000f1'; name = 'p92' } | ConvertTo-Json -Compress) }
        'apim show*' { return (@{ id = "/subscriptions/$sub/resourceGroups/rg-p92/providers/Microsoft.ApiManagement/service/apim-p92"; gatewayUrl = 'https://apim-p92.azure-api.net'; location = 'eastus2'; sku = @{ name = 'BasicV2'; capacity = 1 } } | ConvertTo-Json -Compress -Depth 4) }
        'cognitiveservices account show*' { return (@{ properties = @{ endpoints = @{ 'AI Foundry API' = $endpoint } } } | ConvertTo-Json -Compress -Depth 5) }
        'apim api show*' { return (@{ serviceUrl = $endpoint + 'anthropic' } | ConvertTo-Json -Compress) }
        'cognitiveservices account deployment list*' {
            return (ConvertTo-Json -Compress -Depth 8 -InputObject @(foreach ($n in 'claude-opus-5', 'claude-sonnet-5') {
                        @{ name = $n; sku = @{ name = 'GlobalStandard'; capacity = 10 }; properties = @{ provisioningState = 'Succeeded'; model = @{ format = 'Anthropic'; name = $n; version = '2' } } } }))
        }
        'apim nv list*' { return (ConvertTo-Json -Compress -InputObject @(@{ name = 'models-standard'; value = ',,' }, @{ name = 'models-premium'; value = ',,' }, @{ name = 'entitlement-source'; value = 'named-value' })) }
        default { $global:LASTEXITCODE = 2; Write-Error "flow inventory stub: unexpected az $joined" -ErrorAction Continue; return }
    }
}
function global:Invoke-RestMethod { param($Uri, $Method, $Headers, $Body, $ContentType, $TimeoutSec, $ErrorAction, [switch]$UseBasicParsing) return [pscustomobject]@{ Items = @(); NextPageLink = $null } }
function global:Invoke-WebRequest { param($Uri, $Method, $TimeoutSec, $ErrorAction, [switch]$UseBasicParsing) throw 'flow inventory stub: no network' }

$target = [ordered]@{ schemaVersion = 2; mode = 'gateway'; subscriptionId = $sub; tenantId = '00000000-0000-4000-8000-0000000000f1'; resourceGroup = 'rg-p92'; apimName = 'apim-p92'
    foundryAccount = 'ai-p92'; foundryResourceGroup = 'rg-ai-p92'; location = 'eastus2'; sku = 'BasicV2'; gatewayUrl = 'https://apim-p92.azure-api.net/claude' }
$sets = [ordered]@{
    'no-decisions' = @{}
    'keyvault-azuredns' = @{ address = @{ certificateSource = 'KeyVault'; dnsMode = 'AzureDns' } }
    'pfx-external' = @{ address = @{ certificateSource = 'Pfx'; dnsMode = 'External' } }
}
. (Join-Path $Root 'scripts\flow\FlowContract.ps1')
. (Join-Path $Root 'scripts\ClaudeChoice.ps1')
$results = [System.Collections.Generic.List[object]]::new()
$modules = @(Get-ChildItem -LiteralPath (Join-Path $Root 'scripts\flow') -Filter '*.ps1' -File | Where-Object { $_.Name -notin 'FlowContract.ps1', 'Discovery.ps1' } | Sort-Object Name)
foreach ($file in $modules) {
    foreach ($name in 'Get-ClaudeFlowStepInfo', 'Get-ClaudeFlowStepQuestions', 'Get-ClaudeFlowStepPlan') { Remove-Item "function:\$name" -Force -ErrorAction SilentlyContinue }
    $entry = & {
        . $file.FullName
        foreach ($set in $sets.GetEnumerator()) {
            $record = ([pscustomobject]$target | ConvertTo-Json -Depth 8) | ConvertFrom-Json
            $record | Add-Member -NotePropertyName decisions -NotePropertyValue (($set.Value | ConvertTo-Json -Depth 8) | ConvertFrom-Json) -Force
            $discovery = [pscustomobject]@{ subscriptionId = $sub; resourceGroup = 'rg-p92'; apimName = 'apim-p92'; location = 'eastus2'; sku = 'BasicV2'; Region = 'eastus2'
                namedValues = @{ 'entitlement-source' = 'named-value' }; AumPrices = @{}; TurnstilePrices = @{} }
            $error.Clear()
            $questions = @(Get-ClaudeFlowStepQuestions -Record $record -Discovery $discovery)
            [pscustomobject]@{
                module = $file.BaseName; record = $set.Key; decisions = $set.Value
                keys = @($questions | Where-Object { $_ -and $_.Key } | ForEach-Object {
                        $visible = -not ($_.PSObject.Properties.Name -contains 'When') -or [bool](& $_.When $record)
                        [pscustomobject]@{ key = [string]$_.Key; hasWhen = [bool]($_.PSObject.Properties.Name -contains 'When'); visible = $visible } })
            }
        }
    }
    foreach ($e in @($entry)) { $results.Add($e) }
}
. (Join-Path $Root 'scripts\flow\Foundation.ps1')
$map = [ordered]@{}
foreach ($p in (Get-ClaudeFlowFoundationInstallerMap).GetEnumerator()) { $map[[string]$p.Key] = [string]$p.Value }
[IO.File]::WriteAllText($OutPath, ([pscustomobject]@{ modules = @($results); foundationMap = $map } | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
