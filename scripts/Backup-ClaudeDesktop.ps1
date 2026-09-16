<#
.SYNOPSIS
    Backs up Claude Desktop conversations, from either mode.

.DESCRIPTION
    The third of three backups, and the one the 1P-to-3P migration depends on.

    Why it exists separately from Backup-ClaudeCode.ps1: Claude Desktop keeps
    its conversations in an Electron profile, not in ~/.claude, and the two
    modes keep separate roots.

      %APPDATA%\Claude\          first-party. Signed into claude.ai
      %LOCALAPPDATA%\Claude-3p\  third-party provider. This gateway

    Observed on a machine that has run both, 2026-09-16 - the IndexedDB origins
    say which is which outright:

      Claude\IndexedDB\https_claude.ai_0.indexeddb.leveldb
      Claude-3p\IndexedDB\app_localhost_0.indexeddb.leveldb

    **Read this before relying on it for a 1P migration.** In first-party mode
    conversations live on Anthropic's backend, not on the disk - measured, that
    profile's whole IndexedDB is 7 KB, which is a cache and not a history. This
    cannot back up conversations that are not here. Moving claude.ai history to
    3P is the import wizard's job, using an export from claude.ai:
    docs/MIGRATION.md section 1.

    Where this does matter is the other side of that migration. In third-party
    mode conversation storage **is** local disk, with no copy on any server. So
    once the import has run, the machine holds the only copy of everything that
    came across - and that is a risk the migration creates rather than one it
    inherits.

.PARAMETER Force
    Back up even while Claude Desktop is running. See the refusal below; this
    produces a snapshot that may not restore.

.EXAMPLE
    ./scripts/Backup-ClaudeDesktop.ps1
    ./scripts/Backup-ClaudeDesktop.ps1 -Profile ThirdParty
