<#
.SYNOPSIS
    One-command deployment of the governed Claude Code gateway.

.DESCRIPTION
    Deploys and wires everything needed to hand Claude Code to a team without
    giving anyone a model credential:

      * API Management (v2 tier) with a system-assigned managed identity
      * Application Insights + Log Analytics, with custom metric dimensions on
      * the Claude API, its operations, and the governance policy
      * Cognitive Services User for the gateway identity on your Foundry account
      * Entra ID groups for the standard and premium tiers
      * an initial membership sync

    Re-running is safe: the deployment is idempotent and will update in place.

.PARAMETER FoundryAccount
    Name of the existing Foundry (AIServices) account hosting your Claude
    deployments. Omit to auto-discover one that has Anthropic deployments.

.PARAMETER ResourceGroup
    Resource group to deploy the gateway into. Created if missing.

.PARAMETER Location
    Azure region. Defaults to the Foundry account's region.

.PARAMETER Sku
    API Management SKU. Must be a v2 tier: only v2 parses Anthropic token usage,
    so on classic tiers every budget silently counts zero.

.PARAMETER SkipGroups
    Do not create or sync the Entra ID tier groups.

.EXAMPLE
    ./deploy.ps1 -FoundryAccount ai-contoso-foundry -ResourceGroup rg-claude-gateway

.EXAMPLE
    ./deploy.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$FoundryAccount,
    [string]$FoundryResourceGroup,
    [string]$ResourceGroup = 'rg-claude-gateway',
    [string]$Location,
    [ValidateSet('BasicV2', 'StandardV2', 'PremiumV2')]
    [string]$Sku = 'BasicV2',
    [string]$NamePrefix,
    [string]$PublisherEmail,
    [string]$PublisherName = 'AI Platform Team',
    [string]$StandardGroup = 'claude-code-standard',
    [string]$PremiumGroup = 'claude-code-premium',
    [switch]$SkipGroups
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path

function Write-Step { param([string]$Text) Write-Host "`n==> $Text" -ForegroundColor Cyan }
function Write-Detail { param([string]$Text) Write-Host "    $Text" -ForegroundColor DarkGray }
function Write-Ok { param([string]$Text) Write-Host "    $Text" -ForegroundColor Green }

# ---------------------------------------------------------------------------
Write-Step 'Checking prerequisites'

$account = az account show -o json 2>$null | ConvertFrom-Json
if (-not $account) { throw "Not signed in. Run 'az login' first." }
Write-Detail "subscription : $($account.name)"
Write-Detail "tenant       : $($account.tenantId)"

if (-not $PublisherEmail) { $PublisherEmail = $account.user.name }
if ($PublisherEmail -notmatch '@') { throw "Could not infer a publisher email. Pass -PublisherEmail." }

# ---------------------------------------------------------------------------
Write-Step 'Locating the Foundry account'

if (-not $FoundryAccount) {
    Write-Detail 'scanning for AIServices accounts with Anthropic deployments...'
    $candidates = az cognitiveservices account list -o json | ConvertFrom-Json |
        Where-Object { $_.kind -eq 'AIServices' }

    foreach ($c in $candidates) {
        $deps = az cognitiveservices account deployment list -n $c.name -g $c.resourceGroup -o json 2>$null | ConvertFrom-Json
        if (@($deps | Where-Object { $_.properties.model.format -eq 'Anthropic' }).Count -gt 0) {
            $FoundryAccount = $c.name
            $FoundryResourceGroup = $c.resourceGroup
            break
        }
    }
    if (-not $FoundryAccount) {
        throw 'No Foundry account with Anthropic (Claude) deployments found. Deploy a Claude model first, or pass -FoundryAccount.'
    }
}

if (-not $FoundryResourceGroup) {
    $FoundryResourceGroup = (az cognitiveservices account list -o json | ConvertFrom-Json |
        Where-Object { $_.name -eq $FoundryAccount } | Select-Object -First 1).resourceGroup
}
if (-not $FoundryResourceGroup) { throw "Could not resolve the resource group for '$FoundryAccount'." }

$foundry = az cognitiveservices account show -n $FoundryAccount -g $FoundryResourceGroup -o json | ConvertFrom-Json
if ($foundry.kind -ne 'AIServices') { throw "'$FoundryAccount' is kind '$($foundry.kind)'. An AIServices account is required." }
if (-not $Location) { $Location = $foundry.location }

$deployments = az cognitiveservices account deployment list -n $FoundryAccount -g $FoundryResourceGroup -o json | ConvertFrom-Json
$claude = @($deployments | Where-Object { $_.properties.model.format -eq 'Anthropic' })
if ($claude.Count -eq 0) { throw "'$FoundryAccount' has no Anthropic deployments." }

$sonnet = ($claude | Where-Object { $_.name -like '*sonnet*' } | Select-Object -First 1).name
$opus = ($claude | Where-Object { $_.name -like '*opus*' } | Select-Object -First 1).name
$haiku = ($claude | Where-Object { $_.name -like '*haiku*' } | Select-Object -First 1).name
if (-not $sonnet) { $sonnet = $claude[0].name }
if (-not $opus) { $opus = $sonnet }
# Claude Code uses the haiku alias for background work. If no Haiku deployment
# exists, point the alias at Sonnet rather than leaving it to fail mid-task.
if (-not $haiku) { $haiku = $sonnet }

