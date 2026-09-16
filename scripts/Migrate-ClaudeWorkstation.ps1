<#
.SYNOPSIS
    The developer-side migration tool: back up, switch to the gateway, restore.

.DESCRIPTION
    One command for the person moving from first-party Claude to this gateway,
    wrapping the three things that have to happen on their machine in the order
    they have to happen in.

      -Status    what is on this machine, and what would be captured
      -Backup    Claude Code history and Claude Desktop conversations
      -Configure point Claude Code, Desktop and VS Code at the gateway
      -Restore   put the backups back, on this machine or a new one

    Why the order matters. Configuring the gateway switches Claude Desktop to a
    different profile root - %LOCALAPPDATA%\Claude-3p instead of
    %APPDATA%\Claude - so the first thing a developer sees afterwards is an
    empty Desktop. Backing up first means that is reversible.

    What this cannot do, and says so rather than implying otherwise:
    **first-party conversations are on Anthropic's servers, not on this disk.**
    Measured 2026-09-16, the first-party profile's whole IndexedDB is 7 KB,
    which is a cache. Moving claude.ai history across is the import wizard's
    job, from a claude.ai export - see docs/MIGRATION.md section 1. This backs
    up what is local, which after that import is the only copy there is.

.EXAMPLE
    ./scripts/Migrate-ClaudeWorkstation.ps1 -Status
    ./scripts/Migrate-ClaudeWorkstation.ps1 -Backup
    ./scripts/Migrate-ClaudeWorkstation.ps1 -Configure -GatewayUrl https://...
    ./scripts/Migrate-ClaudeWorkstation.ps1 -Restore -Apply
