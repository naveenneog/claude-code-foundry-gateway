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
    [string]$Model = 'claude-sonnet-5',
    # Supply the client id from Claude Desktop's Connection screen to test the
    # device-code flow it uses. That flow fails before any token exists, so no
    # role assignment can fix it and the other checks here cannot see it.
    [string]$ClientId,
    [string]$TenantId
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

# 2b. Who does that token actually belong to? -------------------------------
# The refusal Foundry returns names a "Principal", and the Azure Identity chain
# puts environment variables ahead of the signed-in CLI user - so the principal
# is often not the person reading the message.
$claims = $null
if ($token) {
    try {
        $p = $token.Split('.')[1].Replace('-', '+').Replace('_', '/')
        switch ($p.Length % 4) { 2 { $p += '==' } 3 { $p += '=' } 1 { $p += '===' } }
        $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p)) | ConvertFrom-Json
    } catch { $claims = $null }
}
if ($claims) {
    $who = if ($claims.upn) { $claims.upn }
           elseif ($claims.unique_name) { $claims.unique_name }
           elseif ($claims.appid) { "application $($claims.appid)" }
           else { '<unnamed>' }
    $isUser = [bool]($claims.upn -or $claims.unique_name)
    Add-Result 'Token belongs to a signed-in user' $isUser "$who  tenant=$($claims.tid)"
    if (-not $isUser) {
        Write-Host '         A service principal is ahead of your CLI sign-in. Check:' -ForegroundColor DarkGray
        Write-Host '         Get-ChildItem Env: | Where-Object Name -match ''AZURE_CLIENT_ID''' -ForegroundColor DarkGray
    }
}

# 2c. Is the resource in that token's tenant? -------------------------------
# A token for the wrong tenant is valid and useless: the resource's tenant has
# never heard of the principal, and says so in a way that reads like RBAC.
$rgFound = az cognitiveservices account list --query "[?name=='$Resource'].resourceGroup | [0]" -o tsv 2>$null
if ($rgFound) { $rgFound = $rgFound.Trim() }
if ($claims) {
    Add-Result 'Resource is in the signed-in tenant' ([bool]$rgFound) $(
        if ($rgFound) { "resource group $rgFound" }
        else { "$Resource is not visible from tenant $($claims.tid) - sign in to the tenant that owns it" })
}

# 2d. Does the principal hold a role that reaches Claude? -------------------
# Azure AI Developer and Cognitive Services OpenAI User are confined to
# accounts/OpenAI/*, and Claude is not served there - so they look like the
# obvious AI roles and grant nothing on this endpoint.
if ($claims -and $rgFound) {
    $scopeId = az cognitiveservices account show -n $Resource -g $rgFound --query id -o tsv 2>$null
    if ($scopeId) { $scopeId = $scopeId.Trim() }
    $held = @()
    if ($scopeId -and $claims.oid) {
        $raw = az role assignment list --assignee $claims.oid --scope $scopeId --include-inherited `
                  --query "[].roleDefinitionName" -o tsv 2>$null
        if ($raw) { $held = @($raw -split "`r?`n" | Where-Object { $_ } | ForEach-Object { $_.Trim() } | Sort-Object -Unique) }
    }
    $capable = @()
    foreach ($r in $held) {
        $da = az role definition list --name $r --query "[0].permissions[0].dataActions" -o tsv 2>$null
        if (-not $da) { continue }
        $acts = @($da -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($acts -contains 'Microsoft.CognitiveServices/*') { $capable += $r }
    }
    if ($capable.Count -gt 0) {
        Add-Result 'A role reaches the Claude data plane' $true ($capable -join ', ')
    }
    elseif ($held.Count -gt 0) {
        Add-Result 'A role reaches the Claude data plane' $false `
            ("held: $($held -join ', ') - none carries Microsoft.CognitiveServices/*")
    }
    else {
        Add-Result 'A role reaches the Claude data plane' $false `
            'no role assignment on this resource for that principal'
    }
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

# 8. The three clients agree -----------------------------------------------
# Claude Desktop cannot read ~/.claude/settings.json, and VS Code can hold its
# own copy. A stale value in either outlives a correct CLI configuration and
# looks like an intermittent fault.
$expected = "https://$Resource.services.ai.azure.com/anthropic"
$cliFile  = Join-Path $env:USERPROFILE '.claude\settings.json'
$codeFile = Join-Path $env:APPDATA 'Code\User\settings.json'

$cliTarget = $null
if (Test-Path $cliFile) {
    try {
        $c = Get-Content $cliFile -Raw | ConvertFrom-Json
        $cliTarget = if ($c.env.ANTHROPIC_FOUNDRY_RESOURCE) { "resource:$($c.env.ANTHROPIC_FOUNDRY_RESOURCE)" }
                     elseif ($c.env.ANTHROPIC_FOUNDRY_BASE_URL) { $c.env.ANTHROPIC_FOUNDRY_BASE_URL }
        # Both set at once ends the session outright.
        if ($c.env.ANTHROPIC_FOUNDRY_RESOURCE -and $c.env.ANTHROPIC_FOUNDRY_BASE_URL) {
            Add-Result 'CLI settings are not self-contradictory' $false `
                'both ANTHROPIC_FOUNDRY_RESOURCE and ANTHROPIC_FOUNDRY_BASE_URL are set - mutually exclusive'
        }
    } catch { }
}
Add-Result 'Claude CLI is configured' ([bool]$cliTarget) $(if ($cliTarget) { "$cliFile -> $cliTarget" } else { "nothing Foundry-related in $cliFile" })
# Configured is not the same as configured for this resource. A machine on the
# gateway passes every check above - the token, the role and the endpoint are
# all genuinely fine - and is still not on the direct path.
if ($cliTarget) {
    $onDirect = ($cliTarget -eq "resource:$Resource") -or ($cliTarget -eq $expected)
    Add-Result 'Claude CLI points at this resource' $onDirect $(
        if ($onDirect) { 'direct path' }
        elseif ($cliTarget -match 'azure-api\.net') { "this machine is on the gateway ($cliTarget), not the direct path" }
        else { "points at $cliTarget" })
}

