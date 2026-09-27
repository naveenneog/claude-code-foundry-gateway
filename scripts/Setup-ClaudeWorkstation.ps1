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
    # Interactive opens a browser, which is the right default on a laptop and
    # impossible on a jump box, VDI session or anything reached over SSH.
    # Device code prints a code to paste into a browser elsewhere.
    [ValidateSet('interactive', 'device')][string]$Auth = 'interactive',

    # Where the credential helper is installed for Claude Desktop.
    [string]$HelperDir = (Join-Path $env:LOCALAPPDATA 'ClaudeFoundry')
)

$ErrorActionPreference = 'Stop'
# ClaudeClientSupport.ps1 and ClaudeDesktopSignIn.ps1 define what the steps below call; without
# them the setup would fail halfway with an unknown command, so it stops here and says why.
$missingHelpers = @('ClaudeClientSupport.ps1', 'ClaudeDesktopSignIn.ps1' | Where-Object { -not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $_)) })
if ($missingHelpers.Count) {
    Write-Host "    [FAIL] $($missingHelpers -join ' and ') must be in the same folder as this script ($PSScriptRoot)." -ForegroundColor Red
    Write-Host '    Fetch the whole scripts folder, or use the command in your onboarding email, which fetches every file.' -ForegroundColor DarkGray
    exit 1
}
. (Join-Path $PSScriptRoot 'ClaudeDesktopSignIn.ps1')
# Model capabilities, client versions and bounded client commands (ADR-0031).
. (Join-Path $PSScriptRoot 'ClaudeClientSupport.ps1')

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

$banner = Join-Path $PSScriptRoot 'Show-Banner.ps1'
if (Test-Path $banner) {
    . $banner
    Show-ClaudeBanner -Subtitle 'Workstation setup - CLI, VS Code and Desktop'
}
else { Write-Head 'Claude on Microsoft Foundry - workstation setup' }

# ----------------------------------------------------------------- 0. config

