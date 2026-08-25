<#
.SYNOPSIS
    End-to-end health check for Claude Code on Microsoft Foundry, from the
    Azure side down to the VS Code extension host.

.DESCRIPTION
    Written after a "Claude Code is broken, I think my az login expired"
    report where the sign-in, the tenant, the gateway and the CLI were all
    healthy, and the actual cause was a VS Code window that had been running
    for a week across seven extension updates.

    Checks, in the order that eliminates the most:

      1. Azure sign-in and token - the usual suspect, and usually innocent
      2. Gateway reachability, per model
      3. Client configuration - CLI settings and VS Code settings
      4. A real end-to-end call, verified to have arrived at the gateway
      5. Extension host staleness

    Read-only apart from one small inference call.

.EXAMPLE
    ./scripts/Debug-ClaudeCode.ps1 -GatewayBaseUrl https://apim-x.azure-api.net/claude

.EXAMPLE
    ./scripts/Debug-ClaudeCode.ps1 -GatewayBaseUrl https://apim-x.azure-api.net/claude `
        -AppInsightsId <app-id> -SkipLiveCall
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$GatewayBaseUrl,
    [string[]]$Models = @('claude-sonnet-5', 'claude-opus-5'),

    # Application Insights *AppId* (not the resource id). Enables the check
    # that a call actually arrived, which is what separates "failing" from
    # "never sent".
    [string]$AppInsightsId,

    [switch]$SkipLiveCall
)

$ErrorActionPreference = 'Continue'

function Ok    ($m) { Write-Host "  [OK]   $m" -ForegroundColor Green }
function Bad   ($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Warn  ($m) { Write-Host "  [WARN] $m" -ForegroundColor Yellow }
function Info  ($m) { Write-Host "         $m" -ForegroundColor DarkGray }

$issues = @()

Write-Host ''
Write-Host 'Claude Code - end-to-end health check' -ForegroundColor Cyan
Write-Host ''

# ---------------------------------------------------------------- 1. identity
Write-Host '1. Azure sign-in' -ForegroundColor White
$acct = az account show -o json 2>$null | ConvertFrom-Json
if (-not $acct) {
    Bad 'not signed in'
    Info 'az login --tenant <tenant-id>'
    $issues += 'not signed in'
}
else {
    Ok "$($acct.user.name)"
    Info "tenant $($acct.tenantId)"

    $tokJson = az account get-access-token --resource https://cognitiveservices.azure.com -o json 2>$null | ConvertFrom-Json
    if (-not $tokJson) {
        Bad 'could not acquire a Cognitive Services token'
        $issues += 'token acquisition'
    }
    else {
        $token = $tokJson.accessToken
        $p = $token.Split('.')[1].Replace('-', '+').Replace('_', '/')
        while ($p.Length % 4) { $p += '=' }
        $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p)) | ConvertFrom-Json
        $exp = [DateTimeOffset]::FromUnixTimeSeconds($claims.exp).LocalDateTime
        $mins = [int]($exp - (Get-Date)).TotalMinutes
        if ($mins -gt 0) {
            Ok "token valid for $mins more minutes"
            Info "aud $($claims.aud)"
            Info "oid $($claims.oid)"
        }
        else {
            Bad "token expired $([Math]::Abs($mins)) minutes ago"
            $issues += 'expired token'
        }
    }
}

# ----------------------------------------------------------------- 2. gateway
Write-Host ''
Write-Host '2. Gateway' -ForegroundColor White
$gatewayOk = $false
if ($token) {
    foreach ($m in $Models) {
        $body = @{ model = $m; max_tokens = 16; messages = @(@{ role = 'user'; content = 'say OK' }) } | ConvertTo-Json -Depth 5
        try {
            $r = Invoke-WebRequest -Method Post -Uri ($GatewayBaseUrl.TrimEnd('/') + '/v1/messages') -TimeoutSec 90 `
                 -Headers @{ Authorization = "Bearer $token"; 'anthropic-version' = '2023-06-01'; 'Content-Type' = 'application/json' } `
                 -Body $body
            Ok "$m -> HTTP $($r.StatusCode)"
            $gatewayOk = $true
            if ($r.Headers['x-claude-tier']) { Info "tier $($r.Headers['x-claude-tier'] -join '')  remaining $($r.Headers['x-ratelimit-remaining-tokens'] -join '')" }
        }
        catch {
            $code = $null; try { $code = $_.Exception.Response.StatusCode.value__ } catch { }
            Bad "$m -> HTTP $code"
            $issues += "gateway $m"
        }
    }
}
else { Warn 'skipped - no token' }

