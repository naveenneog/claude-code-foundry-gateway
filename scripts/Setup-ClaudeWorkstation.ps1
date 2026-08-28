<#
.SYNOPSIS
    One-command workstation setup for Claude on Microsoft Foundry: checks and
    installs prerequisites, then configures Claude Code CLI, the VS Code
    extension, and Claude Desktop including Cowork.

.DESCRIPTION
    Hand this to a developer after adding them to the entitlement group. It
    needs no administrator rights and issues no API key.

    What it does, in order:

      1. Prerequisites  - Node.js, Azure CLI, VS Code, and the Claude clients.
                          Installs anything missing via winget.
      2. Sign-in        - az login, into the right tenant. Guests are the usual
                          failure here, so the tenant is pinned explicitly.
      3. Claude Code    - writes ~/.claude/settings.json
      4. VS Code        - writes claudeCode.environmentVariables, because the
                          extension host does not inherit shell environment
      5. Claude Desktop - writes the third-party profile, optionally with Cowork
      6. Verify         - a real call through the gateway, and reports the tier
                          and remaining budget it came back with

    Idempotent. Re-run it after a change and it will reconcile.

.PARAMETER ConfigPath
    Path or URL to the claude-gateway.json your platform team sent you. Supplies
    the gateway URL and tenant id so you do not have to type either.

.EXAMPLE
    ./Setup-ClaudeWorkstation.ps1 -ConfigPath .\claude-gateway.json

.EXAMPLE
    ./Setup-ClaudeWorkstation.ps1 `
        -GatewayUrl https://apim-x.azure-api.net/claude `
        -TenantId 00000000-0000-0000-0000-000000000000

.EXAMPLE
    # only fix configuration, install nothing
    ./Setup-ClaudeWorkstation.ps1 -ConfigPath .\claude-gateway.json -SkipInstall
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$GatewayUrl,
    [string]$TenantId,

    [string[]]$Models = @('claude-sonnet-5', 'claude-opus-5'),

    [switch]$SkipInstall,
    [switch]$SkipDesktop,
    [switch]$SkipVSCode,
    [switch]$NoCowork,

    # Where the credential helper is installed for Claude Desktop.
    [string]$HelperDir = (Join-Path $env:LOCALAPPDATA 'ClaudeFoundry')
)

$ErrorActionPreference = 'Stop'

function Write-Head($t) {
    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor DarkCyan
    Write-Host " $t" -ForegroundColor Cyan
    Write-Host ('=' * 70) -ForegroundColor DarkCyan
}
function Write-Step($t) { Write-Host ''; Write-Host "==> $t" -ForegroundColor Cyan }
function Write-Ok($t)   { Write-Host "    [OK]   $t" -ForegroundColor Green }
function Write-Warn2($t){ Write-Host "    [WARN] $t" -ForegroundColor Yellow }
function Write-Bad($t)  { Write-Host "    [FAIL] $t" -ForegroundColor Red }
function Write-Note($t) { Write-Host "    $t" -ForegroundColor DarkGray }

$problems = @()

Write-Head 'Claude on Microsoft Foundry - workstation setup'

# ----------------------------------------------------------------- 0. config

Write-Step 'Configuration'
if ($ConfigPath) {
    try {
        $raw = if ($ConfigPath -match '^https?://') {
            (Invoke-WebRequest -Uri $ConfigPath -UseBasicParsing -TimeoutSec 30).Content
        } else { Get-Content $ConfigPath -Raw }
        $cfg = $raw | ConvertFrom-Json
        if (-not $GatewayUrl) { $GatewayUrl = $cfg.gatewayUrl }
        if (-not $TenantId)   { $TenantId = $cfg.tenantId }
        Write-Ok "loaded from $ConfigPath"
        if ($cfg.tiers.standard) {
            Write-Note ("standard tier: {0:n0} tokens/min, {1:n0} tokens/day" -f $cfg.tiers.standard.tokensPerMinute, $cfg.tiers.standard.tokensPerDay)
        }
    }
    catch { Write-Warn2 "Could not read $ConfigPath - $($_.Exception.Message)" }
}
if (-not $GatewayUrl) { throw 'Supply -ConfigPath, or -GatewayUrl and -TenantId.' }
$GatewayUrl = $GatewayUrl.TrimEnd('/')
Write-Ok "gateway: $GatewayUrl"
if ($TenantId) { Write-Note "tenant : $TenantId" }

