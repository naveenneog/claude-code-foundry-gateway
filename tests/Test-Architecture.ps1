# Architecture sources, rendered pictures and code must agree.
# Mutations run in a unique copy under the repository, never against real files.
[CmdletBinding()]
param([switch]$CheckOnly)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$checker = Join-Path $root 'guide/check-architecture.mjs'
$fail = 0
$assertions = 0

function Assert($Label, $Condition, $Detail = '') {
    $script:assertions++
    if ($Condition) { Write-Host "  [OK]   $Label" -ForegroundColor Green }
    else {
        $script:fail++
        Write-Host "  [FAIL] $Label - $Detail" -ForegroundColor Red
    }
}

function Invoke-ArchitectureCheck([string]$Directory) {
    # PS 5.1 turns redirected native stderr into error records. A negative
    # mutation is expected to write stderr; inspect its exit code, do not throw.
    $ErrorActionPreference = 'Continue'
    $output = & node $checker --root $Directory 2>&1 | Out-String
    [pscustomobject]@{ Code = $LASTEXITCODE; Output = $output }
}

Write-Host 'Architecture generation contract' -ForegroundColor Cyan
& node --test (Join-Path $root 'guide/architecture-live.test.mjs') (Join-Path $root 'guide/architecture-cache.test.mjs') | Out-Host
Assert 'live-capture discovery and privacy helpers hold offline' ($LASTEXITCODE -eq 0)
Assert 'the offline architecture checker ships' (Test-Path $checker)
if (-not (Test-Path $checker)) { exit 1 }
$baseline = Invoke-ArchitectureCheck $root
Assert 'committed pictures agree with sources and code' ($baseline.Code -eq 0) $baseline.Output
if ($baseline.Code -ne 0) { exit 1 }
if ($CheckOnly) { Write-Host $baseline.Output; exit 0 }

$fixture = Join-Path (Join-Path $root '.shots-entra') ('architecture-test-' + [guid]::NewGuid().ToString('N'))
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Copy-FixtureFile([string]$Relative) {
    $from = Join-Path $root $Relative
    $to = Join-Path $fixture $Relative
    $parent = Split-Path $to -Parent
    if (-not (Test-Path $parent)) { New-Item $parent -ItemType Directory -Force | Out-Null }
    Copy-Item -LiteralPath $from -Destination $to -Force
}

function Write-FixtureJson([string]$Path, $Value) {
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 80), $script:utf8)
}

