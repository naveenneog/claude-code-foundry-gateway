<#
.SYNOPSIS
    Generates one platform's Claude Desktop 3P policy for an access-catalog profile.

.DESCRIPTION
    The access catalog remains authoritative for profile identity and capabilities.
    The existing Claude Code policy generator remains authoritative for the full
    third-party connection settings and OS-specific serialization.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)][string]$CatalogPath,
    [Parameter(Mandatory = $true)][string]$ProfileId,
    [Parameter(Mandatory = $true)]
    [ValidateSet('Linux', 'Windows', 'macOS')]
    [string]$Platform,
    [string]$ConfigPath,
    [string]$GatewayUrl,
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'

function Resolve-ClaudeAccessProfileCatalogPath {
    param([Parameter(Mandatory)][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path -match '[\*\?\[\]\x00-\x1f]') {
        throw 'Access profile policy refused: CatalogPath is unsafe. Use one literal JSON file path.'
    }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item -or $item.PSIsContainer -or $item.PSProvider.Name -ne 'FileSystem' -or $item.Extension -ine '.json') {
        throw 'Access profile policy refused: CatalogPath must name one existing JSON file.'
    }
    return $item.FullName
}

function Resolve-ClaudeAccessProfileOutputPath {
    param([Parameter(Mandatory)][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path -match '[\*\?\[\]\x00-\x1f]') {
        throw 'Access profile policy refused: OutputPath is unsafe. Use one literal filesystem directory.'
    }
    $provider = $null
    $drive = $null
    try {
        $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
            $Path,
            [ref]$provider,
            [ref]$drive
        )
    }
    catch {
        throw 'Access profile policy refused: OutputPath is not a valid filesystem directory.'
    }
    if (-not $provider -or $provider.Name -ne 'FileSystem') {
        throw 'Access profile policy refused: OutputPath must use the filesystem provider.'
    }
    $root = [IO.Path]::GetPathRoot($resolved)
    if ($resolved.TrimEnd('\', '/') -eq $root.TrimEnd('\', '/')) {
        throw 'Access profile policy refused: OutputPath cannot be a filesystem root.'
    }
    if (Test-Path -LiteralPath $resolved -PathType Leaf) {
        throw 'Access profile policy refused: OutputPath names a file, not a directory.'
    }
    return $resolved
}

if ($ProfileId -cnotmatch '^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$') {
    throw 'Access profile policy refused: ProfileId must be a canonical lowercase id.'
}

$resolvedCatalog = Resolve-ClaudeAccessProfileCatalogPath -Path $CatalogPath
if (-not $OutputPath) { $OutputPath = ".\policy-claude-desktop-$ProfileId" }
$resolvedOutput = Resolve-ClaudeAccessProfileOutputPath -Path $OutputPath
$descriptorCli = Join-Path (Split-Path $PSScriptRoot -Parent) 'sync\src\describe-access-profile.mjs'

$previousPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = 'Continue'
    $global:LASTEXITCODE = 0
    $raw = @(& node $descriptorCli --catalog $resolvedCatalog --profile $ProfileId 2>&1)
    $code = $LASTEXITCODE
}
finally { $ErrorActionPreference = $previousPreference }

$lastJson = @($raw | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] } |
    ForEach-Object { [string]$_ } | Where-Object { $_.Trim().StartsWith('{') }) | Select-Object -Last 1
$descriptor = $null
if ($lastJson) {
    try { $descriptor = $lastJson | ConvertFrom-Json -ErrorAction Stop }
    catch { $descriptor = $null }
}
if ($code -ne 0 -or -not $descriptor -or $descriptor.ok -ne $true) {
    $stage = if ($descriptor -and [string]$descriptor.stage -cmatch '^[a-z][a-z-]{0,39}$') {
        [string]$descriptor.stage
    }
    else { 'catalog' }
    $message = if ($descriptor -and $descriptor.message) { [string]$descriptor.message } else { 'validation failed' }
    throw "Access profile policy refused at stage $stage`: $message"
}

