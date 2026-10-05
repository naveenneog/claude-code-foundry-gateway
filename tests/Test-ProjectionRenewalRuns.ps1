# The projection renewal job, run offline as the scheduled job runs it (ADR-0049, P94).
#
# Stages the sync package exactly as the image and the runner receive it, swaps the Azure SDK for
# stand-ins (tests/projection-fakes), and runs tests/projection-renewal-runs.test.mjs: scheduled
# runs, a snapshot population, admission, Graph and ARM refusals and business-unit changes, with a
# controlled clock. Also checks that the job orders business units as the PowerShell sync does.

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$fail = 0
function Assert($Label, [bool]$Condition, $Detail = '') {
    if ($Condition) { Write-Host "  [OK]   $Label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $Label$(if ($Detail) { " - $Detail" })" -ForegroundColor Red; $script:fail++ }
}

# The simulation's test count. A test that stops loading or is removed shows up as a lower count.
$expectedTests = 14

. (Join-Path $root 'scripts\ClaudeProjectionPackage.ps1')
. (Join-Path $root 'scripts\ClaudeBusinessUnit.ps1')
$work = Join-Path $root '.test-work\projection-runs'
Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
try {
    Write-Host ''
    Write-Host 'Projection renewal runs - scheduled runs reach admission offline' -ForegroundColor Cyan
    $package = New-ClaudeProjectionSyncPackage -Destination (Join-Path $work 'package') -Root $root
    foreach ($standIn in @(@('@azure/cosmos', 'cosmos.mjs'), @('@azure/identity', 'identity.mjs'))) {
        $dir = Join-Path $package ('sync\node_modules\' + ($standIn[0] -replace '/', '\'))
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot "projection-fakes\$($standIn[1])") -Destination (Join-Path $dir 'index.mjs')
        [IO.File]::WriteAllText((Join-Path $dir 'package.json'), "{`"name`":`"$($standIn[0])`",`"version`":`"0.0.0-stand-in`",`"type`":`"module`",`"exports`":`"./index.mjs`"}`n")
    }
    $env:PROJECTION_PACKAGE = $package
    $env:PROJECTION_FAKES = Join-Path $PSScriptRoot 'projection-fakes'
    $env:PROJECTION_REPO = $root
    $env:PROJECTION_TEST_WORK = Join-Path $work 'node'
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out = & node --test --test-reporter=tap (Join-Path $PSScriptRoot 'projection-renewal-runs.test.mjs') 2>&1 | Out-String
    $code = $LASTEXITCODE
    $ErrorActionPreference = $previous
    $tests = if ($out -match '(?m)^# tests (\d+)') { [int]$Matches[1] } else { -1 }
    $passed = if ($out -match '(?m)^# pass (\d+)') { [int]$Matches[1] } else { -1 }
    $failed = if ($out -match '(?m)^# fail (\d+)') { [int]$Matches[1] } else { -1 }
    foreach ($line in $out -split "`r?`n" | Where-Object { $_ -match '^(not )?ok \d+ - ' }) { Write-Host "    $line" }
    Assert "the simulation ran its $expectedTests tests" ($tests -eq $expectedTests) "tests $tests"
    Assert 'every simulated run behaved as the job must' ($code -eq 0 -and $failed -eq 0 -and $passed -eq $expectedTests) (($out -split "`r?`n" | Where-Object { $_ -match 'not ok|AssertionError|Error:|expected|actual' } | Select-Object -First 12) -join ' | ')

    Write-Host ''
    Write-Host 'Projection renewal runs - the job orders units as the PowerShell sync does' -ForegroundColor Cyan
    $cases = @(
        @{ Name = 'units only'; Registry = ',eng=Claude Engineering:1000,fin=Finance:5,'; Parents = ',,' }
        @{ Name = 'teams under units'; Registry = ',eng=G1:1,fin=G2:1,platform=G3:1,api=G4:1,ops=G5:1,'; Parents = ',platform=eng,api=eng,' }
        @{ Name = 'a team listed before its unit'; Registry = ',api=G4:1,eng=G1:1,platform=G3:1,'; Parents = ',api=eng,platform=eng,' }
        @{ Name = 'a group name with a colon'; Registry = ',fin=Finance: EMEA:7,eng=Eng:1,'; Parents = ',fin=eng,' }
        @{ Name = 'malformed entries'; Registry = ',=x:1,eng,nobudget=G,bad=G:1x,ok=G:7,'; Parents = ',=eng,orphan=,' }
        @{ Name = 'a cycle'; Registry = ',a=GA:1,b=GB:1,c=GC:1,'; Parents = ',a=b,b=a,' }
    @{ Name = 'a team id in another case in bu-parents'; Registry = ',eng=G:1,team=G2:1,'; Parents = ',Team=eng,' }
    @{ Name = 'a cycle through another case'; Registry = ',a=GA:1,b=GB:1,c=GC:1,'; Parents = ',a=B,b=a,' }
        @{ Name = 'three hundred units'; Registry = ',' + ((1..300 | ForEach-Object { "u$_=G$($_):1" }) -join ',') + ','; Parents = ',' + ((1..300 | Where-Object { $_ % 3 -eq 0 } | ForEach-Object { "u$_=u1" }) -join ',') + ',' }
    )
    $module = ([Uri](Join-Path $root 'sync\src\business-units.mjs')).AbsoluteUri
    $script = "import { readFileSync } from 'node:fs'; import { parseBuRegistry, parseBuParents, sortUnitsByDepth } from '$module'; const c = JSON.parse(readFileSync(process.argv[1], 'utf8')); console.log(sortUnitsByDepth(parseBuRegistry(c.registry), parseBuParents(c.parents)).map((u) => u.id + '=' + u.group).join(','));"
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    $casePath = Join-Path $work 'parity-case.json'
    foreach ($case in $cases) {
        $units = @(ConvertFrom-ClaudeBuRegistry $case.Registry 3>$null)
        $parents = ConvertFrom-ClaudeBuParents $case.Parents
        $powershell = @(Sort-ClaudeBuByDepth $units -Parents $parents | ForEach-Object { "$($_.Id)=$($_.Group)" }) -join ','
        [IO.File]::WriteAllText($casePath, (@{ registry = $case.Registry; parents = $case.Parents } | ConvertTo-Json -Compress))
        $node = (& node --input-type=module -e $script $casePath 2>&1 | Out-String).Trim()
        Assert "PowerShell and the job agree: $($case.Name)" ($powershell -ceq $node) "powershell=$powershell node=$node"
    }
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\PROJECTION_PACKAGE, Env:\PROJECTION_FAKES, Env:\PROJECTION_REPO, Env:\PROJECTION_TEST_WORK -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail) { Write-Host "$fail assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'Projection renewal runs hold.' -ForegroundColor Green
exit 0