# ---------------------------------------------------------- 1. prerequisites

Write-Step 'Prerequisites'

function Test-Cmd($name) { [bool](Get-Command $name -ErrorAction SilentlyContinue) }

function Install-With-Winget {
    param([string]$Id, [string]$Label)
    if (-not (Test-Cmd 'winget')) {
        Write-Bad "$Label missing, and winget is unavailable to install it."
        return $false
    }
    Write-Note "installing $Label ..."
    winget install --id $Id --accept-source-agreements --accept-package-agreements --silent -e 2>&1 | Out-Null
    # winget does not refresh the current session's PATH.
    $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path','User')
    return $true
}

$prereqs = @(
    @{ Cmd = 'node'; Label = 'Node.js';    Winget = 'OpenJS.NodeJS.LTS' },
    @{ Cmd = 'az';   Label = 'Azure CLI';  Winget = 'Microsoft.AzureCLI' },
    @{ Cmd = 'code'; Label = 'VS Code';    Winget = 'Microsoft.VisualStudioCode'; Optional = $true }
)

foreach ($p in $prereqs) {
    if (Test-Cmd $p.Cmd) {
        # Tools emit warnings on stderr that can land first, so take the first
        # line that actually looks like a version rather than line one.
        $ver = try {
            $lines = & $p.Cmd --version 2>&1 | ForEach-Object { [string]$_ }
            $hit = $lines | Where-Object { $_ -match '\d+\.\d+' -and $_ -notmatch '(?i)warning|error|unable' } | Select-Object -First 1
            if ($hit) { $hit.Trim() } else { '' }
        } catch { '' }
        Write-Ok "$($p.Label)  $ver"
    }
    elseif ($SkipInstall) {
        if ($p.Optional) { Write-Warn2 "$($p.Label) missing (skipped)" } else { Write-Bad "$($p.Label) missing"; $problems += $p.Label }
    }
    else {
        Write-Warn2 "$($p.Label) not found"
        if (Install-With-Winget -Id $p.Winget -Label $p.Label) {
            if (Test-Cmd $p.Cmd) { Write-Ok "$($p.Label) installed" }
            else {
                Write-Warn2 "$($p.Label) installed but not yet on PATH - reopen your terminal afterwards"
                if (-not $p.Optional) { $problems += "$($p.Label) PATH" }
            }
        }
        elseif (-not $p.Optional) { $problems += $p.Label }
    }
}

# Claude Code CLI.
if (Test-Cmd 'claude') {
    $v = try { (& claude --version 2>&1 | Select-Object -First 1) } catch { '' }
    Write-Ok "Claude Code CLI  $v"
}
elseif ($SkipInstall) { Write-Warn2 'Claude Code CLI missing (skipped)' }
else {
    Write-Note 'installing Claude Code CLI ...'
    npm install -g @anthropic-ai/claude-code 2>&1 | Out-Null
    if (Test-Cmd 'claude') { Write-Ok 'Claude Code CLI installed' }
    else { Write-Warn2 'Claude Code CLI install did not complete - reopen your terminal and re-run' }
}

# ---------------------------------------------------------------- 2. sign-in

Write-Step 'Azure sign-in'
$acct = az account show -o json 2>$null | ConvertFrom-Json
$needLogin = -not $acct
if ($acct -and $TenantId -and $acct.tenantId -ne $TenantId) {
    Write-Warn2 "Signed into tenant $($acct.tenantId), need $TenantId"
    $needLogin = $true
}
if ($needLogin) {
    Write-Note 'A browser window will open.'
    if ($TenantId) { az login --tenant $TenantId -o none } else { az login -o none }
    $acct = az account show -o json 2>$null | ConvertFrom-Json
}
if (-not $acct) { Write-Bad 'Sign-in failed.'; $problems += 'sign-in' }
else {
    Write-Ok $acct.user.name
    Write-Note "tenant $($acct.tenantId)"
}

