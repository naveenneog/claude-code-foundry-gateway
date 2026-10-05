<#
.SYNOPSIS
    Runs a disposable live projection install and one request through the gateway.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$Location,
    [Parameter(Mandatory)][string]$FoundryAccount,
    [Parameter(Mandatory)][string]$FoundryResourceGroup,
    [string]$ResourceGroup,
    [string]$NamePrefix,
    [string]$StandardGroup = 'claude-live-projection-standard',
    [string]$PremiumGroup = 'claude-live-projection-premium',
    [switch]$UseCurrentAzLogin,
    [switch]$Teardown
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$results = [System.Collections.Generic.List[object]]::new()
function Add-Result([string]$Step, [bool]$Ok, [string]$Detail = '') {
    $results.Add([pscustomobject]@{ step = $Step; ok = $Ok; detail = $Detail })
}
function Assert-Form([string]$Name, [string]$Value, [string]$Pattern) {
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -notmatch $Pattern) { throw "$Name is not in the accepted form." }
}

try {
    $guid = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    Assert-Form SubscriptionId $SubscriptionId $guid
    Assert-Form Location $Location '^[A-Za-z0-9 -]{2,40}$'
    Assert-Form FoundryAccount $FoundryAccount '^[A-Za-z0-9][A-Za-z0-9-]{1,62}$'
    Assert-Form FoundryResourceGroup $FoundryResourceGroup '^[A-Za-z0-9._-]{1,90}$'
    Assert-Form StandardGroup $StandardGroup '^[A-Za-z0-9._-]{1,120}$'
    Assert-Form PremiumGroup $PremiumGroup '^[A-Za-z0-9._-]{1,120}$'
    if (-not $UseCurrentAzLogin -and [string]::IsNullOrWhiteSpace($env:AZURE_CONFIG_DIR)) {
        throw 'Set an isolated AZURE_CONFIG_DIR or pass -UseCurrentAzLogin to use the current Azure CLI profile.'
    }
    if (-not $ResourceGroup) { $ResourceGroup = 'rg-claude-live-' + [guid]::NewGuid().ToString('N').Substring(0, 10) }
    if (-not $NamePrefix) { $NamePrefix = 'clive' + [guid]::NewGuid().ToString('N').Substring(0, 10) }
    Assert-Form ResourceGroup $ResourceGroup '^[A-Za-z0-9._-]{1,90}$'
    Assert-Form NamePrefix $NamePrefix '^(?=.{1,37}$)[a-z0-9]+(?:-[a-z0-9]+)*$'
    $apimName = "apim-$NamePrefix"

    az account set --subscription $SubscriptionId
    if ($LASTEXITCODE -ne 0) { throw 'az account set failed.' }
    $account = az account show -o json | ConvertFrom-Json
    Add-Result account $true $account.user.name

    $exists = [string](az group exists --name $ResourceGroup -o tsv)
    if ($exists.Trim().ToLowerInvariant() -eq 'true') { throw "Resource group $ResourceGroup already exists; pass a new name." }
    az group create --name $ResourceGroup --location $Location -o none
    if ($LASTEXITCODE -ne 0) { throw 'resource group create failed.' }
    Add-Result resourceGroup $true $ResourceGroup

    & (Join-Path $root 'Install-ClaudeGateway.ps1') -SubscriptionId $SubscriptionId -FoundryAccount $FoundryAccount `
        -FoundryResourceGroup $FoundryResourceGroup -ResourceGroup $ResourceGroup -Location $Location -NamePrefix $NamePrefix `
        -Sku BasicV2 -EntitlementStore projection -DeployProjection -Yes -StandardGroup $StandardGroup -PremiumGroup $PremiumGroup
    Add-Result installer $true $apimName

    $signedInUser = [string](az ad signed-in-user show --query id -o tsv)
    Assert-Form SignedInUser $signedInUser $guid
    az ad group member add --group $StandardGroup --member-id $signedInUser -o none
    if ($LASTEXITCODE -ne 0) { throw 'adding the signed-in user to the standard group failed.' }
    Add-Result addUser $true $signedInUser

    & (Join-Path $root 'scripts\Sync-ClaudeAccess.ps1') -ResourceGroup $ResourceGroup -ApimName $apimName -User $signedInUser
    Add-Result targetedSync $true $signedInUser

    $token = [string](az account get-access-token --resource https://cognitiveservices.azure.com --query accessToken -o tsv)
    if ([string]::IsNullOrWhiteSpace($token)) { $token = 'stub-token' }
    $body = @{ model = 'claude-sonnet-5'; max_tokens = 8; messages = @(@{ role = 'user'; content = 'Return ok.' }) } | ConvertTo-Json -Depth 8
    $gatewayUrl = "https://$apimName.azure-api.net/claude"
    $reply = Invoke-RestMethod -Uri "$gatewayUrl/v1/messages" -Method Post -Headers @{ Authorization = "Bearer $token"; 'anthropic-version' = '2023-06-01' } -ContentType 'application/json' -Body $body -TimeoutSec 60
    Add-Result gatewayRequest $true ([string]$reply.id)

    if ($Teardown) {
        az group delete --name $ResourceGroup --yes --no-wait -o none
        az ad group delete --group $StandardGroup -o none 2>$null
        az ad group delete --group $PremiumGroup -o none 2>$null
        $apps = az ad app list --display-name "claude-projection-resolver-$NamePrefix" -o json | ConvertFrom-Json
        foreach ($app in @($apps)) { if ($app.appId -match $guid) { az ad app delete --id $app.appId -o none 2>$null } }
        az role assignment delete --assignee $apimName --scope "/subscriptions/$SubscriptionId/resourceGroups/$FoundryResourceGroup/providers/Microsoft.CognitiveServices/accounts/$FoundryAccount" -o none 2>$null
        Add-Result teardown $true $ResourceGroup
    }
}
catch {
    Add-Result failed $false $_.Exception.Message
    $results | ConvertTo-Json -Depth 5
    throw
}

$results | ConvertTo-Json -Depth 5
