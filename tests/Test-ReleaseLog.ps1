# Release log hygiene.
#
# The changelog is the release record, so it has to be true. Before this test it
# had drifted: every entry sat under [Unreleased] across six months and 46
# commits, no version was ever cut, no tag existed, and one release had two
# separate "### Fixed" sections - so an entry could be filed under either and
# a reader would see only one.
#
# What this asserts is the shape a reader relies on: versions are dated, ordered,
# tagged, and each section appears once.

param([switch]$SkipLive)

$root = Split-Path $PSScriptRoot -Parent
$changelog = Join-Path $root 'CHANGELOG.md'

$fail = 0
function Assert($label, $condition, $detail = '') {
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $label$(if ($detail) { " - $detail" })" -ForegroundColor Red; $script:fail++ }
}

Write-Host ''
Write-Host 'Release log - structure' -ForegroundColor Cyan

Assert 'a changelog exists' (Test-Path $changelog) $changelog
if (-not (Test-Path $changelog)) { Write-Host ''; Write-Host "$fail assertion(s) failed." -ForegroundColor Red; exit 1 }

$lines = Get-Content $changelog
$text = $lines -join "`n"

Assert 'it declares its format'    ($text -match 'Keep a Changelog')
Assert 'it declares its versioning' ($text -match '(?i)semantic versioning')
Assert 'it has an Unreleased section' ($text -match '(?m)^##\s*\[Unreleased\]')

# Released versions, newest first.
$versionLines = @($lines | Where-Object { $_ -match '^##\s*\[\d+\.\d+\.\d+\]' })
Assert 'it has at least one released version' ($versionLines.Count -gt 0)

$releases = @()
foreach ($l in $versionLines) {
    if ($l -match '^##\s*\[(?<v>\d+\.\d+\.\d+)\]\s*-\s*(?<d>\d{4}-\d{2}-\d{2})\s*$') {
        $releases += [pscustomobject]@{ Version = $Matches.v; Date = [datetime]$Matches.d; Line = $l }
    }
    else {
        $releases += [pscustomobject]@{ Version = $null; Date = $null; Line = $l }
    }
}

$undated = @($releases | Where-Object { -not $_.Version })
Assert 'every version carries an ISO date' ($undated.Count -eq 0) ($undated.Line -join ' | ')

if (-not $undated.Count -and $releases.Count -gt 1) {
    # Newest first. A changelog read top-down should walk backwards in time.
    $ordered = $true
    for ($i = 1; $i -lt $releases.Count; $i++) {
        if ($releases[$i].Date -gt $releases[$i - 1].Date) { $ordered = $false; break }
    }
    Assert 'releases run newest first' $ordered (($releases | ForEach-Object { "$($_.Version) $($_.Date.ToString('yyyy-MM-dd'))" }) -join ' -> ')
}

Write-Host ''
Write-Host 'Release log - each release is well formed' -ForegroundColor Cyan

# Split into blocks so section headings can be counted per release rather than
# across the file, which is how a duplicate "### Fixed" hid.
$blocks = @{}
$current = $null
foreach ($l in $lines) {
    if ($l -match '^##\s*\[(?<v>[^\]]+)\]') { $current = $Matches.v; $blocks[$current] = @() ; continue }
    if ($current) { $blocks[$current] += $l }
}

$known = @('Added', 'Changed', 'Deprecated', 'Removed', 'Fixed', 'Security', 'Known limitation')
$dupes = @()
$unknown = @()
foreach ($v in $blocks.Keys) {
    $heads = @($blocks[$v] | Where-Object { $_ -match '^###\s+' } | ForEach-Object { ($_ -replace '^###\s+', '').Trim() })
    foreach ($g in ($heads | Group-Object | Where-Object { $_.Count -gt 1 })) { $dupes += "$v has $($g.Count)x '$($g.Name)'" }
    foreach ($h in $heads) { if ($h -notin $known) { $unknown += "$v : $h" } }
}
Assert 'no release repeats a section heading' ($dupes.Count -eq 0) ($dupes -join ' | ')
Assert 'sections use the Keep a Changelog set' ($unknown.Count -eq 0) ($unknown -join ' | ')

