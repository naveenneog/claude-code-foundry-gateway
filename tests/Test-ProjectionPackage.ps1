# The sync package that the projection renewal image and the in-network runner run (ADR-0049).
#
# sync/src/plan.mjs imports ../../resolver/src/entitlement.mjs. Tests that run in the repository
# layout cannot see a package that leaves that file out, so this check builds the package, unpacks
# it outside the repository and starts both entry points there. Offline: the Azure SDK modules are
# stand-ins, and nothing reaches Azure or the npm registry.

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$fail = 0
function Assert($Label, [bool]$Condition, $Detail = '') {
    if ($Condition) { Write-Host "  [OK]   $Label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $Label$(if ($Detail) { " - $Detail" })" -ForegroundColor Red; $script:fail++ }
}

function Get-ModuleImports([string]$Path) {
    $text = [IO.File]::ReadAllText($Path)
    $specs = @()
    foreach ($m in [regex]::Matches($text, '(?m)^\s*(?:import|export)\s[^;]*?\sfrom\s+[''"]([^''"]+)[''"]')) { $specs += $m.Groups[1].Value }
    foreach ($m in [regex]::Matches($text, '(?m)^\s*import\s+[''"]([^''"]+)[''"]')) { $specs += $m.Groups[1].Value }
    foreach ($m in [regex]::Matches($text, 'import\(\s*[''"]([^''"]+)[''"]\s*\)')) { $specs += $m.Groups[1].Value }
    return $specs
}

