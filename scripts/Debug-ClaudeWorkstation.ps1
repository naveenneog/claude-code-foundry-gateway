<#
.SYNOPSIS
    Read-only developer workstation diagnostics for Claude on Microsoft Foundry.
#>
[CmdletBinding()]
param(
    [string]$RecordPath,
    [string]$GatewayUrl,
    [string]$TenantId,
    [switch]$NoRequest,
    [string]$SupportBundle,
    [switch]$AsJson,
    [ValidateSet('fail','warn')][string]$FailOn = 'warn'
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'ClaudeDiagnoseCommon.ps1')
# Client versions, model capabilities and bounded client commands (ADR-0031).
. (Join-Path $PSScriptRoot 'ClaudeClientSupport.ps1')
. (Join-Path $PSScriptRoot 'ClaudeDesktopSignIn.ps1')
if ($env:CLAUDE_DIAGNOSE_FORCE_NO_REQUEST) { $NoRequest = $true }
$doctorTimeout = if ($env:CLAUDE_DIAGNOSE_DOCTOR_TIMEOUT_SECONDS) { [int]$env:CLAUDE_DIAGNOSE_DOCTOR_TIMEOUT_SECONDS } else { 45 }

Write-Host ''
Write-Host 'Claude workstation diagnostics' -ForegroundColor Cyan
Write-Host ''

$record = $null
if ($RecordPath) {
    try {
        if (Test-Path -LiteralPath $RecordPath -PathType Leaf) {
            $record = Get-Content -LiteralPath $RecordPath -Raw | ConvertFrom-Json
            if (-not $GatewayUrl) { $GatewayUrl = [string](Get-ClaudeDiagnoseProperty $record 'gatewayUrl') }
            if (-not $TenantId) { $TenantId = [string](Get-ClaudeDiagnoseProperty $record 'tenantId') }
            if (Get-ClaudeDiagnoseProperty $record 'gatewayUrl') {
                Add-ClaudeDiagnoseCheck 'Decision record' 'PASS' "Loaded workstation target from $RecordPath" 'No fix needed.' 'Repository > onboarding > claude-gateway.json'
            } else {
                # The guided flow writes its decisions before the installer runs; an install that
                # stopped leaves a record with no gateway in it.
                Add-ClaudeDiagnoseCheck 'Decision record' 'WARN' "Loaded $RecordPath, but it has no gatewayUrl: the gateway setup has not finished, so there is nothing to point this workstation at." 'Finish the setup (.\Install-ClaudeGateway.ps1, or .\Start-ClaudeGateway.ps1 -Action Setup), or ask your platform team for claude-gateway.json.' 'Repository > onboarding > claude-gateway.json'
            }
        } else {
            Add-ClaudeDiagnoseCheck 'Decision record' 'WARN' "No decision record at $RecordPath" 'Pass -GatewayUrl and -TenantId, or run Start-ClaudeGateway.ps1 -Action Setup.' 'Repository > onboarding'
        }
    } catch {
        Add-ClaudeDiagnoseCheck 'Decision record' 'FAIL' $_.Exception.Message 'Repair or restore the decision record JSON.' 'Repository > onboarding'
    }
}
# A fix that tells someone to sign in names the tenant only when it is known.
$loginFix = 'az login' + $(if ($TenantId) { " --tenant $TenantId" } else { '' }) + ' --allow-no-subscriptions'

