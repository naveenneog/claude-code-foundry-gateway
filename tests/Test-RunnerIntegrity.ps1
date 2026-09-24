# Test-All.ps1 cannot report success for a check that did not run.
#
# Found 2026-09-24. A terminating error travels up to the nearest try block,
# across script boundaries, and Test-All ran every check inside one
# try/finally with no catch. When one check stopped with an error - a temp
# file locked by a second run on the same machine - the try block ended,
# every later check silently never ran, and the summary still printed
# "All checks passed." with exit code 0. A packet gate passed in 57 seconds
# on nine of 32 checks.
#
# This copies Test-All.ps1 into a scratch folder beside stub checks, makes the
# stubs misbehave one way at a time, and reads what the copy reports. The last
# two cases put the old runner back and prove these assertions catch it.

$ErrorActionPreference = 'Stop'

$runner = Join-Path $PSScriptRoot 'Test-All.ps1'
$source = [IO.File]::ReadAllText($runner)

$fail = 0
function Assert($label, $condition, $detail = '') {
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $label$(if ($detail) { " - $detail" })" -ForegroundColor Red; $script:fail++ }
}

# The offline checks are the ones registered before the -IncludeAzure block.
$azureAt = $source.IndexOf('if ($IncludeAzure)')
$registered = @([regex]::Matches($source, "Invoke-Check\s+'([^']+)'\s+'([^']+\.ps1)'") |
    Where-Object { $azureAt -lt 0 -or $_.Index -lt $azureAt } |
    ForEach-Object { [pscustomobject]@{ Name = $_.Groups[1].Value; Script = $_.Groups[2].Value } })

Write-Host ''
Write-Host 'Test-All - every registered check runs, or the run fails' -ForegroundColor Cyan
Assert 'Test-All registers at least ten offline checks' ($registered.Count -ge 10) "found $($registered.Count)"
if ($registered.Count -lt 3) { Write-Host ''; Write-Host "$fail assertion(s) failed." -ForegroundColor Red; exit 1 }

# The check that aborted on 2026-09-24, or a stand-in if it is ever renamed.
$victim = $registered | Where-Object Script -eq 'Test-On-PS51.ps1' | Select-Object -First 1
if (-not $victim) { $victim = $registered[2] }
$other = $registered | Where-Object Script -ne $victim.Script | Select-Object -Last 1

$scratch = Join-Path ([IO.Path]::GetTempPath()) ('runner-integrity-' + [guid]::NewGuid().ToString('N'))
$testsDir = Join-Path $scratch 'tests'
New-Item -ItemType Directory -Path $testsDir, (Join-Path $scratch 'scripts') -Force | Out-Null
$marker = Join-Path $scratch 'ran.txt'
$locked = Join-Path $scratch 'locked.txt'

function Invoke-Scenario {
    param([string]$RunnerText, [hashtable]$Behaviour = @{}, [string[]]$Missing = @())
    Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
    Get-ChildItem -LiteralPath $testsDir -File | Remove-Item -Force
    [IO.File]::WriteAllText((Join-Path $testsDir 'Test-All.ps1'), $RunnerText)
    foreach ($c in $registered) {
        if ($Missing -contains $c.Script) { continue }
        $tail = if ($Behaviour.ContainsKey($c.Script)) { $Behaviour[$c.Script] } else { 'exit 0' }
        [IO.File]::WriteAllText((Join-Path $testsDir $c.Script), "Add-Content -LiteralPath '$marker' -Value '$($c.Script)'`r`n$tail`r`n")
    }
    $out = & pwsh -NoProfile -File (Join-Path $testsDir 'Test-All.ps1') 2>&1 | Out-String
    $code = $LASTEXITCODE
    $ran = if (Test-Path -LiteralPath $marker) { @(Get-Content -LiteralPath $marker) } else { @() }
    [pscustomobject]@{ Exit = $code; Output = $out; Ran = $ran }
}

