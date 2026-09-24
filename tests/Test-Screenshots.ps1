# Screenshots and the documentation that shows them.
#
# The complaint this exists to answer: "documentation still points to old
# screenshots". Three distinct ways that happens, and none of them break a
# build, so all three survive review:
#
#   1. a doc references an image that is not in the repository - the page
#      renders a broken image icon, which nobody sees until a reader reports it
#   2. an image is captured and committed but no doc shows it - dead weight
#      that looks like evidence of coverage it does not have
#   3. a capture step is added to guide/capture.mjs for a new feature and never
#      run, so the feature ships documented in prose and undocumented in
#      pictures
#
# The third is the one the others do not catch. A capture step is a declaration
# that this feature is worth showing; until the file exists, the declaration is
# unkept. Failing here is what turns "we should grab a screenshot of that" into
# a step that cannot be skipped.

$root = Split-Path $PSScriptRoot -Parent

$fail = 0
function Assert($label, $condition, $detail = '') {
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $label$(if ($detail) { " - $detail" })" -ForegroundColor Red; $script:fail++ }
}

Write-Host ''
Write-Host 'Screenshots' -ForegroundColor Cyan

$guideDir = Join-Path $root 'docs/guide'
$imagesDir = Join-Path $root 'docs/images'
$shots = @(Get-ChildItem $guideDir -Filter '*.png' -ErrorAction SilentlyContinue) +
         @(Get-ChildItem $imagesDir -Filter '*.png' -ErrorAction SilentlyContinue)
Assert 'the guide ships screenshots' ($shots.Count -gt 0)

# Every markdown file, wherever it lives, plus the two at the root.
$docs = @(Get-ChildItem (Join-Path $root 'docs') -Filter '*.md' -Recurse -ErrorAction SilentlyContinue) +
        @(Get-ChildItem $root -Filter '*.md' -ErrorAction SilentlyContinue)

# What the docs ask for, and where from. A path is recorded by file name only:
# DEVELOPER.md at the root writes docs/guide/x.png and MONITORING.md inside docs
# writes guide/x.png, and both mean the same file.
$referenced = @{}
$broken = @()
foreach ($d in $docs) {
    $n = 0
    foreach ($line in (Get-Content $d.FullName)) {
        $n++
        foreach ($m in [regex]::Matches($line, '!\[[^\]]*\]\(([^)]+\.png)\)')) {
            $rel = $m.Groups[1].Value
            if ($rel -match '^https?://') { continue }
            # Resolved against the document's own directory, which is what a
            # markdown renderer does. Images live in two places - docs/guide for
            # the annotated walkthrough captures and docs/images for the
            # diagrams - so checking one of them reports the other as broken.
            $target = Join-Path $d.DirectoryName $rel
            $referenced[(Split-Path $rel -Leaf)] = $true
            if (-not (Test-Path $target)) { $broken += "$($d.Name):$n -> $rel" }
        }
    }
}

Assert 'every image a doc shows exists' ($broken.Count -eq 0) ($broken -join ' | ')

# An orphan is not a failure on its own - a capture can legitimately be kept for
# a guide not yet written - but it is worth naming, because the usual cause is a
# doc that was rewritten and dropped the picture with it.
$orphans = @($shots | Where-Object { -not $referenced[$_.Name] } | ForEach-Object { $_.Name })
if ($orphans.Count) {
    Write-Host ("  [note] {0} image(s) no doc shows: {1}" -f $orphans.Count, ($orphans -join ', ')) -ForegroundColor DarkGray
}

Write-Host ''
Write-Host 'Captures declared against captures taken' -ForegroundColor Cyan

# Step ids are the contract. `id: 'd1-chargeback-totals',` in capture.mjs says
# there could be a docs/guide/d1-chargeback-totals.png.
#
# Not every one is committed, and that is deliberate rather than debt. A portal
# blade showing directory membership puts real names, addresses and object ids
# in the frame, and an Application Insights overview puts an instrumentation key
# in it - both were captured during this work and both were deleted rather than
# shipped. docs/ONBOARDING.md tells the reader to take those against their own
# tenant instead. So this reports drift rather than failing on it: the count is
# visible, and a reviewer can see whether a new feature arrived without a
# picture.
$capture = Get-Content (Join-Path $root 'guide/capture.mjs') -Raw
$ids = @([regex]::Matches($capture, "(?m)^\s*id:\s*'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
Assert 'capture.mjs declares steps' ($ids.Count -gt 0)

$taken = @($ids | Where-Object { Test-Path (Join-Path $guideDir "$_.png") })
$notTaken = @($ids | Where-Object { -not (Test-Path (Join-Path $guideDir "$_.png")) })
Write-Host ("  [note] {0} of {1} declared capture(s) committed; taken locally: {2}" -f `
    $taken.Count, $ids.Count, ($notTaken -join ', ')) -ForegroundColor DarkGray

# Identities must not survive into a committed screenshot. The capture masks
# them in the DOM before the pixels exist; this asserts the masking is still
# wired in, because a capture with a real address in it cannot be un-shipped.
$capMask = $capture -match 'NodeFilter\.SHOW_TEXT' -and $capture -match 'Redactor'
Assert 'captures mask identities before screenshotting' $capMask
Assert 'and refuse identifiers instead of retaining real tenant domains' (
    $capture -match 'redactor\.leaks' -and $capture -notmatch "m\.lastIndexOf\('@'\)")
# Masking emails is not the whole job - an Entra members blade shows display
# names and object ids beside them, and a metrics overview shows an
# instrumentation key. Those blades are not committed at all, and the guide has
# to say so or somebody will capture them again.
$guideDoc = Get-Content (Join-Path $root 'guide/README.md') -Raw
Assert 'the guide says which blades are not committed' (
    $guideDoc -match '(?s)not committed|against your own tenant')

Write-Host ''
Write-Host 'Turnstile live capture provenance and mutations' -ForegroundColor Cyan
Push-Location $root
try {
    & node --test tests/turnstile-captures.test.mjs
    Assert 'every Turnstile capture has verified live provenance' ($LASTEXITCODE -eq 0)
}
finally { Pop-Location }

Write-Host ''
if ($fail) { Write-Host "$fail assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host ("Screenshots hold: {0} image(s), {1} declared capture(s), {2} referenced." -f `
    $shots.Count, $ids.Count, $referenced.Count) -ForegroundColor Green
exit 0