if (Test-Path $codeFile) {
    try {
        $v = (Get-Content $codeFile -Raw | ConvertFrom-Json).'claudeCode.environmentVariables'
        if ($v) {
            $res = ($v | Where-Object name -eq 'ANTHROPIC_FOUNDRY_RESOURCE').value
            $url = ($v | Where-Object name -eq 'ANTHROPIC_FOUNDRY_BASE_URL').value
            $codeTarget = if ($res) { "resource:$res" } else { $url }
            $agrees = (-not $codeTarget) -or ($codeTarget -eq $cliTarget)
            Add-Result 'VS Code agrees with the CLI' $agrees $(
                if ($agrees) { 'same target' } else { "VS Code -> $codeTarget, CLI -> $cliTarget" })
        }
    } catch { }
}

$lib = Join-Path $env:LOCALAPPDATA 'Claude-3p\configLibrary'
$metaFile = Join-Path $lib '_meta.json'
if (Test-Path $metaFile) {
    try {
        $meta = Get-Content $metaFile -Raw | ConvertFrom-Json
        $pf = Join-Path $lib "$($meta.appliedId).json"
        if (Test-Path $pf) {
            $dp = Get-Content $pf -Raw | ConvertFrom-Json
            $agrees = $dp.inferenceGatewayBaseUrl -eq $expected
            Add-Result 'Claude Desktop points at this resource' $agrees $(
                if ($agrees) { 'direct path' }
                elseif ($dp.inferenceGatewayBaseUrl -match 'azure-api\.net') { "on the gateway ($($dp.inferenceGatewayBaseUrl)), not the direct path" }
                else { "Desktop -> $($dp.inferenceGatewayBaseUrl)" })
            if ($dp.inferenceCredentialHelper -and -not (Test-Path $dp.inferenceCredentialHelper)) {
                Add-Result 'Desktop credential helper exists' $false $dp.inferenceCredentialHelper
            }
        }
    } catch { }
}

# 9. Entra device-code init, only when a client id is given -----------------
# Claude Desktop's native Foundry Entra mode posts to /devicecode before any
# token exists. A 400 there is an app registration problem and no role
# assignment can affect it, which is why it needs its own check.
if ($ClientId) {
    $tid = if ($TenantId) { $TenantId } elseif ($claims) { $claims.tid } else { $null }
    if (-not $tid) { Write-Host '  [SKIP] Entra device-code init - pass -TenantId' -ForegroundColor Yellow }
    else {
        $dcScope = 'https://cognitiveservices.azure.com/.default offline_access'
        try {
            $r = Invoke-WebRequest "https://login.microsoftonline.com/$tid/oauth2/v2.0/devicecode" `
                    -Method POST -ContentType 'application/x-www-form-urlencoded' `
                    -Body "client_id=$ClientId&scope=$([uri]::EscapeDataString($dcScope))" `
                    -UseBasicParsing -TimeoutSec 30 -SkipHttpErrorCheck
            if ($r.StatusCode -eq 200) {
                Add-Result 'Entra device-code init (Desktop)' $true "client $ClientId accepted"
            }
            else {
                $err = $null
                try { $err = ($r.Content | ConvertFrom-Json).error_description } catch { }
                $aadsts = if ($err -match '(AADSTS\d+)') { $Matches[1] } else { "HTTP $($r.StatusCode)" }
                Add-Result 'Entra device-code init (Desktop)' $false "$aadsts - app registration or tenant, not RBAC"
            }
        }
        catch { Add-Result 'Entra device-code init (Desktop)' $false $_.Exception.Message }
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
