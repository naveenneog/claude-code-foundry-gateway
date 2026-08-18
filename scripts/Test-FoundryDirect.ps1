<#
.SYNOPSIS
    Verifies that Claude Code is correctly wired to Claude models deployed in
    Microsoft Foundry using Microsoft Entra ID (az login / managed identity).

.DESCRIPTION
    Runs seven independent checks and prints a PASS/FAIL summary:

      1. Azure CLI sign-in
      2. Entra ID data-plane token for the Foundry resource
      3. Foundry resource reachable and Claude deployments present
      4. Anthropic Messages API answers over Entra ID auth
      5. Claude Code CLI installed
      6. Claude Code reports the Foundry provider
      7. Claude Code completes a real round trip on Foundry

.PARAMETER Resource
    Foundry (AIServices) account name, e.g. ai-contosohub530569751908.

.PARAMETER ResourceGroup
    Resource group of the Foundry account. Optional; enables the deployment check.

.PARAMETER Model
    Deployment name to exercise. Defaults to claude-sonnet-5.

.EXAMPLE
    .\Test-ClaudeFoundry.ps1 -Resource ai-contosohub530569751908 -ResourceGroup rg-contosohub
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Resource,
    [string]$ResourceGroup,
    [string]$Model = 'claude-sonnet-5'
)

$ErrorActionPreference = 'Continue'
$BaseUrl = "https://$Resource.services.ai.azure.com/anthropic"
$Scope   = 'https://cognitiveservices.azure.com'
$results = [System.Collections.Generic.List[object]]::new()

function Add-Result {
    param([string]$Name, [bool]$Ok, [string]$Detail)
    $results.Add([pscustomobject]@{ Check = $Name; Status = $(if ($Ok) { 'PASS' } else { 'FAIL' }); Detail = $Detail })
    $colour = if ($Ok) { 'Green' } else { 'Red' }
    Write-Host ("  [{0}] {1}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name) -ForegroundColor $colour
    if ($Detail) { Write-Host "         $Detail" -ForegroundColor DarkGray }
}

Write-Host ""
Write-Host "Claude Code on Microsoft Foundry - verification" -ForegroundColor Cyan
Write-Host "Resource : $Resource"
Write-Host "Endpoint : $BaseUrl"
Write-Host "Model    : $Model"
Write-Host ""

# 1. Azure CLI sign-in ------------------------------------------------------
$account = az account show -o json 2>$null | ConvertFrom-Json
if ($account) {
    Add-Result 'Azure CLI signed in' $true "$($account.user.name) / $($account.name)"
}
else {
    Add-Result 'Azure CLI signed in' $false "Run 'az login' (or 'az login --identity' on Azure compute)."
}

# 2. Entra ID data-plane token ---------------------------------------------
$token = az account get-access-token --resource $Scope --query accessToken -o tsv 2>$null
if ($token) {
    Add-Result 'Entra ID token acquired' $true "scope $Scope"
}
else {
    Add-Result 'Entra ID token acquired' $false "Could not get a token for $Scope."
}

# 3. Deployments present ----------------------------------------------------
if ($ResourceGroup) {
    $deps = az cognitiveservices account deployment list -n $Resource -g $ResourceGroup -o json 2>$null | ConvertFrom-Json
    $claude = @($deps | Where-Object { $_.properties.model.format -eq 'Anthropic' })
    if ($claude.Count -gt 0) {
        Add-Result 'Claude deployments found' $true (($claude.name) -join ', ')
    }
    else {
        Add-Result 'Claude deployments found' $false 'No Anthropic-format deployments on this resource.'
    }
}
else {
    Write-Host "  [SKIP] Claude deployments found" -ForegroundColor Yellow
    Write-Host "         Pass -ResourceGroup to enable this check." -ForegroundColor DarkGray
}

# 4. Messages API round trip ------------------------------------------------
if ($token) {
    $body = @{
        model      = $Model
        max_tokens = 32
        messages   = @(@{ role = 'user'; content = 'Reply with exactly: FOUNDRY-OK' })
    } | ConvertTo-Json -Depth 6

    try {
        $resp = Invoke-RestMethod -Uri "$BaseUrl/v1/messages" -Method Post -Body $body `
            -ContentType 'application/json' `
            -Headers @{ Authorization = "Bearer $token"; 'anthropic-version' = '2023-06-01' }
        $text = ($resp.content | Where-Object { $_.type -eq 'text' } | Select-Object -First 1).text
        Add-Result 'Messages API responds (Entra ID)' $true "model=$($resp.model) reply='$text'"
    }
    catch {
        Add-Result 'Messages API responds (Entra ID)' $false $_.Exception.Message
    }
}

# 5. Claude Code CLI --------------------------------------------------------
$cli = Get-Command claude -ErrorAction SilentlyContinue
if ($cli) {
    $ver = (claude --version 2>$null | Out-String).Trim()
    Add-Result 'Claude Code CLI installed' $true $ver
}
else {
    Add-Result 'Claude Code CLI installed' $false 'npm install -g @anthropic-ai/claude-code'
}

# 6. Provider reported by Claude Code --------------------------------------
if ($cli) {
    try {
        $auth = claude auth status 2>$null | Out-String | ConvertFrom-Json
        $isFoundry = $auth.apiProvider -eq 'foundry'
        Add-Result 'Claude Code provider = foundry' $isFoundry "apiProvider=$($auth.apiProvider) authMethod=$($auth.authMethod)"
    }
    catch {
        Add-Result 'Claude Code provider = foundry' $false 'Could not parse `claude auth status`.'
    }
}

# 7. End-to-end Claude Code turn -------------------------------------------
if ($cli) {
    try {
        $json = claude -p 'Reply with exactly: FOUNDRY-OK' --output-format json 2>$null | Out-String | ConvertFrom-Json
        $usage = $json.modelUsage.PSObject.Properties | Select-Object -First 1
        $provider = $usage.Value.provider
        $ok = ($provider -eq 'foundry') -and -not $json.is_error
        Add-Result 'Claude Code end-to-end on Foundry' $ok "model=$($usage.Name) provider=$provider reply='$($json.result)'"
    }
    catch {
        Add-Result 'Claude Code end-to-end on Foundry' $false $_.Exception.Message
    }
}

# Summary -------------------------------------------------------------------
Write-Host ""
$failed = @($results | Where-Object { $_.Status -eq 'FAIL' }).Count
if ($failed -eq 0) {
    Write-Host "All $($results.Count) checks passed - Claude Code is running on Microsoft Foundry." -ForegroundColor Green
}
else {
    Write-Host "$failed of $($results.Count) checks failed." -ForegroundColor Red
}
Write-Host ""
exit $failed
