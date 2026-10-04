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
