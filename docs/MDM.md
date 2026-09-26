# Fleet deployment with Intune, Jamf or Group Policy

This guide covers device delivery for Claude Code, the VS Code extension and
Claude Desktop when inference is governed by the Microsoft Foundry gateway.
History migration and first-party cutover remain in
[Migration section 2](MIGRATION.md#2-mass-deployment-through-mdm); this page
does not repeat that migration runbook.

**Scope.** The device receives software, managed settings and optional network
trust. The user still performs `az login` in the correct tenant, because MDM
cannot complete an interactive Entra sign-in on behalf of a developer.

**Sources fetched 2026-09-26.**

| Area | Reference |
|---|---|
| Claude Code managed settings, precedence, HKLM/HKCU and file paths | https://code.claude.com/docs/en/managed-settings |
| Claude Code install methods, Windows/macOS requirements, `claude doctor` | https://code.claude.com/docs/en/setup |
| VS Code extension install and bundled CLI behavior | https://code.claude.com/docs/en/ide-integrations |
| Claude Desktop MDM workflow and stores | https://claude.com/docs/third-party/claude-desktop/mdm |
| Claude Desktop managed configuration keys and value encoding | https://claude.com/docs/third-party/claude-desktop/configuration |
| Microsoft Foundry Claude Desktop fleet deployment note | https://learn.microsoft.com/en-us/azure/foundry/foundry-models/how-to/configure-claude-desktop |
| Intune Windows custom OMA-URI profiles | https://learn.microsoft.com/en-us/intune/device-configuration/templates/configure-custom-settings-windows |
| Intune OMA-URI and CSP delivery model | https://learn.microsoft.com/en-us/troubleshoot/mem/intune/device-configuration/deploy-oma-uris-to-target-csp-via-intune |
| Intune ADMX/settings catalog behavior | https://learn.microsoft.com/en-us/intune/device-configuration/settings-catalog/configure-admx-templates-windows |
| Intune PowerShell scripts and monitoring | https://learn.microsoft.com/en-us/intune/device-management/tools/run-powershell-scripts-windows |
| Intune Management Extension | https://learn.microsoft.com/en-us/intune/device-management/tools/management-extension-windows |
| Intune Remediations | https://learn.microsoft.com/en-us/intune/device-management/tools/deploy-remediations |
| Intune Win32 app management | https://learn.microsoft.com/en-us/intune/app-management/deployment/win32 |
| Intune Microsoft Store app deployment | https://learn.microsoft.com/en-us/intune/app-management/deployment/add-microsoft-store |
| Intune macOS custom `.mobileconfig` profiles | https://learn.microsoft.com/en-us/intune/device-configuration/templates/configure-custom-settings-apple |
| Intune macOS PKG and DMG deployment | https://learn.microsoft.com/en-us/intune/app-management/deployment/add-lob-macos, https://learn.microsoft.com/en-us/intune/app-management/deployment/add-dmg-macos |
| Intune assignment user-group and device-group behavior | https://learn.microsoft.com/en-us/intune/device-configuration/assign-device-profile |

## 1. Device contract

| Delivered item | Reason | Windows channel | macOS channel | Notes |
|---|---|---|---|---|
| Azure CLI | `az login` and the credential helper obtain the developer's Entra token | Microsoft Store app, Win32 app, winget script or existing software portal | PKG/DMG app deployment or existing software portal | Device install is managed; user sign-in is not. |
| Claude Code CLI | Terminal client and the engine used by the VS Code extension and Desktop Code/Cowork | Native installer, winget package `Anthropic.ClaudeCode`, Win32 app or software portal | Native installer or Homebrew package through a script/app channel | Anthropic documents native install (`irm https://claude.ai/install.ps1 \| iex` on Windows; `curl -fsSL https://claude.ai/install.sh \| bash` on macOS/Linux), Homebrew and WinGet. |
| VS Code | IDE host for the Claude Code extension | Microsoft Store app (new), Win32 app or software portal | PKG/DMG app deployment or software portal | VS Code 1.94.0 or later is documented by Anthropic for the extension. |
| Claude Code VS Code extension | IDE surface that reads the same managed settings as Claude Code | User or device script running `code --install-extension anthropic.claude-code`, or an editor-extension management channel | Shell script or editor-extension management channel | The extension bundles a CLI for the panel; the standalone CLI is still required for `claude` in the integrated terminal. |
| Claude Desktop | Chat, Cowork and Code desktop surface | Win32 app, Microsoft Store app if available in the tenant, or software portal | PKG or DMG app deployment | Managed configuration should arrive before first launch so users land in third-party mode. |
| Claude Code managed settings | Gateway URL, Foundry provider flag, tier model list and permission hardening | `HKLM\SOFTWARE\Policies\ClaudeCode` value `Settings`; or `C:\Program Files\ClaudeCode\managed-settings.json`; HKCU only for a pilot where higher sources are absent | `com.anthropic.claudecode` `.mobileconfig`; or `/Library/Application Support/ClaudeCode/managed-settings.json` | Claude Code source order is remote, MDM/HKLM, file, HKCU by default. The legacy `C:\ProgramData\ClaudeCode\managed-settings.json` path is not read. |
| Claude Desktop managed configuration | Desktop gateway connection, tabs, plugins and the P60 sign-in choice | `HKLM\SOFTWARE\Policies\Claude` values directly under the key | `com.anthropic.claudefordesktop` `.mobileconfig` | Desktop Windows values are strings directly under the policy key; subkeys are ignored. HKLM suppresses HKCU. |
| Optional CA certificate or proxy/PAC | Private edge, TLS inspection or corporate egress | Intune certificate/profile, proxy profile or platform script | Intune certificate/profile or shell script | Network choices and private-edge proof are in [Network Enterprise](NETWORK-ENTERPRISE.md). |
| Per-user `az login` | Entra token issuance for the developer | User terminal: `az login --tenant <tenant-id>` | User terminal: `az login --tenant <tenant-id>` | A device deployment cannot assert that the user completed sign-in. |

No new ADR is recorded for this packet. The existing decision remains: device
policy is delivered by the customer's device-management plane, while entitlement,
budgets and model allowlists are enforced at the gateway.

## 2. Generate the profiles

Run profile generation from the repository root after the gateway deployment has
written `onboarding/claude-gateway.json`, or after the platform owner supplies
the explicit gateway URL and model names.

```powershell
# Standard tier
.\scripts\New-ClaudeCodePolicy.ps1 `
  -ConfigPath .\onboarding\claude-gateway.json `
  -Tier standard `
  -OutputPath .\policy-claude-code-standard

# Premium tier
.\scripts\New-ClaudeCodePolicy.ps1 `
  -ConfigPath .\onboarding\claude-gateway.json `
  -Tier premium `
  -OutputPath .\policy-claude-code-premium
```

For a read-only discovery run against an existing gateway:

```powershell
$apim = az apim list --query "[].{name:name,rg:resourceGroup,gatewayUrl:gatewayUrl}" -o json |
  ConvertFrom-Json |
  Out-GridView -Title 'Select the Claude gateway' -PassThru

.\scripts\New-ClaudeCodePolicy.ps1 `
  -GatewayUrl ($apim.gatewayUrl.TrimEnd('/') + '/claude') `
  -Tier standard `
  -OutputPath .\policy-claude-code-standard
```

The generator outputs one tier's payloads:

| Output file | Use |
|---|---|
| `claude-code.managed-settings.json` | File-based policy for `C:\Program Files\ClaudeCode\managed-settings.json`, `/Library/Application Support/ClaudeCode/managed-settings.json`, or `/etc/claude-code/managed-settings.json`. |
| `claude-code.reg` | Windows Group Policy, Intune script or pilot import for `HKLM\SOFTWARE\Policies\ClaudeCode`. |
| `claude-code.intune-omauri.csv` | Intune custom OMA-URI row with `./Device/Vendor/MSFT/Policy/Config/ClaudeCode/Settings`, data type `String`, and the JSON policy as the value. The CSV records the intended row; Windows only applies it if the tenant also has a matching custom ADMX/Policy CSP route for the `ClaudeCode` policy area. In tenants without that ADMX ingestion, a platform script, remediation or Win32 app script is the deterministic registry writer. |
| `claude-code.mobileconfig` | macOS custom configuration profile for the `com.anthropic.claudecode` managed preferences domain. |
| `claude-code.apply.ps1` | Local elevated pilot that writes the file-based policy under Program Files. It is not used by Intune directly. |
| `claude-code.README.txt` | Generated operator notes for that tier. |
| `claude-desktop.managed-settings.json` | Desktop Linux JSON and a readable source for Windows/macOS managed Desktop keys. |
| `claude-desktop.reg` | Windows Desktop policy values under `HKLM\SOFTWARE\Policies\Claude`. |

P60 adds the admin's `desktopSignIn` choice to
`onboarding/claude-gateway.json`. After P60 is on `main`, the same generator run
emits either helper-script Desktop keys or `external-idp` keys
(`inferenceCredentialKind`, `inferenceIdpOidc`, `inferenceIdpAuthFlow`) that
match that recorded choice. This packet does not copy P60 code by hand.

## 3. Intune on Windows

### 3.1 Claude Code policy

| Step | Intune admin center path and values |
|---|---|
| 1 | `https://intune.microsoft.com` > **Devices** > **Manage devices** > **Configuration** > **Create** > **New policy**. |
| 2 | **Platform**: `Windows 10 and later`; **Profile type**: `Templates` > `Custom`, when a working OMA-URI/ADMX mapping exists for the `ClaudeCode` policy area. |
| 3 | **OMA-URI row** from `claude-code.intune-omauri.csv`: name `Claude Code managed settings`; OMA-URI `./Device/Vendor/MSFT/Policy/Config/ClaudeCode/Settings`; data type `String`; value equal to the generated JSON string. |
| 4 | **Assignments**: the Entra tier user group, when the policy must follow entitled users across devices; or a device group, when the machine is dedicated and every user on it should receive the same tier. Microsoft documents that user-group policy follows the user, while device-group policy stays with the device. |
| 5 | **Review + create** creates the profile. **Device status** and **Per setting status** show delivery. |

Plain blade path for runbooks and screenshots:
Devices > Manage devices > Configuration.

The generated OMA-URI CSV is a portable record of the intended custom row. It
does not create an ADMX file. Microsoft documents custom OMA-URI profiles as
containers for CSP paths; the Windows CSP must understand the path. A fresh
Intune tenant does not automatically know a third-party `ClaudeCode` Policy CSP
area. The deterministic Windows delivery choices are therefore:

| Mechanism | Intune path | Use |
|---|---|---|
| Platform script | **Devices** > **Scripts and remediations** > **Platform scripts** > **Add** > **Windows 10 and later** | Writes `HKLM:\SOFTWARE\Policies\ClaudeCode` value `Settings` from the generated JSON. Microsoft documents script assignment to Entra user or device groups and **Device status** / **User status** monitoring. |
| Remediation | **Devices** > **Manage devices** > **Scripts and remediations** > **Create script package** | Detection checks the registry value hash; remediation writes the generated value when missing or drifted. Microsoft documents that remediation runs only when detection exits `1`. |
| Win32 app script installer | **Apps** > **All apps** > **Create** > **Windows app (Win32)** | Packages the policy as a required app with install and uninstall commands. Detection rules check the registry value or file hash. Microsoft documents silent installation, detection rules and app device status. |
| Custom ADMX + Settings catalog | **Devices** > **Manage devices** > **Configuration** > **Import ADMX**, then **Settings catalog** | Schema-managed registry policy if the organization authors and imports a Claude Code ADMX. Values still need the same JSON payload. |

Example platform script body:

```powershell
$ErrorActionPreference = 'Stop'
$settings = @'
<paste claude-code.managed-settings.json as one JSON document>
'@
$key = 'HKLM:\SOFTWARE\Policies\ClaudeCode'
New-Item -Path $key -Force | Out-Null
New-ItemProperty -Path $key -Name Settings -PropertyType String -Value $settings -Force | Out-Null
```

Example uninstall or rollback body:

```powershell
$key = 'HKLM:\SOFTWARE\Policies\ClaudeCode'
Remove-ItemProperty -Path $key -Name Settings -ErrorAction SilentlyContinue
if (Test-Path $key) {
  $remaining = Get-ItemProperty -Path $key
  if ($remaining.PSObject.Properties.Name -notcontains 'Settings') {
    Remove-Item -Path $key -Recurse -Force -ErrorAction SilentlyContinue
  }
}
```

Example detection script:

```powershell
$expected = '<sha256 of claude-code.managed-settings.json>'
$value = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\ClaudeCode' -Name Settings -ErrorAction SilentlyContinue).Settings
if (-not $value) { exit 1 }
$actual = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($value))).ToLowerInvariant()
if ($actual -eq $expected) { exit 0 }
exit 1
```

### 3.2 Claude Desktop policy

Desktop policy values belong directly under
`HKLM\SOFTWARE\Policies\Claude`. A platform script, remediation or Win32 app
script writes the generated `claude-desktop.reg` values. Each object or array is
a JSON document encoded as a single string; booleans are strings. Subkeys are
not read by Desktop.

Example registry import in a platform script:

```powershell
reg.exe import .\claude-desktop.reg
```

Desktop reads configuration at launch. A restart of Claude Desktop is part of
the deployment window.

### 3.3 App deployment

| App | Intune app path | Field values |
|---|---|---|
| Azure CLI | **Apps** > **All apps** > **Create** > **Microsoft Store app (new)** where available, or **Windows app (Win32)** | Required assignment to developer user groups or device groups. Microsoft Store apps are automatically kept up to date by Intune when available. Win32 apps require silent install commands and detection rules. |
| Claude Code CLI | **Apps** > **All apps** > **Create** > **Windows app (Win32)** | Install command from the organization-approved package, winget wrapper, or native installer wrapper. Detection: `claude --version` or file path/version. |
| VS Code | **Microsoft Store app (new)** or **Windows app (Win32)** | Store search for Visual Studio Code where available; otherwise Win32 package. |
| Claude Code VS Code extension | Platform script or Win32 app dependency after VS Code | `code --install-extension anthropic.claude-code` in the user's install context when the extension must be per user. |
| Claude Desktop | **Windows app (Win32)** or software portal package | Required assignment after the Desktop policy profile; silent install; detection by Desktop install path/version. |

### 3.4 Assignment, monitoring, update and rollback

| Operation | Intune path and expected state |
|---|---|
| Assignment | Profile/app **Properties** > **Assignments** > **Edit** > **Included groups**. User groups align with Entra tier entitlement; device groups apply the same policy for every user on the device. |
| Status | Configuration profile > **Monitor** > **Device status** and **Per setting status**; scripts > **Monitor** > **Device status** / **User status**; apps > selected app > **Monitor** > **Device install status**. |
| Update | Generate a new tier profile, update the platform script/remediation/app content, and confirm pilot device status before broad assignment. |
| Rollback | Remove the assignment for profiles that the CSP removes cleanly; run the rollback script for registry values because Microsoft documents that removing some custom policy assignments might not revert the setting. For Win32 apps, assign **Uninstall** where packaging supports it. |

## 4. Intune on macOS

### 4.1 Claude Code custom profile

| Step | Intune admin center path and values |
|---|---|
| 1 | **Devices** > **Manage devices** > **Configuration** > **Create** > **New policy**. |
| 2 | **Platform**: `macOS`; **Profile type**: `Templates` > `Custom`. |
| 3 | **Configuration profile name**: `Claude Code managed settings - <tier>`; **Deployment channel**: `Device channel`, unless the organization intentionally builds a per-user payload. |
| 4 | **Configuration profile file**: upload `claude-code.mobileconfig`. |
| 5 | **Assignments**: the Entra tier user group for user-following rollout, or a device group for shared/dedicated Macs. |
| 6 | **Monitor**: profile **Device status** and **Per setting status**. |

`claude-code.mobileconfig` targets `com.anthropic.claudecode`. The file-based
alternative is `/Library/Application Support/ClaudeCode/managed-settings.json`.

### 4.2 Claude Desktop profile

Desktop uses the `com.anthropic.claudefordesktop` managed preferences domain.
The generated Windows `.reg` and JSON show the keys; macOS delivery uses a
Desktop `.mobileconfig` exported from the Desktop in-app configuration window
or from the P60-enabled generator once it lands on `main`.

Claude Desktop MDM rollout order:

1. Configuration profile assigned.
2. Required firewall/proxy/certificate profile assigned.
3. Claude Desktop app assigned.
4. First launch shows the third-party gateway path instead of a claude.ai
   account path.

### 4.3 macOS apps and scripts

| Item | Intune path | Field values |
|---|---|---|
| Azure CLI, VS Code, Claude Desktop | **Apps** > **All apps** > **Create** > macOS **Line-of-business app**, **macOS app (PKG)**, or **macOS app (DMG)** depending on the approved installer | Microsoft documents signed PKG LOB requirements and DMG requirements. Required assignment to the pilot group first. |
| Claude Code CLI | App package or shell script | Native install, Homebrew, or organization package. Homebrew-managed installs require update management outside Claude Code auto-update. |
| VS Code extension | Shell script after VS Code | `code --install-extension anthropic.claude-code`; user context may be required depending on the VS Code deployment. |
| CA certificate/proxy | Device configuration profile | Certificate trust and proxy/PAC profiles before app first run. |

## 5. Jamf Pro and Group Policy alternatives

| Tool | Steps |
|---|---|
| Jamf Pro | **Computers** > **Configuration Profiles** > **New** > **Application & Custom Settings** > upload the Claude Code `.mobileconfig` for `com.anthropic.claudecode` and the Desktop `.mobileconfig` for `com.anthropic.claudefordesktop`; scope each profile to the tier smart group; monitor profile status; deploy PKG/DMG packages through Jamf policies. |
| Windows Group Policy | Computer Configuration policy preference or startup script writes `HKLM\SOFTWARE\Policies\ClaudeCode` value `Settings` and Desktop values under `HKLM\SOFTWARE\Policies\Claude`. `claude-code.reg` and `claude-desktop.reg` are UTF-16 registry imports. Group Policy Preferences can also delete those values for rollback. |
| File distribution | A software-distribution tool copies `claude-code.managed-settings.json` to `C:\Program Files\ClaudeCode\managed-settings.json`, `/Library/Application Support/ClaudeCode/managed-settings.json`, or `/etc/claude-code/managed-settings.json`. This is lower precedence than MDM/HKLM. |

## 6. Verify one device

### 6.1 Windows commands

```powershell
# Claude Code policy source
reg query HKLM\SOFTWARE\Policies\ClaudeCode /v Settings
reg query HKCU\SOFTWARE\Policies\ClaudeCode /v Settings
Test-Path 'C:\Program Files\ClaudeCode\managed-settings.json'

# Desktop policy source
reg query HKLM\SOFTWARE\Policies\Claude
reg query HKCU\SOFTWARE\Policies\Claude

# Isolated Claude Code diagnostics
$env:CLAUDE_CONFIG_DIR = "$env:TEMP\claude-mdm-empty"
New-Item -ItemType Directory -Force -Path $env:CLAUDE_CONFIG_DIR | Out-Null
claude doctor
claude -p "Respond with exactly P65-OK." --output-format json
Remove-Item Env:\CLAUDE_CONFIG_DIR
```

`claude doctor` names third-party provider state and managed-source problems.
An interactive Claude Code session also shows source precedence in `/status`.
When no managed source is present, `/status` and `doctor` do not prove policy
application.

### 6.2 macOS commands

```bash
profiles show -type configuration | grep -E 'com.anthropic.claudecode|com.anthropic.claudefordesktop'
plutil -p "/Library/Managed Preferences/com.anthropic.claudecode.plist"
plutil -p "/Library/Managed Preferences/com.anthropic.claudefordesktop.plist"
test -f "/Library/Application Support/ClaudeCode/managed-settings.json" && cat "/Library/Application Support/ClaudeCode/managed-settings.json"
CLAUDE_CONFIG_DIR="$(mktemp -d)" claude doctor
CLAUDE_CONFIG_DIR="$(mktemp -d)" claude -p "Respond with exactly P65-OK." --output-format json
```

### 6.3 Desktop checks

Claude Desktop configuration is read at launch. A full quit and reopen is part
of verification. The visible checks are:

| Check | Expected state |
|---|---|
| Sign-in screen | The third-party gateway path is available; users are not directed to Google/email for the governed path. |
| Settings > Connection | Gateway URL or configured third-party provider appears. |
| Plugin browser, when blocked | Add-marketplace and upload routes are absent. |
| Logs | Linux logs name rejected `managed-settings.json` or schema errors. Windows/macOS policy errors are checked through the managed profile and registry/plist state. |

### 6.4 Live request proof

The proof command sends a tiny prompt through Claude Code with an empty
`CLAUDE_CONFIG_DIR`. A successful JSON result has:

| Field | Meaning |
|---|---|
| `provider: "foundry"` under `modelUsage` | The client used Microsoft Foundry, not api.anthropic.com. |
| `result: "P65-OK"` | The request completed. |
| `terminal_reason: "completed"` and `is_error: false` | Claude Code completed the turn. |
| Gateway telemetry | The platform owner can join the request by UTC timestamp, user object id and model in Application Insights. |

## 7. Live validation on this workstation

Validation ran on 2026-09-26 UTC against the read-only reference gateway
`apim-claude-gw-fzgql9` in `rg-contosohub`.

| Check | Result |
|---|---|
| Profile generation | `New-ClaudeCodePolicy.ps1` generated `claude-code.managed-settings.json`, `claude-code.intune-omauri.csv`, `claude-code.mobileconfig`, `claude-code.reg`, `claude-desktop.managed-settings.json` and `claude-desktop.reg` outside the repository. |
| HKCU policy pilot | Blocked by workstation ACL before any policy write: `HKCU\SOFTWARE\Policies` is owned by SYSTEM and grants this user read-only access. No HKLM, Program Files or ACL change was attempted. |
| Restore proof | Before state: `HKCU\SOFTWARE\Policies\ClaudeCode` absent. After state: `HKCU\SOFTWARE\Policies\ClaudeCode` absent. Restore comparison: true. |
| Generated settings request | The generated policy `env` was applied to the process with an empty `CLAUDE_CONFIG_DIR`. `claude doctor` reported Microsoft Foundry mode. `claude -p "Respond with exactly P65-OK." --output-format json` returned `result: "P65-OK"`, `provider: "foundry"`, `terminal_reason: "completed"`, `is_error: false`. |
| Terminal evidence | Redacted rendered transcripts are stored outside the repository in the session artifact folder: `p65-live-validation\hkcu-validation.png` and `p65-live-validation\env-validation.png`. |

The Intune admin center screenshots were not captured. This account has no
Intune administrator role in the tenant. No sign-in flow, role request or
portal mutation was attempted. A tenant with Intune rights can capture:
Intune administrator role was not available for this live validation.

| Capture | Blade and expected state |
|---|---|
| Windows custom profile | Intune admin center > **Devices** > **Manage devices** > **Configuration** > selected Claude Code profile > **Properties**; OMA-URI row visible or script/remediation link visible. |
| Windows script/remediation status | **Devices** > **Scripts and remediations** > selected script package > **Monitor** > **Device status**; pilot device succeeded. |
| Windows app status | **Apps** > **All apps** > selected Claude app > **Monitor** > **Device install status**; pilot device installed. |
| macOS custom profile | **Devices** > **Manage devices** > **Configuration** > selected macOS profile > **Properties**; uploaded `.mobileconfig` and assignment visible. |
| macOS app status | **Apps** > **All apps** > selected macOS app > **Monitor** > install status; pilot device installed. |
| Assignment | Selected profile/app > **Properties** > **Assignments**; included Entra tier group visible and no broad group accidentally included. |

Rollback for a successful HKCU pilot would remove the HKCU policy and compare
the before/after registry value. The live run reached the same restored state
because the policy key could not be created.

## 8. Troubleshooting

| Symptom | Likely cause | Check |
|---|---|---|
| `/status` or `claude doctor` does not show managed settings | Policy landed in a lower-precedence source or did not land | Check remote/MDM/file/HKCU order; check `reg query` or profile/plist. |
| File under `C:\ProgramData\ClaudeCode` is ignored | Legacy path | Use `C:\Program Files\ClaudeCode\managed-settings.json`. |
| Registry policy does not apply | Value under a subkey, wrong hive, malformed JSON, or HKLM shadowing HKCU | Windows Claude Code expects `HKLM\SOFTWARE\Policies\ClaudeCode` value `Settings`; Desktop expects values directly under `HKLM\SOFTWARE\Policies\Claude`. |
| Desktop ignores HKCU | HKLM has any readable policy value | Desktop HKLM suppresses HKCU; consolidate the full configuration into one hive. |
| A standard user receives premium models | Device-group assignment applies the machine profile to every user | Use user-group assignment for tier-specific user entitlement, or restrict the device group to dedicated devices. |
| Entitled user receives 403 | Entra group changed but gateway entitlement store was not published | Run the onboarding publication path for the active store, then retry with a fresh token. |
| Request fails before the gateway | User not signed in to Azure CLI or signed into the wrong tenant | `az account show`; then `az login --tenant <tenant-id> --allow-no-subscriptions` when the user has no subscription role. |
| Intune OMA-URI shows success but registry key is absent | The custom CSP/ADMX path did not map to the third-party registry location | Use platform script, remediation or Win32 app script to write the registry value deterministically. |
| Claude Desktop policy values appear but app stays local | App was already running or policy only contains app-behavior keys | Fully quit/reopen Desktop; verify managed keys include the connection keys. |
| Private edge works on one network only | CA certificate, proxy or PAC profile missing on the test device | Follow [Network Enterprise](NETWORK-ENTERPRISE.md) for CA/proxy/PAC checks. |
| Rollback removes assignment but device remains configured | CSP/profile removal did not delete registry values | Run the rollback script or Group Policy Preference delete action. |