function Get-ImportClosureProblems([string]$PackageRoot, [string[]]$Dependencies) {
    $problems = @()
    $full = [IO.Path]::GetFullPath($PackageRoot)
    foreach ($module in Get-ChildItem -LiteralPath $PackageRoot -Recurse -File -Filter '*.mjs' | Where-Object { $_.FullName -notmatch '[\\/]node_modules[\\/]' }) {
        foreach ($spec in Get-ModuleImports $module.FullName) {
            $where = $module.FullName.Substring($full.Length + 1) -replace '\\', '/'
            if ($spec.StartsWith('.')) {
                $target = [IO.Path]::GetFullPath((Join-Path $module.DirectoryName $spec))
                if (-not $target.StartsWith($full + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { $problems += "$where imports $spec outside the package" }
                elseif (-not (Test-Path -LiteralPath $target -PathType Leaf)) { $problems += "$where imports $spec, which the package does not contain" }
            }
            elseif ($spec.StartsWith('node:')) { continue }
            else {
                $name = if ($spec.StartsWith('@')) { ($spec -split '/')[0..1] -join '/' } else { ($spec -split '/')[0] }
                if ($name -notin $Dependencies) { $problems += "$where imports $spec, which sync/package.json does not declare" }
            }
        }
    }
    return $problems
}

function Add-StandInSdk([string]$SyncDirectory) {
    $modules = @{
        '@azure/cosmos'   = "export class CosmosClient { constructor(options) { this.options = options; } database() { return { container: () => ({ items: {} }) }; } }`n"
        '@azure/identity' = "export class DefaultAzureCredential { async getToken() { return { token: 'stand-in' }; } }`n"
    }
    foreach ($name in $modules.Keys) {
        $dir = Join-Path $SyncDirectory ('node_modules\' + ($name -replace '/', '\'))
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        [IO.File]::WriteAllText((Join-Path $dir 'package.json'), "{`"name`":`"$name`",`"version`":`"0.0.0-stand-in`",`"type`":`"module`",`"exports`":`"./index.mjs`"}`n")
        [IO.File]::WriteAllText((Join-Path $dir 'index.mjs'), $modules[$name])
    }
}

function Invoke-Entrypoint([string]$Script) {
    $saved = @{}
    foreach ($name in 'COSMOS_ENDPOINT', 'PROJECTION_TENANT_ID', 'PROJECTION_ACCOUNT_RESOURCE_ID', 'PROJECTION_IMAGE_DIGEST', 'PROJECTION_ENTRYPOINT') {
        $saved[$name] = [Environment]::GetEnvironmentVariable($name)
        [Environment]::SetEnvironmentVariable($name, $null)
    }
    try {
        $previous = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $out = & node $Script 2>&1 | Out-String
        $code = $LASTEXITCODE
        $ErrorActionPreference = $previous
    }
    finally { foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) } }
    $json = $null
    $last = @($out -split "`r?`n" | Where-Object { $_.Trim().StartsWith('{') }) | Select-Object -Last 1
    if ($last) { try { $json = $last | ConvertFrom-Json } catch { $json = $null } }
    [pscustomobject]@{ Output = $out; Code = $code; Json = $json }
}

Write-Host ''
Write-Host 'Projection sync package - one layout for the image and the runner' -ForegroundColor Cyan

. (Join-Path $root 'scripts\ClaudeProjectionPackage.ps1')
$dependencies = @((Get-Content -LiteralPath (Join-Path $root 'sync\package.json') -Raw | ConvertFrom-Json).dependencies.PSObject.Properties.Name)
$work = Join-Path ([IO.Path]::GetTempPath()) ('projection-package-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    $package = New-ClaudeProjectionSyncPackage -Destination (Join-Path $work 'package') -Root $root
    $closure = @(Get-ImportClosureProblems $package $dependencies)
    Assert 'every import in the package resolves inside it or to a declared dependency' ($closure.Count -eq 0) ($closure -join '; ')
    Assert 'the package holds no tests and no installed modules' (-not @(Get-ChildItem -LiteralPath $package -Recurse -Directory | Where-Object { $_.Name -in 'test', 'tests', 'node_modules' }).Count)

    # The runner's layout: the archive unpacked at /work, then the entry points run from it.
    $archive = New-ClaudeProjectionSyncArchive -Path (Join-Path $work 'sync-source.tar.gz') -Root $root
    $listing = @(& tar -t -z -f $archive | ForEach-Object { ($_ -replace '\\', '/').TrimStart('.', '/') })
    foreach ($required in 'sync/package.json', 'sync/package-lock.json', 'sync/src/apply-projection.mjs', 'sync/src/check-admission.mjs', 'sync/src/plan.mjs', 'resolver/src/entitlement.mjs') {
        Assert "the runner archive carries $required" ($listing -contains $required) ($listing -join ', ')
    }
    $unpacked = Join-Path $work 'work'
    New-Item -ItemType Directory -Force -Path $unpacked | Out-Null
    & tar -x -z -f $archive -C $unpacked
    Assert 'the runner archive unpacks' ($LASTEXITCODE -eq 0)
    Add-StandInSdk (Join-Path $unpacked 'sync')
    $apply = Invoke-Entrypoint (Join-Path $unpacked 'sync\src\apply-projection.mjs')
    Assert 'apply-projection.mjs starts outside the repository and asks for its endpoint' ($apply.Code -eq 1 -and $apply.Json -and $apply.Json.error -eq '--cosmos is required') $apply.Output.Trim()
    $admission = Invoke-Entrypoint (Join-Path $unpacked 'sync\src\check-admission.mjs')
    Assert 'check-admission.mjs starts outside the repository and asks for its endpoint' ($admission.Code -eq 1 -and $admission.Json -and $admission.Json.error -eq '--cosmos is required') $admission.Output.Trim()

    # Negative control: the same start fails when the package misses a module, so the two
    # assertions above cannot pass on a layout that stops with a missing import.
    $broken = Join-Path $work 'broken'
    Copy-Item -LiteralPath $unpacked -Destination $broken -Recurse
    $entitlement = Join-Path $broken 'resolver\src\entitlement.mjs'
    if (Test-Path -LiteralPath $entitlement) { Remove-Item -LiteralPath $entitlement }
    $missing = Invoke-Entrypoint (Join-Path $broken 'sync\src\apply-projection.mjs')
    Assert 'control: without resolver/src/entitlement.mjs the entry point stops with a missing module' ($missing.Code -ne 0 -and $missing.Output -match 'ERR_MODULE_NOT_FOUND') $missing.Output.Trim()

    $lock = Join-Path $root 'sync\package-lock.json'
    Assert 'sync/package-lock.json is committed' (Test-Path -LiteralPath $lock)
    if (Test-Path -LiteralPath $lock) {
        $lockText = [IO.File]::ReadAllText($lock)
        # npm writes a "resolved" tarball URL for the registry it used. A workstation behind a
        # private feed would put that feed's host into the repository, and npm ci elsewhere would
        # try to reach it; without the key npm ci uses the registry it is configured with.
        Assert 'the lockfile names no registry tarball URL' ($lockText -notmatch '"resolved"\s*:')
        $lockJson = $lockText | ConvertFrom-Json -AsHashtable
        $declared = (Get-Content -LiteralPath (Join-Path $root 'sync\package.json') -Raw | ConvertFrom-Json -AsHashtable).dependencies
        $locked = $lockJson.packages[''].dependencies
        $same = $locked -and @($declared.Keys | Where-Object { $locked[$_] -ne $declared[$_] }).Count -eq 0 -and $locked.Count -eq $declared.Count
        Assert 'the lockfile records the dependencies sync/package.json declares' $same
        foreach ($name in $declared.Keys) {
            Assert "the lockfile pins $name" ([bool]$lockJson.packages["node_modules/$name"].version)
        }
        $unhashed = @($lockJson.packages.Keys | Where-Object { $_ -and -not $lockJson.packages[$_].integrity })
        Assert 'every locked package carries an integrity hash' ($unhashed.Count -eq 0) ($unhashed -join ', ')
    }
}
finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host ''
Write-Host 'Projection sync package - the image and the deployer use the package' -ForegroundColor Cyan

$docker = Get-Content -LiteralPath (Join-Path $root 'sync\Dockerfile') -Raw
$copies = @([regex]::Matches($docker, '(?m)^COPY\s+(.+?)\s+(\S+)\s*$') | ForEach-Object { [pscustomobject]@{ Sources = @($_.Groups[1].Value -split '\s+'); Target = $_.Groups[2].Value } })
$packagePaths = @(Get-ClaudeProjectionSyncPackagePaths)
$copied = @($copies | ForEach-Object { $_.Sources })
foreach ($source in $copied) {
    Assert "the image copies $source from the package" ($packagePaths -contains $source -or @($packagePaths | Where-Object { $source.StartsWith("$_/") }).Count -gt 0) ($packagePaths -join ', ')
}
foreach ($path in $packagePaths | Where-Object { $_ -ne 'sync/Dockerfile' }) {
    Assert "the image copies package path $path" ($copied -contains $path)
}
Assert 'the image installs from the lockfile' ($docker -match '(?m)^RUN npm ci --omit=dev --ignore-scripts\b')
Assert 'the entry point is unchanged' ($docker -match '(?m)^ENTRYPOINT \["node", "/app/sync/src/apply-projection\.mjs"\]')
Assert 'the resolver module lands where plan.mjs imports it' ($docker -match '(?m)^COPY resolver/src/entitlement\.mjs /app/resolver/src/entitlement\.mjs\s*$' -and
    [IO.File]::ReadAllText((Join-Path $root 'sync\src\plan.mjs')).Contains("from '../../resolver/src/entitlement.mjs'"))

$deployer = Get-Content -LiteralPath (Join-Path $root 'scripts\Deploy-ClaudeProjection.ps1') -Raw
Assert 'the deployer archives the package' ($deployer -match 'New-ClaudeProjectionSyncArchive -Path \$syncArchive' -and $deployer -notmatch "tar -c -z -f \`$syncArchive -C \(Join-Path \`$root 'sync'\)")
Assert 'the runner unpacks the package at /work' ($deployer.Contains("'tar -x -z -f /work/sync-source.tar.gz -C /work'"))
Assert 'the runner installs from the lockfile' ($deployer.Contains("'npm --prefix /work/sync ci --omit=dev --ignore-scripts --no-audit --fund=false'"))

# The bash guide cannot call the PowerShell function, so its archive list is bound to it here.
$guide = [IO.File]::ReadAllText((Join-Path $root 'docs\AZ-COMMANDS.md'))
$tarLine = [regex]::Match($guide, '(?m)^\s*tar -c -z -f sync-source\.tar\.gz (.+?) \|\| return 1\s*$')
$guidePaths = if ($tarLine.Success) { @($tarLine.Groups[1].Value.Trim() -split '\s+') } else { @() }
Assert 'the guide runner archive lists exactly the package paths' (($guidePaths -join ' ') -ceq ((Get-ClaudeProjectionSyncPackagePaths) -join ' ')) ($guidePaths -join ' ')
Assert 'the guide runner unpacks at /work and installs from the lockfile' ($guide.Contains('tar -x -z -f /work/sync-source.tar.gz -C /work"') -and $guide.Contains('npm --prefix /work/sync ci --omit=dev --ignore-scripts'))
$secure = [IO.File]::ReadAllText((Join-Path $root 'docs\SECURE-PROJECTION.md'))
# No locked package declares an install script, so skipping them changes nothing and removes a path
# by which a replaced package could run code at install time.
$lockPackages = @(((Get-Content -LiteralPath (Join-Path $root 'sync\package-lock.json') -Raw | ConvertFrom-Json -AsHashtable).packages).GetEnumerator() | Where-Object { $_.Key })
$withScripts = @($lockPackages | Where-Object { $_.Value.hasInstallScript } | ForEach-Object Key)
$installs = foreach ($source in @(@('sync/Dockerfile', $docker), @('scripts/Deploy-ClaudeProjection.ps1', $deployer), @('docs/AZ-COMMANDS.md', $guide), @('docs/SECURE-PROJECTION.md', $secure))) {
    foreach ($m in [regex]::Matches($source[1], '(?m)npm (?:--prefix \S+ )?ci\b[^\r\n''"]*')) { [pscustomobject]@{ File = $source[0]; Command = $m.Value } }
}
$unsafe = @($installs | Where-Object { $_.Command -notmatch '--ignore-scripts\b' } | ForEach-Object { "$($_.File): $($_.Command)" })
Assert 'every npm ci of the sync package skips install scripts, and no locked package has one' (@($installs).Count -ge 4 -and $unsafe.Count -eq 0 -and $withScripts.Count -eq 0) "installs $(@($installs).Count); unsafe: $($unsafe -join ' | '); with scripts: $($withScripts -join ', ')"
Assert 'the runbook archives the package and unpacks it at /work' ($secure.Contains('New-ClaudeProjectionSyncArchive -Path $archive') -and $secure.Contains("'tar -x -z -f /work/sync-source.tar.gz -C /work'") -and $secure -notmatch 'tar -c -z -f \$archive -C sync')
Assert 'the runbook builds the image from the package through the renewal script' ($secure.Contains('scripts\Deploy-ClaudeProjectionRenewal.ps1') -and $secure.Contains('`az acr build` from the sync package') -and $secure -notmatch 'az acr build [^\r\n]*--no-logs sync\b')

# The Windows suite cannot build a Linux image, so CI builds it from the same package and starts
# both entry points; a missing module there exits 1 without the JSON line the check requires.
$workflow = [IO.File]::ReadAllText((Join-Path $root '.github\workflows\projection-image.yml'))
Assert 'CI builds the image from the package the deployer and the runner use' ($workflow.Contains('New-ClaudeProjectionSyncPackage -Destination') -and $workflow -match 'docker build --file "\$PACKAGE_DIR/sync/Dockerfile" [^\r\n]* "\$PACKAGE_DIR"')
Assert 'CI starts both entry points and requires their own argument error' ($workflow -match '(?m)^\s+check apply-projection docker run --rm claude-projection-sync:ci\s*$' -and $workflow -match '(?m)^\s+check check-admission docker run --rm --entrypoint node claude-projection-sync:ci /app/sync/src/check-admission\.mjs\s*$' -and $workflow.Contains('.error == "--cosmos is required"'))
foreach ($path in Get-ClaudeProjectionSyncPackagePaths) {
    Assert "CI runs when $path changes" ($workflow -match "(?m)^\s+- '$([regex]::Escape($(if ($path -eq 'sync/src' -or $path -like 'sync/*') { 'sync/**' } else { $path })))'\s*$")
}

Write-Host ''
if ($fail) { Write-Host "$fail assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'Projection sync package holds.' -ForegroundColor Green
exit 0