# The incident's own error: Set-Content on a file another process holds.
$lockedWrite = "`$held = [IO.File]::Open('$locked', 'OpenOrCreate', 'ReadWrite', 'None')`r`n" +
    "try { 'y' | Set-Content -LiteralPath '$locked' -Encoding ASCII } finally { `$held.Dispose() }`r`nexit 0"
$all = $registered.Count
$victimFail = 'FAIL\s+' + [regex]::Escape($victim.Name)

try {
    $r = Invoke-Scenario -RunnerText $source
    Assert 'with every check passing, the run passes' ($r.Exit -eq 0) "exit $($r.Exit)"
    Assert 'with every check passing, every registered check ran' ($r.Ran.Count -eq $all) "$($r.Ran.Count) of $all"

    $r = Invoke-Scenario -RunnerText $source -Behaviour @{ $victim.Script = $lockedWrite }
    Assert 'a check stopped by a locked file fails the run' ($r.Exit -ne 0) "exit $($r.Exit)"
    Assert 'that check is reported as FAIL' ($r.Output -match $victimFail)
    Assert 'every check after it still runs' ($r.Ran.Count -eq $all) "$($r.Ran.Count) of $all"
    Assert 'the summary does not claim success' ($r.Output -notmatch 'All checks passed')

    $r = Invoke-Scenario -RunnerText $source -Behaviour @{ $victim.Script = "throw 'simulated abort'" }
    Assert 'a check that throws fails the run' ($r.Exit -ne 0) "exit $($r.Exit)"
    Assert 'a check that throws is reported as FAIL, and the rest run' (($r.Output -match $victimFail) -and $r.Ran.Count -eq $all) "$($r.Ran.Count) of $all"

    $r = Invoke-Scenario -RunnerText $source -Behaviour @{ $other.Script = 'exit 1' }
    Assert 'a check that exits 1 fails the run, and the rest run' (($r.Exit -ne 0) -and $r.Ran.Count -eq $all) "exit $($r.Exit), $($r.Ran.Count) of $all"

    $r = Invoke-Scenario -RunnerText $source -Missing @($other.Script)
    Assert 'a registered check whose script is missing fails the run' ($r.Exit -ne 0) "exit $($r.Exit)"
    Assert 'the missing script is named' ($r.Output -match ([regex]::Escape($other.Script) + ' not found'))

    # Mutation: take the per-check catch away. The completion guard must still fail the run.
    # A plain throw would end the whole script with exit 1 and hide a missing guard;
    # the locked-file error ends only the try statement, which is what the guard is for.
    $noCatch = $source -replace '(?m)^[ \t]*catch \{ Write-Host "  FAIL - the check stopped with an error.*$', '    finally { }'
    Assert 'mutation applied: per-check catch removed' ($noCatch -ne $source)
    $r = Invoke-Scenario -RunnerText $noCatch -Behaviour @{ $victim.Script = $lockedWrite }
    Assert 'without the catch, the completion guard still fails the run' ($r.Exit -ne 0) "exit $($r.Exit)"
    Assert 'and it says the run stopped before every check ran' ($r.Output -match 'stopped before every check ran')

    # Mutation: take the guard away as well. That is the runner as it was, and
    # the assertions above must be the ones that would have caught it.
    $asItWas = $noCatch -replace '(?m)^.*-not \$completed.*$', ''
    Assert 'mutation applied: completion guard removed' ($asItWas -ne $noCatch)
    $r = Invoke-Scenario -RunnerText $asItWas -Behaviour @{ $victim.Script = $lockedWrite }
    Assert 'the old runner is reproduced: exit 0 with checks never run' (($r.Exit -eq 0) -and $r.Ran.Count -lt $all) "exit $($r.Exit), $($r.Ran.Count) of $all ran"
}
finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail) { Write-Host "$fail assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'Test-All counts every check.' -ForegroundColor Green
exit 0
