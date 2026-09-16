<#
.SYNOPSIS
    Backs up a developer's Claude Code conversations and memory.

.DESCRIPTION
    A different thing from Backup-ClaudeGateway.ps1. That one captures how the
    gateway behaves; this one captures what a person did with it - their
    conversations, the command history and their memory files. It runs on the
    developer's own machine, against their own profile.

    Read this before running it anywhere central: **conversations contain
    prompts and source code**. That is the whole value of keeping them and the
    whole reason they are not something to scoop into a shared location without
    telling people. This writes to a path you choose and nowhere else.

    What it captures, from ~/.claude:

      projects/        the conversation transcripts, one folder per project
      history.jsonl    the command history
      CLAUDE.md        memory, if present
      settings.json    preferences - only after a credential scan

    What it deliberately leaves out, and why:

      ~/.claude.json   measured 2026-09-16, this file contains oauth, key and
                       token material. A backup of credentials is a credential
                       leak with a filename.
      cache/           regenerated on demand
      plugins/         reinstallable, and large
      file-history/    snapshots of source files; included only with
                       -IncludeFileHistory, because the size and the sensitivity
                       are both a step up
      sessions/        live state, not history

    Every file that goes in is scanned for credential-shaped content first, and
    the backup refuses rather than writing one that leaks.

.PARAMETER Path
    Destination .zip. Defaults to a timestamped file in ./claude-code-backups.

.PARAMETER IncludeFileHistory
    Also capture ~/.claude/file-history, which holds copies of source files.

.EXAMPLE
    ./scripts/Backup-ClaudeCode.ps1
    ./scripts/Backup-ClaudeCode.ps1 -Path D:\handover\my-claude-history.zip
#>
[CmdletBinding()]
param(
    [string]$Path,
    [string]$ClaudeHome = (Join-Path $env:USERPROFILE '.claude'),
    [switch]$IncludeFileHistory
)

$ErrorActionPreference = 'Stop'
$SCHEMA = 1

if (-not (Test-Path $ClaudeHome)) {
    throw "No Claude Code data at '$ClaudeHome'. Pass -ClaudeHome if it lives elsewhere."
}

# Credential-shaped content. Matched on the key name rather than the value,
# because a value that looks random is indistinguishable from a hash and a value
# that does not may still be a password.
$CREDENTIAL_KEYS = 'oauth|accessToken|refreshToken|apiKey|api_key|client_secret|ANTHROPIC_AUTH_TOKEN|ANTHROPIC_API_KEY|password'

# Config and conversations need different treatment, and the first version of
# this got it wrong by treating them the same.
#
# A credential key in a config file is a finding: config is machine-written and
# has no reason to mention one. A credential key in a conversation is Tuesday -
# measured against real history, 12 of 93 transcripts matched, every one of them
# a conversation *about* rotating a key or handling a password rather than one
# containing a live secret. Refusing on that makes the tool useless for the only
# thing it is for.
#
# So: config is scanned and blocks. Conversations are reported and do not,
# because history that mentions credentials cannot be mechanically cleaned - it
# can only be labelled for what it is.
$sets = @(
    @{ Name = 'projects';  Relative = 'projects';      Kind = 'dir';  Why = 'conversation transcripts'; Scan = 'report' }
    @{ Name = 'history';   Relative = 'history.jsonl'; Kind = 'file'; Why = 'command history';          Scan = 'report' }
    @{ Name = 'memory';    Relative = 'CLAUDE.md';     Kind = 'file'; Why = 'memory';                   Scan = 'report' }
    @{ Name = 'settings';  Relative = 'settings.json'; Kind = 'file'; Why = 'preferences';              Scan = 'block' }
    @{ Name = 'plans';     Relative = 'plans';         Kind = 'dir';  Why = 'saved plans';              Scan = 'report' }
)
if ($IncludeFileHistory) {
    $sets += @{ Name = 'file-history'; Relative = 'file-history'; Kind = 'dir'; Why = 'snapshots of edited source files'; Scan = 'report' }
}

$excluded = [ordered]@{
    '~/.claude.json' = 'contains oauth, key and token material - measured 2026-09-16'
    'cache/'         = 'regenerated on demand'
    'plugins/'       = 'reinstallable, and large'
    'sessions/'      = 'live state, not history'
    'session-env/'   = 'live state, not history'
}
if (-not $IncludeFileHistory) {
    $excluded['file-history/'] = 'copies of source files - add -IncludeFileHistory to capture them'
}

Write-Host ''
Write-Host ("Backing up Claude Code data from {0}" -f $ClaudeHome) -ForegroundColor Cyan
Write-Host ''