$azCmd = Get-Command az -ErrorAction SilentlyContinue
$cognitiveToken = ''
if ($azCmd) {
    Add-ClaudeDiagnoseCheck 'Azure CLI installed' 'PASS' $azCmd.Source 'Install or update with winget install Microsoft.AzureCLI.' 'https://learn.microsoft.com/cli/azure/install-azure-cli'
    $acctRaw = Get-ClaudeDiagnoseAz @('account','show','-o','json')
    $acct = ConvertFrom-ClaudeDiagnoseJson $acctRaw.Output
    if ($acct) {
        $tenantStatus = if ($TenantId -and $acct.tenantId -ne $TenantId) { 'FAIL' } else { 'PASS' }
        Add-ClaudeDiagnoseCheck 'Azure sign-in and tenant' $tenantStatus "Signed in as $($acct.user.name); tenant $($acct.tenantId)" $loginFix 'Microsoft Entra admin center > Overview'
        $tokRaw = Get-ClaudeDiagnoseAz @('account','get-access-token','--resource','https://cognitiveservices.azure.com','-o','json')
        $tok = ConvertFrom-ClaudeDiagnoseJson $tokRaw.Output
        if ($tok.accessToken) {
            $cognitiveToken = [string]$tok.accessToken
            Add-ClaudeDiagnoseCheck 'Cognitive Services token' 'PASS' 'Token obtained for https://cognitiveservices.azure.com; value not printed.' 'No fix needed.' 'Microsoft Entra admin center > Sign-in logs'
        }
        else { Add-ClaudeDiagnoseCheck 'Cognitive Services token' 'FAIL' 'Azure CLI did not return a token.' $loginFix 'Microsoft Entra admin center > Sign-in logs' }
    } else {
        Add-ClaudeDiagnoseCheck 'Azure sign-in and tenant' 'FAIL' 'az account show returned no account.' $loginFix 'Microsoft Entra admin center > Overview'
    }
} else {
    Add-ClaudeDiagnoseCheck 'Azure CLI installed' 'FAIL' 'az was not found on PATH.' 'Install Azure CLI from your managed software portal or winget install Microsoft.AzureCLI.' 'https://learn.microsoft.com/cli/azure/install-azure-cli'
}

$claudeInstalls = @(Get-ClaudeCodeInstall)
$claudeVersion = ''
if ($claudeInstalls.Count) {
    $claudePath = $claudeInstalls[0].Source
    $versionRun = Invoke-ClaudeClientCommand -Path $claudePath -Arguments @('--version') -TimeoutSeconds 30
    $claudeVersion = if ($versionRun.StartFailed -or $versionRun.TimedOut) { '' } else { $versionRun.Output }
    $others = @($claudeInstalls | Select-Object -Skip 1 | ForEach-Object { $_.Source })
    $alsoOnPath = $(if ($others.Count) { "; also on PATH, not used: $($others -join ', ')" } else { '' })
}
if ($claudeInstalls.Count -and -not $claudeVersion) {
    $why = if ($versionRun.TimedOut) { 'claude --version did not answer within 30 s' } else { $versionRun.Output }
    Add-ClaudeDiagnoseCheck 'Claude Code installed' 'FAIL' "$why$alsoOnPath" 'Reinstall Claude Code from the approved channel (claude install, or npm install -g @anthropic-ai/claude-code), then reopen the terminal.' 'Developer workstation > Apps'
}
elseif ($claudeInstalls.Count) {
    $installEvidence = "$claudeVersion at $claudePath$alsoOnPath"
    Add-ClaudeDiagnoseCheck 'Claude Code installed' 'PASS' $installEvidence 'No fix needed.' 'Developer workstation > Apps'
    # Some releases' doctor waits for a key press; it gets no input and a time limit here.
    $doctorRun = Invoke-ClaudeClientCommand -Path $claudePath -Arguments @('doctor') -TimeoutSeconds $doctorTimeout
    $doctorLines = @(($doctorRun.Output -split "\r?\n") | Where-Object { $_ -match '(?i)\b(warning|error|fix)\b' } | ForEach-Object { $_.Trim() } | Select-Object -First 8)
    if ($doctorRun.TimedOut) {
        $evidence = "claude doctor did not finish within $doctorTimeout s; this release waits for a key press." + $(if ($doctorLines.Count) { ' It reported: ' + ($doctorLines -join ' | ') } else { '' })
        Add-ClaudeDiagnoseCheck 'claude doctor' 'WARN' $evidence 'Run claude doctor in a terminal and follow its fixes; claude update brings a release whose doctor exits on its own.' 'Claude Code terminal > claude doctor'
    } elseif ($doctorLines.Count) {
        Add-ClaudeDiagnoseCheck 'claude doctor' 'WARN' ($doctorLines -join ' | ') 'Follow the fixes claude doctor names, then rerun.' 'Claude Code terminal > claude doctor'
    } else {
        Add-ClaudeDiagnoseCheck 'claude doctor' 'PASS' "No warnings in $($doctorRun.Seconds) s." 'No fix needed.' 'Claude Code terminal > claude doctor'
    }
} else {
    Add-ClaudeDiagnoseCheck 'Claude Code installed' 'FAIL' 'claude was not found on PATH.' 'Install Claude Code from the approved channel, then reopen the terminal.' 'Developer workstation > Apps'
}

