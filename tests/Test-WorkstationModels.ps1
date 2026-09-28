# Fast retirement regression: execute the setup's real jq writer, not a second implementation.
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
. (Join-Path $RepoRoot 'scripts\ClaudeClientSupport.ps1')
$count = 0; $failed = 0
function Check($Name, [scriptblock]$Run) {
    $script:count++
    try {
        if (-not (& $Run)) { throw 'condition was false' }
        Write-Host "  [OK] $Name"
    }
    catch { $script:failed++; Write-Host "  [FAIL] $Name - $($_.Exception.Message)" }
}
function Bash-Path([string]$Path) {
    if ([Environment]::OSVersion.Platform -ne 'Win32NT') { return $Path }
    $full = [IO.Path]::GetFullPath($Path)
    return '/' + $full.Substring(0,1).ToLowerInvariant() + $full.Substring(2).Replace('\','/')
}
$bash = $null
if ([Environment]::OSVersion.Platform -eq 'Win32NT') {
    foreach ($path in @('C:\Program Files\Git\bin\bash.exe', 'C:\Program Files\Git\usr\bin\bash.exe', "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe")) {
        if (Test-Path -LiteralPath $path) { $bash = $path; break }
    }
} else { $bash = (Get-Command bash -ErrorAction Stop).Source }
if (-not $bash) { throw 'Workstation retirement checks require Git Bash and jq.' }
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('workstation-models-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null
try {
    $source = [IO.File]::ReadAllText((Join-Path $RepoRoot 'scripts\setup-claude-workstation.sh'))
    $writer = [regex]::Match($source, '(?ms)^  jq \\\r?\n.*?^    '' "\$SETTINGS" > "\$tmp" && mv "\$tmp" "\$SETTINGS"')
    Check 'the exact shell settings writer is present' { $writer.Success }
    foreach ($family in 'sonnet','opus','haiku') {
        $deployment = [pscustomobject]@{ name = "current-$family"; model = "claude-$family-5" }
        $oldEnv = [ordered]@{ MY_TOOL = 'keep' }
        foreach ($alias in 'OPUS','SONNET','HAIKU') {
            $oldEnv["ANTHROPIC_DEFAULT_${alias}_MODEL"] = "retired-$alias"
            $oldEnv["ANTHROPIC_DEFAULT_${alias}_MODEL_SUPPORTED_CAPABILITIES"] = 'old-capabilities'
        }
        $old = [pscustomobject]@{ env = [pscustomobject]$oldEnv; theme = 'keep' }
        $windows = Set-ClaudeCodeGatewaySettings -Settings ($old | ConvertTo-Json | ConvertFrom-Json) -GatewayUrl 'https://gateway.contoso.example/claude' -Deployments @($deployment)
        $desired = Get-ClaudeCodeModelEnvironment -Deployments @($deployment)
        $settings = Join-Path $scratch "settings-$family.json"
        [IO.File]::WriteAllText($settings, ($old | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
        $vars = @("set -eu", "SETTINGS='$(Bash-Path $settings)'", "tmp='$(Bash-Path $settings).tmp'", "GATEWAY_URL='https://gateway.contoso.example/claude'")
        foreach ($alias in 'OPUS','SONNET','HAIKU') {
            $vars += "$alias='$($desired["ANTHROPIC_DEFAULT_${alias}_MODEL"])'"
            $vars += "${alias}_CAPS='$($desired["ANTHROPIC_DEFAULT_${alias}_MODEL_SUPPORTED_CAPABILITIES"])'"
        }
        $vars += "models_json='[`"$($deployment.name)`"]'"
        $shellFile = Join-Path $scratch "write-$family.sh"
        [IO.File]::WriteAllText($shellFile, (($vars -join "`n") + "`n" + $writer.Value).Replace("`r`n","`n"), (New-Object Text.UTF8Encoding($false)))
        $output = & $bash (Bash-Path $shellFile) 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
        $linux = Get-Content -LiteralPath $settings -Raw | ConvertFrom-Json
        Check "C2 $family-only shell settings writer succeeds" { $exitCode -eq 0 }
        Check "C2 $family-only Windows setup removes absent aliases and declarations" {
            $absent = @('OPUS','SONNET','HAIKU' | Where-Object { -not $desired.Contains("ANTHROPIC_DEFAULT_${_}_MODEL") })
            @($absent | Where-Object {
                $windows.env.PSObject.Properties.Name -contains "ANTHROPIC_DEFAULT_${_}_MODEL" -or
                $windows.env.PSObject.Properties.Name -contains "ANTHROPIC_DEFAULT_${_}_MODEL_SUPPORTED_CAPABILITIES"
            }).Count -eq 0
        }
        Check "C2 $family-only bash and Windows have identical owned model settings" {
            (ConvertTo-Json -InputObject @($linux.env.PSObject.Properties | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -Compress) -ceq
                (ConvertTo-Json -InputObject @($windows.env.PSObject.Properties | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -Compress)
        }
        Check "C2 $family-only retirement keeps user settings and the remaining picker" {
            $linux.theme -eq 'keep' -and $linux.env.MY_TOOL -eq 'keep' -and
                ($linux.availableModels -join ',') -eq $deployment.name -and
                ($windows.availableModels -join ',') -eq $deployment.name
        }
    }
}
finally { Remove-Item -LiteralPath $scratch -Recurse -Force }
Write-Host "Workstation models: $count assertions, $failed failed."
if ($failed) { exit 1 }
exit 0