#>
[CmdletBinding()]
param(
    [string]$Path,
    [ValidateSet('Both', 'FirstParty', 'ThirdParty')]
    [string]$Profile = 'Both',
    [string]$FirstPartyRoot = (Join-Path $env:APPDATA 'Claude'),
    [string]$ThirdPartyRoot = (Join-Path $env:LOCALAPPDATA 'Claude-3p'),
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$SCHEMA = 1

$profiles = @(
    @{ Key = 'FirstParty'; Root = $FirstPartyRoot; Label = 'first-party (claude.ai)' }
    @{ Key = 'ThirdParty'; Root = $ThirdPartyRoot; Label = 'third-party (this gateway)' }
) | Where-Object { $Profile -eq 'Both' -or $_.Key -eq $Profile }

# What holds conversations, and what is bulk. Measured 2026-09-16 on a real
# third-party profile: 11.4 GB total, of which vm_bundles alone is 10.6 GB and
# the session data is 4 MB. Copying the lot would move eleven gigabytes of
# reinstallable virtual machine images to save four megabytes of work.
$KEEP = @(
    'IndexedDB'                  # the conversations
    'Local Storage'              # app state that references them
    'Session Storage'
    'local-agent-mode-sessions'  # Cowork and agent work product
    'claude-code-sessions'
    'configLibrary'
    'Partitions'
)
$SKIP = [ordered]@{
    'vm_bundles'     = 'virtual machine images, reinstallable - 10.6 GB measured'
    'claude-code'    = 'a bundled binary, not data'
    'claude-code-vm' = 'a bundled virtual machine, not data'
    'Cache'          = 'regenerated on demand'
    'Code Cache'     = 'regenerated on demand'
    'GPUCache'       = 'regenerated on demand'
    'blob_storage'   = 'transient'
    'Crashpad'       = 'crash dumps'
    'sentry'         = 'crash reporting'
    'logs'           = 'diagnostics, not history'
}

Write-Host ''
Write-Host 'Backing up Claude Desktop' -ForegroundColor Cyan

# --- the running check ------------------------------------------------------
#
# This is the correctness property, not a courtesy. Conversations live in a
# LevelDB, and Claude Desktop holds it open. Measured 2026-09-16 with Desktop
# running: LOCK, LOG and 000003.log could not be opened at all, while CURRENT
# could - so a copy taken now silently captures some files and not others, and
# what it produces is not a database. It restores as corruption, which shows up
# later and looks like data loss rather than a bad backup.
$running = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^claude' })
if ($running.Count) {
    Write-Host ("  Claude Desktop is running ({0} process(es))." -f $running.Count) -ForegroundColor Yellow
    if (-not $Force) {
        Write-Host ''
        throw ("Claude Desktop holds its conversation database open while it runs, so a copy taken now " +
               "would capture some of its files and not others - which is not a database, and restores as " +
               "corruption rather than as history. Quit Claude Desktop and run this again. " +
               "-Force takes the snapshot anyway if you accept it may not restore.")
    }
    Write-Host '  -Force given: the snapshot may not restore.' -ForegroundColor Red
}
else {
    Write-Host '  Claude Desktop is not running - the database can be copied cleanly.' -ForegroundColor Green
}

$staging = Join-Path ([IO.Path]::GetTempPath()) ("claude-desktop-backup-{0}" -f [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $staging -Force | Out-Null

$manifest = [ordered]@{
    schemaVersion = $SCHEMA
    capturedAt    = (Get-Date).ToUniversalTime().ToString('o')
    machine       = $env:COMPUTERNAME
    desktopRunning = [bool]$running.Count
    profiles      = @()
    skipped       = $SKIP
    note          = 'First-party conversations live on Anthropic servers and are not on this disk. See docs/MIGRATION.md section 1.'
    warning       = 'Conversations contain prompts and source code. Treat this file as source.'
}

try {
    foreach ($p in $profiles) {
        Write-Host ''
        Write-Host ("  {0}" -f $p.Label) -ForegroundColor Cyan
        if (-not (Test-Path $p.Root)) {
            Write-Host '    not present on this machine' -ForegroundColor DarkGray
            continue
        }

        $captured = @()
        foreach ($dir in $KEEP) {
            $src = Join-Path $p.Root $dir
            if (-not (Test-Path $src)) { continue }
            $files = @(Get-ChildItem $src -Recurse -File -ErrorAction SilentlyContinue)
            if (-not $files.Count) { continue }

            $dest = Join-Path (Join-Path $staging $p.Key) $dir
            New-Item -ItemType Directory -Path (Split-Path $dest -Parent) -Force | Out-Null
            Copy-Item $src $dest -Recurse -Force -ErrorAction SilentlyContinue

            $copied = @(Get-ChildItem $dest -Recurse -File -ErrorAction SilentlyContinue)
            $bytes = ($files | Measure-Object Length -Sum).Sum
            # A file the app had open is skipped by Copy-Item without comment.
            # Saying how many were missed is the difference between a backup and
            # a directory that resembles one.
            $missed = $files.Count - $copied.Count
            $flag = if ($missed -gt 0) { "  ({0} unreadable)" -f $missed } else { '' }
            Write-Host ("    {0,-26} {1,4} file(s) {2,8:n0} KB{3}" -f $dir, $copied.Count, ($bytes / 1KB), $flag) `
                -ForegroundColor $(if ($missed -gt 0) { 'Yellow' } else { 'Green' })
            $captured += [ordered]@{ dir = $dir; files = $copied.Count; expected = $files.Count; bytes = $bytes }
        }

        if ($captured.Count) {
            $manifest.profiles += [ordered]@{ key = $p.Key; label = $p.Label; root = $p.Root; contents = $captured }
        }
        else {
            Write-Host '    nothing to capture' -ForegroundColor DarkGray
        }
    }

    if (-not $manifest.profiles.Count) { throw "No Claude Desktop data found to back up." }

    [IO.File]::WriteAllText((Join-Path $staging 'manifest.json'), ($manifest | ConvertTo-Json -Depth 8))

    if (-not $Path) {
        $dir = Join-Path (Split-Path $PSScriptRoot -Parent) 'claude-code-backups'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $Path = Join-Path $dir ("claude-desktop-{0}-{1}.zip" -f $env:USERNAME, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    }
    $full = if ([IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path (Get-Location).Path $Path }
    New-Item -ItemType Directory -Path (Split-Path $full -Parent) -Force | Out-Null
    if (Test-Path $full) { Remove-Item $full -Force }
    Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $full -CompressionLevel Optimal
}
finally {
    Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host ("  written to {0}" -f $full) -ForegroundColor Green
Write-Host ("  {0:n0} KB, schema version {1}" -f ((Get-Item $full).Length / 1KB), $SCHEMA) -ForegroundColor DarkGray
Write-Host ''
Write-Host '  Left out on purpose:' -ForegroundColor DarkGray
foreach ($k in $SKIP.Keys) { Write-Host ("    {0,-16} {1}" -f $k, $SKIP[$k]) -ForegroundColor DarkGray }
Write-Host ''
Write-Host '  First-party conversations are on Anthropic servers, not on this disk, so they' -ForegroundColor Yellow
Write-Host '  are not in here. Move those with the import wizard - docs/MIGRATION.md.' -ForegroundColor Yellow
Write-Host '  In third-party mode this machine holds the only copy, which is what this is for.' -ForegroundColor DarkGray
Write-Host ''