function Invoke-Mutation([string]$Label, [string]$Relative, [scriptblock]$Change, [string]$Expected) {
    $path = Join-Path $fixture $Relative
    $existed = Test-Path -LiteralPath $path
    $before = if ($existed) { [IO.File]::ReadAllBytes($path) } else { $null }
    try {
        & $Change $path
        $result = Invoke-ArchitectureCheck $fixture
        Assert $Label ($result.Code -ne 0 -and $result.Output.Contains($Expected)) $result.Output
    }
    finally {
        if ($existed) { [IO.File]::WriteAllBytes($path, $before) }
        elseif (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
}

try {
    New-Item $fixture -ItemType Directory -Force | Out-Null
    $manifest = Get-Content (Join-Path $root 'docs/architecture/manifest.json') -Raw | ConvertFrom-Json
    $files = @('docs/architecture/manifest.json', 'README.md', 'docs/ARCHITECTURE.md')
    foreach ($diagram in $manifest.diagrams) {
        $files += @($diagram.inputs.PSObject.Properties | ForEach-Object { $_.Name })
        $files += @($diagram.outputs | ForEach-Object { $_.path })
    }
    $files += @(Get-ChildItem (Join-Path $root 'infra') -Filter '*.bicep' -Recurse |
        ForEach-Object { $_.FullName.Substring($root.Length + 1) })
    $files += @(Get-ChildItem (Join-Path $root 'docs') -Filter '*.md' -Recurse |
        ForEach-Object { $_.FullName.Substring($root.Length + 1) })
    foreach ($file in @($files | Sort-Object -Unique)) { Copy-FixtureFile $file }
    $copy = Invoke-ArchitectureCheck $fixture
    Assert 'an isolated copy passes without Azure, npm or a Git checkout' ($copy.Code -eq 0) $copy.Output
    if ($copy.Code -ne 0) { throw 'The mutation fixture is not a faithful copy.' }

    Invoke-Mutation 'editing a source without rendering is caught' 'docs/architecture/01-system.json' {
        param($p)
        $spec = Get-Content $p -Raw | ConvertFrom-Json
        $spec.subtitle += ' changed'
        Write-FixtureJson $p $spec
    } 'SOURCE_STALE'

    Invoke-Mutation 'editing the shared renderer invalidates pictures' 'guide/render-architecture.mjs' {
        param($p)
        [IO.File]::AppendAllText($p, "`n// mutation`n", $script:utf8)
    } 'SOURCE_STALE'

    Invoke-Mutation 'altering rendered bytes is caught' 'docs/images/architecture/system-overview.png' {
        param($p)
        [IO.File]::WriteAllBytes($p, ([IO.File]::ReadAllBytes($p) + [byte]0))
    } 'IMAGE_STALE'

    Invoke-Mutation 'a stale README alias is caught' 'docs/images/request-flow.png' {
        param($p)
        [IO.File]::WriteAllBytes($p, ([IO.File]::ReadAllBytes($p) + [byte]0))
    } 'IMAGE_STALE'

    Invoke-Mutation 'a source with a missing rendered image is caught' 'docs/images/architecture/system-overview.png' {
        param($p)
        Remove-Item -LiteralPath $p
    } 'IMAGE_MISSING'

    Invoke-Mutation 'a newly added source must be rendered' 'docs/architecture/99-unrendered.json' {
        param($p)
        $spec = Get-Content (Join-Path $fixture 'docs/architecture/01-system.json') -Raw | ConvertFrom-Json
        $spec.id = 'unrendered'
        $spec.outputs = @('docs/images/architecture/unrendered.png')
        Write-FixtureJson $p $spec
    } 'SOURCE_UNRENDERED'

    Invoke-Mutation 'deleting a source leaves an orphan image' 'docs/architecture/01-system.json' {
        param($p)
        Remove-Item -LiteralPath $p
    } 'IMAGE_ORPHAN'

    Invoke-Mutation 'an image with no source is caught' 'docs/images/architecture/unowned.png' {
        param($p)
        Copy-Item (Join-Path $fixture 'docs/images/architecture/system-overview.png') $p
    } 'IMAGE_ORPHAN'

    Invoke-Mutation 'an unowned SVG cannot bypass PNG ownership checks' 'docs/images/architecture/unowned.svg' {
        param($p)
        [IO.File]::WriteAllText($p, '<svg xmlns="http://www.w3.org/2000/svg"/>', $script:utf8)
    } 'IMAGE_ORPHAN'

    Invoke-Mutation 'a picture no document references is caught' 'docs/ARCHITECTURE.md' {
        param($p)
        $text = [IO.File]::ReadAllText($p)
        $text = [regex]::Replace($text, '(?m)^!\[[^\]]*\]\(images/architecture/system-overview\.png\)\r?\n?', '')
        [IO.File]::WriteAllText($p, $text, $script:utf8)
    } 'IMAGE_UNREFERENCED'

    Invoke-Mutation 'deleting a labelled script cannot hide behind prose' 'scripts/Sync-ClaudeAccess.ps1' {
        param($p)
        Remove-Item -LiteralPath $p
    } 'IDENTIFIER_MISSING'

    Invoke-Mutation 'renaming a log table in its query is caught' 'analytics/chargeback-ledger.kql' {
        param($p)
        $text = [IO.File]::ReadAllText($p).Replace('ApiManagementGatewayLlmLog', 'RenamedGatewayLog')
        [IO.File]::WriteAllText($p, $text, $script:utf8)
    } 'IDENTIFIER_MISSING'

    Invoke-Mutation 'renaming a named value in the policy is caught' 'infra/policy.xml' {
        param($p)
        $text = [IO.File]::ReadAllText($p).Replace('quota-org', 'renamed-org-quota')
        [IO.File]::WriteAllText($p, $text, $script:utf8)
    } 'IDENTIFIER_MISSING'

    Invoke-Mutation 'renaming a resolver function is caught' 'resolver/src/lookup.mjs' {
        param($p)
        $text = [IO.File]::ReadAllText($p).Replace('createLookup', 'renamedLookup')
        [IO.File]::WriteAllText($p, $text, $script:utf8)
    } 'IDENTIFIER_MISSING'

    Invoke-Mutation 'merged AUM engine labels are checked against local code' 'cli/finops/src/claude_finops/engine.py' {
        param($p)
        $text = [IO.File]::ReadAllText($p).Replace('class Engine:', 'class RenamedEngine:')
        [IO.File]::WriteAllText($p, $text, $script:utf8)
    } 'IDENTIFIER_MISSING'

    Invoke-Mutation 'renaming an Entra app role is caught' 'scripts/New-ClaudeTurnstileEntraApp.ps1' {
        param($p)
        $text = [IO.File]::ReadAllText($p).Replace('Turnstile.Manager', 'Turnstile.RenamedManager')
        [IO.File]::WriteAllText($p, $text, $script:utf8)
    } 'IDENTIFIER_MISSING'

    Invoke-Mutation 'renaming a sign-in route is caught' 'scripts/Open-ClaudeTurnstile.ps1' {
        param($p)
        $text = [IO.File]::ReadAllText($p).Replace('/api/v1/auth/cli', '/api/v1/auth/renamed')
        [IO.File]::WriteAllText($p, $text, $script:utf8)
    } 'IDENTIFIER_MISSING'

    Invoke-Mutation 'an unbound code label is caught before rendering' 'docs/architecture/01-system.json' {
        param($p)
        $spec = Get-Content $p -Raw | ConvertFrom-Json
        $spec.subtitle += ' [[nonexistent-label]]'
        Write-FixtureJson $p $spec
    } 'IDENTIFIER_UNBOUND'

    Invoke-Mutation 'a new Azure resource type needs a diagram' 'infra/architecture-mutation.bicep' {
        param($p)
        [IO.File]::WriteAllText($p, "resource sample 'Microsoft.ArchitectureMutation/widgets@2026-01-01' = { name: 'example' }", $script:utf8)
    } 'RESOURCE_UNCOVERED'

    Invoke-Mutation 'a diagram cannot invent an Azure resource type' 'docs/architecture/07-resources.json' {
        param($p)
        $spec = Get-Content $p -Raw | ConvertFrom-Json
        $spec.sections[0].types += 'Microsoft.ArchitectureMutation/widgets'
        Write-FixtureJson $p $spec
    } 'RESOURCE_UNKNOWN'

    $hiddenTypeFile = Join-Path $fixture 'infra/architecture-mutation.bicep'
    try {
        [IO.File]::WriteAllText($hiddenTypeFile, "resource sample 'Microsoft.ArchitectureMutation/widgets@2026-01-01' = { name: 'example' }", $script:utf8)
        Invoke-Mutation 'undrawn flow metadata cannot satisfy resource coverage' 'docs/architecture/01-system.json' {
            param($p)
            $spec = Get-Content $p -Raw | ConvertFrom-Json
            $section = [pscustomobject]@{ title = 'Hidden'; note = 'Not drawn'; types = @('Microsoft.ArchitectureMutation/widgets') }
            $spec | Add-Member -MemberType NoteProperty -Name sections -Value @($section) -Force
            Write-FixtureJson $p $spec
        } 'RESOURCE_UNCOVERED'
    }
    finally { Remove-Item -LiteralPath $hiddenTypeFile -Force }

    Invoke-Mutation 'undrawn inventory cards cannot satisfy label coverage' 'docs/architecture/07-resources.json' {
        param($p)
        $spec = Get-Content $p -Raw | ConvertFrom-Json
        $card = [pscustomobject]@{ id = 'hidden'; title = '[[hidden-script]]'; lines = @() }
        $spec | Add-Member -MemberType NoteProperty -Name nodes -Value @($card) -Force
        $witness = [pscustomobject]@{ label = 'Sync-ClaudeAccess.ps1'; source = 'scripts/Sync-ClaudeAccess.ps1'; kind = 'file' }
        $spec.identifiers | Add-Member -MemberType NoteProperty -Name 'hidden-script' -Value $witness -Force
        Write-FixtureJson $p $spec
    } 'IDENTIFIER_MISSING'

    Invoke-Mutation 'two sources cannot overwrite the same output' 'docs/architecture/01-system.json' {
        param($p)
        $spec = Get-Content $p -Raw | ConvertFrom-Json
        $spec.outputs += 'docs/images/architecture/request-path.png'
        Write-FixtureJson $p $spec
    } 'OUTPUT_DUPLICATE'

    Invoke-Mutation 'output paths cannot escape the diagram directory' 'docs/architecture/01-system.json' {
        param($p)
        $spec = Get-Content $p -Raw | ConvertFrom-Json
        $spec.outputs = @('../escaped.png')
        Write-FixtureJson $p $spec
    } 'PATH_UNSAFE'

    Invoke-Mutation 'malformed sources fail clearly' 'docs/architecture/01-system.json' {
        param($p)
        [IO.File]::WriteAllText($p, '{not json', $script:utf8)
    } 'SPEC_INVALID'

    $commentFile = Join-Path $fixture 'infra/architecture-mutation.bicep'
    try {
        [IO.File]::WriteAllText($commentFile,
            "// resource sample 'Microsoft.ArchitectureMutation/widgets@2026-01-01' = {}`n/* resource other 'Microsoft.ArchitectureMutation/other@2026-01-01' = {} */",
            $script:utf8)
        $commented = Invoke-ArchitectureCheck $fixture
        Assert 'commented-out resource examples do not invent deployments' ($commented.Code -eq 0) $commented.Output
    }
    finally { Remove-Item -LiteralPath $commentFile -Force }

    $baselines = Join-Path $fixture 'docs/images/finops'
    New-Item $baselines -ItemType Directory -Force | Out-Null
    $baselineSvg = Join-Path $baselines 'unreferenced-test-baseline.svg'
    try {
        [IO.File]::WriteAllText($baselineSvg, '<svg xmlns="http://www.w3.org/2000/svg"/>', $script:utf8)
        $baselineScope = Invoke-ArchitectureCheck $fixture
        Assert 'unreferenced FinOps snapshot baselines are not architecture orphans' ($baselineScope.Code -eq 0) $baselineScope.Output
    }
    finally { Remove-Item -LiteralPath $baselineSvg -Force }

    $normalizedPath = Join-Path $fixture 'infra/policy.xml'
    $before = [IO.File]::ReadAllBytes($normalizedPath)
    try {
        $text = [IO.File]::ReadAllText($normalizedPath).Replace("`r`n", "`n")
        [IO.File]::WriteAllText($normalizedPath, $text, $script:utf8)
        $endings = Invoke-ArchitectureCheck $fixture
        Assert 'Git line-ending conversion does not report false drift' ($endings.Code -eq 0) $endings.Output
    }
    finally { [IO.File]::WriteAllBytes($normalizedPath, $before) }

    $boundary = Join-Path $fixture 'boundary'
    $outside = Join-Path $fixture 'outside-boundary'
    $link = Join-Path $boundary 'link'
    New-Item $boundary, $outside -ItemType Directory | Out-Null
    [IO.File]::WriteAllText((Join-Path $outside 'marker.txt'), 'test data', $script:utf8)
    try {
        $linkType = if ($env:OS -eq 'Windows_NT') { 'Junction' } else { 'SymbolicLink' }
        New-Item -Path $link -ItemType $linkType -Target $outside | Out-Null
        $probe = 'import {pathToFileURL} from "node:url"; const m=await import(pathToFileURL(process.argv[2])); try { m.localPath(process.argv[3], "link/marker.txt"); console.log("unexpected path escape"); } catch(e) { console.log(e.message); process.exitCode=1; }'
        $result = $probe | & node --input-type=module - (Join-Path $root 'guide/architecture-model.mjs') $boundary | Out-String
        Assert 'junctions cannot escape the declared root' ($LASTEXITCODE -ne 0 -and $result.Contains('PATH_UNSAFE')) $result
    }
    finally {
        if (Test-Path -LiteralPath $link) { [IO.Directory]::Delete($link) }
    }

    $resourceProbe = @'
import { pathToFileURL } from 'node:url';
const m = await import(pathToFileURL(process.argv[2]));
const root = process.argv[3];
const { specs } = m.loadSpecs(root);
const spec = specs.find(s => s.id === 'system-overview');
spec.identifiers['resource-probe'] = {
  kind: 'resource', label: 'Microsoft.ArchitectureMutation/widgets',
  source: 'infra/architecture-mutation.bicep',
  match: "resource sample 'Microsoft.ArchitectureMutation/widgets@2026-01-01'"
};
spec.nodes[0].lines.push('[[resource-probe]]');
const errors = m.validateSpecs(root, specs);
console.log(errors.join('\n') || 'Rendered resource coverage PASS');
process.exitCode = errors.length ? 1 : 0;
'@
    $resourceFile = Join-Path $fixture 'infra/architecture-mutation.bicep'
    $notBicep = Join-Path $fixture 'infra/architecture-mutation.txt'
    try {
        [IO.File]::WriteAllText($resourceFile, "resource sample 'Microsoft.ArchitectureMutation/widgets@2026-01-01' = { name: 'example' }", $script:utf8)
        $result = $resourceProbe | & node --input-type=module - (Join-Path $root 'guide/architecture-model.mjs') $fixture | Out-String
        Assert 'a drawn source-backed resource label satisfies type coverage' ($LASTEXITCODE -eq 0) $result
        [IO.File]::WriteAllText($resourceFile, "// resource sample 'Microsoft.ArchitectureMutation/widgets@2026-01-01' = { name: 'example' }", $script:utf8)
        $result = $resourceProbe | & node --input-type=module - (Join-Path $root 'guide/architecture-model.mjs') $fixture | Out-String
        Assert 'a resource label needs a declaration, not a comment witness' ($LASTEXITCODE -ne 0 -and $result.Contains('RESOURCE_LABEL_INVALID')) $result
        [IO.File]::WriteAllText($resourceFile, "resource sample 'Microsoft.ArchitectureMutation/widgets@2026-01-01' = { name: 'example' }", $script:utf8)
        [IO.File]::WriteAllText($notBicep, "resource sample 'Microsoft.ArchitectureMutation/widgets@2026-01-01' = { name: 'example' }", $script:utf8)
        $nonBicepProbe = $resourceProbe.Replace("source: 'infra/architecture-mutation.bicep'", "source: 'infra/architecture-mutation.txt'")
        $result = $nonBicepProbe | & node --input-type=module - (Join-Path $root 'guide/architecture-model.mjs') $fixture | Out-String
        Assert 'a resource witness must be Bicep, not documentation text' ($LASTEXITCODE -ne 0 -and $result.Contains('RESOURCE_LABEL_INVALID')) $result
    }
    finally { Remove-Item -LiteralPath $resourceFile,$notBicep -Force -ErrorAction SilentlyContinue }
}
finally {
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}

Write-Host ''
if ($fail) { Write-Host "$fail architecture assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "Architecture holds: $assertions assertions, including isolated mutations." -ForegroundColor Green
exit 0