#>
[CmdletBinding(DefaultParameterSetName = 'Status')]
param(
    [Parameter(ParameterSetName = 'Status')][switch]$Status,
    [Parameter(ParameterSetName = 'Backup')][switch]$Backup,
    [Parameter(ParameterSetName = 'Configure')][switch]$Configure,
    [Parameter(ParameterSetName = 'Restore')][switch]$Restore,

    [Parameter(ParameterSetName = 'Backup')]
    [Parameter(ParameterSetName = 'Restore')]
    [string]$Folder,

    [Parameter(ParameterSetName = 'Restore')][switch]$Apply,
    [Parameter(ParameterSetName = 'Restore')][switch]$Force,
    [Parameter(ParameterSetName = 'Backup')][switch]$IgnoreRunning,

    [Parameter(ParameterSetName = 'Configure')][string]$GatewayUrl,
    [Parameter(ParameterSetName = 'Configure')][string]$TenantId,
    [Parameter(ParameterSetName = 'Configure')][string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
if (-not $Folder) { $Folder = Join-Path (Split-Path $here -Parent) 'claude-code-backups' }

$CODE_HOME = Join-Path $env:USERPROFILE '.claude'
$FP_ROOT   = Join-Path $env:APPDATA 'Claude'
$TP_ROOT   = Join-Path $env:LOCALAPPDATA 'Claude-3p'

function Show-Head($t) {
    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor DarkCyan
    Write-Host " $t" -ForegroundColor Cyan
    Write-Host ('=' * 70) -ForegroundColor DarkCyan
}

function Measure-Tree($p) {
    if (-not (Test-Path $p)) { return [pscustomobject]@{ Files = 0; MB = 0 } }
    $s = Get-ChildItem $p -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum
    return [pscustomobject]@{ Files = $s.Count; MB = [math]::Round($s.Sum / 1MB, 1) }
}

function Test-DesktopRunning {
    return @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^claude' })
}

# ------------------------------------------------------------------- status
if ($Status -or $PSCmdlet.ParameterSetName -eq 'Status') {
    Show-Head 'What is on this machine'

    $rows = @(
        [pscustomobject]@{ What = 'Claude Code history'; Where = $CODE_HOME; Mode = 'any provider' }
        [pscustomobject]@{ What = 'Desktop, first-party'; Where = $FP_ROOT;  Mode = 'claude.ai' }
        [pscustomobject]@{ What = 'Desktop, third-party'; Where = $TP_ROOT;  Mode = 'this gateway' }
    )
    Write-Host ''
    Write-Host ("  {0,-24} {1,-14} {2,8} {3,10}  {4}" -f 'What', 'Mode', 'Files', 'Size MB', 'Path')
    Write-Host ('  ' + ('-' * 104)) -ForegroundColor DarkGray
    foreach ($r in $rows) {
        $m = Measure-Tree $r.Where
        $colour = if ($m.Files -gt 0) { 'Green' } else { 'DarkGray' }
        Write-Host ("  {0,-24} {1,-14} {2,8} {3,10}  {4}" -f $r.What, $r.Mode, $m.Files, $m.MB, $r.Where) -ForegroundColor $colour
    }

    $running = Test-DesktopRunning
    Write-Host ''
    if ($running.Count) {
        Write-Host ("  Claude Desktop is running ({0} process(es)). Quit it before backing up -" -f $running.Count) -ForegroundColor Yellow
        Write-Host '  it holds its conversation database open, and a copy taken now is not a database.' -ForegroundColor DarkGray
    }
    else {
        Write-Host '  Claude Desktop is not running, so its database can be copied cleanly.' -ForegroundColor Green
    }

    Write-Host ''
    Write-Host '  First-party conversations are on Anthropic servers, not in that folder - the local' -ForegroundColor DarkGray
    Write-Host '  store is a cache. Move them with Desktop''s import wizard from a claude.ai export;' -ForegroundColor DarkGray
    Write-Host '  docs/MIGRATION.md section 1 covers the two switches that have to be on first.' -ForegroundColor DarkGray
    Write-Host ''
    exit 0
}

# ------------------------------------------------------------------- backup
if ($Backup) {
    Show-Head 'Backing up this machine'

    $running = Test-DesktopRunning
    if ($running.Count -and -not $IgnoreRunning) {
        Write-Host ''
        throw ("Claude Desktop is running ($($running.Count) process(es)). Quit it first - it holds its " +
               "conversation database open, and a copy taken now captures some of its files and not others, " +
               "which restores as corruption rather than as history. -IgnoreRunning takes it anyway.")
    }

    New-Item -ItemType Directory -Path $Folder -Force | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

    Write-Host ''
    Write-Host '  1. Claude Code history' -ForegroundColor Cyan
    & (Join-Path $here 'Backup-ClaudeCode.ps1') -Path (Join-Path $Folder "claude-code-$env:USERNAME-$stamp.zip")

    Write-Host ''
    Write-Host '  2. Claude Desktop conversations' -ForegroundColor Cyan
    $desktopArgs = @{ Path = (Join-Path $Folder "claude-desktop-$env:USERNAME-$stamp.zip") }
    if ($IgnoreRunning) { $desktopArgs.Force = $true }
    & (Join-Path $here 'Backup-ClaudeDesktop.ps1') @desktopArgs

    Show-Head 'Done'
    Get-ChildItem $Folder -Filter "*-$stamp.zip" | ForEach-Object {
        Write-Host ("  {0,-46} {1,8:n0} KB" -f $_.Name, ($_.Length / 1KB)) -ForegroundColor Green
    }
    Write-Host ''
    Write-Host '  These hold prompts and source code. Treat them as source.' -ForegroundColor Yellow
    Write-Host ''
    exit 0
}

# ---------------------------------------------------------------- configure
if ($Configure) {
    Show-Head 'Pointing this machine at the gateway'

    $setup = Join-Path $here 'Setup-ClaudeWorkstation.ps1'
    if (-not (Test-Path $setup)) { throw "Missing $setup." }

    $latest = @(Get-ChildItem $Folder -Filter 'claude-desktop-*.zip' -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending)
    if (-not $latest.Count) {
        Write-Host ''
        Write-Host '  No Desktop backup found in this folder.' -ForegroundColor Yellow
        Write-Host '  Configuring switches Desktop to a different profile root, so the first thing you' -ForegroundColor DarkGray
        Write-Host '  will see is an empty Desktop. Run -Backup first to make that reversible.' -ForegroundColor DarkGray
        Write-Host ''
    }

    $a = @{}
    if ($GatewayUrl) { $a.GatewayUrl = $GatewayUrl }
    if ($TenantId)   { $a.TenantId   = $TenantId }
    if ($ConfigPath) { $a.ConfigPath = $ConfigPath }
    & $setup @a
    exit $LASTEXITCODE
}

# ------------------------------------------------------------------ restore
if ($Restore) {
    Show-Head 'Restoring onto this machine'

    $code = @(Get-ChildItem $Folder -Filter 'claude-code-*.zip' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    $desk = @(Get-ChildItem $Folder -Filter 'claude-desktop-*.zip' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)

    if (-not $code.Count -and -not $desk.Count) {
        throw "No backups in '$Folder'. Pass -Folder to say where they are."
    }

    $common = @{}
    if ($Apply) { $common.Apply = $true }
    if ($Force) { $common.Force = $true }

    if ($code.Count) {
        Write-Host ''
        Write-Host ("  1. Claude Code history  <- {0}" -f $code[0].Name) -ForegroundColor Cyan
        & (Join-Path $here 'Restore-ClaudeCode.ps1') -Path $code[0].FullName @common
    }
    if ($desk.Count) {
        Write-Host ''
        Write-Host ("  2. Claude Desktop       <- {0}" -f $desk[0].Name) -ForegroundColor Cyan
        & (Join-Path $here 'Restore-ClaudeDesktop.ps1') -Path $desk[0].FullName @common
    }

    if (-not $Apply) {
        Show-Head 'Dry run'
        Write-Host '  Nothing has been changed. Add -Apply to write.' -ForegroundColor Cyan
        Write-Host ''
    }
    exit 0
}
