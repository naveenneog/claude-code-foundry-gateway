<#
.SYNOPSIS
    Restores Claude Desktop conversations from a backup.

.DESCRIPTION
    Unpacks an archive written by Backup-ClaudeDesktop.ps1 into a Claude Desktop
    profile. The usual reasons: a new machine, a rebuilt one, or recovering a
    third-party profile after the 1P-to-3P import - where this machine holds the
    only copy, because in third-party mode conversation storage is local disk
    and there is nothing on a server to fall back to.

    Dry run until -Apply.

    It refuses while Claude Desktop is running, and that refusal matters more
    here than it does on the backup side. Writing into a LevelDB that the app
    has open corrupts the database the app is currently using - so the failure
    is not "the restore did not work", it is "the history that was already there
    is now gone too".

.PARAMETER Apply
    Actually write. Without it, nothing is changed.

.PARAMETER Force
    Overwrite a profile that already has data.

.EXAMPLE
    ./scripts/Restore-ClaudeDesktop.ps1 -Path ./claude-code-backups/claude-desktop-....zip
    ./scripts/Restore-ClaudeDesktop.ps1 -Path ....zip -Apply
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Path,
    [switch]$Apply,
    [switch]$Force,
    [string]$FirstPartyRoot = (Join-Path $env:APPDATA 'Claude'),
    [string]$ThirdPartyRoot = (Join-Path $env:LOCALAPPDATA 'Claude-3p')
)

$ErrorActionPreference = 'Stop'
$SCHEMA = 1

if (-not (Test-Path $Path)) { throw "No backup at '$Path'." }

$staging = Join-Path ([IO.Path]::GetTempPath()) ("claude-desktop-restore-{0}" -f [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $staging -Force | Out-Null

try {
    Expand-Archive -Path $Path -DestinationPath $staging -Force

    $manifestPath = Join-Path $staging 'manifest.json'
    if (-not (Test-Path $manifestPath)) {
        throw "'$Path' has no manifest.json, so it was not written by Backup-ClaudeDesktop.ps1."
    }
    $m = Get-Content $manifestPath -Raw | ConvertFrom-Json
    if ($m.schemaVersion -ne $SCHEMA) {
        throw ("'$Path' is schema version $($m.schemaVersion); this script understands $SCHEMA. " +
               "Use the version of the accelerator that wrote it.")
    }

    Write-Host ''
    Write-Host ("Restore Claude Desktop from {0}" -f (Split-Path $Path -Leaf)) -ForegroundColor Cyan
    Write-Host ("  taken     {0} on {1}" -f $m.capturedAt, $m.machine) -ForegroundColor DarkGray
    if ($m.desktopRunning) {
        Write-Host '  note      this backup was taken while Desktop was running, so it may be incomplete' -ForegroundColor Yellow
    }

    # Worse here than on the backup side: backing up from a live database gives
    # a bad copy, but writing into one corrupts the database in use. The failure
    # is not a failed restore, it is losing the history that was already there.
    $running = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^claude' })
    if ($running.Count -and $Apply) {
        Write-Host ''
        throw ("Claude Desktop is running ($($running.Count) process(es)). Writing into a conversation " +
               "database the app has open corrupts the one it is using, so this would not just fail - it " +
               "would take the history already on this machine with it. Quit Claude Desktop and run this again.")
    }

    $plan = @()
    foreach ($p in $m.profiles) {
        $target = switch ($p.key) {
            'FirstParty' { $FirstPartyRoot }
            'ThirdParty' { $ThirdPartyRoot }
            default      { $null }
        }
        if (-not $target) { continue }
        foreach ($c in $p.contents) {
            $src = Join-Path (Join-Path $staging $p.key) $c.dir
            if (-not (Test-Path $src)) { continue }
            $dst = Join-Path $target $c.dir
            $existing = if (Test-Path $dst) { @(Get-ChildItem $dst -Recurse -File -ErrorAction SilentlyContinue).Count } else { 0 }
            $plan += [pscustomobject]@{
                Profile = $p.key; Dir = $c.dir; Files = $c.files; Existing = $existing
                State = $(if ($existing -eq 0) { 'restore' } else { 'overwrite' })
                Src = $src; Dst = $dst
            }
        }
    }

    if (-not $plan.Count) { throw "Nothing in this backup matches a profile to restore into." }

    Write-Host ''
    Write-Host ("  {0,-12} {1,-26} {2,8} {3,8}  {4}" -f 'Profile', 'Set', 'Backup', 'On disk', 'Action')
    Write-Host ('  ' + ('-' * 74)) -ForegroundColor DarkGray
    foreach ($p in $plan) {
        Write-Host ("  {0,-12} {1,-26} {2,8} {3,8}  {4}" -f $p.Profile, $p.Dir, $p.Files, $p.Existing, $p.State) `
            -ForegroundColor $(if ($p.State -eq 'overwrite') { 'Yellow' } else { 'Green' })
    }

    $clashes = @($plan | Where-Object { $_.State -eq 'overwrite' })
    if ($clashes.Count -and -not $Force) {
        Write-Host ''
        Write-Host ("  {0} set(s) already have data." -f $clashes.Count) -ForegroundColor Yellow
        Write-Host '  Restoring over a profile replaces its conversations rather than merging them -' -ForegroundColor DarkGray
        Write-Host '  a LevelDB cannot be merged by copying files. Add -Force to replace, or restore' -ForegroundColor DarkGray
        Write-Host '  into an empty profile root with -ThirdPartyRoot and compare.' -ForegroundColor DarkGray
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
    foreach ($p in $toWrite) {
        New-Item -ItemType Directory -Path (Split-Path $p.Dst -Parent) -Force | Out-Null
        if (Test-Path $p.Dst) { Remove-Item $p.Dst -Recurse -Force }
        Copy-Item $p.Src $p.Dst -Recurse -Force
        Write-Host ("    {0} {1}\{2}" -f $p.State, $p.Profile, $p.Dir) -ForegroundColor Green
    }

    Write-Host ''
    Write-Host '  Restored. Start Claude Desktop to pick the conversations up.' -ForegroundColor Green
    Write-Host '  Credentials were never in the backup, so sign in again if prompted.' -ForegroundColor DarkGray
    Write-Host ''
}
finally {
    Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
}
