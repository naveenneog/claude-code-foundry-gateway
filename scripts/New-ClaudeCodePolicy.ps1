<#
.SYNOPSIS
    Generates Claude Code managed-settings policy for mass deployment, in every
    format an enterprise fleet tool consumes.

.DESCRIPTION
    Companion to the Claude Desktop generator in claude-desktop-foundry. This
    one covers the CLI, the VS Code and JetBrains extensions, and the Code tab
    in Claude Desktop - all of which read the same managed settings.

    Managed settings sit above every other level: no user, project, local or
    --settings value overrides them. That is what makes this the right lever for
    a fleet, rather than asking thousands of developers to run a setup script.

    Emits, from one set of answers:

      managed-settings.json     file-based, for the OS system directory
      .reg                      HKLM\SOFTWARE\Policies\ClaudeCode
      .intune-omauri.csv        Intune custom OMA-URI rows
      .mobileconfig             macOS/Jamf, com.anthropic.claudecode
      .apply.ps1                apply locally, for piloting before a fleet push
      README.txt                what to do with each

    Three things worth knowing before deploying, all confirmed from Anthropic's
    documentation rather than assumed:

    1. On Windows the file path is C:\Program Files\ClaudeCode\. The older
       C:\ProgramData\ClaudeCode\managed-settings.json is explicitly not read.

    2. Server-managed settings from the claude.ai console do not apply here.
       Claude Code fetches those only when the session authenticates to
       Anthropic's API directly; pointing it at your own gateway means it skips
       that source and starts at MDM. So MDM or the file is the mechanism, and
       the console is not.

    3. When several managed sources reach one machine, the default is
       first-wins, not merge: the highest-ranked source that supplies any policy
       key wins outright and the rest are ignored silently. Ranking is remote,
       then MDM/HKLM, then the file, then HKCU. Deploying both the .reg and the
       .json means the .reg wins and the file is ignored - pick one per machine
       unless you set managedSourcesBehavior to merge.

    Reference: https://code.claude.com/docs/en/managed-settings

.EXAMPLE
    ./New-ClaudeCodePolicy.ps1 -GatewayUrl https://apim-x.azure-api.net/claude

.EXAMPLE
    ./New-ClaudeCodePolicy.ps1 -ConfigPath ./onboarding/claude-gateway.json
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$GatewayUrl,
    [string]$OpusModel   = 'claude-opus-5',
    [string]$SonnetModel = 'claude-sonnet-5',
    [string]$HaikuModel,

    # Which entitlement tier this profile is for. The tiers already differ by
    # budget at the gateway; this is what makes them differ by capability.
    #
    # The profile is a management control, not a security boundary. Anthropic
    # states that "a user who can run a modified Claude Code binary can bypass
    # any client-side control", and that applies to everything here. The
    # controls that must hold - entitlement, budgets, and the model allowlist -
    # are enforced in the gateway policy instead. See docs/adr/0004.
    [ValidateSet('standard', 'premium')]
    [string]$Tier = 'standard',

    # Models this tier may select. Defaults to the tier's own sensible set.
    # Mirror it into the gateway's models-standard / models-premium named
    # values, which is where it is actually enforced.
    [string[]]$AvailableModels,

    # Claude Desktop tabs, for the profile New-ClaudeDesktopPolicy consumes.
    # Left unset, a tier gets everything its plan allows.
    [ValidateSet('default', 'chat-only', 'no-cowork')]
    [string]$DesktopTabs = 'default',
    [ValidateSet('none', 'basic', 'strict')]
    [string]$Hardening = 'basic',

    # Where a developer's conversation history lives. Local disk is the default
    # and is all Claude Code does on its own; the other two are what make it
    # survivable and auditable for an organisation.
    #
    #   local       device only. Nothing roams, nothing is backed up, and a
    #               reimaged laptop loses the history. Nothing leaves the
    #               machine either.
    #   redirected  CLAUDE_CONFIG_DIR points settings, session history and
    #               plugins at a path you control - a redirected folder, an
    #               Azure Files share, an FSLogix container. Roams and is backed
    #               up with the rest of the profile.
    #   audited     local working copy, plus an OpenTelemetry export to your own
    #               collector for retention, chargeback and eDiscovery. Metadata
    #               only unless -CaptureContent is passed.
    [ValidateSet('local', 'redirected', 'audited')]
    [string]$ConversationStorage = 'local',
    [string]$ConfigDir,
    [string]$OtlpEndpoint,
    [switch]$CaptureContent,

    [string]$OutputPath = './policy-claude-code'
)

$ErrorActionPreference = 'Stop'

$banner = Join-Path $PSScriptRoot 'Show-Banner.ps1'
if (Test-Path $banner) { . $banner; Show-ClaudeBanner -Subtitle 'Claude Code managed settings' }