# ------------------------------------------------------------ 3. Claude Code

Write-Step 'Claude Code CLI configuration'
$claudeDir = Join-Path $env:USERPROFILE '.claude'
New-Item -ItemType Directory -Force -Path $claudeDir | Out-Null
$settingsPath = Join-Path $claudeDir 'settings.json'

$settings = if (Test-Path $settingsPath) {
    try { Get-Content $settingsPath -Raw | ConvertFrom-Json } catch { [pscustomobject]@{} }
} else { [pscustomobject]@{} }

$envBlock = [ordered]@{
    CLAUDE_CODE_USE_FOUNDRY        = '1'
    ANTHROPIC_FOUNDRY_BASE_URL     = $GatewayUrl
    ANTHROPIC_DEFAULT_OPUS_MODEL   = ($Models | Where-Object { $_ -match 'opus' }   | Select-Object -First 1)
    ANTHROPIC_DEFAULT_SONNET_MODEL = ($Models | Where-Object { $_ -match 'sonnet' } | Select-Object -First 1)
}
if (-not $envBlock.ANTHROPIC_DEFAULT_OPUS_MODEL)   { $envBlock.Remove('ANTHROPIC_DEFAULT_OPUS_MODEL') }
if (-not $envBlock.ANTHROPIC_DEFAULT_SONNET_MODEL) { $envBlock.Remove('ANTHROPIC_DEFAULT_SONNET_MODEL') }
# Haiku has no Foundry deployment in most tenants; point the alias at Sonnet so
# background tasks do not fail with DeploymentNotFound mid-session.
if ($envBlock.ANTHROPIC_DEFAULT_SONNET_MODEL) { $envBlock['ANTHROPIC_DEFAULT_HAIKU_MODEL'] = $envBlock.ANTHROPIC_DEFAULT_SONNET_MODEL }

# ANTHROPIC_FOUNDRY_RESOURCE is mutually exclusive with the base URL and the
# session dies with "baseURL and resource are mutually exclusive".
$settings | Add-Member -NotePropertyName 'env' -NotePropertyValue ([pscustomobject]$envBlock) -Force
$settings | Add-Member -NotePropertyName 'availableModels' -NotePropertyValue $Models -Force
$settings | Add-Member -NotePropertyName 'enforceAvailableModels' -NotePropertyValue $true -Force
if ($settings.env.PSObject.Properties.Name -contains 'ANTHROPIC_FOUNDRY_RESOURCE') {
    $settings.env.PSObject.Properties.Remove('ANTHROPIC_FOUNDRY_RESOURCE')
}

$settings | ConvertTo-Json -Depth 8 | Set-Content $settingsPath -Encoding UTF8
Write-Ok $settingsPath

# ---------------------------------------------------------------- 4. VS Code

if (-not $SkipVSCode) {
    Write-Step 'VS Code extension'

    if (Test-Cmd 'code') {
        $installed = & code --list-extensions 2>$null
        if ($installed -contains 'anthropic.claude-code') { Write-Ok 'extension present' }
        elseif ($SkipInstall) { Write-Warn2 'extension missing (skipped)' }
        else {
            Write-Note 'installing anthropic.claude-code ...'
            & code --install-extension anthropic.claude-code 2>&1 | Out-Null
            Write-Ok 'extension installed'
        }
    }
    else { Write-Warn2 'code command unavailable - skipping extension install' }

    # The extension host does not inherit shell environment, so the same values
    # have to be repeated here.
    $vsDir = Join-Path $env:APPDATA 'Code\User'
    $vsPath = Join-Path $vsDir 'settings.json'
    if (Test-Path $vsDir) {
        $vs = if (Test-Path $vsPath) {
            try {
                $rawVs = Get-Content $vsPath -Raw
                (($rawVs -replace '(?m)^\s*//.*$', '') -replace ',(\s*[}\]])', '$1') | ConvertFrom-Json
            } catch { Write-Warn2 'VS Code settings.json will not parse - leaving it alone'; $null }
        } else { [pscustomobject]@{} }

        if ($vs) {
            if (Test-Path $vsPath) { Copy-Item $vsPath "$vsPath.bak" -Force }
            $arr = foreach ($k in $envBlock.Keys) { [pscustomobject]@{ name = $k; value = [string]$envBlock[$k] } }
            $vs | Add-Member -NotePropertyName 'claudeCode.environmentVariables' -NotePropertyValue @($arr) -Force
            $vs | ConvertTo-Json -Depth 8 | Set-Content $vsPath -Encoding UTF8
            Write-Ok "$vsPath  ($(@($arr).Count) variables)"
            Write-Note 'Reload the VS Code window afterwards, or it keeps the old configuration.'
        }
    }
    else { Write-Warn2 'VS Code user directory not found - skipping' }
}