# ------------------------------------------------------------ 3. client config
Write-Host ''
Write-Host '3. Client configuration' -ForegroundColor White

$settings = "$env:USERPROFILE\.claude\settings.json"
if (Test-Path $settings) {
    try {
        $j = Get-Content $settings -Raw | ConvertFrom-Json
        $provider = $j.env.CLAUDE_CODE_USE_FOUNDRY
        $baseUrl = $j.env.ANTHROPIC_FOUNDRY_BASE_URL
        if ($provider -eq '1') { Ok 'CLI: CLAUDE_CODE_USE_FOUNDRY=1' } else { Bad 'CLI: CLAUDE_CODE_USE_FOUNDRY not set'; $issues += 'CLI provider' }
        if ($baseUrl) { Info "base URL $baseUrl" }
        if ($j.env.ANTHROPIC_FOUNDRY_RESOURCE -and $baseUrl) {
            Bad 'both ANTHROPIC_FOUNDRY_BASE_URL and ANTHROPIC_FOUNDRY_RESOURCE set - mutually exclusive'
            $issues += 'mutually exclusive settings'
        }
    }
    catch { Bad "settings.json will not parse: $($_.Exception.Message)"; $issues += 'settings.json' }
}
else { Warn "no $settings" }

$vs = "$env:APPDATA\Code\User\settings.json"
if (Test-Path $vs) {
    try {
        $clean = ((Get-Content $vs -Raw) -replace '(?m)^\s*//.*$', '') -replace ',(\s*[}\]])', '$1'
        $vj = $clean | ConvertFrom-Json
        $ev = $vj.'claudeCode.environmentVariables'
        if ($ev) {
            $names = @($ev | ForEach-Object { $_.name })
            if ($names -contains 'CLAUDE_CODE_USE_FOUNDRY') { Ok "VS Code: $($names.Count) environment variables set" }
            else { Bad 'VS Code: CLAUDE_CODE_USE_FOUNDRY missing'; $issues += 'VS Code provider' }
        }
        else {
            Warn 'VS Code: claudeCode.environmentVariables not set'
            Info 'the extension host does not inherit shell exports'
        }
    }
    catch { Warn "VS Code settings.json will not parse" }
}