# The wizard writes onboarding/claude-gateway.json; reuse it so the same values
# cannot drift between the developer path and the fleet path.
if ($ConfigPath) {
    if (-not (Test-Path $ConfigPath)) { throw "Config not found: $ConfigPath" }
    $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    if (-not $GatewayUrl -and $cfg.gatewayUrl) { $GatewayUrl = $cfg.gatewayUrl }
    if ($cfg.models) {
        $o = $cfg.models | Where-Object { $_ -match 'opus' }   | Select-Object -First 1
        $s = $cfg.models | Where-Object { $_ -match 'sonnet' } | Select-Object -First 1
        if ($o) { $OpusModel = $o }
        if ($s) { $SonnetModel = $s }
    }
}

if (-not $GatewayUrl) {
    throw 'Pass -GatewayUrl, or -ConfigPath pointing at onboarding/claude-gateway.json.'
}
if (-not $HaikuModel) { $HaikuModel = $SonnetModel }

# Default model set per tier. Standard gets the Sonnet-class model, premium gets
# both. An operator can override with -AvailableModels; whatever is chosen has
# to be mirrored into the gateway's models-{tier} named value, because that is
# the copy that is enforced.
if (-not $AvailableModels) {
    $AvailableModels = if ($Tier -eq 'premium') { @($OpusModel, $SonnetModel, $HaikuModel) } else { @($SonnetModel, $HaikuModel) }
}
$AvailableModels = @($AvailableModels | Select-Object -Unique)

# ------------------------------------------------------------------- policy

# env is the mechanism that actually redirects Claude Code at the gateway.
# CLAUDE_CODE_USE_FOUNDRY selects the Foundry provider, and the base URL points
# at API Management rather than the Foundry endpoint directly, so budgets,
# tiering and chargeback apply. No API key: the gateway takes the developer's
# own Entra token.
$settings = [ordered]@{
    env = [ordered]@{
        CLAUDE_CODE_USE_FOUNDRY        = '1'
        ANTHROPIC_FOUNDRY_BASE_URL     = $GatewayUrl
        ANTHROPIC_DEFAULT_OPUS_MODEL   = $OpusModel
        ANTHROPIC_DEFAULT_SONNET_MODEL = $SonnetModel
        ANTHROPIC_DEFAULT_HAIKU_MODEL  = $HaikuModel
    }
    availableModels = @($AvailableModels)
}

# Claude Desktop reads its own keys. They are emitted here so one run produces
# one tier's complete profile rather than two half-profiles that can drift.
$desktop = [ordered]@{
    chatTabEnabled                = $true
    coworkTabEnabled              = ($DesktopTabs -eq 'default')
    isClaudeCodeForDesktopEnabled = ($DesktopTabs -ne 'chat-only')
}

if ($Hardening -ne 'none') {
    # Reading a .env or a private key is the common way a credential leaves a
    # machine through an agent. Denying it centrally means a project-level
    # settings file cannot allow it back.
    $settings['permissions'] = [ordered]@{
        deny = @(
            'Read(./.env)',
            'Read(./.env.*)',
            'Read(./secrets/**)',
            'Read(**/id_rsa)',
            'Read(**/*.pem)'
        )
    }
}

if ($Hardening -eq 'strict') {
    $settings['permissions']['disableBypassPermissionsMode'] = 'disable'
    # Without this, a repo's own .claude/settings.json can widen what is allowed.
    $settings['allowManagedPermissionRulesOnly'] = $true
}

# ------------------------------------------------- conversation history mode

switch ($ConversationStorage) {
    'redirected' {
        if (-not $ConfigDir) {
            throw 'ConversationStorage "redirected" needs -ConfigDir, the path to redirect history to.'
        }
        # Relocates settings, session history and plugins wholesale. Point it at
        # something that is actually backed up: a redirected folder, an Azure
        # Files share, an FSLogix container.
        #
        # Do not point it at a file-sync client that syncs continuously. Session
        # transcripts are written while Claude Code runs, and a sync client that
        # copies a file mid-write produces a corrupt transcript rather than a
        # backed-up one. FSLogix or folder redirection to a share is the right
        # shape; OneDrive on the same folder is not.
        $settings.env['CLAUDE_CONFIG_DIR'] = $ConfigDir
    }
    'audited' {
        if (-not $OtlpEndpoint) {
            throw 'ConversationStorage "audited" needs -OtlpEndpoint, your OpenTelemetry collector.'
        }
        $settings.env['CLAUDE_CODE_ENABLE_TELEMETRY'] = '1'
        $settings.env['OTEL_LOGS_EXPORTER'] = 'otlp'
        $settings.env['OTEL_METRICS_EXPORTER'] = 'otlp'
        $settings.env['OTEL_EXPORTER_OTLP_PROTOCOL'] = 'grpc'
        $settings.env['OTEL_EXPORTER_OTLP_ENDPOINT'] = $OtlpEndpoint

        if ($CaptureContent) {
            # Off by default in Claude Code, and deliberately opt-in here too.
            # This exports what people typed and what the model replied. It is
            # what makes the history discoverable, and it is also a change in
            # what the organisation is collecting - it belongs in a privacy
            # review and usually in a works-council or employee notice, not in
            # a default.
            $settings.env['OTEL_LOG_USER_PROMPTS'] = '1'
            $settings.env['OTEL_LOG_ASSISTANT_RESPONSES'] = '1'
        }
    }
}