$homeDir = if ($env:CLAUDE_DIAGNOSE_HOME) { $env:CLAUDE_DIAGNOSE_HOME } else { $env:USERPROFILE }
$cliSettingsPath = Join-Path $homeDir '.claude\settings.json'
$cliSettings = $null
if (Test-Path -LiteralPath $cliSettingsPath) {
    try {
        $cliSettings = Get-Content -LiteralPath $cliSettingsPath -Raw | ConvertFrom-Json
        $base = [string](Get-ClaudeDiagnoseProperty $cliSettings 'env.ANTHROPIC_FOUNDRY_BASE_URL')
        $resource = [string](Get-ClaudeDiagnoseProperty $cliSettings 'env.ANTHROPIC_FOUNDRY_RESOURCE')
        $provider = [string](Get-ClaudeDiagnoseProperty $cliSettings 'env.CLAUDE_CODE_USE_FOUNDRY')
        Add-ClaudeDiagnoseCheck 'User Claude Code settings' $(if ($provider -eq '1' -and $base) { 'PASS' } else { 'WARN' }) "settings.json provider=$provider baseURL=$base resource=$resource" 'Set CLAUDE_CODE_USE_FOUNDRY=1 and ANTHROPIC_FOUNDRY_BASE_URL to the gateway URL.' 'Developer workstation > ~/.claude/settings.json'
    } catch { Add-ClaudeDiagnoseCheck 'User Claude Code settings' 'FAIL' $_.Exception.Message 'Repair JSON in ~/.claude/settings.json.' 'Developer workstation > ~/.claude/settings.json' }
} else {
    Add-ClaudeDiagnoseCheck 'User Claude Code settings' 'WARN' "$cliSettingsPath not found." './scripts/Setup-ClaudeWorkstation.ps1 -ConfigPath .\claude-gateway.json -SkipInstall' 'Developer workstation > ~/.claude/settings.json'
}

