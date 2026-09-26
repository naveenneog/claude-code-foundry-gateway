<#
.SYNOPSIS
    Read-only developer workstation diagnostics for Claude on Microsoft Foundry.
#>
[CmdletBinding()]
param(
    [string]$GatewayUrl,
    [string]$TenantId,
    [switch]$NoRequest,
    [string]$SupportBundle,
    [switch]$AsJson,
    [ValidateSet('fail','warn')][string]$FailOn = 'warn'
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'ClaudeDiagnoseCommon.ps1')
if ($env:CLAUDE_DIAGNOSE_FORCE_NO_REQUEST) { $NoRequest = $true }

Write-Host ''
Write-Host 'Claude workstation diagnostics' -ForegroundColor Cyan
Write-Host ''

$azCmd = Get-Command az -ErrorAction SilentlyContinue
$cognitiveToken = ''
if ($azCmd) {
    Add-ClaudeDiagnoseCheck 'Azure CLI installed' 'PASS' $azCmd.Source 'Install or update with winget install Microsoft.AzureCLI.' 'https://learn.microsoft.com/cli/azure/install-azure-cli'
    $acctRaw = Get-ClaudeDiagnoseAz @('account','show','-o','json')
    $acct = ConvertFrom-ClaudeDiagnoseJson $acctRaw.Output
    if ($acct) {
        $tenantStatus = if ($TenantId -and $acct.tenantId -ne $TenantId) { 'FAIL' } else { 'PASS' }
        Add-ClaudeDiagnoseCheck 'Azure sign-in and tenant' $tenantStatus "Signed in as $($acct.user.name); tenant $($acct.tenantId)" "az login --tenant $TenantId --allow-no-subscriptions" 'Microsoft Entra admin center > Overview'
        $tokRaw = Get-ClaudeDiagnoseAz @('account','get-access-token','--resource','https://cognitiveservices.azure.com','-o','json')
        $tok = ConvertFrom-ClaudeDiagnoseJson $tokRaw.Output
        if ($tok.accessToken) {
            $cognitiveToken = [string]$tok.accessToken
            Add-ClaudeDiagnoseCheck 'Cognitive Services token' 'PASS' 'Token obtained for https://cognitiveservices.azure.com; value not printed.' 'No fix needed.' 'Microsoft Entra admin center > Sign-in logs'
        }
        else { Add-ClaudeDiagnoseCheck 'Cognitive Services token' 'FAIL' 'Azure CLI did not return a token.' "az login --tenant $TenantId --allow-no-subscriptions" 'Microsoft Entra admin center > Sign-in logs' }
    } else {
        Add-ClaudeDiagnoseCheck 'Azure sign-in and tenant' 'FAIL' 'az account show returned no account.' "az login --tenant $TenantId --allow-no-subscriptions" 'Microsoft Entra admin center > Overview'
    }
} else {
    Add-ClaudeDiagnoseCheck 'Azure CLI installed' 'FAIL' 'az was not found on PATH.' 'Install Azure CLI from your managed software portal or winget install Microsoft.AzureCLI.' 'https://learn.microsoft.com/cli/azure/install-azure-cli'
}

$claude = Get-Command claude -ErrorAction SilentlyContinue
if ($claude) {
    $version = (& claude --version 2>&1 | Select-Object -First 1 | Out-String).Trim()
    Add-ClaudeDiagnoseCheck 'Claude Code installed' 'PASS' "$version at $($claude.Source)" 'No fix needed.' 'Developer workstation > Apps'
    $doctor = (& claude doctor 2>&1 | Out-String)
    Add-ClaudeDiagnoseCheck 'claude doctor' 'PASS' ($doctor.Trim()) 'Fix any reported provider or auth issue, then rerun.' 'Claude Code terminal > claude doctor'
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

$desktopPolicy = if ($policyRoot) { Join-Path $policyRoot 'HKLM\SOFTWARE\Policies\Claude\Settings.json' } else { '' }
if ($desktopPolicy -and (Test-Path $desktopPolicy)) {
    $desktopJson = Get-Content -LiteralPath $desktopPolicy -Raw | ConvertFrom-Json
    Add-ClaudeDiagnoseCheck 'Claude Desktop third-party configuration' 'PASS' "kind=$($desktopJson.inferenceCredentialKind); gateway=$($desktopJson.inferenceGatewayBaseUrl)" 'No fix needed.' 'Claude Desktop > Settings > Connection'
} else {
    Add-ClaudeDiagnoseCheck 'Claude Desktop third-party configuration' 'WARN' 'No Desktop managed configuration found in the checked source.' './scripts/Setup-ClaudeWorkstation.ps1 -ConfigPath .\claude-gateway.json -SkipInstall' 'Claude Desktop > Settings > Connection'
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
            $body = @{ model = 'claude-sonnet-5'; max_tokens = 8; messages = @(@{ role='user'; content='say OK' }) } | ConvertTo-Json -Depth 6
            try {
                $r = Invoke-WebRequest -Method Post -Uri ($GatewayUrl.TrimEnd('/') + '/v1/messages') -Headers @{ Authorization = 'Bearer ' + $cognitiveToken; 'anthropic-version'='2023-06-01'; 'Content-Type'='application/json' } -Body $body -TimeoutSec 90
                Add-ClaudeDiagnoseCheck 'Gateway real request' 'PASS' "HTTP $($r.StatusCode); tier=$($r.Headers['x-claude-tier'] -join '')" 'No fix needed.' 'Azure portal > API Management services > <gateway> > APIs > Claude API > Test'
            } catch {
                $code = $null; try { $code = $_.Exception.Response.StatusCode.value__ } catch {}
                Add-ClaudeDiagnoseCheck 'Gateway real request' 'FAIL' "HTTP $code; $($_.Exception.Message)" "./scripts/Debug-ClaudeCode.ps1 -GatewayBaseUrl $GatewayUrl" 'Azure portal > API Management services > <gateway> > APIs > Claude API > Test'
            }
        } else {
            Add-ClaudeDiagnoseCheck 'Gateway real request' 'SKIP' 'No Cognitive Services token was available for the request.' "az login --tenant $TenantId --allow-no-subscriptions" 'Microsoft Entra admin center > Sign-in logs'
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