$json = $settings | ConvertTo-Json -Depth 8

# ------------------------------------------------------------------- outputs

New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null
$base = Join-Path $OutputPath 'claude-code'
$written = @()
function Save($path, $content, $encoding = 'UTF8') {
    Set-Content -Path $path -Value $content -Encoding $encoding
    $script:written += (Split-Path $path -Leaf)
}

Save "$base.managed-settings.json" $json

# .reg carries the whole JSON as one REG_SZ named Settings. Backslashes and
# quotes are escaped for the .reg format, and the file must be UTF-16 or
# regedit rejects it.
$regEscaped = $json -replace '\\', '\\\\' -replace '"', '\"'
$regEscaped = ($regEscaped -split "`r?`n" | ForEach-Object { $_.Trim() }) -join ''
$reg = @"
Windows Registry Editor Version 5.00

; Claude Code managed settings.
; HKLM outranks the managed-settings.json file. With the default first-wins
; behaviour, deploying both means this wins and the file is ignored.
[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\ClaudeCode]
"Settings"="$regEscaped"
"@
Save "$base.reg" $reg 'Unicode'

$omaValue = $regEscaped -replace '"', '""'
$oma = @"
"OMA-URI","Data type","Value"
"./Device/Vendor/MSFT/Policy/Config/ClaudeCode/Settings","String","$omaValue"
"@
Save "$base.intune-omauri.csv" $oma

$plistEntries = ($settings.env.GetEnumerator() | ForEach-Object {
    "            <key>$($_.Key)</key>`n            <string>$($_.Value)</string>"
}) -join "`n"

$mobileconfig = @"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>PayloadDisplayName</key><string>Claude Code - Microsoft Foundry gateway</string>
  <key>PayloadIdentifier</key><string>com.anthropic.claudecode.foundry</string>
  <key>PayloadType</key><string>Configuration</string>
  <key>PayloadUUID</key><string>$([guid]::NewGuid())</string>
  <key>PayloadVersion</key><integer>1</integer>
  <key>PayloadScope</key><string>System</string>
  <key>PayloadContent</key>
  <array>
    <dict>
      <key>PayloadType</key><string>com.anthropic.claudecode</string>
      <key>PayloadIdentifier</key><string>com.anthropic.claudecode.foundry.settings</string>
      <key>PayloadUUID</key><string>$([guid]::NewGuid())</string>
      <key>PayloadVersion</key><integer>1</integer>
      <key>PayloadDisplayName</key><string>Managed settings</string>
      <key>env</key>
      <dict>
$plistEntries
      </dict>
    </dict>
  </array>
</dict>
</plist>
"@
Save "$base.mobileconfig" $mobileconfig

$apply = @"
# Applies the policy on this machine, for piloting before a fleet rollout.
# Needs an elevated shell: it writes under Program Files.
#Requires -RunAsAdministrator

