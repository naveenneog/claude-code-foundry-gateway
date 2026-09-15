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

Write-Host ''
if ($fail) { Write-Host "$fail assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host ("Format strings hold across {0} script(s)." -f $files.Count) -ForegroundColor Green
exit 0
