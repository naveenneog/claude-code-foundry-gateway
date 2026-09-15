# Negative test for the business unit checks.
#
# A check that passes is worth nothing until it has been seen to fail. This
# breaks each thing Test-BusinessUnits.ps1 claims to guard, one at a time,
# confirms the suite goes red, and moves on.
#
# It works on a throwaway copy of the repository, never the repository itself.
# The first version edited the real files and restored them afterwards, which
# has two failure modes that matter: two suites running at once see each
# other's mutations, and an interrupted run leaves a corrupted policy.xml
# behind. Both were observed - a concurrent -IncludeAzure run turned the gate
# red while every mutation here reported caught.

$root = Split-Path $PSScriptRoot -Parent
$sandbox = Join-Path ([IO.Path]::GetTempPath()) "bu-negative-$PID-$(Get-Random)"

$mutations = @(
    @{ Name  = 'membership lookup removed from the policy'
       File  = 'infra/policy.xml'
       From  = 'bu-members'
       To    = 'bu-members-DISABLED' }

    @{ Name  = 'comma anchoring dropped from the lookup'
       File  = 'infra/policy.xml'
       From  = 'var marker = "," + oid + "=";'
       To    = 'var marker = oid + "=";' }

    @{ Name  = 'the per-unit quota stops being monthly'
       File  = 'infra/policy.xml'
       From  = 'token-quota-period="Monthly"'
       To    = 'token-quota-period="Yearly"' }

    @{ Name  = 'the refusal stops naming the unit'
       File  = 'infra/policy.xml'
       From  = '(string)(context.Variables.GetValueOrDefault("businessUnit", "unknown"))'
       To    = '"your unit"' }

    @{ Name  = 'the registry parser splits on the first colon'
       File  = 'scripts/ClaudeBusinessUnit.ps1'
       From  = 'LastIndexOf('
       To    = 'IndexOf(' }

    @{ Name  = 'an identifier with a comma is accepted'
       File  = 'scripts/ClaudeBusinessUnit.ps1'
       From  = "^[a-z0-9][a-z0-9-]*$"
       To    = '.' }

    @{ Name  = 'the report stops saying the figure is list price'
       File  = 'scripts/Get-ClaudeBusinessUnit.ps1'
       From  = "'  Figures are at list price"
       To    = "'  Figures are at the price" }

    @{ Name  = 'the cache caveat retreats into a comment'
       File  = 'scripts/Get-ClaudeBusinessUnit.ps1'
       From  = 'and exclude cached tokens'
       To    = 'and are approximate' }

    @{ Name  = 'the guide understates the measured cache gap'
       File  = 'docs/BUSINESS-UNITS.md'
       From  = '38.7'
       To    = '3.7' }

    @{ Name  = 'the guide loses its screenshots'
       File  = 'docs/BUSINESS-UNITS.md'
       From  = '!['
       To    = 'see [' }

    @{ Name  = 'the guide stops explaining unassigned'
       File  = 'docs/BUSINESS-UNITS.md'
       From  = 'unassigned'
       To    = 'unallocated' }
)

$missed = @()
$caught = 0

try {
    New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
    foreach ($d in 'infra', 'scripts', 'tests', 'analytics') {
        if (Test-Path (Join-Path $root $d)) {
            Copy-Item (Join-Path $root $d) $sandbox -Recurse -Force
        }
    }
    # Screenshots are a few megabytes and nothing here reads them, so the
    # markdown is copied without them.
    New-Item -ItemType Directory -Path (Join-Path $sandbox 'docs/adr') -Force | Out-Null
    Get-ChildItem (Join-Path $root 'docs') -Recurse -File -Filter *.md | ForEach-Object {
        $rel = $_.FullName.Substring((Join-Path $root 'docs').Length).TrimStart('\', '/')
        $dest = Join-Path (Join-Path $sandbox 'docs') $rel
        New-Item -ItemType Directory -Path (Split-Path $dest -Parent) -Force | Out-Null
        Copy-Item $_.FullName $dest -Force
    }

    $suite = Join-Path $sandbox 'tests/Test-BusinessUnits.ps1'

    # The copy must pass before any mutation, or a "caught" result below could
    # just mean the sandbox is broken.
    & $suite *>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host '  [SETUP] the unmutated copy already fails - the sandbox is wrong, not the code' -ForegroundColor Red
        exit 1
    }
    Write-Host '  [BASE]   the unmutated copy passes' -ForegroundColor DarkGray

    foreach ($m in $mutations) {
        $path = Join-Path $sandbox $m.File
        $original = [IO.File]::ReadAllText($path)

        if (-not $original.Contains($m.From)) {
            Write-Host "  [SETUP] '$($m.From)' not found in $($m.File)" -ForegroundColor Yellow
            $missed += "$($m.Name) (mutation did not apply)"
            continue
        }

        # Replace() not -replace: the patterns hold regex metacharacters, and a
        # literal swap is what we want.
        [IO.File]::WriteAllText($path, $original.Replace($m.From, $m.To))

        & $suite *>&1 | Out-Null
        $wentRed = ($LASTEXITCODE -ne 0)

        [IO.File]::WriteAllText($path, $original)

        if ($wentRed) {
            Write-Host "  [CAUGHT] $($m.Name)" -ForegroundColor Green
            $caught++
        }
        else {
            Write-Host "  [MISSED] $($m.Name)" -ForegroundColor Red
            $missed += $m.Name
        }
    }
}
finally {
    if (Test-Path $sandbox) { Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
Write-Host "$caught of $($mutations.Count) mutations caught."

if ($missed.Count) {
    Write-Host ''
    Write-Host 'Not caught - these assertions do not measure what they claim:' -ForegroundColor Red
    $missed | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}

Write-Host 'Every mutation was caught.' -ForegroundColor Green
# Explicit: the loop above deliberately leaves $LASTEXITCODE at 1, because the
# last thing it ran was a suite that was supposed to go red. Falling off the
# end here would report that as this script's own failure.
exit 0