# Claude Code sends thinking.type.enabled to a model it does not know, and the 5-series models
# refuse it with a 400. A release that knows the model, or a capability declaration, avoids it.
$recordedDeployments = @(Get-ClaudeRecordedDeployment -Config $record)
if (-not $recordedDeployments.Count -and $cliSettings) {
    $names = @('OPUS', 'SONNET', 'HAIKU' | ForEach-Object { [string](Get-ClaudeDiagnoseProperty $cliSettings "env.ANTHROPIC_DEFAULT_$($_)_MODEL") } | Where-Object { $_ } | Select-Object -Unique)
    $recordedDeployments = @(Get-ClaudeRecordedDeployment -Config ([pscustomobject]@{}) -Names $names)
}
$neededClaude = Get-ClaudeCodeRequiredVersion -Deployments $recordedDeployments
if ($claudeVersion -and $cliSettings) {
    $have = ConvertTo-ClaudeClientVersion $claudeVersion
    # Each pinned alias is judged by Get-ClaudeCodeAliasCheck, on what each Claude Code release
    # was measured to send for a declaration, or for the pinned name without one.
    $deploymentByName = @{}
    foreach ($d in $recordedDeployments) { $deploymentByName[[string]$d.name] = $d }
    $pinnedKnown = @(); $aliasChecks = @()
    foreach ($alias in 'OPUS', 'SONNET', 'HAIKU') {
        $pinnedName = [string](Get-ClaudeDiagnoseProperty $cliSettings "env.ANTHROPIC_DEFAULT_$($alias)_MODEL")
        if (-not $pinnedName) { continue }
        $variable = "ANTHROPIC_DEFAULT_$($alias)_MODEL_SUPPORTED_CAPABILITIES"
        $recorded = $deploymentByName.ContainsKey($pinnedName)
        $known = if ($recorded) { Get-ClaudeDeploymentClientSupport $deploymentByName[$pinnedName] } else { Get-ClaudeModelClientSupport -Model $pinnedName }
        if ($known) { $pinnedKnown += $alias }
        $aliasChecks += Get-ClaudeCodeAliasCheck -Variable $variable -PinnedName $pinnedName -Declared ([string](Get-ClaudeDiagnoseProperty $cliSettings "env.$variable")) -Known $known -Recorded:$recorded -Installed $claudeVersion
    }
    $failTexts = @($aliasChecks | Where-Object { $_.Status -eq 'fail' } | ForEach-Object { $_.Text })
    $warnTexts = @($aliasChecks | Where-Object { $_.Status -eq 'warn' } | ForEach-Object { $_.Text })
    $setupFix = './scripts/Setup-ClaudeWorkstation.ps1 -ConfigPath <claude-gateway.json> writes the declarations and runs claude update.'
    $behind = $neededClaude -and (Test-ClaudeClientVersionAtLeast -Installed $claudeVersion -Required $neededClaude.Version) -ne $true
    if ($failTexts.Count) {
        Add-ClaudeDiagnoseCheck 'Claude Code and the recorded models' 'FAIL' ((@($failTexts) + @($warnTexts)) -join '; ') $setupFix 'Developer workstation > ~/.claude/settings.json'
    } elseif ($behind -and -not $pinnedKnown.Count) {
        Add-ClaudeDiagnoseCheck 'Claude Code and the recorded models' 'FAIL' "Claude Code $have predates $($neededClaude.Version), the first release that knows $($neededClaude.Model), and settings.json pins no model it could declare capabilities for. Requests fail with 400 thinking.type.enabled is not supported." $setupFix 'Developer workstation > ~/.claude/settings.json'
    } elseif ($warnTexts.Count) {
        Add-ClaudeDiagnoseCheck 'Claude Code and the recorded models' 'WARN' ($warnTexts -join '; ') $setupFix 'Developer workstation > ~/.claude/settings.json'
    } elseif ($behind) {
        Add-ClaudeDiagnoseCheck 'Claude Code and the recorded models' 'WARN' "Claude Code $have predates $($neededClaude.Version), the first release that knows $($neededClaude.Model); its requests work through the capability declarations in settings.json for $($pinnedKnown -join ', ')." 'claude update' 'Developer workstation > claude --version'
    } elseif ($neededClaude) {
        Add-ClaudeDiagnoseCheck 'Claude Code and the recorded models' 'PASS' "Claude Code $have knows $($neededClaude.Model) (from $($neededClaude.Version))." 'No fix needed.' 'Developer workstation > claude --version'
    } elseif ($pinnedKnown.Count) {
        Add-ClaudeDiagnoseCheck 'Claude Code and the recorded models' 'PASS' "settings.json declares the capabilities of every pinned model ($($pinnedKnown -join ', '))." 'No fix needed.' 'Developer workstation > ~/.claude/settings.json'
    }
}