# ---------------------------------------------------------- 5. Claude Desktop

if (-not $SkipDesktop) {
    Write-Step 'Claude Desktop'

    $desktopInstalled = $false
    try {
        $pkg = Get-AppxPackage -Name '*Claude*' -ErrorAction SilentlyContinue
        if ($pkg) { $desktopInstalled = $true; Write-Ok "installed  $($pkg.Version)" }
    } catch { }
    if (-not $desktopInstalled) {
        $proc = Get-Process -Name 'Claude' -ErrorAction SilentlyContinue
        if ($proc) { $desktopInstalled = $true; Write-Ok 'installed (running)' }
    }
    if (-not $desktopInstalled) {
        if ($SkipInstall) { Write-Warn2 'Claude Desktop missing (skipped)' }
        else { if (Install-With-Winget -Id 'Anthropic.Claude' -Label 'Claude Desktop') { $desktopInstalled = $true } }
    }

    if ($desktopInstalled) {
        # Credential helper. Uses the Azure CLI's own pre-consented client, so
        # this needs no app registration and no admin consent.
        New-Item -ItemType Directory -Force -Path $HelperDir | Out-Null
        $helperPs1 = Join-Path $HelperDir 'get-foundry-token.ps1'
        $helperCmd = Join-Path $HelperDir 'get-foundry-token.cmd'

        $srcPs1 = Join-Path $PSScriptRoot 'get-foundry-token.ps1'
        $srcCmd = Join-Path $PSScriptRoot 'get-foundry-token.cmd'
        if ((Test-Path $srcPs1) -and (Test-Path $srcCmd)) {
            Copy-Item $srcPs1 $helperPs1 -Force
            Copy-Item $srcCmd $helperCmd -Force
            Write-Ok "credential helper -> $HelperDir"
        }
        else { Write-Warn2 'credential helper sources not found next to this script'; $problems += 'helper' }

        if (Test-Path $helperCmd) {
            # Developer settings reveal Settings -> Connection and create the
            # profile library this writes into.
            $devSettings = Join-Path $env:APPDATA 'Claude\developer_settings.json'
            New-Item -ItemType Directory -Force -Path (Split-Path $devSettings) | Out-Null
            if (-not (Test-Path $devSettings)) {
                '{ "allowDevTools": true }' | Set-Content $devSettings -Encoding UTF8
                Write-Ok 'developer settings enabled'
            }
            else { Write-Ok 'developer settings already enabled' }

            $lib = Join-Path $env:LOCALAPPDATA 'Claude-3p\configLibrary'
            $metaPath = Join-Path $lib '_meta.json'

            if (-not (Test-Path $metaPath)) {
                # First run: create the library ourselves so the profile can be
                # written before the user has ever opened the Connection screen.
                New-Item -ItemType Directory -Force -Path $lib | Out-Null
                $id = [guid]::NewGuid().ToString()
                @{ appliedId = $id; entries = @(@{ id = $id; name = 'Default' }) } |
                    ConvertTo-Json -Depth 5 | Set-Content $metaPath -Encoding UTF8
                Write-Note 'created the profile library'
            }

            $meta = Get-Content $metaPath -Raw | ConvertFrom-Json
            $profilePath = Join-Path $lib "$($meta.appliedId).json"
            if (Test-Path $profilePath) { Copy-Item $profilePath "$profilePath.bak" -Force }

            $profile = [ordered]@{
                inferenceProvider                             = 'gateway'
                inferenceGatewayBaseUrl                       = $GatewayUrl
                inferenceGatewayAuthScheme                    = 'bearer'
                inferenceCredentialKind                       = 'helper-script'
                inferenceCredentialHelper                     = $helperCmd
                inferenceCredentialHelperTimeoutSec           = 60
                inferenceCredentialHelperTtlSec               = 1800
                inferenceCredentialHelperSilentRefreshEnabled = $true
                inferenceModels                               = @($Models | ForEach-Object { @{ name = $_ } })
                chatTabEnabled                                = $true
                isClaudeCodeForDesktopEnabled                 = $true
                inferenceModelPricingEnabled                  = $true
            }
            if (-not $NoCowork) { $profile['coworkTabEnabled'] = $true }

            $profile | ConvertTo-Json -Depth 6 | Set-Content $profilePath -Encoding UTF8
            Write-Ok "profile written$(if (-not $NoCowork) { ' (Cowork enabled)' })"
            Write-Note 'Quit Claude Desktop completely, including the tray icon, then reopen.'
        }
    }
}