# -------------------------------------------------------------- 4. live call
Write-Host ''
Write-Host '4. End-to-end call' -ForegroundColor White
if ($SkipLiveCall) { Warn 'skipped' }
else {
    $stamp = "PROBE-$(Get-Random -Minimum 100000 -Maximum 999999)"
    $o = Join-Path $env:TEMP 'cc-hc.out'; $e = Join-Path $env:TEMP 'cc-hc.err'
    $proc = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', 'claude', '-p', "`"Reply with exactly: $stamp`"" `
            -NoNewWindow -Wait -PassThru -RedirectStandardOutput $o -RedirectStandardError $e
    $out = (Get-Content $o -Raw -ErrorAction SilentlyContinue)
    if ($proc.ExitCode -eq 0 -and $out -match $stamp) { Ok "claude -p returned $stamp" }
    else {
        Bad "claude -p failed (exit $($proc.ExitCode))"
        $err = (Get-Content $e -Raw -ErrorAction SilentlyContinue)
        if ($err) { Info $err.Trim() }
        $issues += 'CLI call'
    }
    Remove-Item $o, $e -Force -ErrorAction SilentlyContinue

    # Did it actually arrive? This is what separates "failing" from "never sent".
    if ($AppInsightsId -and $proc.ExitCode -eq 0) {
        Info 'waiting 90s for telemetry ingestion...'
        Start-Sleep -Seconds 90
        $atok = az account get-access-token --resource https://api.applicationinsights.io --query accessToken -o tsv 2>$null
        if ($atok) {
            $q = 'requests | where timestamp > ago(10m) | summarize n=count() by resultCode'
            try {
                $qr = Invoke-RestMethod -Method Post -Uri "https://api.applicationinsights.io/v1/apps/$AppInsightsId/query" `
                      -Headers @{ Authorization = "Bearer $atok" } -ContentType 'application/json' -Body (@{query=$q}|ConvertTo-Json)
                if ($qr.tables[0].rows.Count -gt 0) {
                    Ok 'traffic reached the gateway'
                    $qr.tables[0].rows | ForEach-Object { Info "HTTP $($_[0]) x$($_[1])" }
                }
                else {
                    Bad 'the call succeeded but nothing reached the gateway'
                    Info 'Claude Code is answering from somewhere else - check the provider'
                    $issues += 'bypassing the gateway'
                }
            }
            catch { Warn "could not query Application Insights: $($_.Exception.Message)" }
        }
    }
}

# ------------------------------------------------------- 5. extension host age
Write-Host ''
Write-Host '5. VS Code extension host' -ForegroundColor White
$extRoot = "$env:USERPROFILE\.vscode\extensions"
$latest = Get-ChildItem $extRoot -Directory -Filter 'anthropic.claude-code-*' -ErrorAction SilentlyContinue |
          Sort-Object LastWriteTime -Descending | Select-Object -First 1

# Two traps here, and getting either wrong gives a confident wrong answer.
#
# "Developer: Reload Window" restarts the renderer and the extension host but
# leaves the main VS Code process running, so the start time of the oldest
# Code.exe never changes on reload - it is not evidence either way.
#
# And current VS Code does not run the host as --type=extensionHost; on Windows
# it is a utility process with a node.mojom.NodeService sub-type. Searching for
# "extensionHost" finds nothing and looks like the host is missing.
$cim = Get-CimInstance Win32_Process -Filter "Name='Code.exe'" -ErrorAction SilentlyContinue

if (-not $latest) { Warn 'extension not installed' }
elseif (-not $cim) { Info 'VS Code is not running - it will load the current build on next start' }
else {
    $hosts = foreach ($p in $cim) {
        $cl = [string]$p.CommandLine
        $type = if ($cl -match '--type=([a-zA-Z]+)') { $Matches[1] } else { 'main' }
        $sub  = if ($cl -match '--utility-sub-type=([^\s"]+)') { $Matches[1] } else { '' }
        if (($type -match 'extensionHost') -or ($type -eq 'utility' -and $sub -match 'NodeService')) {
            $started = if ($p.CreationDate -is [datetime]) { $p.CreationDate }
                       else {
                           try { [Management.ManagementDateTimeConverter]::ToDateTime([string]$p.CreationDate) }
                           catch { (Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue).StartTime }
                       }
            [pscustomobject]@{ ProcId = $p.ProcessId; Started = $started }
        }
    }
    $hosts = @($hosts)

    Info "extension $($latest.Name -replace '^anthropic\.claude-code-','' -replace '-win32-x64$','') installed $($latest.LastWriteTime)"

    if ($hosts.Count -eq 0) { Warn 'could not identify the extension host process' }
    else {
        $stale = @($hosts | Where-Object { $_.Started -lt $latest.LastWriteTime })
        Info "$($hosts.Count) extension host(s) running - one per open window"
        if ($stale.Count -gt 0) {
            $oldest = ($stale | Sort-Object Started | Select-Object -First 1)
            Bad "$($stale.Count) of $($hosts.Count) predate the extension update"
            Info "oldest running $([int](((Get-Date) - $oldest.Started).TotalHours)) hours (started $($oldest.Started))"
            Info 'Fix: in EACH affected window, Ctrl+Shift+P -> Developer: Reload Window'
            Info 'Reloading one window does not fix the others.'
            $issues += 'stale extension host'
        }
        else { Ok 'every extension host has the current build' }
    }
}

# -------------------------------------------------------------------- verdict
Write-Host ''
Write-Host ('-' * 68) -ForegroundColor DarkGray
if ($issues.Count -eq 0) {
    Write-Host 'Everything healthy.' -ForegroundColor Green
}
else {
    Write-Host "$($issues.Count) issue(s): $($issues -join ', ')" -ForegroundColor Yellow
    if ($gatewayOk -and $issues -contains 'stale extension host') {
        Write-Host ''
        Write-Host 'Azure is fine. The problem is on this machine - reload the VS Code window.' -ForegroundColor White
    }
}
Write-Host ''