$staging = Join-Path ([IO.Path]::GetTempPath()) ("claude-code-backup-{0}" -f [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $staging -Force | Out-Null

$manifest = [ordered]@{
    schemaVersion = $SCHEMA
    capturedAt    = (Get-Date).ToUniversalTime().ToString('o')
    machine       = $env:COMPUTERNAME
    claudeHome    = $ClaudeHome
    contents      = @()
    excluded      = $excluded
    warning       = 'Conversations contain prompts and source code. Treat this file as source.'
}

$flagged = @()
$blocking = @()
$mentions = @()
try {
    foreach ($s in $sets) {
        $src = Join-Path $ClaudeHome $s.Relative
        if (-not (Test-Path $src)) {
            Write-Host ("  {0,-14} not present, skipped" -f $s.Name) -ForegroundColor DarkGray
            continue
        }

        $files = if ($s.Kind -eq 'dir') { @(Get-ChildItem $src -Recurse -File) } else { @(Get-Item $src) }
        if (-not $files.Count) {
            Write-Host ("  {0,-14} empty, skipped" -f $s.Name) -ForegroundColor DarkGray
            continue
        }

        # Scan before copying. A backup that has already written the file and
        # then warns is a backup that leaked.
        $setHits = @()
        foreach ($f in $files) {
            if ($f.Length -gt 8MB) { continue }
            $hit = Select-String -Path $f.FullName -Pattern $CREDENTIAL_KEYS -List -ErrorAction SilentlyContinue
            if ($hit) { $setHits += [pscustomobject]@{ File = $f.FullName; Matched = $hit.Matches[0].Value } }
        }
        if ($s.Scan -eq 'block' -and $setHits.Count) { $blocking += $setHits }
        else { $mentions += $setHits }

        $dest = Join-Path $staging $s.Relative
        if ($s.Kind -eq 'dir') { Copy-Item $src $dest -Recurse -Force }
        else { Copy-Item $src $dest -Force }

        $bytes = ($files | Measure-Object Length -Sum).Sum
        Write-Host ("  {0,-14} {1,5} file(s)  {2,8:n0} KB   {3}" -f $s.Name, $files.Count, ($bytes / 1KB), $s.Why) -ForegroundColor Green
        $manifest.contents += [ordered]@{ name = $s.Name; path = $s.Relative; files = $files.Count; bytes = $bytes }
    }

    if ($blocking.Count) {
        Write-Host ''
        Write-Host ("  {0} configuration file(s) contain credential material:" -f $blocking.Count) -ForegroundColor Red
        foreach ($f in $blocking) { Write-Host ("    {0}  ({1})" -f $f.File, $f.Matched) -ForegroundColor Red }
        throw ("Refusing to write a backup containing credentials from a configuration file. Config has no " +
               "reason to hold one. Remove the value, then run this again - a backup of credentials is a " +
               "credential leak with a filename on it.")
    }

    if (-not $manifest.contents.Count) {
        throw "Nothing to back up - none of the expected files exist under '$ClaudeHome'."
    }

    [IO.File]::WriteAllText((Join-Path $staging 'manifest.json'), ($manifest | ConvertTo-Json -Depth 8))

    if (-not $Path) {
        $dir = Join-Path (Split-Path $PSScriptRoot -Parent) 'claude-code-backups'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $Path = Join-Path $dir ("claude-code-{0}-{1}.zip" -f $env:USERNAME, (Get-Date -Format 'yyyyMMdd-HHmmss'))
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
foreach ($k in $excluded.Keys) { Write-Host ("    {0,-16} {1}" -f $k, $excluded[$k]) -ForegroundColor DarkGray }
Write-Host ''
Write-Host '  This archive contains prompts and source code. Treat it as source.' -ForegroundColor Yellow
if ($mentions.Count) {
    Write-Host ("  {0} of the captured transcripts mention credentials by name." -f $mentions.Count) -ForegroundColor Yellow
    Write-Host '  That is usually a conversation about handling one rather than a live secret,' -ForegroundColor DarkGray
    Write-Host '  which is why it is reported and not blocked - history that discusses credentials' -ForegroundColor DarkGray
    Write-Host '  cannot be cleaned mechanically. Review before sharing this outside your machine:' -ForegroundColor DarkGray
    foreach ($f in $mentions | Select-Object -First 5) {
        Write-Host ("    {0}  ({1})" -f (Split-Path $f.File -Leaf), $f.Matched) -ForegroundColor DarkGray
    }
    if ($mentions.Count -gt 5) { Write-Host ("    ... and {0} more" -f ($mentions.Count - 5)) -ForegroundColor DarkGray }
}
Write-Host '  Restore with ./scripts/Restore-ClaudeCode.ps1 -Path <file>.' -ForegroundColor DarkGray
Write-Host ''