Write-Step 'Configuration'
$cfg = $null
if ($ConfigPath) {
    try {
        # Decoded from the bytes: a record the installer wrote on Windows PowerShell 5.1 starts
        # with a UTF-8 byte-order mark, which 5.1 leaves in a text/plain body as three characters
        # that ConvertFrom-Json refuses (measured). The decoder throws on bytes that are not UTF-8,
        # so a record in another encoding is reported below rather than read with its characters
        # replaced.
        $raw = if ($ConfigPath -match '^https?://') {
            $bytes = (Invoke-WebRequest -Uri $ConfigPath -UseBasicParsing -TimeoutSec 30).RawContentStream.ToArray()
            (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes).TrimStart([char]0xFEFF)
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
if (-not $GatewayUrl) {
    Write-Host ''
    Write-Bad 'No gateway configuration.'
    Write-Host ''
    Write-Host '  This script needs to know which gateway to point at. That comes from a' -ForegroundColor White
    Write-Host '  small file called claude-gateway.json.' -ForegroundColor White
    Write-Host ''
    Write-Host '  Where to get it:' -ForegroundColor White
    Write-Host '    Your platform team generates it when they deploy the gateway, and sends'
    Write-Host '    it to you - usually attached to your onboarding email, or on an internal'
    Write-Host '    share. It is not in this repository, because it describes your specific'
    Write-Host '    deployment.'
    Write-Host ''
    Write-Host '  Then run:' -ForegroundColor White
    Write-Host '    .\Setup-ClaudeWorkstation.ps1 -ConfigPath <path-to-claude-gateway.json>'
    Write-Host ''
    Write-Host '  Or skip the file and pass the two values directly:' -ForegroundColor White
    Write-Host '    .\Setup-ClaudeWorkstation.ps1 -GatewayUrl https://<apim>.azure-api.net/claude -TenantId <tenant-id>'
    Write-Host ''
    Write-Host '  It contains no secret - just the gateway URL, tenant id and tier limits.' -ForegroundColor DarkGray
    Write-Host '  Access comes from your Entra group membership, not from this file.' -ForegroundColor DarkGray
    Write-Host ''
    return
}
$GatewayUrl = $GatewayUrl.TrimEnd('/')
Write-Ok "gateway: $GatewayUrl"
if ($TenantId) { Write-Note "tenant : $TenantId" }
# The deployments the gateway serves, with the model behind each one. -Models names win when
# passed; otherwise the record written by the installer; otherwise the default names.
$deployments = @(if ($PSBoundParameters.ContainsKey('Models')) {
    Get-ClaudeRecordedDeployment -Config ([pscustomobject]@{}) -Names $Models
} else {
    $recorded = @(Get-ClaudeRecordedDeployment -Config $cfg)
    if ($recorded.Count) { $recorded } else { Get-ClaudeRecordedDeployment -Config ([pscustomobject]@{}) -Names $Models }
})
$Models = @($deployments | ForEach-Object { $_.name })
Write-Note ("models : " + (($deployments | ForEach-Object { if ($_.model -and $_.model -ne $_.name) { "$($_.name) ($($_.model))" } else { $_.name } }) -join ', '))
$desktopSignIn = if (Get-Command Get-ClaudeDesktopSignIn -ErrorAction SilentlyContinue) {
    Get-ClaudeDesktopSignIn -Config $(if ($cfg) { $cfg } else { [pscustomobject]@{} })
} else {
    [pscustomobject]@{ kind = 'helper-script' }
}
Write-Note "Desktop sign-in: $(if ($desktopSignIn.kind -eq 'external-idp') { "$($desktopSignIn.kind) $($desktopSignIn.flow) $($desktopSignIn.bearerTokenType)" } else { $desktopSignIn.kind })"

# Check the environment before touching anything. The gateway URL is known by
# now, so reachability can be probed too.
$preflight = Join-Path $PSScriptRoot 'Test-Prerequisites.ps1'
if (Test-Path $preflight) {
    . $preflight
    # Warnings only: this script installs what is missing, so an absent tool is
    # not a blocker the way it is for the admin path.
    $null = Test-ClaudePrerequisites -Mode Workstation -GatewayUrl $GatewayUrl -WarnOnly
}

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

# Claude Code CLI. Every install on PATH is listed, because the first one is the one that runs,
# and a newer install behind an older one changes nothing.
$claudeInstalls = @(Get-ClaudeCodeInstall)
$requiredClaude = Get-ClaudeCodeRequiredVersion -Deployments $deployments
if ($claudeInstalls.Count) {
    $claudePath = $claudeInstalls[0].Source
    $versionRun = Invoke-ClaudeClientCommand -Path $claudePath -Arguments @('--version') -TimeoutSeconds 60
    $v = $versionRun.Output
    if ($versionRun.StartFailed -or $versionRun.TimedOut) { Write-Warn2 "Claude Code CLI at $claudePath did not report a version: $(if ($versionRun.TimedOut) { 'no answer in 60 s' } else { $v })"; $v = '' }
    else { Write-Ok "Claude Code CLI  $v" }
    Write-Note "runs from $claudePath"
    foreach ($other in ($claudeInstalls | Select-Object -Skip 1)) { Write-Note "also on PATH, not used: $($other.Source)" }
    if ($requiredClaude -and (Test-ClaudeClientVersionAtLeast -Installed $v -Required $requiredClaude.Version) -eq $false) {
        Write-Warn2 "Claude Code $((ConvertTo-ClaudeClientVersion $v)) predates $($requiredClaude.Version), the first release that knows $($requiredClaude.Model)."
        Write-Note 'The capability settings written below make its requests work; the update brings the rest.'
        if ($SkipInstall) { Write-Note 'Update it with: claude update' }
        else {
            Write-Note 'updating with claude update (at most 5 minutes) ...'
            $update = Invoke-ClaudeClientCommand -Path $claudePath -Arguments @('update') -TimeoutSeconds 300
            $after = (Invoke-ClaudeClientCommand -Path $claudePath -Arguments @('--version') -TimeoutSeconds 60).Output
            if ((Test-ClaudeClientVersionAtLeast -Installed $after -Required $requiredClaude.Version) -eq $true) { Write-Ok "Claude Code CLI  $after" }
            else {
                $why = if ($update.TimedOut) { 'claude update did not finish in 5 minutes' } else { (($update.Output -split "`r?`n") | Select-Object -Last 3) -join ' / ' }
                Write-Warn2 "Claude Code is still $((ConvertTo-ClaudeClientVersion $after)): $why"
                Write-Note "The one that runs is $claudePath. If it came from a package or software portal, update it there."
            }
        }
    }
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
    $loginArgs = @('login', '-o', 'none')
    if ($TenantId) { $loginArgs += @('--tenant', $TenantId) }
    if ($Auth -eq 'device') {
        $loginArgs += '--use-device-code'
        Write-Note 'A code will be printed. Open the URL on any machine with a browser.'
    }
    else {
        Write-Note 'A browser window will open. On a machine without one, re-run with -Auth device.'
    }
    az @loginArgs
    $acct = az account show -o json 2>$null | ConvertFrom-Json
}
if (-not $acct) {
    Write-Bad 'Sign-in failed.'
    if ($Auth -ne 'device') { Write-Note 'If no browser opened, re-run with -Auth device.' }
    $problems += 'sign-in'
}
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

# One function writes this for the CLI, and its variables are repeated for VS Code below. It
# keeps the developer's other settings and environment variables, removes
# ANTHROPIC_FOUNDRY_RESOURCE (mutually exclusive with the base URL), pins each alias to a
# deployment by model, and declares the model's capabilities (ADR-0031).
$settings = Set-ClaudeCodeGatewaySettings -Settings $settings -GatewayUrl $GatewayUrl -Deployments $deployments
$envBlock = [ordered]@{ CLAUDE_CODE_USE_FOUNDRY = '1'; ANTHROPIC_FOUNDRY_BASE_URL = $GatewayUrl }
$modelEnvironment = Get-ClaudeCodeModelEnvironment -Deployments $deployments
foreach ($k in $modelEnvironment.Keys) { $envBlock[$k] = $modelEnvironment[$k] }

$settings | ConvertTo-Json -Depth 8 | Set-Content $settingsPath -Encoding UTF8
Write-Ok $settingsPath
$declared = @($modelEnvironment.Keys | Where-Object { $_ -like '*_SUPPORTED_CAPABILITIES' })
if ($declared.Count) { Write-Note "capabilities declared for: $(($declared | ForEach-Object { ($_ -replace '^ANTHROPIC_DEFAULT_','') -replace '_MODEL_SUPPORTED_CAPABILITIES$','' }) -join ', ')" }

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
            # Entries the developer added for other purposes are kept; the gateway's are replaced.
            $keep = @($vs.'claudeCode.environmentVariables' | Where-Object { $_ -and $_.name -and $script:ClaudeCodeGatewayEnvKeys -notcontains $_.name })
            $arr = @($keep) + @(foreach ($k in $envBlock.Keys) { [pscustomobject]@{ name = $k; value = [string]$envBlock[$k] } })
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

    $desktopInstall = Get-ClaudeDesktopInstall
    $desktopInstalled = [bool]$desktopInstall.Installed
    if ($desktopInstalled) { Write-Ok "installed  $($desktopInstall.Version)" }
    if (-not $desktopInstalled) {
        if ($SkipInstall) { Write-Warn2 'Claude Desktop missing (skipped)' }
        else {
            if (Install-With-Winget -Id 'Anthropic.Claude' -Label 'Claude Desktop') {
                $desktopInstalled = $true
                $desktopInstall = Get-ClaudeDesktopInstall
            }
        }
    }

    if ($desktopInstalled) {
        $helperPs1 = Join-Path $HelperDir 'get-foundry-token.ps1'
        $helperCmd = Join-Path $HelperDir 'get-foundry-token.cmd'

        if ($desktopSignIn.kind -eq 'helper-script') {
            # Credential helper. Uses the Azure CLI's own pre-consented client,
            # so this needs no app registration and no admin consent.
            New-Item -ItemType Directory -Force -Path $HelperDir | Out-Null

            $srcPs1 = Join-Path $PSScriptRoot 'get-foundry-token.ps1'
            $srcCmd = Join-Path $PSScriptRoot 'get-foundry-token.cmd'
            if ((Test-Path $srcPs1) -and (Test-Path $srcCmd)) {
                Copy-Item $srcPs1 $helperPs1 -Force
                Copy-Item $srcCmd $helperCmd -Force
                Write-Ok "credential helper -> $HelperDir"
            }
            else {
                Write-Warn2 'get-foundry-token.ps1 and .cmd are not next to this script.'
                Write-Note 'They are copied, not generated, so Claude Desktop cannot be'
                Write-Note 'configured without them. The CLI and VS Code are unaffected.'
                Write-Note 'Fetch the whole scripts folder rather than this file alone.'
                $problems += 'helper'
            }
        }
        else { Write-Ok 'Desktop will use its own Entra sign-in; no helper script is written.' }

        $canWriteDesktopProfile = $false
        if ($desktopSignIn.kind -eq 'helper-script') {
            if (Test-Path $helperCmd) { $canWriteDesktopProfile = $true }
        }
        else { $canWriteDesktopProfile = $true }

        if ($canWriteDesktopProfile) {
            # Developer settings reveal Settings -> Connection and create the
            # profile library this writes into.
            $devSettings = Join-Path $env:APPDATA 'Claude\developer_settings.json'
            New-Item -ItemType Directory -Force -Path (Split-Path $devSettings) | Out-Null
            # Presence is not the same as enabled. A file left behind with
            # allowDevTools false reported "already enabled" and turned nothing
            # on, and the developer then could not find Settings -> Connection.
            $devOn = $false
            $devDoc = $null
            if (Test-Path $devSettings) {
                try { $devDoc = Get-Content $devSettings -Raw | ConvertFrom-Json } catch { $devDoc = $null }
                if ($devDoc -and $devDoc.allowDevTools -eq $true) { $devOn = $true }
            }
            if ($devOn) { Write-Ok 'developer settings already enabled' }
            else {
                # Keep any other keys the app has put there.
                if (-not $devDoc) { $devDoc = [pscustomobject]@{} }
                $devDoc | Add-Member -NotePropertyName 'allowDevTools' -NotePropertyValue $true -Force
                $devDoc | ConvertTo-Json -Depth 5 | Set-Content $devSettings -Encoding UTF8
                Write-Ok 'developer settings enabled'
            }

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

            $desktopReads = Get-ClaudeDesktopReadingVersion -Install $desktopInstall
            $profile = New-ClaudeDesktopSettings -GatewayUrl $GatewayUrl -Models $Models -HelperPath $helperCmd -DesktopSignIn $desktopSignIn -NoCowork:$NoCowork -DesktopVersion $desktopReads

            $profile | ConvertTo-Json -Depth 6 | Set-Content $profilePath -Encoding UTF8
            Write-Ok "profile written$(if (-not $NoCowork) { ' (Cowork enabled)' })"
            $flowKey = @('inferenceGatewayOidcAuthFlow', 'inferenceIdpAuthFlow') | Where-Object { $profile.Contains($_) } | Select-Object -First 1
            Write-Note "sign-in: $($profile.inferenceCredentialKind)$(if ($flowKey) { ' (' + $profile[$flowKey] + ')' }) for Desktop $(if ($desktopReads) { $desktopReads } else { 'of unknown version' })"
            if ($desktopInstall.RunningVersion -and $desktopInstall.Version -and $desktopInstall.RunningVersion -ne $desktopInstall.Version) {
                Write-Warn2 "Claude Desktop $($desktopInstall.Version) is installed, but $($desktopInstall.RunningVersion) is running ($($desktopInstall.RunningPath))."
                foreach ($s in @(Get-ClaudeDesktopVersionedShortcut)) { Write-Note "shortcut to one build: $($s.Shortcut) -> $($s.Target)" }
                Write-Note 'Quit Desktop fully, including the tray icon, and start it from the Start menu.'
            }
            # A release older than the keys needs ignores them, and the Connection screen then
            # shows an empty Credential kind. Say so now rather than after the first failed chat.
            $desktopNeeds = Get-ClaudeDesktopRequiredVersion -Settings $profile
            $desktopOk = if ($desktopNeeds) { Test-ClaudeClientVersionAtLeast -Installed $desktopReads -Required $desktopNeeds } else { $true }
            if ($desktopOk -eq $false) {
                Write-Warn2 "Claude Desktop $desktopReads is older than $desktopNeeds, which this sign-in needs. Update Claude Desktop, then reopen it."
                $problems += 'Claude Desktop version'
            }
            elseif ($null -eq $desktopOk) { Write-Note "Claude Desktop version unknown; this sign-in needs $desktopNeeds or later." }
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
    # The Sonnet deployment is in every tier by default; an Opus-only request refuses standard users.
    $probeModel = $envBlock['ANTHROPIC_DEFAULT_SONNET_MODEL']
    if (-not $probeModel) { $probeModel = $Models | Select-Object -First 1 }
    $body = @{ model = $probeModel; max_tokens = 16
               messages = @(@{ role = 'user'; content = 'Reply with exactly: READY' }) } | ConvertTo-Json -Depth 5
    # -UseBasicParsing: without it Windows PowerShell 5.1 throws "Object reference not set to an
    # instance of an object" on a machine without Internet Explorer, and no request is sent (measured).
    try {
        $resp = Invoke-WebRequest -Method Post -Uri "$GatewayUrl/v1/messages" -TimeoutSec 90 -UseBasicParsing `
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

    # The same path the developer will use: Claude Code itself, with the settings just written.
    # A raw request proves the gateway; this proves the client and its model settings, and is
    # what catches the next client and model mismatch (ADR-0031).
    $cliNow = @(Get-ClaudeCodeInstall) | Select-Object -First 1
    if ($cliNow -and $probeModel -and $probeModel -match '^[A-Za-z0-9._-]+$') {
        Write-Note "asking Claude Code for one reply through the gateway ($probeModel, at most 2 minutes) ..."
        $cliCall = Invoke-ClaudeClientCommand -Path $cliNow.Source -Arguments @('-p', 'ping', '--model', $probeModel) -TimeoutSeconds 120 -WorkingDirectory ([IO.Path]::GetTempPath())
        if ($cliCall.TimedOut) { Write-Warn2 'Claude Code did not answer within 2 minutes'; $problems += 'Claude Code request' }
        elseif ($cliCall.ExitCode -eq 0 -and $cliCall.Output -notmatch 'API Error') { Write-Ok "Claude Code answered through the gateway in $($cliCall.Seconds) s" }
        else {
            $firstLine = (($cliCall.Output -split "`r?`n") | Where-Object { $_ } | Select-Object -First 1)
            Write-Bad "Claude Code request failed: $firstLine"
            if ($cliCall.Output -match 'thinking\.type\.enabled') { Write-Note 'This Claude Code does not know the model. Update it (claude update) or check the capability settings above.' }
            elseif ($cliCall.Output -match '\b403\b') { Write-Note 'Refused by the gateway: check your tier includes this model.' }
            $problems += 'Claude Code request'
        }
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