$policyRoot = if ($env:CLAUDE_DIAGNOSE_WINDOWS_POLICY_ROOT) { $env:CLAUDE_DIAGNOSE_WINDOWS_POLICY_ROOT } else { '' }
$sources = @()
if ($policyRoot) {
    foreach ($s in @(
        @{ Name='HKLM'; Path=(Join-Path $policyRoot 'HKLM\SOFTWARE\Policies\ClaudeCode\Settings.json') },
        @{ Name='file'; Path=(Join-Path $env:ProgramFiles 'ClaudeCode\managed-settings.json') },
        @{ Name='HKCU'; Path=(Join-Path $policyRoot 'HKCU\SOFTWARE\Policies\ClaudeCode\Settings.json') }
    )) {
        if ($s.Path -and (Test-Path -LiteralPath $s.Path)) { $sources += [pscustomobject]$s }
    }
} else {
    $regHklm = 'HKLM:\SOFTWARE\Policies\ClaudeCode'
    $regHkcu = 'HKCU:\SOFTWARE\Policies\ClaudeCode'
    foreach ($s in @(
        @{ Name='HKLM'; Value=(Get-ItemProperty -Path $regHklm -Name Settings -ErrorAction SilentlyContinue).Settings },
        @{ Name='file'; Path=(Join-Path $env:ProgramFiles 'ClaudeCode\managed-settings.json') },
        @{ Name='HKCU'; Value=(Get-ItemProperty -Path $regHkcu -Name Settings -ErrorAction SilentlyContinue).Settings }
    )) {
        if ($s.Value) { $sources += [pscustomobject]@{ Name=$s.Name; Inline=$s.Value } }
        elseif ($s.Path -and (Test-Path -LiteralPath $s.Path)) { $sources += [pscustomobject]@{ Name=$s.Name; Path=$s.Path } }
    }
}
$winner = if (@($sources | Where-Object Name -eq 'HKLM').Count) { 'HKLM wins' } elseif (@($sources | Where-Object Name -eq 'file').Count) { 'file wins' } elseif (@($sources | Where-Object Name -eq 'HKCU').Count) { 'HKCU wins' } else { 'none' }
Add-ClaudeDiagnoseCheck 'Managed settings precedence' $(if ($winner -eq 'none') { 'WARN' } else { 'PASS' }) "Sources: $((@($sources.Name) -join ', ')); $winner. Windows order: HKLM, file, HKCU. macOS/Linux: managed profile, /Library or /etc file, user settings." 'Deploy the intended highest-precedence source or remove stale lower-precedence settings.' 'Intune/Jamf/GPO > Claude Code managed settings'

$envBase = [Environment]::GetEnvironmentVariable('ANTHROPIC_FOUNDRY_BASE_URL','Process')
$envResource = [Environment]::GetEnvironmentVariable('ANTHROPIC_FOUNDRY_RESOURCE','Process')
$settingBase = [string](Get-ClaudeDiagnoseProperty $cliSettings 'env.ANTHROPIC_FOUNDRY_BASE_URL')
$conflicts = @()
if ($envBase -and $settingBase -and $envBase.TrimEnd('/') -ne $settingBase.TrimEnd('/')) { $conflicts += 'environment base URL differs from settings.json' }
if (($envBase -or $settingBase) -and $envResource) { $conflicts += 'base URL and resource are mutually exclusive' }
if ($conflicts.Count) { Add-ClaudeDiagnoseCheck 'Configuration conflicts' 'FAIL' ($conflicts -join '; ') 'Keep only ANTHROPIC_FOUNDRY_BASE_URL for the gateway and remove ANTHROPIC_FOUNDRY_RESOURCE.' 'Developer workstation > environment variables and ~/.claude/settings.json' }
else { Add-ClaudeDiagnoseCheck 'Configuration conflicts' 'PASS' 'No conflicting gateway settings found.' 'No fix needed.' 'Developer workstation > environment variables and ~/.claude/settings.json' }

$code = Get-Command code -ErrorAction SilentlyContinue
if ($code) {
    $codeVersion = (& code --version 2>&1 | Select-Object -First 1 | Out-String).Trim()
    $extensions = (& code --list-extensions 2>&1 | Out-String)
    $vsPath = Join-Path $env:APPDATA 'Code\User\settings.json'
    $vsEvidence = "VS Code $codeVersion; Claude extension=" + [string]($extensions -match 'anthropic\.claude-code')
    if (Test-Path -LiteralPath $vsPath) { $vsEvidence += "; settings=$vsPath" }
    Add-ClaudeDiagnoseCheck 'VS Code and Claude extension' $(if ($extensions -match 'anthropic\.claude-code') { 'PASS' } else { 'WARN' }) $vsEvidence 'code --install-extension anthropic.claude-code; reload each VS Code window.' 'VS Code > Extensions; Settings > claudeCode.environmentVariables'
} else {
    Add-ClaudeDiagnoseCheck 'VS Code and Claude extension' 'WARN' 'code was not found on PATH.' 'Install VS Code and the Claude Code extension if the developer uses the IDE.' 'VS Code > Extensions'
}

