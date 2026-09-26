# Diagnostics contracts for P66. Offline; Azure, Claude and VS Code calls are stubbed.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$fail = 0
function Assert($label, $condition, $detail = '') {
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $label$(if ($detail) { " - $detail" })" -ForegroundColor Red; $script:fail++ }
}
function Invoke-DiagScript([string]$Script, [string[]]$Args, [string]$StubDir, [string]$HomeDir) {
    $env:PATH = $StubDir + [IO.Path]::PathSeparator + $env:PATH
    $env:USERPROFILE = $HomeDir
    $env:APPDATA = Join-Path $HomeDir 'AppData\Roaming'
    $env:LOCALAPPDATA = Join-Path $HomeDir 'AppData\Local'
    $env:CLAUDE_DIAGNOSE_WINDOWS_POLICY_ROOT = Join-Path $HomeDir 'policy'
    $env:CLAUDE_DIAGNOSE_HOME = $HomeDir
    $env:CLAUDE_DIAGNOSE_NO_NETWORK = '1'
    $env:CLAUDE_DIAGNOSE_SKIP_RENDER = '1'
    & (Join-Path $root $Script) @Args 2>&1 | Out-String
    [pscustomobject]@{ Output = $LASTEXITCODE; Text = $script:__lastText }
}

Write-Host ''
Write-Host 'P66 diagnostics' -ForegroundColor Cyan
$script:hostExe = if ($PSVersionTable.PSVersion.Major -lt 6) {
    Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
} else {
    (Get-Command pwsh -ErrorAction Stop).Source
}