`$dir = 'C:\Program Files\ClaudeCode'
New-Item -ItemType Directory -Force -Path `$dir | Out-Null
Copy-Item "`$PSScriptRoot\claude-code.managed-settings.json" (Join-Path `$dir 'managed-settings.json') -Force

Write-Host "Written: `$dir\managed-settings.json" -ForegroundColor Green
Write-Host 'Verify with /status inside Claude Code - Setting sources should read' -ForegroundColor DarkGray
Write-Host '"Enterprise managed settings (file)".' -ForegroundColor DarkGray
"@
Save "$base.apply.ps1" $apply

$readme = @"
Claude Code managed settings - Microsoft Foundry gateway
========================================================

Gateway : $GatewayUrl
Models  : $OpusModel, $SonnetModel, $HaikuModel
Harden  : $Hardening
History : $ConversationStorage$(if ($ConfigDir) { " -> $ConfigDir" })$(if ($OtlpEndpoint) { " -> $OtlpEndpoint" })$(if ($CaptureContent) { ' (content capture ON)' })

Where conversation history lives
--------------------------------
Claude Code keeps session transcripts, CLAUDE.md memory and settings on the
local disk, under ~/.claude. That is provider-independent: moving to Foundry
does not touch any of it. It also means that by default nothing roams, nothing
is backed up, and a reimaged laptop loses the lot.

This policy is set to: $ConversationStorage

  local       Device only. Simplest, and nothing leaves the machine. Accept
              that history is lost with the device.

  redirected  CLAUDE_CONFIG_DIR moves settings, session history and plugins to
              a path you control, so they roam and get backed up with the rest
              of the profile. Use folder redirection to a share, Azure Files,
              or an FSLogix container.

              Do NOT point this at a continuously syncing client such as
              OneDrive on the same folder. Transcripts are written while
              Claude Code is running, and a sync client that copies a file
              mid-write produces a corrupt transcript rather than a backup.

  audited     Local working copy, plus an OpenTelemetry export to your own
              collector, which is what gives you retention, chargeback and
              something to search for eDiscovery. Metadata only unless content
              capture is switched on:

                  OTEL_LOG_USER_PROMPTS
                  OTEL_LOG_ASSISTANT_RESPONSES

              Both are off by default. Turning them on exports what people
              typed and what the model replied. That is a change in what the
              organisation collects: put it through privacy review, and in most
              jurisdictions tell the people it affects.

The three are not exclusive. A common shape is redirected for continuity plus
audited for the compliance record.

Claude Desktop has the equivalent controls under different names - otlpEndpoint
and otlpContentCapture, whose categories are userPrompts, assistantResponses,
toolDetails, toolContent and rawApiBodies. See the Desktop accelerator.

Pick ONE mechanism per machine
------------------------------
When more than one managed source reaches a machine, the default behaviour is
first-wins, not merge: the highest-ranked source that supplies any policy key
wins and the others are ignored, with no warning. The order is

    remote  >  MDM / HKLM  >  managed-settings.json  >  HKCU

so shipping both the .reg and the .json means the .reg wins. Set
managedSourcesBehavior to "merge" only if you deliberately want them combined.

Note that server-managed settings from the claude.ai admin console do NOT apply
to this deployment. Claude Code fetches those only when the session
authenticates to Anthropic's API directly; pointing it at your own gateway
makes it skip that source. MDM or the file is the mechanism here.

Windows, Intune
---------------
Devices > Configuration > Create > Windows 10 and later > Templates > Custom.
Import claude-code.intune-omauri.csv, or add the row by hand:

    OMA-URI    ./Device/Vendor/MSFT/Policy/Config/ClaudeCode/Settings
    Data type  String

Windows, Group Policy or a run-once script
------------------------------------------
Import claude-code.reg, which writes HKLM\SOFTWARE\Policies\ClaudeCode.
The file is UTF-16; keep it that way or regedit will refuse it.

Windows, file-based
-------------------
Copy claude-code.managed-settings.json to

    C:\Program Files\ClaudeCode\managed-settings.json

Not C:\ProgramData\ClaudeCode\ - that older path is no longer read.

macOS, Jamf or Intune
---------------------
Deploy claude-code.mobileconfig. It targets the com.anthropic.claudecode
managed preferences domain. Or place the JSON at

    /Library/Application Support/ClaudeCode/managed-settings.json

Linux and WSL
-------------
    /etc/claude-code/managed-settings.json

Verify
------
On one machine, run /status inside Claude Code. The "Setting sources" line
names the source that applied, and the ones it skipped. Then check the gateway
is actually in the path - a request should carry x-governed-by, and App
Insights should show the call.

Cowork
------
Cowork sessions in Claude Desktop run on Claude Code and read this policy from
the device - but not when your Desktop configuration sets
requireCoworkFullVmSandbox, because the VM has no device policy, and not for
remote Cowork sessions on Anthropic-managed VMs. If you enforce the full VM
sandbox, Cowork will not pick up this gateway configuration.

What is deliberately not here
-----------------------------
No API key, and no credential of any kind. Claude Code acquires the developer's
own Entra token through the default Azure credential chain, and the gateway
exchanges it for its own managed identity. Entitlement is Entra group
membership, so removing someone from the group removes their access without
touching any machine.

forceLoginMethod and forceLoginOrgUUID can additionally stop a developer
signing in to a personal Claude account. They are not set here because the
accepted values were not confirmed at the time of writing - see
https://code.claude.com/docs/en/settings-reference before adding them.
"@
Save "$base.README.txt" $readme

Write-Host ''
Write-Host "Written to $OutputPath" -ForegroundColor Cyan
$written | Sort-Object | ForEach-Object { Write-Host "  $_" }
Write-Host ''
Write-Host 'Pick ONE mechanism per machine - the default is first-wins, not merge.' -ForegroundColor Yellow
Write-Host 'Read the README before deploying.' -ForegroundColor DarkGray
Write-Host ''