Write-Ok "foundry      : $FoundryAccount ($FoundryResourceGroup, $($foundry.location))"
Write-Ok "deployments  : $(($claude.name) -join ', ')"
Write-Detail "aliases      : sonnet=$sonnet  opus=$opus  haiku=$haiku"

# ---------------------------------------------------------------------------
Write-Step 'Preparing the target resource group'

if (-not $NamePrefix) {
    $NamePrefix = 'claudegw' + -join ((48..57) + (97..122) | Get-Random -Count 8 | ForEach-Object { [char]$_ })
}
Write-Detail "name prefix  : $NamePrefix"
Write-Detail "location     : $Location"
Write-Detail "sku          : $Sku"

if ($PSCmdlet.ShouldProcess($ResourceGroup, 'create resource group')) {
    az group create -n $ResourceGroup -l $Location -o none
    Write-Ok "resource group ready: $ResourceGroup"
}

# ---------------------------------------------------------------------------
Write-Step 'Deploying the gateway (API Management provisioning takes a few minutes)'

$deployParams = @(
    "namePrefix=$NamePrefix"
    "location=$Location"
    "foundryAccountName=$FoundryAccount"
    "foundryResourceGroup=$FoundryResourceGroup"
    "publisherEmail=$PublisherEmail"
    "publisherName=$PublisherName"
    "apimSku=$Sku"
    "sonnetDeployment=$sonnet"
    "opusDeployment=$opus"
    "haikuDeployment=$haiku"
)

$deploymentName = "claude-gateway-$(Get-Date -Format 'yyyyMMddHHmmss')"

if ($PSCmdlet.ShouldProcess($ResourceGroup, 'deploy Bicep template')) {
    az deployment group create `
        -g $ResourceGroup -n $deploymentName `
        --template-file (Join-Path $root 'infra/main.bicep') `
        --parameters $deployParams `
        -o none

    if ($LASTEXITCODE -ne 0) { throw 'Deployment failed. Run with --debug for detail.' }
}
else {
    az deployment group what-if -g $ResourceGroup --template-file (Join-Path $root 'infra/main.bicep') --parameters $deployParams
    return
}

$outputs = az deployment group show -g $ResourceGroup -n $deploymentName --query properties.outputs -o json | ConvertFrom-Json
$apimName = $outputs.apimName.value
$gatewayUrl = $outputs.gatewayUrl.value

Write-Ok "gateway      : $gatewayUrl"
Write-Ok "identity     : $($outputs.apimPrincipalId.value)"

# ---------------------------------------------------------------------------
if (-not $SkipGroups) {
    Write-Step 'Creating the Entra ID tier groups'

    foreach ($g in @($StandardGroup, $PremiumGroup)) {
        $existing = az ad group show --group $g --query id -o tsv 2>$null
        if ($existing) {
            Write-Detail "$g already exists ($existing)"
        }
        elseif ($PSCmdlet.ShouldProcess($g, 'create Entra group')) {
            $id = (az ad group create --display-name $g --mail-nickname $g -o json 2>$null | ConvertFrom-Json).id
            if ($id) { Write-Ok "$g created ($id)" }
            else { Write-Warning "Could not create '$g'. Your tenant may restrict group creation - create it manually and re-run with -SkipGroups." }
        }
    }

    Write-Step 'Syncing group membership into the gateway'
    & (Join-Path $root 'scripts/Sync-ClaudeAccess.ps1') `
        -ApimName $apimName -ResourceGroup $ResourceGroup `
        -StandardGroup $StandardGroup -PremiumGroup $PremiumGroup
}

# ---------------------------------------------------------------------------
Write-Step 'Done'

$settings = [ordered]@{
    '$schema' = 'https://json.schemastore.org/claude-code-settings.json'
    env       = [ordered]@{
        CLAUDE_CODE_USE_FOUNDRY        = '1'
        ANTHROPIC_FOUNDRY_BASE_URL     = $gatewayUrl
        ANTHROPIC_DEFAULT_OPUS_MODEL   = $opus
        ANTHROPIC_DEFAULT_SONNET_MODEL = $sonnet
        ANTHROPIC_DEFAULT_HAIKU_MODEL  = $haiku
    }
    availableModels        = @($sonnet, $opus) | Select-Object -Unique
    enforceAvailableModels = $true
}

$settingsPath = Join-Path $root 'claude-settings.json'
$settings | ConvertTo-Json -Depth 6 | Set-Content $settingsPath -Encoding utf8

Write-Host ''
Write-Host 'Give developers this file as ~/.claude/settings.json:' -ForegroundColor White
Write-Host "  $settingsPath" -ForegroundColor Cyan
Write-Host ''
Get-Content $settingsPath | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
Write-Host ''
Write-Host 'Next steps:' -ForegroundColor White
Write-Host "  1. Entitle a developer:  az ad group member add --group $StandardGroup --member-id <their-object-id>"
Write-Host "  2. Push the change:      ./scripts/Sync-ClaudeAccess.ps1 -ApimName $apimName -ResourceGroup $ResourceGroup"
Write-Host "  3. Verify the controls:  ./scripts/Show-Governance.ps1 -ApimName $apimName -ResourceGroup $ResourceGroup"
Write-Host ''
Write-Host 'Remove developers direct Cognitive Services User role on the Foundry account,' -ForegroundColor Yellow
Write-Host 'otherwise they can bypass the gateway entirely.' -ForegroundColor Yellow
Write-Host ''