$capabilities = @($descriptor.profile.capabilities)
$chatEnabled = $capabilities -contains 'chat'
$coworkEnabled = $capabilities -contains 'cowork'
$codeEnabled = $capabilities -contains 'code'
$policyFile = switch ($Platform) {
    'Linux' { 'claude-desktop.managed-settings.json' }
    'Windows' { 'claude-desktop.reg' }
    'macOS' { 'claude-desktop.mobileconfig' }
}
$manifestFile = 'claude-desktop.profile.json'
$policyTarget = Join-Path $resolvedOutput $policyFile
$manifestTarget = Join-Path $resolvedOutput $manifestFile

Write-Host ("Access profile policy plan: catalog={0} plan={1} profile={2} platform={3}" -f
    $descriptor.catalog.hash, $descriptor.plan.id, $descriptor.profile.id, $Platform)
Write-Host "Intended policy: $policyTarget"
Write-Host "Intended manifest: $manifestTarget"

if ($WhatIfPreference) {
    Write-Host 'WhatIf: catalog and profile validation completed; no policy files were written.'
    return [pscustomobject]@{
        Written = $false
        CatalogHash = $descriptor.catalog.hash
        PlanId = $descriptor.plan.id
        ProfileId = $descriptor.profile.id
        Platform = $Platform
        Outputs = @($policyTarget, $manifestTarget)
    }
}

if (-not $PSCmdlet.ShouldProcess($resolvedOutput, "write Claude Desktop $Platform access-profile policy")) {
    throw 'Access profile policy generation was declined; no policy files were written.'
}

$work = Join-Path ([IO.Path]::GetTempPath()) ('claude-desktop-profile-' + [guid]::NewGuid().ToString('N'))
try {
    $generator = Join-Path $PSScriptRoot 'New-ClaudeCodePolicy.ps1'
    $arguments = @{
        Tier = [string]$descriptor.plan.compatibilityTier
        DesktopChatEnabled = [bool]$chatEnabled
        DesktopCoworkEnabled = [bool]$coworkEnabled
        DesktopCodeEnabled = [bool]$codeEnabled
        OutputPath = $work
    }
    if ($ConfigPath) { $arguments['ConfigPath'] = $ConfigPath }
    if ($GatewayUrl) { $arguments['GatewayUrl'] = $GatewayUrl }
    $null = & $generator @arguments

    $sourcePolicy = Join-Path $work $policyFile
    if (-not (Test-Path -LiteralPath $sourcePolicy -PathType Leaf)) {
        throw "Access profile policy generation failed: $policyFile was not rendered."
    }

    $unsupported = @()
    if ($capabilities -contains 'design') {
        $unsupported += [ordered]@{
            id = 'design'
            kind = 'capability'
            reason = 'no-documented-claude-desktop-3p-setting'
        }
    }
    $unmanaged = @()
    if (@($descriptor.profile.connectors) -contains 'm365') {
        $unmanaged += [ordered]@{
            id = 'm365'
            kind = 'connector'
            deploymentPath = 'connector-admin'
            reason = 'no-documented-managed-configuration-toggle'
        }
    }
    $manifest = [ordered]@{
        schemaVersion = 1
        platform = $Platform
        policyFile = $policyFile
        catalog = $descriptor.catalog
        plan = $descriptor.plan
        profile = $descriptor.profile
        clientControls = [ordered]@{
            chatTabEnabled = [bool]$chatEnabled
            coworkTabEnabled = [bool]$coworkEnabled
            isClaudeCodeForDesktopEnabled = [bool]$codeEnabled
        }
        metadata = [ordered]@{
            modelFamilies = @($descriptor.profile.modelFamilies)
            connectors = @($descriptor.profile.connectors)
        }
        unsupported = @($unsupported)
        unmanaged = @($unmanaged)
    }

    New-Item -ItemType Directory -Force -Path $resolvedOutput | Out-Null
    Copy-Item -LiteralPath $sourcePolicy -Destination $policyTarget -Force
    [IO.File]::WriteAllText(
        $manifestTarget,
        ($manifest | ConvertTo-Json -Depth 10),
        [Text.UTF8Encoding]::new($false)
    )
}
finally {
    if (Test-Path -LiteralPath $work) {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "Wrote: $policyTarget"
Write-Host "Wrote: $manifestTarget"
return [pscustomobject]@{
    Written = $true
    CatalogHash = $descriptor.catalog.hash
    PlanId = $descriptor.plan.id
    ProfileId = $descriptor.profile.id
    Platform = $Platform
    Outputs = @($policyTarget, $manifestTarget)
}
