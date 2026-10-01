param(
    [string]$GuidePath,
    [string]$SpecPath,
    [string]$CapturePath
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if (-not $GuidePath) { $GuidePath = Join-Path $root 'docs\AZ-COMMANDS.md' }
if (-not $SpecPath) { $SpecPath = Join-Path $root 'guide\captures-pending\p90.json' }
if (-not $CapturePath) { $CapturePath = Join-Path $root 'docs\guide\portal-captures.json' }

$script:fail = 0
function Assert($Name, [bool]$Condition, [string]$Detail = '') {
    if ($Condition) {
        Write-Host "  [PASS] $Name" -ForegroundColor Green
    }
    else {
        $script:fail++
        Write-Host "  [FAIL] $Name $Detail" -ForegroundColor Red
    }
}

function Read-Text($Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Missing $Path" }
    Get-Content -LiteralPath $Path -Raw
}

function Get-PartBody([string]$Markdown, [int]$Part) {
    $pattern = "(?ms)^## $Part\. .*?(?=^## \d+\. |^## Pending portal captures|\z)"
    $match = [regex]::Match($Markdown, $pattern)
    if ($match.Success) { return $match.Value }
    return ''
}

function Get-PortalBody([string]$PartBody, [int]$Part) {
    $pattern = "(?ms)^### Part $Part in the portal\s*(.*?)(?=^## \d+\. |^## Pending portal captures|\z)"
    $match = [regex]::Match($PartBody, $pattern)
    if ($match.Success) { return $match.Groups[1].Value }
    return ''
}

function ConvertTo-RepoPath([string]$MarkdownPath) {
    $withoutAnchor = ($MarkdownPath -replace '#.*$', '')
    if (-not $withoutAnchor) { return $null }
    if ($withoutAnchor -match '^[a-z]+://') { return $null }
    $combined = [IO.Path]::GetFullPath((Join-Path (Join-Path $root 'docs') ($withoutAnchor -replace '/', '\')))
    if (-not $combined.StartsWith((Join-Path $root 'docs'), [StringComparison]::OrdinalIgnoreCase)) {
        throw "Image reference escapes docs: $MarkdownPath"
    }
    return $combined
}

function Load-Spec([string]$RelativePath) {
    $full = Join-Path $root ($RelativePath -replace '/', '\')
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "Missing spec $RelativePath" }
    return Read-Text $full | ConvertFrom-Json
}

Write-Host 'Azure CLI portal guide contract' -ForegroundColor Cyan
$markdown = Read-Text $GuidePath

for ($part = 1; $part -le 12; $part++) {
    $body = Get-PartBody $markdown $part
    Assert "part $part exists" ($body.Length -gt 0) "part=$part"
    $portalHeadingCount = @([regex]::Matches($body, "(?m)^### Part $part in the portal\s*$")).Count
    Assert "part $part has exactly one portal subsection" ($portalHeadingCount -eq 1) "count=$portalHeadingCount"
    $portal = Get-PortalBody $body $part
    $numbered = @([regex]::Matches($portal, '(?m)^\d+\. \*\*')).Count
    if ($part -eq 8) {
        Assert 'part 8 documents no portal equivalent' ($portal -match '(?i)No portal equivalent') 'part=8'
    }
    else {
        Assert "part $part portal subsection has a numbered step" ($numbered -ge 1) "count=$numbered"
    }
    $changeLaterCount = @([regex]::Matches($portal, '(?m)^\*\*Change later\.\*\*')).Count
    Assert "part $part has exactly one portal Change later paragraph" ($changeLaterCount -eq 1) "count=$changeLaterCount"
}

Assert 'per-step Portal paragraphs are removed' (-not ($markdown -match '(?m)^\*\*Portal\.\*\*'))

$withoutFences = [regex]::Replace($markdown, '(?ms)^```.*?^```', '')
$paragraphs = @(
    [regex]::Split($withoutFences, "(?:\r?\n){2,}") |
    ForEach-Object { ($_.Trim() -replace '\s+', ' ') } |
    Where-Object { $_.Length -ge 80 -and -not $_.StartsWith('|') -and -not $_.StartsWith('![') }
)
$duplicateParagraphs = @(
    $paragraphs | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name }
)
Assert 'no duplicate prose paragraphs of 80+ chars outside fenced blocks' ($duplicateParagraphs.Count -eq 0) ($duplicateParagraphs -join ' || ')

$imageMatches = @([regex]::Matches($markdown, '!\[[^\]]+\]\(([^)]+\.png)\)'))
$captureDoc = Read-Text $CapturePath | ConvertFrom-Json
$recordsByOutput = @{}
foreach ($record in $captureDoc.captures) {
    $recordsByOutput[$record.output] = $record
}
$recordsById = @{}
foreach ($record in $captureDoc.captures) {
    $recordsById[$record.id] = $record
}
$captionMatches = @([regex]::Matches($markdown, 'Capture id:\s+`([^`]+)`\.'))
$captionIds = @($captionMatches | ForEach-Object { $_.Groups[1].Value })

foreach ($match in $imageMatches) {
    $relative = $match.Groups[1].Value
    $file = ConvertTo-RepoPath $relative
    $repoOutput = (Resolve-Path -LiteralPath $file -ErrorAction SilentlyContinue)
    Assert "image resolves: $relative" ($null -ne $repoOutput) $relative
    if (-not $repoOutput) { continue }
    $output = [IO.Path]::GetRelativePath($root, $repoOutput.Path).Replace('\', '/')
    $record = $recordsByOutput[$output]
    Assert "image has portal capture record: $output" ($null -ne $record) $output
    if ($record) {
        Assert "record is live and redacted: $output" ([bool]$record.live -and [bool]$record.redaction.applied -and [bool]$record.redaction.leak_check_passed) $record.id
        $sha = (Get-FileHash -LiteralPath $repoOutput.Path -Algorithm SHA256).Hash.ToLowerInvariant()
        Assert "record sha256 matches file: $output" ($sha -eq $record.sha256) "$sha != $($record.sha256)"
        Assert "caption id matches record id: $output" ($captionIds -contains $record.id) $record.id
    }
}

foreach ($captionId in $captionIds) {
    Assert "caption id exists in capture inventory: $captionId" ($recordsById.ContainsKey($captionId)) $captionId
}

$pendingMatch = [regex]::Match($markdown, '(?ms)^## Pending portal captures.*?(?<table>\| planned capture id \| output path under `docs/guide/` \| spec file \| blade \| which step it illustrates \| what must exist live \| capture discovery kind \|\s*\r?\n\|[- |`]+\|\s*\r?\n(?<rows>(?:\|.*\|\s*\r?\n)+))')
Assert 'pending-captures table exists with spec file column' $pendingMatch.Success
$pending = @()
if ($pendingMatch.Success) {
    foreach ($line in ($pendingMatch.Groups['rows'].Value -split "`r?`n")) {
        if (-not $line.Trim()) { continue }
        $cells = @($line.Trim().Trim('|').Split('|') | ForEach-Object { $_.Trim() })
        if ($cells.Count -eq 7) {
            $pending += [pscustomobject]@{
                id = $cells[0].Trim('`')
                output = 'docs/guide/' + $cells[1].Trim('`')
                specFile = $cells[2].Trim('`')
            }
        }
    }
}

$specCache = @{}
foreach ($item in $pending) {
    if (-not $specCache.ContainsKey($item.specFile)) {
        $specCache[$item.specFile] = Load-Spec $item.specFile
    }
    $match = @($specCache[$item.specFile].steps | Where-Object { $_.id -eq $item.id -and $_.output -eq $item.output })
    Assert "pending row exists in named spec: $($item.id)" ($match.Count -eq 1) "$($item.specFile) $($item.output)"
    Assert "pending output is not already present: $($item.output)" (-not (Test-Path -LiteralPath (Join-Path $root ($item.output -replace '/', '\')) -PathType Leaf)) $item.output
}

Assert 'staged pending capture spec exists' (Test-Path -LiteralPath $SpecPath -PathType Leaf) $SpecPath
$spec = $null
if (Test-Path -LiteralPath $SpecPath -PathType Leaf) {
    $spec = Read-Text $SpecPath | ConvertFrom-Json
    $modulePath = [IO.Path]::GetFullPath((Join-Path $root 'guide\lib\portal-specs.mjs'))
    $check = @"
import fs from 'node:fs';
import { pathToFileURL } from 'node:url';
const moduleUrl = pathToFileURL(process.argv[2]).href;
const { specProblems } = await import(moduleUrl);
const file = process.argv[3];
const doc = JSON.parse(fs.readFileSync(file, 'utf8'));
const problems = specProblems(doc, file);
if (problems.length) {
  console.error(problems.join('\n'));
  process.exit(1);
}
"@
    $checkPath = Join-Path ([IO.Path]::GetTempPath()) ('p90-spec-check-' + [guid]::NewGuid().ToString('N') + '.mjs')
    Set-Content -LiteralPath $checkPath -Value $check -Encoding UTF8
    try {
        Push-Location $root
        $nodeOutput = & node $checkPath $modulePath $SpecPath 2>&1 | Out-String
        $nodeOk = $LASTEXITCODE -eq 0
    }
    finally {
        Pop-Location
        Remove-Item -LiteralPath $checkPath -Force -ErrorAction SilentlyContinue
    }
    Assert 'staged pending spec passes specProblems()' $nodeOk $nodeOutput
}

$p90Rows = @($pending | Where-Object { $_.specFile -eq 'guide/captures-pending/p90.json' } | ForEach-Object { "$($_.id)|$($_.output)" })
$p90SpecPairs = @()
if ($spec -and $spec.steps) {
    foreach ($step in $spec.steps) { $p90SpecPairs += "$($step.id)|$($step.output)" }
}
Assert 'every p90.json pending step appears in the table' ((@($p90Rows | Sort-Object) -join "`n") -eq (@($p90SpecPairs | Sort-Object) -join "`n")) "table=$($p90Rows -join ', ') spec=$($p90SpecPairs -join ', ')"

$overview = [regex]::Match($markdown, '(?ms)^## Portal and CLI overview\s*(?<table>\| Part \| What it configures .*?\r?\n\|[- |]+\|\s*\r?\n(?<rows>(?:\|.*\|\s*\r?\n)+))')
Assert 'overview table exists' $overview.Success
if ($overview.Success) {
    $parts = @()
    foreach ($line in ($overview.Groups['rows'].Value -split "`r?`n")) {
        if ($line -match '^\|\s*§?(\d+)\b') { $parts += [int]$matches[1] }
        if ($line -match '^\|\s*(\d+)\b') {
            $part = [int]$matches[1]
            Assert "overview portal column links to part $part subsection" ($line -match "\(#part-$part-in-the-portal\)") $line
        }
    }
    $partList = @($parts | Sort-Object) -join ','
    Assert 'overview table has one row per part, 1-12' ($partList -eq '1,2,3,4,5,6,7,8,9,10,11,12') ($parts -join ',')
}

if ($script:fail) {
    Write-Host "Azure CLI portal guide contract failed: $script:fail check(s)." -ForegroundColor Red
    exit 1
}
Write-Host 'Azure CLI portal guide contract passed.' -ForegroundColor Green