$desktopInstall = Get-ClaudeDesktopInstall
# The oldest build that may read the configuration: after an update the running process can
# still be the old build.
$desktopReading = Get-ClaudeDesktopReadingVersion -Install $desktopInstall
if ($desktopInstall.RunningVersion -and $desktopInstall.Version -and (Test-ClaudeClientVersionAtLeast -Installed $desktopInstall.RunningVersion -Required ([string](ConvertTo-ClaudeClientVersion $desktopInstall.Version))) -eq $false) {
    $stale = @(Get-ClaudeDesktopVersionedShortcut)
    $shortcutNote = if ($stale.Count) { ' Shortcuts that start that build: ' + (($stale | ForEach-Object { "$($_.Shortcut) -> $($_.Target)" }) -join '; ') + '.' } else { '' }
    Add-ClaudeDiagnoseCheck 'Claude Desktop running build' 'WARN' "Claude Desktop $($desktopInstall.Version) is installed, but $($desktopInstall.RunningVersion) is running from $($desktopInstall.RunningPath).$shortcutNote" 'Quit Claude Desktop fully, including the tray icon, and start it from the Start menu; replace any shortcut to a versioned app-<version> folder with one to %LOCALAPPDATA%\AnthropicClaude\claude.exe.' 'Task Manager > Claude > Open file location'
}
$desktopSource = $null
$desktopSettings = $null
$desktopPolicy = if ($policyRoot) { Join-Path $policyRoot 'HKLM\SOFTWARE\Policies\Claude\Settings.json' } else { '' }
if ($desktopPolicy -and (Test-Path $desktopPolicy)) {
    $desktopSource = "managed policy ($desktopPolicy)"
    $desktopSettings = Get-Content -LiteralPath $desktopPolicy -Raw | ConvertFrom-Json
} elseif (-not $policyRoot) {
    # Managed policy wins over the local library; machine policy hides user policy entirely.
    foreach ($hive in 'HKLM:\SOFTWARE\Policies\Claude', 'HKCU:\SOFTWARE\Policies\Claude') {
        $values = Get-ItemProperty -Path $hive -ErrorAction SilentlyContinue
        $names = @($values.PSObject.Properties.Name | Where-Object { $_ -like 'inference*' })
        if ($names.Count) {
            $desktopSource = "managed policy ($hive)"
            $desktopSettings = [pscustomobject]@{}
            foreach ($n in $names) { $desktopSettings | Add-Member -NotePropertyName $n -NotePropertyValue $values.$n }
            break
        }
    }
}
if (-not $desktopSettings -and $env:LOCALAPPDATA) {
    $library = Join-Path $env:LOCALAPPDATA 'Claude-3p\configLibrary'
    $meta = ConvertFrom-ClaudeDiagnoseJson ([string](Get-Content -LiteralPath (Join-Path $library '_meta.json') -Raw -ErrorAction SilentlyContinue))
    if ($meta -and $meta.appliedId) {
        $profilePath = Join-Path $library "$($meta.appliedId).json"
        $desktopSettings = ConvertFrom-ClaudeDiagnoseJson ([string](Get-Content -LiteralPath $profilePath -Raw -ErrorAction SilentlyContinue))
        if ($desktopSettings) { $desktopSource = "local profile ($profilePath)" }
    }
}
$desktopFix = './scripts/Setup-ClaudeWorkstation.ps1 -ConfigPath <claude-gateway.json> -SkipInstall rewrites the profile.'
if (-not $desktopSettings) {
    $state = if ($desktopInstall.Installed) { "Claude Desktop $desktopReading is installed" } else { 'Claude Desktop was not found' }
    Add-ClaudeDiagnoseCheck 'Claude Desktop sign-in configuration' 'WARN' "$state, with no third-party configuration in managed policy or the local library." $desktopFix 'Claude Desktop > Developer > Configure third-party inference'
} else {
    $kind = [string]$desktopSettings.inferenceCredentialKind
    $issues = @()
    if ([string]$desktopSettings.inferenceProvider -ne 'gateway') { $issues += "provider is '$($desktopSettings.inferenceProvider)', not gateway" }
    if (-not $desktopSettings.inferenceGatewayBaseUrl) { $issues += 'no gateway base URL' }
    if (-not $kind) { $issues += 'the Credential kind is empty, so Desktop has no way to sign in (the Connection screen says "Connection needs Credential kind")' }
    $needed = Get-ClaudeDesktopRequiredVersion -Settings $desktopSettings
    if ($desktopReading -and $needed -and (Test-ClaudeClientVersionAtLeast -Installed $desktopReading -Required $needed) -eq $false) {
        $issues += "its keys need Desktop $needed$(if ($kind -eq 'external-idp') { ' (external-idp and inferenceIdpOidc arrived in 2.7032.0)' }); the Desktop that reads them is $desktopReading"
    }
    if ($kind -eq 'helper-script') {
        $helper = if ($desktopSettings.inferenceCredentialHelperWindows) { [string]$desktopSettings.inferenceCredentialHelperWindows } else { [string]$desktopSettings.inferenceCredentialHelper }
        if (-not $helper -or -not (Test-Path -LiteralPath $helper)) { $issues += "the credential helper '$helper' does not exist" }
    }
    if ($kind -in @('interactive', 'external-idp') -and [string]$desktopSettings.inferenceProvider -eq 'gateway') {
        $oidc = if ($desktopSettings.inferenceGatewayOidc) { $desktopSettings.inferenceGatewayOidc } else { $desktopSettings.inferenceIdpOidc }
        if ($oidc -is [string]) { $oidc = ConvertFrom-ClaudeDiagnoseJson $oidc }
        if (-not $oidc -or -not $oidc.issuer -or -not $oidc.clientId) { $issues += 'Entra sign-in has no identity provider issuer and client id' }
    }
    $summary = "kind=$kind; gateway=$($desktopSettings.inferenceGatewayBaseUrl); Desktop $(if ($desktopReading) { $desktopReading } else { 'version unknown' }); from $desktopSource"
    if ($issues.Count) {
        Add-ClaudeDiagnoseCheck 'Claude Desktop sign-in configuration' 'FAIL' ("$summary. " + ($issues -join '; ') + '.') $desktopFix 'Claude Desktop > Developer > Configure third-party inference > Connection'
    } else {
        Add-ClaudeDiagnoseCheck 'Claude Desktop sign-in configuration' 'PASS' $summary 'No fix needed.' 'Claude Desktop > Developer > Configure third-party inference > Connection'
    }
}