$scratch = Join-Path ([IO.Path]::GetTempPath()) ('diagnose-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch -Force | Out-Null
$originalPath = $env:PATH
try {
    $stubs = Join-Path $scratch 'bin'
    $homeDir = Join-Path $scratch 'home'
    New-Item -ItemType Directory -Path $stubs, $homeDir, (Join-Path $homeDir '.claude'), (Join-Path $homeDir 'AppData\Roaming\Code\User'), (Join-Path $homeDir 'AppData\Roaming\Claude') -Force | Out-Null

    Set-Content -Path (Join-Path $stubs 'az.cmd') -Encoding ASCII -Value @'
@echo off
if "%1"=="account" if "%2"=="show" (
  echo {"tenantId":"11111111-1111-1111-1111-111111111111","user":{"name":"dev@example.com","type":"user"}}
  exit /b 0
)
if "%1"=="account" if "%2"=="get-access-token" (
  echo {"accessToken":"eyJhbGciOiJub25lIn0.eyJhdWQiOiJodHRwczovL2NvZ25pdGl2ZXNlcnZpY2VzLmF6dXJlLmNvbSIsIm9pZCI6IjIyMjIyMjIyLTIyMjItMjIyMi0yMjIyLTIyMjIyMjIyMjIyMiIsInRpZCI6IjExMTExMTExLTExMTEtMTExMS0xMTExLTExMTExMTExMTExMSIsImV4cCI6NDEwMjQ0NDgwMH0.","expiresOn":"2099-12-31 00:00:00.000000"}
  exit /b 0
)
if "%1"=="apim" if "%2"=="show" (
  echo {"name":"apim-test","gatewayUrl":"https://apim-test.azure-api.net","sku":{"name":"BasicV2"},"identity":{"principalId":"33333333-3333-3333-3333-333333333333"}}
  exit /b 0
)
if "%1"=="apim" if "%2"=="nv" if "%3"=="list" (
  echo [{"name":"developers-standard","value":"22222222-2222-2222-2222-222222222222"},{"name":"quota-org","value":"1000"},{"name":"turnstile-integration","value":"{\"mode\":\"TurnstileAum\",\"url\":\"https://turnstile.contoso.example\"}"}]
  exit /b 0
)
if "%1"=="apim" if "%2"=="api" if "%3"=="policy" (
  echo ^<policies^>^<inbound^>^<base /^>^</inbound^>^</policies^>
  exit /b 0
)
if "%1"=="role" (
  echo [{"roleDefinitionName":"Cognitive Services User","principalId":"33333333-3333-3333-3333-333333333333"}]
  exit /b 0
)
if "%1"=="resource" (
  echo []
  exit /b 0
)
echo {}
exit /b 0
'@
    Set-Content -Path (Join-Path $stubs 'claude.cmd') -Encoding ASCII -Value '@echo off
if "%1"=="--version" (echo 2.1.272& exit /b 0)
if "%1"=="doctor" (echo Foundry baseURL https://apim-test.azure-api.net/claude& exit /b 0)
echo OK
exit /b 0'
    Set-Content -Path (Join-Path $stubs 'code.cmd') -Encoding ASCII -Value '@echo off
if "%1"=="--version" (echo 1.94.0& exit /b 0)
if "%1"=="--list-extensions" (echo anthropic.claude-code& exit /b 0)
exit /b 0'
    $env:PATH = $stubs + [IO.Path]::PathSeparator + $env:PATH
    $env:CLAUDE_DIAGNOSE_FORCE_NO_REQUEST = '1'

    $settings = @{ env = @{ CLAUDE_CODE_USE_FOUNDRY = '1'; ANTHROPIC_FOUNDRY_BASE_URL = 'https://apim-test.azure-api.net/claude'; ANTHROPIC_AUTH_TOKEN = 'sk-ant-api03-secret-token-like-value' } } | ConvertTo-Json -Depth 5
    Set-Content -Path (Join-Path $homeDir '.claude\settings.json') -Value $settings -Encoding UTF8
    Set-Content -Path (Join-Path $homeDir 'AppData\Roaming\Code\User\settings.json') -Value (@{ 'claudeCode.environmentVariables' = @(@{ name='CLAUDE_CODE_USE_FOUNDRY'; value='1' }, @{ name='ANTHROPIC_FOUNDRY_BASE_URL'; value='https://apim-test.azure-api.net/claude' }) } | ConvertTo-Json -Depth 6) -Encoding UTF8
    $policyRoot = Join-Path $homeDir 'policy'
    New-Item -ItemType Directory -Path (Join-Path $policyRoot 'HKLM\SOFTWARE\Policies\ClaudeCode'), (Join-Path $policyRoot 'HKCU\SOFTWARE\Policies\ClaudeCode'), (Join-Path $policyRoot 'HKLM\SOFTWARE\Policies\Claude') -Force | Out-Null
    Set-Content -Path (Join-Path $policyRoot 'HKLM\SOFTWARE\Policies\ClaudeCode\Settings.json') -Value '{"env":{"ANTHROPIC_FOUNDRY_BASE_URL":"https://managed.example/claude"}}' -Encoding UTF8
    Set-Content -Path (Join-Path $policyRoot 'HKCU\SOFTWARE\Policies\ClaudeCode\Settings.json') -Value '{"env":{"ANTHROPIC_FOUNDRY_BASE_URL":"https://user.example/claude"}}' -Encoding UTF8
    Set-Content -Path (Join-Path $policyRoot 'HKLM\SOFTWARE\Policies\Claude\Settings.json') -Value '{"inferenceCredentialKind":"helper-script","inferenceGatewayBaseUrl":"https://apim-test.azure-api.net/claude"}' -Encoding UTF8

    $record = Join-Path $scratch 'claude-gateway.json'
    Set-Content -Path $record -Value (@{
        schemaVersion = 2
        gatewayUrl = 'https://apim-test.azure-api.net/claude'
        tenantId = '11111111-1111-1111-1111-111111111111'
        resourceGroup = 'rg-test'
        apimName = 'apim-test'
        decisions = @{ sku = 'BasicV2'; entitlementStore = 'named-value'; finops = @{ tool = 'TurnstileAum' } }
    } | ConvertTo-Json -Depth 8) -Encoding UTF8

    $bundle = Join-Path $scratch 'setup-bundle.zip'
    $env:CLAUDE_DIAGNOSE_SKIP_HEALTH = '1'
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $setupText = & $script:hostExe -NoProfile -File (Join-Path $root 'scripts\Debug-ClaudeSetup.ps1') -ResourceGroup rg-test -ApimName apim-test -DecisionRecord $record -NoRequest -SupportBundle $bundle *>&1 | Out-String
    $ErrorActionPreference = $oldEap
    $setupCode = $LASTEXITCODE
    Assert 'admin diagnostics emit PASS/WARN/FAIL/SKIP checks' ($setupText -match '\b(PASS|WARN|FAIL|SKIP)\b' -and $setupText -match 'Evidence:' -and $setupText -match 'Fix:')
    Assert 'admin diagnostics run read-only with -NoRequest skip' ($setupText -match 'Gateway real request' -and $setupText -match 'SKIP')
    Assert 'admin diagnostics support bundle is written' (Test-Path $bundle)
    Assert 'admin diagnostics return non-zero on fail/warn by default' ($setupCode -ne 0)

    $workBundle = Join-Path $scratch 'workstation-bundle.zip'
    $oldPath = $env:PATH; $oldProfile = $env:USERPROFILE; $oldAppData = $env:APPDATA; $oldLocal = $env:LOCALAPPDATA
    try {
        $env:PATH = $stubs + [IO.Path]::PathSeparator + $env:PATH
        $env:USERPROFILE = $homeDir
        $env:APPDATA = Join-Path $homeDir 'AppData\Roaming'
        $env:LOCALAPPDATA = Join-Path $homeDir 'AppData\Local'
        $env:CLAUDE_DIAGNOSE_WINDOWS_POLICY_ROOT = $policyRoot
        $env:ANTHROPIC_FOUNDRY_RESOURCE = 'https://conflicting-resource.example'
        $env:CLAUDE_DIAGNOSE_SKIP_HEALTH = '1'
        $oldEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $workText = & $script:hostExe -NoProfile -File (Join-Path $root 'scripts\Debug-ClaudeWorkstation.ps1') -GatewayUrl https://apim-test.azure-api.net/claude -TenantId 11111111-1111-1111-1111-111111111111 -NoRequest -SupportBundle $workBundle *>&1 | Out-String
        $ErrorActionPreference = $oldEap
        $workCode = $LASTEXITCODE
    } finally {
        $env:PATH = $oldPath; $env:USERPROFILE = $oldProfile; $env:APPDATA = $oldAppData; $env:LOCALAPPDATA = $oldLocal
        Remove-Item Env:\CLAUDE_DIAGNOSE_WINDOWS_POLICY_ROOT -ErrorAction SilentlyContinue
        Remove-Item Env:\ANTHROPIC_FOUNDRY_RESOURCE -ErrorAction SilentlyContinue
        Remove-Item Env:\CLAUDE_DIAGNOSE_SKIP_HEALTH -ErrorAction SilentlyContinue
        Remove-Item Env:\CLAUDE_DIAGNOSE_FORCE_NO_REQUEST -ErrorAction SilentlyContinue
    }
    Assert 'workstation diagnostics emit managed-setting precedence' ($workText -match 'Managed settings precedence' -and $workText -match 'HKLM.*wins')
    Assert 'workstation diagnostics detect configuration conflicts' ($workText -match 'Configuration conflicts')
    Assert 'workstation diagnostics support bundle is written' (Test-Path $workBundle)
    Assert 'workstation diagnostics can exit non-zero when a check fails or warns' ($workCode -ne 0)

    foreach ($zip in @($bundle, $workBundle)) {
        if (-not (Test-Path $zip)) { continue }
        $extract = Join-Path $scratch ([IO.Path]::GetFileNameWithoutExtension($zip))
        Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force
        $all = (Get-ChildItem $extract -Recurse -File | ForEach-Object { Get-Content $_.FullName -Raw }) -join "`n"
        Assert "bundle $([IO.Path]::GetFileName($zip)) masks email" ($all -notmatch 'dev@example\.com')
        Assert "bundle $([IO.Path]::GetFileName($zip)) masks GUIDs and subscription ids" ($all -notmatch '11111111-1111-1111-1111-111111111111' -and $all -notmatch '22222222-2222-2222-2222-222222222222')
        Assert "bundle $([IO.Path]::GetFileName($zip)) masks token-like strings" ($all -notmatch 'sk-ant-api03-secret-token-like-value' -and $all -notmatch 'eyJhbGciOiJub25l')
        Assert "bundle $([IO.Path]::GetFileName($zip)) contains a manifest" (Test-Path (Join-Path $extract 'manifest.json'))
    }

    . (Join-Path $root 'scripts\flow\FlowContract.ps1')
    . (Join-Path $root 'scripts\flow\Diagnose.ps1')
    $info = Get-ClaudeFlowStepInfo
    $plan = Get-ClaudeFlowStepPlan -Record ([pscustomobject]@{ resourceGroup='rg-test'; apimName='apim-test'; gatewayUrl='https://apim-test.azure-api.net/claude' }) -Discovery $null
    Assert 'Diagnose step advertises the fixed interface' ($info.Name -eq 'Diagnose' -and $info.Actions -contains 'Diagnose')
    Assert 'Diagnose plan is read-only and contains only Check actions' ((@($plan.Actions) | Where-Object Verb -ne 'Check').Count -eq 0)
    $env:CLAUDE_DIAGNOSE_SKIP_HEALTH = '1'
    $result = Invoke-ClaudeFlowStep -Record ([pscustomobject]@{ resourceGroup='rg-test'; apimName='apim-test'; gatewayUrl='https://apim-test.azure-api.net/claude' }) -Plan $plan -NoRequest
    Remove-Item Env:\CLAUDE_DIAGNOSE_SKIP_HEALTH -ErrorAction SilentlyContinue
    Assert 'Diagnose apply returns results but no decision changes' ($result.DecisionChanges.Count -eq 0 -and $result.Results.Count -gt 0)

    $bash = $null
    foreach ($candidate in @('C:\Program Files\Git\bin\bash.exe','C:\Program Files\Git\usr\bin\bash.exe',"$env:LOCALAPPDATA\Programs\Git\bin\bash.exe")) {
        if (Test-Path $candidate) { $bash = $candidate; break }
    }
    if (-not $bash) {
        $cmd = Get-Command bash -ErrorAction SilentlyContinue
        if ($cmd) { $bash = $cmd.Source }
    }
    if ($bash) {
        $sh = Join-Path $root 'scripts\debug-claude-workstation.sh'
        & $bash -n ($sh -replace '\\','/') 2>&1 | Out-Null
        Assert 'bash workstation diagnostics parses' ($LASTEXITCODE -eq 0)
        $out = & $bash ($sh -replace '\\','/') --gateway-url https://apim-test.azure-api.net/claude --tenant-id 11111111-1111-1111-1111-111111111111 --no-request 2>&1 | Out-String
        Assert 'bash workstation diagnostics emits check table' ($out -match '\b(PASS|WARN|FAIL|SKIP)\b' -and $out -match 'Fix:')
    } else {
        Assert 'bash workstation diagnostics parses' $true 'bash not present on this host'
    }
}
finally {
    $env:PATH = $originalPath
    Remove-Item Env:\CLAUDE_DIAGNOSE_SKIP_HEALTH -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail) { Write-Host "$fail assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'Diagnostics contracts hold.' -ForegroundColor Green
exit 0
