# P18b: the load envelope, and the ceilings that decide it.
#
# The failure this guards against is a capacity claim with no measurement
# behind it. Two specific ways that happens here:
#
#   a ceiling copied from a document   Documents drift, and the one for named
#                                      values disagreed with the service. Every
#                                      figure the script enforces has to be
#                                      derived or measured, not pasted
#
#   a traffic model invented to fill   The reference deployment holds 111
#   a gap                              requests across 2 days. An envelope
#                                      extrapolated from that would read as
#                                      evidence and be nothing of the kind
#
# Offline. The live half ran against the reference gateway: 4,096 characters
# accepted and 4,097 rejected, 110 object ids accepted and 111 rejected.

$root = Split-Path $PSScriptRoot -Parent
$ceiling = Join-Path $root 'scripts/Measure-ClaudeCeiling.ps1'
$scale = Join-Path $root 'docs/SCALE.md'

$fail = 0
function Assert($label, $condition, $detail = '') {
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $label$(if ($detail) { " - $detail" })" -ForegroundColor Red; $script:fail++ }
}

Write-Host ''
Write-Host 'Scale - the ceiling measurement' -ForegroundColor Cyan

Assert 'a ceiling script exists' (Test-Path $ceiling)
$c = Get-Content $ceiling -Raw

# The limit itself. Asserted as the assignment, because the comment above it
# explains the measurement and repeats every number in prose - matching "4096"
# anywhere in the file would pass with the constant deleted.
Assert 'the character limit is the measured one' ($c -match '\$MaxChars\s*=\s*4096')
Assert 'an object id costs 37 characters'        ($c -match '\$OidCost\s*=\s*37')

# The identity ceiling has to be derived from those two. A hard-coded 110 would
# still be correct today and would silently stop being correct if the service
# raised the limit.
Assert 'the identity ceiling is derived, not pasted' `
    ($c -match '\$MaxIdentities\s*=\s*\[int\]\[math\]::Floor\(\(\$MaxChars - 1\) / \$OidCost\)')
Assert 'and it is not written as a literal' ($c -notmatch '\$MaxIdentities\s*=\s*110')

# Per-entry cost is measured from the list being read. bu-members entries carry
# "oid=unit" and cost more than a bare object id, so assuming 37 would overstate
# the remaining room on exactly the list that fills first.
Assert 'per-entry cost is measured from the data' `
    ($c -match '\$per\s*=\s*if \(\$items\.Count\)\s*\{\s*\[int\]\[math\]::Ceiling\(\$chars / \$items\.Count\)')

# A secret named value returns no value. Counting that as an empty list reads as
# maximum headroom, which is the wrong direction to be wrong in.
Assert 'a secret list is reported, not counted as empty' ($c -match 'if \(\$entry\.secret\)')

# It has to fail, not just report. The condition is asserted rather than the
# word "exit", which appears on the success path too.
Assert 'it exits non-zero past the threshold' `
    ($c -match 'if \(\$worst -ge \$FailAtPercent\)[\s\S]{0,600}exit 1')
Assert 'the threshold is overridable' ($c -match '\[int\]\$FailAtPercent = 80')

# The published per-instance caps differ by SKU, and a wrong cap is worse than
# a missing one, so an unrecognised SKU must say so rather than default.
Assert 'named value caps are held per SKU'   ($c -match "'StandardV2'\s*=\s*10000")
Assert 'and Basic v2 is the lower figure'    ($c -match "'BasicV2'\s*=\s*5000")
Assert 'an unknown SKU is reported, not guessed' ($c -match 'Unknown SKU')

Write-Host ''
Write-Host 'Scale - the envelope' -ForegroundColor Cyan

Assert 'the envelope is documented' (Test-Path $scale)
$s = Get-Content $scale -Raw

Assert 'it names the binding limit'      ($s -match '110 developers per tier')
Assert 'it states writes fail, not truncate' ($s -match 'fails outright')
Assert 'it rejects sharding as the escape'   ($s -match 'Sharding does not rescue it')
Assert 'and says why, not just that'         ($s -match 'in \*\*API Management policy configuration\*\* is what cannot work')

# The five numbers. A capacity page that lists only headcount is the thing this
# packet exists to stop.
foreach ($n in 'Daily active developers', 'Peak requests per second', 'Peak token rate',
                'Streaming concurrency', 'Burst shape') {
    Assert "the envelope asks for $n" ($s -match [regex]::Escape($n))
}

# The honesty requirement. This deployment cannot supply a traffic model, and
# the page has to say so rather than quietly presenting the method as a result.
Assert 'it states what has not been measured' ($s -match '111 requests across 2 days')
Assert 'and refuses to extrapolate from it'   ($s -match 'no evidence behind it')

# A counter test that only proves keys can be created proves nothing about
# whether allowance survives.
Assert 'it defines what a capacity test must prove' ($s -match 'retains its consumed allowance')
foreach ($e in 'Scale-out', 'Policy deployment', 'Period rollover') {
    Assert "and covers $e" ($s -match [regex]::Escape($e))
}

Assert 'it points at the projection decision' ($s -match 'adr/0005-identity-projection\.md')

Write-Host ''
Write-Host 'Scale - reachable from the README' -ForegroundColor Cyan

# Documentation that nothing links to is documentation nobody reads. Six pages
# were unreachable from the README before this check existed, including the
# business unit guide, which is a whole feature area.
#
# Asserted per file, so a new page under docs/ either gets linked or fails the
# run. The list is derived from the directory rather than written out, because
# a hard-coded list stops catching the next one.
$readme = Get-Content (Join-Path $root 'README.md') -Raw
$unlinked = @()
foreach ($doc in Get-ChildItem (Join-Path $root 'docs') -File -Filter *.md) {
    if ($readme -notmatch [regex]::Escape($doc.Name)) { $unlinked += $doc.Name }
}
Assert 'every page under docs/ is linked from the README' ($unlinked.Count -eq 0) ($unlinked -join ', ')

# The ADR directory is linked as a set, not only the individual records that
# happen to be cited in prose.
Assert 'the decision records are linked as a set' ($readme -match '\]\(docs/adr/\)')
Assert 'and the scale guide is in the index'      ($readme -match '\[Scale\]\(docs/SCALE\.md\)')

Write-Host ''
if ($fail) { Write-Host "$fail assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'Scale contract holds.' -ForegroundColor Green
exit 0