$empty = @($blocks.Keys | Where-Object { -not @($blocks[$_] | Where-Object { $_.Trim() }).Count })
Assert 'no release is empty' ($empty.Count -eq 0) ($empty -join ', ')

# A scripted edit once inserted one new entry after every "### Added" heading in
# the file, joined to the next entry on the same line ("rows.- **MDM ..."), and
# the structure checks above still passed. An entry heading appears once, and a
# line never carries the start of a second entry.
$entryHeads = @($lines | Where-Object { $_ -match '^- \*\*[^*]+\*\*' } | ForEach-Object { ([regex]::Match($_, '^- \*\*[^*]+\*\*')).Value })
$repeated = @($entryHeads | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { "$($_.Count)x $($_.Name)" })
Assert 'no entry heading appears twice' ($repeated.Count -eq 0) ($repeated -join ' | ')
$runTogether = @($lines | Select-String -Pattern '[.!?)`*]- (\*\*|`|[A-Z])')
Assert 'no line runs two entries together' ($runTogether.Count -eq 0) (($runTogether | ForEach-Object { "line $($_.LineNumber)" }) -join ', ')

# A merge that was half resolved once committed "<<<<<<< HEAD" and "=======" into
# this file, and every check still passed. Conflict markers are refused in the
# changelog and in every tracked text file. A bare "=======" is not checked:
# Markdown uses it to underline a heading.
$markerPattern = '^(<<<<<<<|>>>>>>>)( |$)'
$changelogMarkers = @($lines | Select-String -Pattern $markerPattern)
Assert 'the changelog carries no merge conflict marker' ($changelogMarkers.Count -eq 0) (
    ($changelogMarkers | ForEach-Object { "line $($_.LineNumber)" }) -join ', ')
$textFiles = @(git -C $root ls-files 2>$null | Where-Object { $_ -match '\.(md|ps1|psm1|py|mjs|js|ts|json|bicep|xml|yml|yaml|toml|txt|sh|tcss|kql)$' })
$marked = @()
foreach ($rel in $textFiles) {
    $full = Join-Path $root $rel
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
    $hit = Select-String -LiteralPath $full -Pattern $markerPattern -List
    if ($hit) { $marked += "${rel}:$($hit.LineNumber)" }
}
Assert 'no tracked text file carries a merge conflict marker' ($textFiles.Count -gt 0 -and $marked.Count -eq 0) (
    $(if ($textFiles.Count) { $marked -join ', ' } else { 'git ls-files returned nothing' }))

Write-Host ''
Write-Host 'Release log - links and tags' -ForegroundColor Cyan

foreach ($r in ($releases | Where-Object { $_.Version })) {
    Assert "$($r.Version) has a compare link" ($text -match "(?m)^\[$([regex]::Escape($r.Version))\]:\s*http")
}
Assert 'Unreleased has a compare link' ($text -match '(?m)^\[Unreleased\]:\s*http')

# A version in the changelog with no tag is a release nobody can check out.
$tags = @(git -C $root tag --list 2>$null)
if (-not $tags.Count) {
    Assert 'the repository has release tags' $false 'no tags at all'
}
else {
    $missing = @($releases | Where-Object { $_.Version -and ("v$($_.Version)" -notin $tags) } | ForEach-Object { $_.Version })
    Assert 'every released version is tagged' ($missing.Count -eq 0) ("untagged: " + ($missing -join ', '))

    $newest = ($releases | Where-Object { $_.Version } | Select-Object -First 1)
    if ($newest) {
        $head = (git -C $root describe --tags --abbrev=0 2>$null)
        Assert 'the newest release is the newest tag reachable from HEAD' ($head -eq "v$($newest.Version)") "changelog says $($newest.Version), git says $head"
    }
}

Write-Host ''
if ($fail) { Write-Host "$fail assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'Release log holds.' -ForegroundColor Green
exit 0
