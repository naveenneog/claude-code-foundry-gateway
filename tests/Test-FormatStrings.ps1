# Format strings that crash at the point of use.
#
# PowerShell's -f operator uses .NET composite formatting, where alignment is
# expressed as {index,width}: a positive width right-aligns and a negative one
# left-aligns. There is no ">" in that syntax.
#
# `"{0,>14}" -f $x` parses fine and passes every static check. It throws only
# when the line runs:
#
#   Error formatting a string: Input string was not in a correct format.
#
# So it survives review, survives a test suite that never executes that branch,
# and fails in front of whoever first runs the command. It shipped that way in
# Set-ClaudeBudget.ps1 -List in v1.4.0 and was found by hand three weeks later.
#
# This is a static check because the alternative - executing every display path
# of every script - needs Azure and an administrator's permissions.

$root = Split-Path $PSScriptRoot -Parent

$fail = 0
function Assert($label, $condition, $detail = '') {
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $label$(if ($detail) { " - $detail" })" -ForegroundColor Red; $script:fail++ }
}

Write-Host ''
Write-Host 'Format strings' -ForegroundColor Cyan

$files = @(Get-ChildItem (Join-Path $root 'scripts') -Filter '*.ps1' -Recurse -ErrorAction SilentlyContinue) +
         @(Get-ChildItem (Join-Path $root 'tests') -Filter '*.ps1' -Recurse -ErrorAction SilentlyContinue) +
         @(Get-ChildItem $root -Filter '*.ps1' -ErrorAction SilentlyContinue)

$bad = @()
foreach ($f in $files) {
    $n = 0
    foreach ($line in (Get-Content $f.FullName)) {
        $n++
        if ($line.TrimStart().StartsWith('#')) { continue }

        # {0,>14} and friends: an alignment that is not a signed integer.
        foreach ($m in [regex]::Matches($line, '\{\s*\d+\s*,\s*(?<a>[^}:]+?)\s*(?::[^}]*)?\}')) {
            $a = $m.Groups['a'].Value
            if ($a -notmatch '^-?\d+$') { $bad += "$($f.Name):$n  $($m.Value)" }
        }
    }
}

Assert 'every alignment is a signed integer' ($bad.Count -eq 0) ($bad -join ' | ')

# Prove the check is not vacuous: the thing it looks for must actually throw.
#
# Built from character codes rather than written out, because any literal form
# of the forbidden pattern is found by the scan above and this file reports
# itself. An open brace never appears in this source.
$ob = [char]0x7B
$cb = [char]0x7D
$gt = [char]0x3E
# Plain concatenation. An interpolated "$ob`0" would read the backtick-zero as a
# NUL escape, which also throws - so the forbidden case would have passed for
# entirely the wrong reason.
$forbidden = $ob + '0,' + $gt + '4' + $cb
$allowed = $ob + '0,-4' + $cb + '|' + $ob + '1,4' + $cb

$throws = $false
try { [string]::Format($forbidden, 'x') | Out-Null } catch { $throws = $true }
Assert 'the pattern it forbids really does throw' $throws '.NET accepted it, so this check guards nothing'

$ok = $true
try { [string]::Format($allowed, 'a', 'b') | Out-Null } catch { $ok = $false }
Assert 'the pattern it allows does not' $ok

# Dot-sourced helpers behind a Test-Path guard.
#
# Same failure shape as the above: it parses, it reviews clean, and it does
# nothing. The guard exists so a trimmed-down copy of the repo still runs, but
# it also swallows a typo in the filename - the script carries on with the
# helper's functions undefined. Manage-ClaudeBusinessUnits.ps1 shipped pointing
# at ClaudeBanner.ps1, which has never existed, and the console simply printed
# no banner. Nothing failed, so nothing reported it.
Write-Host ''
Write-Host 'Dot-sourced helper paths' -ForegroundColor Cyan

$missing = @()
$checked = 0
foreach ($f in $files) {
    $n = 0
    foreach ($line in (Get-Content $f.FullName)) {
        $n++
        if ($line.TrimStart().StartsWith('#')) { continue }

        # $x = Join-Path $PSScriptRoot 'Name.ps1'  - the only form used here.
        # Resolved against the *script's* directory, not the test's, which is
        # what $PSScriptRoot means at that line.
        $m = [regex]::Match($line, "Join-Path\s+\`$PSScriptRoot\s+'(?<f>[^']+\.ps1)'")
        if (-not $m.Success) { continue }
        $checked++
        $target = Join-Path $f.DirectoryName $m.Groups['f'].Value
        if (-not (Test-Path $target)) { $missing += "$($f.Name):$n  -> $($m.Groups['f'].Value)" }
    }
}

Assert 'every dot-sourced helper path resolves' ($missing.Count -eq 0) ($missing -join ' | ')
Assert 'the scan found paths to check' ($checked -gt 0) 'regex matched nothing, so this check guards nothing'

Write-Host ''
if ($fail) { Write-Host "$fail assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host ("Format strings hold across {0} script(s); {1} helper path(s) resolve." -f $files.Count, $checked) -ForegroundColor Green
exit 0
