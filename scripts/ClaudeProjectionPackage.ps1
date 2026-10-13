# The sync package: the files the projection renewal image and the in-network runner both run.
# Paths stay repository-relative, so a module's relative imports resolve in the package exactly
# as they do in the repository (ADR-0049). Importing this file performs no Azure call.

$script:ClaudeProjectionSyncPackagePaths = @(
    'sync/Dockerfile',
    'sync/package.json',
    'sync/package-lock.json',
    'sync/src',
    # sync/src/plan.mjs imports ../../resolver/src/entitlement.mjs, the resolver's own record
    # validation, so admission counts only records the resolver would serve.
    'resolver/src/entitlement.mjs'
)

function Get-ClaudeProjectionSyncPackagePaths {
    [CmdletBinding()]
    param()
    return @($script:ClaudeProjectionSyncPackagePaths)
}

function New-ClaudeProjectionSyncPackage {
    <#
    .SYNOPSIS
        Copies the sync package into an empty directory, keeping repository-relative paths.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Destination,
        [string]$Root = (Split-Path $PSScriptRoot -Parent)
    )
    if (Test-Path -LiteralPath $Destination) {
        if (@(Get-ChildItem -LiteralPath $Destination -Force).Count) { throw "Sync package destination '$Destination' is not empty." }
    }
    else { New-Item -ItemType Directory -Force -Path $Destination | Out-Null }
    foreach ($relative in $script:ClaudeProjectionSyncPackagePaths) {
        $source = Join-Path $Root $relative
        if (-not (Test-Path -LiteralPath $source)) { throw "Sync package source '$relative' is missing under '$Root'." }
        $target = Join-Path $Destination $relative
        New-Item -ItemType Directory -Force -Path (Split-Path $target -Parent) | Out-Null
        Copy-Item -LiteralPath $source -Destination $target -Recurse -Force
    }
    return (Resolve-Path -LiteralPath $Destination).Path
}

function New-ClaudeProjectionResolverArchive {
    <#
    .SYNOPSIS
        Zips a staged resolver publish folder for Kudu zip-deploy
        (az functionapp deployment source config-zip).

    .DESCRIPTION
        Kudu's zip-deploy endpoint needs a real PKZIP archive with forward-slash entry
        names. GNU tar's -a (--auto-compress) does not produce one for an unrecognized
        .zip suffix: GNU tar supports gzip, bzip2, lzip, lzma, lzop, zstd, xz and compress
        only - zip is not an archive format it can write (GNU tar manual, "Creating and
        Reading Compressed Archives",
        https://www.gnu.org/software/tar/manual/html_node/gzip.html, read 2026-10-13). On
        a machine whose tar is GNU tar (most Linux distributions; not the libarchive/bsdtar
        some platforms ship), tar -a -c -f resolver.zip ... silently writes a tar-format
        file under a .zip name, and Kudu then refuses it with
        "InvalidPackageContentException: ... End of Central Directory record could not be
        found" - reproduced live on a customer deployment, 2026-10-13.

        Entries are added one file at a time through System.IO.Compression.ZipFile with an
        explicit, forward-slash-normalized relative name - the same approach
        Publish-ClaudeAumService.ps1 already uses for its own zip-deploy - rather than
        Compress-Archive, because docs/SECURE-PROJECTION.md's "Publish the resolver code"
        step records that Compress-Archive "can write paths with backslashes that break
        extraction on Linux" as the reason tar was chosen originally. (Measured here on
        PowerShell 7.6.6, Compress-Archive already normalizes to forward slashes; this
        function does not depend on that holding across every PowerShell 7 minor version.)
        A file that cannot be read (for example a dangling node_modules/.bin symlink,
        which Node's own module resolution never follows) is skipped, not fatal.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $full = (Resolve-Path -LiteralPath $Source).Path.TrimEnd('\', '/')
    $files = @(Get-ChildItem -LiteralPath $full -Recurse -File -Force -ErrorAction SilentlyContinue)
    if (-not $files.Count) { throw "Resolver publish source '$Source' is empty." }
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::Open($Path, 'Create')
    try {
        foreach ($file in $files) {
            $relative = $file.FullName.Substring($full.Length + 1).Replace('\', '/')
            try { [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $file.FullName, $relative) | Out-Null }
            catch { Write-Warning "Resolver archive: skipped unreadable file '$relative' ($($_.Exception.Message))" }
        }
    }
    finally { $archive.Dispose() }
    return (Resolve-Path -LiteralPath $Path).Path
}

function New-ClaudeProjectionSyncArchive {
    <#
    .SYNOPSIS
        Writes the sync package as a .tar.gz whose entries start at sync/ and resolver/.
        The runner unpacks it at /work, so /work/sync/src/plan.mjs finds its imports.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Root = (Split-Path $PSScriptRoot -Parent)
    )
    $stage = Join-Path ([IO.Path]::GetTempPath()) ('claude-sync-package-' + [guid]::NewGuid().ToString('N'))
    try {
        $null = New-ClaudeProjectionSyncPackage -Destination $stage -Root $Root
        $tops = @($script:ClaudeProjectionSyncPackagePaths | ForEach-Object { ($_ -split '/')[0] } | Select-Object -Unique)
        & tar -c -z -f $Path -C $stage @tops
        if ($LASTEXITCODE -ne 0) { throw 'Sync package archive creation failed.' }
    }
    finally { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
    return $Path
}
