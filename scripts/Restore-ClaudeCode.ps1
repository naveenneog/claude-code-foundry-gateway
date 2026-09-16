<#
.SYNOPSIS
    Restores Claude Code conversations and memory from a backup.

.DESCRIPTION
    Unpacks an archive written by Backup-ClaudeCode.ps1 into a Claude Code
    profile. The usual reasons: a new machine, a rebuilt one, or recovering
    history somebody deleted.

    It is a dry run until you pass -Apply, and it will not overwrite a project
    that already has conversations without -Force. Conversation transcripts are
    append-only history; replacing a populated folder with an older copy loses
    whatever happened in between, silently, and there is no undo.

.PARAMETER Apply
    Actually write. Without it, nothing is changed.

.PARAMETER Force
    Overwrite projects that already have conversations.

.EXAMPLE
    ./scripts/Restore-ClaudeCode.ps1 -Path ./claude-code-backups/claude-code-....zip
    ./scripts/Restore-ClaudeCode.ps1 -Path ....zip -Apply
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Path,
    [switch]$Apply,
    [switch]$Force,
    [string]$ClaudeHome = (Join-Path $env:USERPROFILE '.claude')
)

$ErrorActionPreference = 'Stop'
$SCHEMA = 1

if (-not (Test-Path $Path)) { throw "No backup at '$Path'." }

$staging = Join-Path ([IO.Path]::GetTempPath()) ("claude-code-restore-{0}" -f [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $staging -Force | Out-Null

try {
    Expand-Archive -Path $Path -DestinationPath $staging -Force

    $manifestPath = Join-Path $staging 'manifest.json'
    if (-not (Test-Path $manifestPath)) {
        throw "'$Path' has no manifest.json, so it was not written by Backup-ClaudeCode.ps1."
    }
    $m = Get-Content $manifestPath -Raw | ConvertFrom-Json
    if ($m.schemaVersion -ne $SCHEMA) {
        throw ("'$Path' is schema version $($m.schemaVersion); this script understands $SCHEMA. " +
               "Use the version of the accelerator that wrote it.")
    }

    Write-Host ''
    Write-Host ("Restore from {0}" -f (Split-Path $Path -Leaf)) -ForegroundColor Cyan
    Write-Host ("  taken     {0} on {1}" -f $m.capturedAt, $m.machine) -ForegroundColor DarkGray
    Write-Host ("  from      {0}" -f $m.claudeHome) -ForegroundColor DarkGray
    Write-Host ("  into      {0}" -f $ClaudeHome) -ForegroundColor DarkGray
    Write-Host ''

    $plan = @()
    foreach ($c in $m.contents) {
        $src = Join-Path $staging $c.path
        $dst = Join-Path $ClaudeHome $c.path
        if (-not (Test-Path $src)) {
            Write-Host ("  {0,-14} missing from the archive, skipped" -f $c.name) -ForegroundColor Yellow
            continue
        }
        $existing = if (Test-Path $dst) { @(Get-ChildItem $dst -Recurse -File -ErrorAction SilentlyContinue).Count } else { 0 }
        $state = if ($existing -eq 0) { 'restore' } else { 'overwrite' }
        $plan += [pscustomobject]@{ Name = $c.name; Path = $c.path; Files = $c.files; Existing = $existing; State = $state; Src = $src; Dst = $dst }
    }

    Write-Host ("  {0,-14} {1,8} {2,10}  {3}" -f 'Set', 'In backup', 'On disk', 'Action')
    Write-Host ('  ' + ('-' * 60)) -ForegroundColor DarkGray
    foreach ($p in $plan) {
        Write-Host ("  {0,-14} {1,8} {2,10}  {3}" -f $p.Name, $p.Files, $p.Existing, $p.State) `
            -ForegroundColor $(if ($p.State -eq 'overwrite') { 'Yellow' } else { 'Green' })
    }

    $clashes = @($plan | Where-Object { $_.State -eq 'overwrite' })
    if ($clashes.Count -and -not $Force) {
        Write-Host ''
        Write-Host ("  {0} set(s) already have files on disk." -f $clashes.Count) -ForegroundColor Yellow
        Write-Host '  Transcripts are append-only history, so replacing a populated folder with an' -ForegroundColor DarkGray
        Write-Host '  older copy loses whatever happened in between and there is no undo. Add -Force' -ForegroundColor DarkGray
        Write-Host '  to overwrite, or restore into an empty -ClaudeHome and merge by hand.' -ForegroundColor DarkGray
    }

    if (-not $Apply) {
        Write-Host ''
        Write-Host '  Dry run. Nothing has been changed. Add -Apply to write.' -ForegroundColor Cyan
        Write-Host ''
        exit 0
    }

    $toWrite = if ($Force) { $plan } else { @($plan | Where-Object { $_.State -eq 'restore' }) }
    if (-not $toWrite.Count) {
        Write-Host ''
        Write-Host '  Nothing to do without -Force.' -ForegroundColor Yellow
        Write-Host ''
        exit 0
    }

    Write-Host ''
    Write-Host '  Applying...' -ForegroundColor Cyan
    New-Item -ItemType Directory -Path $ClaudeHome -Force | Out-Null
    foreach ($p in $toWrite) {
        $parent = Split-Path $p.Dst -Parent
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
        Copy-Item $p.Src $p.Dst -Recurse -Force
        Write-Host ("    {0} {1}" -f $p.State, $p.Name) -ForegroundColor Green
    }

    Write-Host ''
    Write-Host '  Restored. Start Claude Code to pick the history up.' -ForegroundColor Green
    Write-Host ''
    Write-Host '  Credentials were never in the backup, so sign in again if prompted.' -ForegroundColor DarkGray
    Write-Host ''
}
finally {
    Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
}