# ----------------------------------------------------------------- 6. verify

Write-Step 'Verifying'
$token = az account get-access-token --resource https://cognitiveservices.azure.com --query accessToken -o tsv 2>$null
if (-not $token) { Write-Bad 'could not acquire a token'; $problems += 'token' }
else {
    Write-Ok 'Entra token acquired'
    $body = @{ model = ($Models | Select-Object -First 1); max_tokens = 16
               messages = @(@{ role = 'user'; content = 'Reply with exactly: READY' }) } | ConvertTo-Json -Depth 5
    try {
        $resp = Invoke-WebRequest -Method Post -Uri "$GatewayUrl/v1/messages" -TimeoutSec 90 `
            -Headers @{ Authorization = "Bearer $token"; 'anthropic-version' = '2023-06-01'; 'Content-Type' = 'application/json' } `
            -Body $body
        Write-Ok "gateway responded  HTTP $($resp.StatusCode)"
        if ($resp.Headers['x-claude-tier']) {
            Write-Note "tier      $($resp.Headers['x-claude-tier'] -join '')"
            Write-Note "remaining $($resp.Headers['x-ratelimit-remaining-tokens'] -join '') tokens this minute"
        }
    }
    catch {
        $code = $null; try { $code = $_.Exception.Response.StatusCode.value__ } catch { }
        Write-Bad "gateway call failed  HTTP $code"
        switch ($code) {
            401 { Write-Note 'Wrong tenant. Re-run with the right -TenantId.' }
            403 { Write-Note 'Not entitled yet - ask your platform team to add you to the group and run the sync.' }
            429 { Write-Note 'Per-minute budget hit. This actually means it is working.' }
            default { Write-Note $_.Exception.Message }
        }
        if ($code -ne 429) { $problems += "gateway $code" }
    }
}

# ------------------------------------------------------------------- summary

Write-Head 'Summary'
Write-Host ''
if ($problems.Count -eq 0) {
    Write-Host '  Everything is configured.' -ForegroundColor Green
    Write-Host ''
    Write-Host '  Claude Code CLI   claude' -ForegroundColor White
    Write-Host '  VS Code           reload the window, then Ctrl+Shift+P -> Claude Code: Open in Side Bar' -ForegroundColor White
    if (-not $SkipDesktop) {
        Write-Host '  Claude Desktop    quit completely including the tray icon, then reopen' -ForegroundColor White
    }
    Write-Host ''
    Write-Host '  No API key was issued. You authenticate as yourself, and your usage' -ForegroundColor DarkGray
    Write-Host '  is metered against your own budget.' -ForegroundColor DarkGray
}
else {
    Write-Host "  $($problems.Count) item(s) need attention: $($problems -join ', ')" -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  If something was just installed, reopen your terminal and re-run -' -ForegroundColor DarkGray
    Write-Host '  installers do not refresh the PATH of a session already running.' -ForegroundColor DarkGray
}
Write-Host ''