# Desktop's own log names the host and the reason when sign-in or a request fails.
$desktopLog = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'Claude-3p\logs\main.log' } else { '' }
if ($desktopLog -and (Test-Path -LiteralPath $desktopLog)) {
    $recent = @(Get-Content -LiteralPath $desktopLog -Tail 3000 -ErrorAction SilentlyContinue |
        Where-Object { $_ -match '\[(warn|error)\]' -and $_ -match '(?i)custom-3p|ENOTFOUND|getaddrinfo|ECONNREFUSED|certificate|credential|sign-in|\b40[13]\b' } |
        Select-Object -Last 5 | ForEach-Object { $_.Trim().Substring(0, [Math]::Min(240, $_.Trim().Length)) })
    if ($recent.Count) { Add-ClaudeDiagnoseCheck 'Claude Desktop recent errors' 'WARN' ($recent -join ' | ') 'Fix the named host, credential or certificate, then quit Desktop fully (including the tray icon) and reopen it.' $desktopLog }
    else { Add-ClaudeDiagnoseCheck 'Claude Desktop recent errors' 'PASS' 'No sign-in or connection errors in the latest log.' 'No fix needed.' $desktopLog }
}

if ($GatewayUrl) {
    $hostName = try { ([Uri]$GatewayUrl).Host } catch { '' }
    if ($hostName) {
        $dns = try { [Net.Dns]::GetHostAddresses($hostName) | Select-Object -First 3 | ForEach-Object IPAddressToString } catch { @() }
        $ca = [Environment]::GetEnvironmentVariable('NODE_EXTRA_CA_CERTS','Process')
        $proxy = [Net.WebRequest]::DefaultWebProxy.GetProxy([Uri]$GatewayUrl)
        Add-ClaudeDiagnoseCheck 'Network path to gateway' $(if ($dns.Count) { 'PASS' } else { 'FAIL' }) "DNS=$($dns -join ', '); proxy=$proxy; NODE_EXTRA_CA_CERTS=$ca" 'Fix DNS/proxy/custom CA; see docs/NETWORK.md.' 'Network team > proxy/PAC/TLS inspection; Azure portal > API Management > Custom domains'
        if ($NoRequest) {
            Add-ClaudeDiagnoseCheck 'Gateway real request' 'SKIP' '-NoRequest was supplied.' 'Rerun without -NoRequest to send one small request through the gateway.' 'Azure portal > API Management services > <gateway> > APIs > Claude API > Test'
        } elseif ($cognitiveToken) {
            # The Sonnet deployment is in every tier by default; an Opus-only request refuses standard users.
            $probe = Get-ClaudeCodePinnedModel -Deployments $recordedDeployments
            $probeModel = if ($probe.Contains('SONNET')) { $probe['SONNET'].name } elseif ($recordedDeployments.Count) { $recordedDeployments[0].name } else { 'claude-sonnet-5' }
            $body = @{ model = $probeModel; max_tokens = 8; messages = @(@{ role='user'; content='say OK' }) } | ConvertTo-Json -Depth 6
            try {
                # -UseBasicParsing: without it Windows PowerShell 5.1 throws "Object reference not set
                # to an instance of an object" on a machine without Internet Explorer (measured).
                $r = Invoke-WebRequest -Method Post -Uri ($GatewayUrl.TrimEnd('/') + '/v1/messages') -Headers @{ Authorization = 'Bearer ' + $cognitiveToken; 'anthropic-version'='2023-06-01'; 'Content-Type'='application/json' } -Body $body -TimeoutSec 90 -UseBasicParsing
                Add-ClaudeDiagnoseCheck 'Gateway real request' 'PASS' "HTTP $($r.StatusCode); tier=$($r.Headers['x-claude-tier'] -join '')" 'No fix needed.' 'Azure portal > API Management services > <gateway> > APIs > Claude API > Test'
            } catch {
                $code = $null; try { $code = $_.Exception.Response.StatusCode.value__ } catch {}
                Add-ClaudeDiagnoseCheck 'Gateway real request' 'FAIL' "HTTP $code; $($_.Exception.Message)" "./scripts/Debug-ClaudeCode.ps1 -GatewayBaseUrl $GatewayUrl" 'Azure portal > API Management services > <gateway> > APIs > Claude API > Test'
            }
        } else {
            Add-ClaudeDiagnoseCheck 'Gateway real request' 'SKIP' 'No Cognitive Services token was available for the request.' $loginFix 'Microsoft Entra admin center > Sign-in logs'
        }
    } else {
        Add-ClaudeDiagnoseCheck 'Network path to gateway' 'FAIL' "Invalid gateway URL: $GatewayUrl" 'Use https://<apim>.azure-api.net/claude.' 'Azure portal > API Management services > <gateway> > Overview'
    }
} else {
    Add-ClaudeDiagnoseCheck 'Network path to gateway' 'SKIP' 'Gateway URL not supplied.' 'Pass -GatewayUrl or run with a config-derived value.' 'Azure portal > API Management services > <gateway> > Overview'
}

if ($SupportBundle) {
    Write-ClaudeDiagnoseSupportBundle -Path $SupportBundle -Results $script:ClaudeDiagnoseResults -Files @{ claude_settings = $cliSettingsPath; vscode_settings = (Join-Path $env:APPDATA 'Code\User\settings.json') } -Data @{ account = $acct; managed_sources = $sources; environment = @{ ANTHROPIC_FOUNDRY_BASE_URL = $envBase; ANTHROPIC_FOUNDRY_RESOURCE = $envResource; NODE_EXTRA_CA_CERTS = [Environment]::GetEnvironmentVariable('NODE_EXTRA_CA_CERTS','Process') } }
}

Write-ClaudeDiagnoseResults -Results $script:ClaudeDiagnoseResults -AsJson:$AsJson
exit (Get-ClaudeDiagnoseExitCode -Results $script:ClaudeDiagnoseResults -FailOn $FailOn)
